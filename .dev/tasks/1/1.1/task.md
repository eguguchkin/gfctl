# Task: 1.1 каркас gfctl — диспетчер + lib/ + профильная таблица + models + гейты + диагностика   Design: architect

## Scope and DoD

Цель — по brief.md: на чистом `/workspace/gfctl/` работает CLI `gfctl`, в котором
функционируют ТОЛЬКО read-only/подготовительные команды: bare/garbage → usage rc=1,
`models` (инвентарь / `download <сет>` / `--check-types`), `doctor`, `status [--json]`.

DoD (из brief, без изменений):
1. Диспетчер: `gfctl` → usage rc=1; `gfctl <garbage>` → rc=1 со списком команд;
   `--help` → usage rc=0; dispatch по модулям.
2. Профильная таблица: 3 профиля, константы байт-в-байт = SPEC §5 + AGENT-CONFIGS пп.3–4.
3. `gfctl models`: инвентарь (файл/размер/sha-статус/свободно); `download <сет>` —
   цифры до трафика, curl resume, sha-verify после.
4. `gfctl models --check-types`: красный на IQ2_S/IQ3_XXS/неизвестных в ffn_*;
   зелёный на pure-IQ4_XS (27B) и Q4_K_XL (flash). Проверка — синтетическими
   мини-GGUF, без реальных весов.
5. `gfctl doctor`: ОС, /dev/kfd, render-группа, memlock, linger, RAM-гейты всех
   профилей цифрами, диск под веса, порт 8080, gpu-lock WARN.
6. `gfctl status --json` — валидный JSON при мёртвом сервере.
7. Internal checks AGENTS.md — зелёные.

**Вне scope (1.2 / этап 3):** serve-юниты и их tpl, install/use/on/off/uninstall,
logs, smoke, bench, watch, cache, agent-check, probe-подбор контекста, реальные
скачивания/приёмка на evo (EXP 1.2).

## Design

### Файловая структура (всё новое; репо сейчас пуст кроме AGENTS.md и .dev/)

```
gfctl                          # диспетчер (исполняемый)
install.sh                     # bootstrap-каркас (полное поведение — приёмка 1.2)
lib/profiles.sh                # таблица профилей + resolve + RAM-гейт-строки
lib/models.sh                  # таблица весов (сеты) + download + check-types
lib/commands.sh                # cmd_models / cmd_doctor / cmd_status
tpl/python/gguf_type_check.py  # GGUF-header парсер типов (python3 stdlib)
tpl/bench/merge_sort_thinking_off.txt  # канон фикстуры, байт-в-байт из hfctl (md5 253c7ac50857fe6d0e10fb0d2c5e35c0 — F12)
tests/make_fixtures.py         # генератор синтетических мини-GGUF (struct.pack)
tests/run_checks.sh            # вся internal-check батарея одним вызовом
```

`lib/serve.sh`, `lib/autostart.sh`, `lib/health.sh`, `tpl/systemd/` — НЕ создавать
(1.2); модули добавляются по мере команд, диспетчер расширяет source-список.
Примечание оркестратору: `tests/` — новая строка в карте репо (AGENTS.md «Что в
репо» — обновить при коммите этапа).

### Диспетчер `gfctl` (механика 1:1 из hfctl/hfctl)

- `set -euo pipefail`; шапка `# === USAGE-BEGIN === … USAGE-END ===` с полным
  списком команд SPEC §3 (usage() = sed между маркерами, как в hfctl).
- env-конфигурация (env переопределяет): `IMAGE="${GFCTL_IMAGE:-ghcr.io/gufo-org/toolboxes/gufo-runtime:latest}"`,
  `STACK_DIR="${GFCTL_DIR:-$HOME/gufo}"`, `MODELS_BASE="${GFCTL_MODELS:-$STACK_DIR/models}"`,
  `PORT="${GFCTL_PORT:-8080}"` (D2), `BIND="${GFCTL_BIND:-0.0.0.0}"`,
  `ASSUME_YES="${GFCTL_YES:-}"`, `SELF/LIB_DIR/TPL_DIR` (дерево рядом с диспетчером).
