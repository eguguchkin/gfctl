# Dev report: 1.1 каркас gfctl — диспетчер + lib/ + профильная таблица + models + гейты + диагностика

- Дата: 2026-11-17 · раунд разработки 1 (до отзыва тестера/ревьюера; найденные батареей дефекты исправлены в этом же проходе)

## What was done

Реализовано строго по task.md (Design + Test strategy), стиле 1:1 hfctl.

| файл | что внутри |
|---|---|
| `gfctl` (исполн.) | диспетчер: шапка USAGE-BEGIN/END со всей картой команд SPEC §3 (заглушки помечены «этап 1.2/3»), env-конфигурация (`GFCTL_IMAGE/DIR/MODELS/PORT/BIND/YES`; порт 8080 — D2), хелперы `log/warn/die/ask/isint` (тела из hfctl), `usage()` = sed между маркерами, source `profiles.sh → models.sh → commands.sh`, case-роутер: `models|doctor|status` → cmd_*; `--help|-h` → rc 0; 11 заглушек 1.2/этапа 3 → die rc 1 с указанием этапа; `""` → usage rc 1; `*` → stderr «неизвестная команда» + Команды + Профили rc 1 |
| `lib/profiles.sh` | таблица 3 профилей (9 полей `set\|ram_gate\|sessions\|context\|cache_ram\|cache_disk\|serve_extra\|probe_ladder\|описание` — литералы SPEC §5/task.md, `@DRAFT@`/`@MTP@`-токены), `PROFILE_LIST/PROFILE_DEFAULT`; функции `profile_field`, `resolve_profile` (single/multi/flash), `cur_profile` (читает `$STACK_DIR/.env`, 1.1 только читает), `ram_pool_gib_dec` (%.1f), `ram_gate_line` (формат DoD `27b-single: ≥56 GiB — есть 59.5: OK`, сравнение целыми GiB, rc 0 всегда), `models_dir_for` |
| `lib/models.sh` | сет-таблицы `set_27b` (2 записи) и `set_flash` (5 записей) с ПОЛНЫМИ 64-hex sha-пинами из task.md §models (не из FACTS — там обрезано/чужой список IQ4_XS); `weights_for`, `set_file_role`, `free_disk_gib` (stat -f, mkdir -p — единственная запись 1.1), `download_file` (SKIP по размеру → pre-flight «нужно X GiB (остаток), свободно Y» ДО трафика → `curl -sSL -C - --retry 4 --retry-delay 5 --connect-timeout 20 -o dest.part` ×3 попытки (sleep 15) → mv → sha256: PASS / MISMATCH → удалить dest+.part rc 1; сетевой отказ → .part остаётся), `inventory` (строка «файл \| пин B \| статус», sha пересчёт при совпавшем размере — OQ4, `.part`-хвосты), `set_total_bytes`, `set_stats` (present/total/missing по размерам, для status/sводки), `check_types` (агрегат по сету, КРАСНЫЙ при ≥1 красном ИЛИ ошибке формата, «нечего проверять» → rc 1) |
| `lib/commands.sh` | `cmd_models`: инвентарь обоих сетов + сводка по 3 профилям (N/M, докачать X GiB, свободно Y: OK/НЕДОСТАТУЧНО) rc 0; `download <сет|профиль> [--yes]` (согласие ask; не-TTY без --yes → авто-нет rc 1; `download_file` по каждому файлу сета); `--check-types [сет|профиль]` (дефолт — сет активного профиля); `resolve_set` (27b/flash напрямую, профиль → поле 1); `cmd_doctor` (rc 0 всегда, деградация `?`/WARN: ОС, /dev/kfd, renderD*, render-группа, memlock+limits.d/*gfctl*, linger, RAM-гейты ×3 через ram_gate_line, диск под оба сета, порт-проба loopback, gpu-lock через `podman ps` — WARN + D3); `cmd_status [--json]`: health = порт-проба («не запущен»/«отвечает»), rc 0 на мёртвом порте, человеко-строка `профиль: X \| health: … \| автозапуск: — (этап 1.2) \| веса N/M`, `--json` — фиксированная схема printf'ом (profile/stack/bind/port/health/route:null/autostart:null/version:null/gates×3/models{27b,flash} — ключи заморожены) |
| `tpl/python/gguf_type_check.py` | потоковый GGUF-парсер заголовка (stdlib: struct/sys): magic/version/n_tensors/n_kv → KV-skip (все типы значений: скаляры, string, массив 1 уровня; вложенный массив/неизвестный тип → format error) → tensor-infos (name, nd≤8, dims, type, offset); санити n_kv/n_tensors ≤ 1e6, бюджет метаданных 64 MiB; **RED-контракт числовой: {16,17,18,19,22,25,26} ∪ {t>29} ТОЛЬКО на `ffn_*`** (validated F3; прототипная NAME-таблица не переносилась — имена канонические ggml 0–29, только отображение); risky вне ffn → WARN + зелёный; rc 0/1/2 (2 доминирует — незапарсенный файл не даёт считать вердикт достоверным); RED-строки `RED: <file>: ffn blk.N.ffn_gate.weight = IQ2_S` |
| `tests/make_fixtures.py` | детерминированный генератор 10 мини-GGUF (struct.pack): ffn IQ2_S(22)/IQ4_XS(23)/Q4_K(12)/unknown(31), attn IQ2_XS(17) вне ffn, не-GGUF, обрезанный заголовок, вложенный KV-массив, массив 9e6×u64 (>64 MiB), n_kv=2e6 (>1e6) |
| `tests/fixtures/*.gguf` | 10 коммиченных бинарных ассетов (по ~100–200 B); `run_checks.sh` сверяет регенерацию с ними байт-в-байт (анти-дрейф) |
| `tests/run_checks.sh` | вся батарея одним вызовом (13 секций, ниже) |
| `install.sh` | каркас-бутстрап: отказ rc 1 вне дерева, `$GFCTL_DIR` (дефолт ~/gufo), cp gfctl + rm-rf/cp-a lib/tpl (повтор = обновление), models/cache/.env/маркеры не трогает, симлинк ~/.local/bin, PATH-WARN, финал «готово» |
| `tpl/bench/merge_sort_thinking_off.txt` | канон из hfctl, md5 проверен `253c7ac50857fe6d0e10fb0d2c5e35c0` ✓, не редактировался |
| `README.md` | quickstart (4 шага), таблица профилей, карта команд с пометками этапов, статус-заглушка этапа 4 |

Не создавались (по task.md): `lib/util.sh`, `lib/ui.sh` (хелперы живут в диспетчере, как в hfctl — потребности нет), `lib/serve.sh`, `lib/health.sh`, `tpl/systemd/` — 1.2.

## How it was checked internally

`bash tests/run_checks.sh` → **ИТОГО: PASS=93 FAIL=0**. Секции:

1. AGENTS internal checks: `bash -n gfctl lib/*.sh` ✓; `python3 -m py_compile tpl/python/*.py` ✓.
2. Диспетчер: bare → usage rc=1 ✓; `garbage` → rc=1 + «неизвестная команда» + Профили ✓; `--help` → rc 0 ✓; все 11 заглушек → rc=1 «1.2» ✓.
3. Фикстуры: регенерация байт-в-байт = коммиченным ассетам (10 шт) ✓.
4. Парсер: IQ2_S в ffn → rc1 КРАСНЫЙ ✓; IQ4_XS → rc0 ✓; Q4_K → rc0 ✓; unknown(31) в ffn → rc1 ✓; IQ2_XS вне ffn → rc0 + WARN-строка ✓; не-GGUF → rc2 ✓; обрезанные метаданные → rc2 ✓; вложенный KV-массив → rc2 ✓; >64 MiB бюджет → rc2 ✓; n_kv>1e6 → rc2 ✓.
5. check-types уровень gfctl: красный файл в `$GFCTL_MODELS` → rc1 + «КРАСНЫЙ» ✓; зелёный → rc0 + «зелёный» ✓; пустой сет → rc1 «нечего проверять» ✓; flash не скачан → rc1 ✓.
6. Профильная таблица: все 27 полей × 3 профиля = литералам task.md ✓; resolve_profile алиасы ✓; неизвестный профиль → rc1 ✓; формат ram_gate_line ✓; models_dir_for ✓.
7. Таблицы весов: set_27b/set_flash байт-в-байт = литералам task.md (cmp) ✓; контроль сумм: flash-сет 114 121 223 034 B (шарды 111 334 654 778 = SPEC §5 + MTP 2 786 568 256) ✓; 27b 15 677 391 456 B ✓; set_file_role ✓.
8. Инвентарь: пустой `GFCTL_MODELS` → 7×«НЕТ» + сводка rc 0 ✓; размер-OK+sha✗ → «перекачай» ✓; РАЗМЕР ≠ с фактом ✓; `.part`-хвост ✓.
9. download_file (file://, сеть не нужна): pre-flight «нужно 10240.0 GiB … свободно» → rc1 ДО трафика, без .part ✓; PASS + sha OK + байты совпали ✓; resume с .part → цельный файл ✓; SKIP ✓; SHA-MISMATCH → rc1, dest+.part удалены ✓.
10. `models download` в не-TTY → rc1 «авто-нет» (сеть не тронута) ✓.
11. doctor на этом хосте (без GPU/podman/loginctl, 31.3 GiB RAM): rc 0 ✓, ОС ✓, гейты ×2 в формате DoD ✓, flash-multi цифрами ✓, диск ×2 ✓, порт+gpu-lock ✓, без traceback/FATAL ✓ (честно печатает НЕДОСТАТУПЕН по всем гейтам — контейнер не целевая машина).
12. `GFCTL_PORT=8198 status --json` → rc 0, `python3 -m json.tool` парсит ✓; схема: health=«не запущен», route/autostart/version=null, gates 3 ключа, totals 2/5 ✓; человеко-строка одной строкой ✓.
13. install.sh: раскладка в tmp ✓ (включая bench-фикстуру), идемпотентный повтор = обновление ✓, вне дерева → rc 1 ✓.

Батарея поймала и я исправил 3 реальных дефекта кода (не теста): (а) busybox-awk `printf "%d"` переполняется на 32 битах → `set_total_bytes` на `%.0f` (работает и GNU, и busybox — dev-контейнер юзерленд busybox); (б) `compgen|head`/`sha256sum|awk`/`loginctl|cut` под `set -o pipefail` роняли doctor/inventory при отсутствии файлов/команд → `|| true` в захватах; (в) тест-ожидания (см. Known limitations п.4 о суммах).

Плюс ручные прогоны: `./gfctl doctor`, `./gfctl status --json | python3 -m json.tool`, `./gfctl models` на пустом каталоге — вывод глянут глазами (деградация корректная, JSON валиден).

## Not checked internally

- **Реальное скачивание по HTTPS** (HF, curl --retry/-C - на живых 14–49 GB файлах, сетевой отказ 3 попыток с sleep 15, HTTP-206 resume) — транспорт проверен через `file://`; реальный curl с HF — EXP приёмки 1.2 на evo (пины и resume-логика уже отработали в окнах IX/FX).
- **podman-ps ветка gpu-lock** (podman в dev-контейнере нет — doctor печатает `?`) и **loginctl-ветка linger** — проверить на приёмке (первая же `gfctl doctor` на evo).
- **GNU-stat ветки на целевой машине** — здесь busybox stat; `stat -f -c '%a %S'` и `stat -c %s` совместимы с GNU, но подтвердить на evo.
- **Поведение на реальных шардах** (49 GB, реальные ffn_-имена — `ffn_gate_exps` и т.п.) — этап 2: UD-IQ4_XS flash → КРАСНЫЙ (регресс-тест правила IX/FX).
- RAM-гейт flash-multi «НЕДОСТАТУПЕН на 60 GiB с цифрами» — на evo (здесь контейнер 31.3 GiB, формат проверен, вердикт проверится на приёмке).

## Known limitations / assumptions

1. **Статус «есть, размер OK, sha ✗»** добавлен к перечню статусов task.md — честное завершение «sha-статуса» (битый-по-sha файл не должен выглядеть годным); таблица DoD «файл/размер/sha-статус» предполагает этот случай.
2. **rc 2 доминирует над rc 1 в парсере** (ошибка формата ≥1 файла → rc 2 даже при красных в других): незапарсенный файл не даёт считать вердикт достоверным. На уровне gfctl оба отображаются в «КРАСНЫЙ… rc 1» (task.md: «1 красный/ошибка формата») — согласовано.
3. **curl без прогресс-метра** (`-sSL`, флаги буквально из task.md Design; PLAN.md упоминал «с прогрессом» — отклонение косметическое, для 49-GB шардов можно добавить `--progress-bar`, см. Out-of-scope).
4. **Расхождение агрегата 27b-сета**: сумма пин-размеров 15 677 391 456 B, а в FACTS F8 и строке «контроль сумм» task.md — 15 677 445 456 B (Δ = ровно 54 000). Пер-файловые пины — sha-verify PASS (первоисточник), агрегатная строка арифметически неверна; код считает от таблицы, тест ассертит посчитанную сумму. Оркестратору: дополнить/поправить F8 (совпадает с рекомендацией OQ №5).
5. **set_stats (status --json, сводка models) считает только размеры** — без sha (цена stat vs ~40 c sha на flash-сете); честный sha-статус — `gfctl models` (inventory). Отражено в комментариях.
6. **`free_disk_gib` делает mkdir -p** каталога сета — единственная запись 1.1 вне tests/ (санкционирована task.md); при сбое stat печатает «?», сравнения трактуют консервативно (НЕДОСТАТУЧНО).
7. **Код должен оставаться совместимым и с GNU, и с busybox-юзерлендом** (dev-контейнер — busybox awk/stat/diff; целевые машины — GNU): пойманный overflow `%d` — тому пример.
8. **Заглушки 1.2** отвечают die rc 1 с указанием этапа — грамматика CLI заморожена в 1.1, как предписано.
9. python 3.14 (контейнер) — синтаксис совместим вниз (struct/sys only).

## Out-of-scope proposals

- **Скрытые алиасы `up|down`** (SPEC §3/PLAN этап 1 упоминают) — в роутере task.md их нет, не делал; добавить в 1.2 вместе с cmd_up/cmd_down (одна строка case).
- **`curl --progress-bar`** для download_file (49-GB шарды без прогресса выглядят зависшими) — одна опция, решить на приёмке 1.2.
- **F8: дополнить полными пинами Q4_K_XL** (из dl_faex.sh) и пометить IQ4_XS-список как «не грузится, F3» + исправить агрегат 27b (п.4) — обновление FACTS, не код.
- **AGENTS.md «Что в репо»**: строка `tests/` (карта репо) — при коммите этапа (замечание task.md оркестратору).
- **gitignore**: `__pycache__/` (py_compile оставляет) — добавить при коммите этапа.