- хелперы в диспетчере (не в lib): `log/warn/die/ask/isint` — тела из hfctl.
- source в фиксированном порядке: `profiles.sh → models.sh → commands.sh`.
- роутер — верхнеуровневый `case "$cmd"`:
  - `models|doctor|status` → cmd_* из commands.sh;
  - `--help|-h` → usage, rc 0;
  - `install|use|logs|watch|on|off|uninstall|bench|smoke|cache|agent-check` →
    `die "команда появится в сабстэдже 1.2 / этапе 3"` rc=1 (грамматика CLI
    финальная уже в 1.1; 1.2 только наполняет cmd_*);
  - `""` → usage, exit 1; `*` → stderr «неизвестная команда …» + список + Профили: $PROFILE_LIST, exit 1.

### `lib/profiles.sh`

Таблица (indirect `${!name}` как в hfctl). Формат записи — 9 полей через `|`:

```
# set|ram_gate_gib|sessions|context|cache_ram_bytes|cache_disk_bytes|serve_extra|probe_ladder|описание
profile_27b_single="27b|56|1|262144|12884901888|68719476736|--speculative dflash2 --dflash-model @DRAFT@|-|solo DFlash2 (максимум соло-скорости)"
profile_27b_multi="27b|56|2|163840|4294967296|68719476736|--speculative dflash2 --dflash-model @DRAFT@|196608 163840 131072|мульти DFlash2 (probe-лестница, D5)"
profile_flash_multi="flash|110|2|131072|4294967296|68719476736|--speculative mtp --mtp-model @MTP@|262144 229376 196608 163840 131072|мульти MTP (максимальные контексты, floor 131072 проверен FX)"
PROFILE_LIST="27b-single 27b-multi flash-multi"; PROFILE_DEFAULT=27b-single
```

- `context` = текущий канон (single — константа 262144; мульти — значение до
  первого probe: проверенные точки 163840 / 131072); `probe_ladder` — вход
  probe'а 1.2 (`-` = probe нет). `@DRAFT@`/`@MTP@` — токены ролей, 1.2 заменяет
  контейнерным путём `/models/<файл>` (маунт models:ro); `--model` 1.2 строит из
  файла с ролью `main` сета.
- `27b-multi` cache-disk 64 GiB — решение (SPEC §5 поле не задаёт; выровнено по
  остальным профилям, см. Open questions №1).
- Функции (контракт-стиль hfctl: Назначение/Побочные эффекты/Ограничения/@param/@returns/@stdout):
  - `profile_field <prof> <n>` → stdout поля; rc 1 неизвестный профиль.
  - `resolve_profile <алиас>` → канон (`single→27b-single`, `multi→27b-multi`,
    `flash→flash-multi`, каноны как есть); rc 1 иначе.
  - `cur_profile` → `GFCTL_PROFILE` из `$STACK_DIR/.env` (`grep '^GFCTL_PROFILE='`),
    иначе `PROFILE_DEFAULT`. Файл .env в 1.1 не пишется — только читается.
  - `ram_pool_gib_dec` → MemTotal /1048576, `%.1f` (evo ≈ `59.5`, F14).
  - `ram_gate_line <prof>` → строка вердикта, формат из DoD doctor:
    `27b-single: ≥56 GiB — есть 59.5: OK` / `flash-multi: ≥110 GiB — есть 59.5: НЕДОСТАТУПЕН`.
    Сравнение целыми GiB (floor), печать have с 1 знаком. rc 0 всегда (строка —
    не блокировка; блокирующий гейт — обёртка в 1.2).
  - `models_dir_for <set>` → `$MODELS_BASE/<set>`.

### `lib/models.sh` — таблица весов (пины, F4/F8 + dl-скрипты окон)

Формат: `filename|size_bytes|sha256|url|role`, role ∈ main|draft|mtp. Пины полные
(F8 цитирует их обрезанно; полные значения — из dl_evo.sh / dl_faex.sh / ix_dl2.sh,
sha-verify PASS в окнах IX/FX — см. Open questions №5):

```
set_27b="qwen3.8-27b-IQ4_XS-pure.gguf|14534384640|ea5a3c45d407f9b9e5d2c0d647f0ea600f486f6b86b92b56d0823ba073dae675|https://huggingface.co/jpetrina/Qwen3.8-27B-IQ4_XS-pure-GGUF/resolve/main/qwen3.8-27b-IQ4_XS-pure.gguf|main
Qwen3.8-27B-DFlash2-Q4_K_M.gguf|1143006816|1a25c56858e1ebe93f2718ac1d49d1151f9323325c1bbfd6209370f4db131ebd|https://huggingface.co/z-lab/Qwen3.8-27B-DFlash2-GGUF/resolve/2d9571f8ce46e151f61c6499c99dee6079e1d610/Qwen3.8-27B-DFlash2-Q4_K_M.gguf|draft"
set_flash="Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf|10946618|acc44040f74d0e55fb89c3967056cce5dbda1bcc52e909c3ba6fc72b5e9c0858|https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf|main
Qwen3.8-Flash-Next-UD-Q4_K_XL-00002-of-00004.gguf|49720539552|45792ae869072d8229384c51c7c73dd959e191505252b41dd71852d9746f5ce4|https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00002-of-00004.gguf|main
Qwen3.8-Flash-Next-UD-Q4_K_XL-00003-of-00004.gguf|32803030176|8c76e79d444b16a663d9c8db54e585ed3b1da13eebd2619c37b0c355da803c82|https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00003-of-00004.gguf|main
Qwen3.8-Flash-Next-UD-Q4_K_XL-00004-of-00004.gguf|28800138432|5de8b5dbf89409acc39468decafd4a4a95b13c29d88a14b0356107897829ec36|https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00004-of-00004.gguf|main
mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf|2786568256|5ff54097406a905cf3a724c709124ceb0e3e10235ee862298969e91c96fa96e6|https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf|mtp"
```

(Контроль сумм: flash шарды = 111 334 654 778 B = 111.3 GB ✓ SPEC §5; 27b сет =
15 677 391 456 B (сумма пинов; исправлено оркестратором 2026-11-17 по
замечанию dev-report п.4). z-lab — пин на коммит; unsloth/jpetrina — `resolve/main`,
целостность ловит sha256. `mmproj` не входит — SPEC §5 запрет.)

Функции:
- `weights_for <set>` → построчно записи сета (rc 1 — неизвестный сет).
- `set_file_role <set> <role>` → filename записи с этой ролью (для @DRAFT@/@MTP@ в 1.2).
- `free_disk_gib <dir>` → stat -f, `%.1f`; dir создаётся при отсутствии (mkdir -p —
  единственная запись 1.1 вне tests/).
- `download_file <url> <dest> <size> <sha>` — единица работы download:
  размер совпал → `SKIP`, rc 0; иначе pre-flight «нужно X GiB (остаток), свободно Y
  GiB» (не хватает → rc 1 ДО трафика); `curl -sSL -C - --retry 4 --retry-delay 5
  --connect-timeout 20 -o <dest>.part` ×3 попытки (sleep 15, паттерн dl-скриптов);
  успех → `mv` поверх dest → sha256sum: OK → `PASS`, rc 0; MISMATCH → **удалить
  dest и dest.part**, rc 1 «перекачай download» (битый файл не должен выглядеть
  скачанным). Существующий `.part` от прошлой сессии подхватывается `-C -` (resume);
  несовместимый .part проявит себя как SHA-MISMATCH → удаление (само-восстановление).
  Сетевой отказ 3 попыток → rc 1, .part остаётся (докачка в следующий запуск).
- `inventory <set>` → построчно `файл | size-пин B | статус` где статус ∈
  `есть, размер OK, sha OK` / `есть, РАЗМЕР ≠ (факт N)` / `НЕТ` (+ строка
  «незавершённый .part: N GiB» при наличии); sha пересчитывается всегда при
  совпавшем размере (честный статус, stateless; ~10 с на 27b, ~40 c на flash —
  Open questions №4).
- `check_types <set>` → для каждого `*.gguf` сета: `python3 "$TPL_DIR/python/gguf_type_check.py" <файл>`;
  вердикт СЕТА = красный, если ≥1 файл красный; файл без ffn_*-тензоров — зелёный.
  Финал: `КРАСНЫЙ — не загрузится (FFN IQ2_S/IQ3_XXS/неизвестные; SPEC §5)` /
  `зелёный`; rc: 0 зелёный, 1 красный/ошибка формата. Веса не скачаны → rc 1 «нечего проверять».

### `tpl/python/gguf_type_check.py` (python3 stdlib; контракт)

- CLI: `gguf_type_check.py FILE...`; на каждый файл строка вердикта.
- Парсинг ТОЛЬКО заголовка (потоково, шарды 49 GB не читаются): magic `GGUF` →
  version u32 → n_tensors u64 → n_kv u64 → KV-пары (string: u64 len+bytes; skip
  значений по типу: скаляры, type 8 = string, type 9 = массив 1 уровня, вложенный
  массив/неизвестный тип → format error) → tensor-infos (name string, nd u32
  (nd>8 → format error), dims u64×nd, type u32, offset u64).
- Санити: n_kv, n_tensors ≤ 1 000 000; суммарный объём метаданных > 64 MiB →
  format error (trap из brief).
- **Контракт красных типов (числовой — validated F3):** RED = {16,17,18,19,22,25,26} ∪
  {t>29}. Красный вердикт файла — если ЛЮБОЙ тензор с `ffn_` в имени имеет RED-тип;
  risky-типы вне ffn_* → информационная строка WARN, вердикт зелёный.
- Таблица имён — канонический ggml enum 0–29 (0 F32, 1 F16, 2 Q4_0, 3 Q4_1, 6 Q5_0,
  7 Q5_1, 8 Q8_0, 9 Q8_1, 10 Q2_K, 11 Q3_K, 12 Q4_K, 13 Q5_K, 14 Q6_K, 15 Q8_K,
  16 IQ2_XXS, 17 IQ2_XS, 18 IQ2_S, 19 IQ3_XXS, 20 IQ1_S, 21 IQ4_NL, 22 IQ3_S,
  23 IQ3_M, 24 IQ4_XS, 25 IQ1_M, 26 BF16, 27–29 legacy-репаки), t>29 →
  `unknown(<t>)`. Имена — только отображение; контракт — числа. ВАЖНО: прототип
  `llm-lab/.local-analysis/dl/gguf_type_check.py` предсказывает отказ верно, но его
  NAME-таблица для 18–28 не канонична — переносим ЧИСЛОВОЙ RISKY-набор {16,17,18,19,22,25,26}
  (совпадает с инструкцией: IQ2_S=18, IQ3_XXS=19 в FFN), таблицу имён берём каноническую.
- Не-GGUF (магия ≠ GGUF) → строка `<file>: не GGUF`, format error.
- exit: 0 — все файлы зелёные; 1 — есть красный; 2 — format/IO ошибка (хотя бы
  одного файла). Красные строки вида `RED: <file>: ffn blk.N.ffn_gate.weight = IQ2_XS`.

### `lib/commands.sh`

- `cmd_models "$@"`: без аргументов → инвентарь обоих сетов + сводка «по профилям»
  (для каждого профиля: сет N/M файлов, докачать X GiB, свободно Y: OK/НЕДОСТАТОЧНО,
  rc 0); `download <сет|профиль>` (27b|flash напрямую, иначе resolve_profile → сет;
  согласие через ask — SPEC «веса качаются только после согласия»; не-TTY без
  `--yes` → авто-нет rc 1) → download_file по каждому отсутствующему/битому файлу;
  `--check-types [сет|профиль]` (дефолт — сет активного профиля) → check_types.
  Неизвестный аргумент → die со списком.
- `cmd_doctor` (rc 0 всегда, read-only; нет команды/устройства → значение `?`,
  не краш): ОС (`PRETTY_NAME` из /etc/os-release) → /dev/kfd + /dev/dri/renderD* →
  render-группа (`id -nG`) → memlock (`ulimit -l` + наличие limits.d/*gfctl*, WARN
  если не unlimited) → linger (`loginctl show-user "$USER" -p Linger`) → **RAM-гейты
  всех 3 профилей** (`ram_gate_line` ×3) → диск под веса (обои сета: нужно X GiB —
  свободно Y: OK/НЕДОСТАТОЧНО) → порт (bash `/dev/tcp/127.0.0.1:$PORT`: не
  отвечает = свободен; отвечает = «что-то слушает») → gpu-lock (`podman ps
  --format '{{.Names}}'` непуст → WARN «GPU может быть занят: <имена>; переключение
  руками — D3»).
- `cmd_status [--json]`: порт-проба как в doctor; health = «не запущен» | «отвечает»;
  роут НЕ парсится (1.2/этап 3). rc 0 и на мёртвом порте (честный отчёт).
  Человекочитаемо: `профиль: X | health: не запущен | автозапуск: — (этап 1.2) |
  веса <сет>: N/M`. `--json` — printf'ом фиксированная схема (без tpl-python):
  `{"profile":…,"stack":"не установлен","bind":…,"port":…,"health":"не запущен",
  "route":null,"autostart":null,"version":null,"gates":{3 профиля: OK|НЕДОСТАТУПЕН},
  "models":{"27b":{"present":N,"total":2,"complete":bool},"flash":{…,"total":5}}}`.
  Ключи замораживаются с 1.1, 1.2 только наполняет route/version.

### `install.sh` (каркас; приёмка — 1.2)

`set -euo pipefail`; рядом со скриптом есть `gfctl` и `lib/` — иначе отказ rc 1
(«запуск вне дерева», SPEC §2); `DEST="${GFCTL_DIR:-$HOME/gufo}"`; `cp -f gfctl`
→ DEST; замена `lib/ tpl/` целиком (`rm -rf` + `cp -a` — повтор = обновление,
SPEC §2); `models/ cache/ .env` и маркеры НЕ трогаются; `mkdir -p ~/.local/bin` +
`ln -sfn` симлинк; PATH-проверка (нет `~/.local/bin` в PATH → WARN + подсказка);
финал «готово — проверь: gfctl doctor».

## Test strategy

Все проверки — локальные, без ssh/podman/сети HF (hygiene). Батарея =
`bash tests/run_checks.sh` (внутри: генерация фикстур в tmp через
tests/make_fixtures.py, затем пункты ниже).

| DoD-пункт | internal check | external (что доказать потом) |
|---|---|---|
| 1 диспетчер | `bash -n gfctl lib/*.sh`; `./gfctl` → rc 1 + usage; `./gfctl garbage` → rc 1 + «Команды: …» + Профили; `./gfctl --help` → rc 0; `./gfctl install` → rc 1 «1.2» | — |
| 2 профильная таблица | в run_checks.sh: source lib/profiles.sh, assert всех 9 полей × 3 профилей + обеих set-таблиц (size/sha/url) против литералов этого task.md | приёмка 1.2: сервер поднялся ровно с этими флагами (роут dflash2 sessions 1 ctx 262144) |
| 3 models inventory/download | `GFCTL_MODELS=<tmp>` ./gfctl models: пустой dir → все НЕТ + сводка, rc 0; подложенный файл с верным размером → sha OK; неверный размер → РАЗМЕР ≠. download_file: python3 -m http.server на localhost → PASS; обрыв .part → resume → PASS; кривой sha → файл+.part удалены, rc 1; pre-flight «нужно/свободно» в stdout | реальный curl c HF + объёмы — EXP на evo в 1.2 |
| 4 check-types | фикстуры make_fixtures.py (мини-заголовки GGUF): ffn-тензор type 18 (IQ2_S) → rc 1 RED; type 24 (IQ4_XS) → rc 0; type 12 (Q4_K) → rc 0; type 31 (unknown>29) в ffn → rc 1; risky вне ffn (attn type 17) → rc 0 + WARN-строка; не-GGUF → rc 2; усечённый заголовок (n_kv завышен) → rc 2. Уровень gfctl: `GFCTL_MODELS=<tmp c красным файлом> ./gfctl models --check-types` → rc 1 + «КРАСНЫЙ» | этап 2: реальные UD-IQ4_XS шарды flash → КРАСНЫЙ (регресс правила IX/FX) |
| 5 doctor | `./gfctl doctor` в dev-контейнере (без GPU/podman): rc 0; строки RAM-гейтов ×3 в формате `≥N GiB — есть X.X: …`; отсутствующие подсистемы → `?`/WARN, без traceback | EXP на evo: /dev/kfd OK, render OK, flash-multi НЕДОСТАТУПЕН с цифрами 59.5 vs 110 |
| 6 status --json | `./gfctl status --json` на мёртвом 8080 → `python3 -m json.tool` парсит; `health == "не запущен"`, `route == null`; без --json — одна строка | 1.2: живой сервер — route/version заполняются |
| 7 internal checks | весь список AGENTS.md («Internal checks») внутри run_checks.sh, зелёный одним вызовом | — |

## Risks and rollback

- **Пины весов**: транскрибированы в task.md из dl-скриптов окон (полные, sha-verify
  PASS); риск опечатки при переносе в код гасится assert-пунктом теста 2 (один
  источник литералов — этот файл). F8 как источник неполон (обрезан, и flash-строки
  там от списка IQ4_XS) — см. Open questions №5.
- **HF `resolve/main` мутирует** (unsloth/jpetrina) — sha256-пин ловит дрейф,
  SHA-MISMATCH = отказ; draft запинован на коммит.
- **Окружения без podman/loginctl/render** (dev-контейнер, «голая» машина до
  host_prep) — doctor обязан деградировать в `?`/WARN, не падать; каждый чек —
  с guard'ом на наличие команды/файла.
- **Откат**: сабстэдж = один коммит, `git revert`; хост-состояние не затрагивается
  (все команды 1.1 read-only; install.sh пишет в ~/gufo только при явном запуске и
  на dev-хосте не запускается).

## References

- SPEC.md §2 (~/gufo/, install.sh-семантика), §3 (строки models/doctor/status),
  §4 (статус-строка), §5 (профили, константы, запреты, RAM-гейты 56/110), §8
  (--dflash-model/--mtp-model), §9 (gpu-lock).
- FACTS: F1 (инсталлятора в образе нет → качает gfctl), F3 (UD-* отказы — контракт
  RED-типов), F4 (полный sha 27B main), F8 (пины — с оговоркой, см. OQ №5), F9
  (podman-флаги — поле serve_extra, потребление 1.2), F12 (фикстура md5 253c7ac5),
  F13 (лестница 27b-multi от 196608), F14 (RAM-пулы машин — гейты).
- DECISIONS: D1 (локальная дистрибуция → install.sh из дерева), D2 (порт 8080),
  D3 (gpu-lock только WARN), D4 (flash только мульти), D5 (27b-multi 163840).
- Пины-первоисточники (sha-verify PASS окон IX/FX): `llm-lab/.local-analysis/dl/dl_evo.sh`,
  `dl_faex.sh`, `ix_dl2.sh`; прототип парсера: `llm-lab/.local-analysis/dl/gguf_type_check.py`.

## Open questions

Блокирующих нет — код можно начинать. Ниже ветки, которые SPEC оставил открытыми,
с принятыми в Design решениями (поменять = дёшево, оркестратор может veto):

1. **cache-disk для `27b-multi`** (SPEC §5 не задаёт). Принято: 68719476736 (64 GiB,
   как во всех профилях — SPEC §1 «cache-disk по умолчанию»). Альтернатива: без
   дискового тира. Рекомендация: оставить 64 GiB.
2. **check-types на шарде без ffn_*-тензоров** (00001). Принято: файл зелёный,
   вердикт агрегируется по сету (движок грузит все шарды — отказ любого = отказ
   сета). Подтвердить на этапе 2 реальными шардах.
3. **download при частично скачанном `.part`**. Принято: curl `-C -` resume;
   итоговый SHA-MISMATCH → удалить файл и `.part`, rc 1 (битый файл не должен
   числиться скачанным). Альтернатива: оставлять для диагностики — отклонена.
4. **sha в инвентаре `models`**: пересчитывать всегда (честный sha-статус, ~40 c
   на flash-сете на NVMe) vs только размер. Принято «всегда»; пересмотреть при
   приёмке, если будет больно.
5. **FACTS F8 неполон** (пины с «…»; flash-строки — размеры/sha списка UD-IQ4_XS
   93.6 GB при заголовке UD-Q4_K_XL 111.3 GB = SPEC §5). Рекомендация оркестратору:
   дополнить F8 полными Q4_K_XL пинами (первоисточник dl_faex.sh, PASS-логи) и
   пометить IQ4_XS-список как «известно-не-грузится (F3), для download не пиновать».
   Профильная таблица в этом task.md уже несёт правильные полные пины — коду это
   не мешает.
