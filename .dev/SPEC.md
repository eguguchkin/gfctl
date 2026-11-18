# Спецификация UX / CLI: gfctl (установка и управление gufo-сервером)

Статус: **DRAFT v2 — к согласованию** (2026-11-17; решения пользователя:
дистрибуция локальная, порт 8080 дефолт, takeover не нужен, flash — только
мульти с максимизацией контекстов). Основание: исследование движков
(окна FX/HX/HX-A/CX, отчёт `llm-lab/flash-next-engines.md`) и свод
конфигураций `llm-lab/.dev/AGENT-CONFIGS.md`. Целевые машины: che-evo
(60 GiB) и che-FAEX1 (128 GB); формат зеркалирует hfctl SPEC.

## 1 · Цели и принципы

1. Путь новичка — **4 команды от клонирования до работающего gufo-сервера
   с автозапуском** (`git clone`/копия → `./install.sh` → `gfctl install` →
   проверка).
2. **Три именованных профиля**: `27b-single`, `27b-multi`, `flash-multi`
   (flash-соло удалён решением пользователя 2026-11-17 — flash используется
   только под параллельные агентов с максимальными контекстами).
   Переключение — одна команда, действует сразу и после ребута.
3. Никаких сюрпризов: RAM/дисковые гейты отсекают несовместимое железо
   **до** трафика, с цифрами; веса качаются только после согласия.
4. Агентский сценарий — первоклассный: профили несут cache-disk по
   умолчанию, `gfctl agent-check` проверяет готовность и регрессии.
5. Официальный контейнер `ghcr.io/gufo-org/toolboxes/gufo-runtime` —
   никаких форков движка; gfctl скачивает веса (инсталлятора в образе
   релиза нет), генерирует systemd-юниты и администрирует.
6. **Максимальные контексты в мульти**: профиль `flash-multi` и
   `27b-multi` не фиксируют контекст константой — gfctl **подбирает
   максимум** (probe-лестница) так, чтобы на RAM-кэш остались зарезервированные
   гигабайты; найденное значение кэшируется в профиле.

## 2 · Дистрибуция и первичная установка

**Дистрибуция — локальная** (публикация на GitHub не планируется):
перенос каталога репо на целевую машину (`rsync -a` / `scp -r` / git-remote
на LAN), затем:

```bash
cd gfctl
./install.sh              # дерево gfctl в ~/gufo/ + симлинк ~/.local/bin/gfctl
gfctl install             # preflight → веса → юниты → старт → health → smoke → автозапуск
```

- `install.sh` — только bootstrap (запуск вне дерева — отказ rc 1);
  повтор = обновление (перезаписывает ровно `gfctl`+`lib/`+`tpl/`).
- Вся инсталляция в `~/gufo/`: диспетчер + `lib/` + `tpl/`, модели
  `~/gufo/models/<сет>/`, кэш `~/gufo/cache/<профиль>/`, маркер
  `.gfctl-stopped`, `.env` (`GFCTL_PROFILE` — канон профиля), логи.
- Вне каталога: systemd-user юниты `gfctl-serve.service` (oneshot,
  ExecStart=`gfctl _boot`) + `gfctl-watchdog.service/.timer` (1 мин) —
  отдельного boot-юнита нет (решение 1.2: serve-юнит сам поднимает канон),
  образ ghcr,
  `limits.d/99-gfctl-memlock.conf`, группа render, linger.

## 3 · Карта команд

| Команда | Действие |
|---|---|
| `gfctl install [--profile P] [--port N] [--bind A] [--models-dir D] [--no-autostart]` | Preflight → скачивание весов профиля (размер + sha256 до и после) → **probe-подбор контекста** (для мульти-профилей; при уже зафиксированном каноне пары или на healthy-повторе — пропускается: идемпотентность; 4.2) → генерация юнитов → старт → health → smoke → **автозапуск** (если не `--no-autostart`). Идемпотентен. Preflight memlock-гейт — по порогу достаточности 8388608 kB (4.1-F2, не по «unlimited»): ml ≥ порога → limits.d-файл перезаписан + WARN, install продолжается; ml < порога или нечитаемый → файл + WARN «перелогинься» + exit 42 |
| `gfctl use 27b-single\|27b-multi\|flash-multi [--sessions N] [--context N] [--no-probe]` | Проверка гейтов → ленивый добор весов → **probe-подбор** (если не `--no-probe`) → перегенерация юнита → recreate → health → smoke. Канон профиля заменяется |
| `gfctl status [--json]` | Профиль, health, **фактический роут** (speculative=mtp/dflash2, sessions, context — из лога `load_completed`), состояние кэша (ram/disk), автозапуск, версия образа |
| `gfctl logs [-f] [N]` | Логи контейнера |
| `gfctl watch [--interval N]` | Живой дашборд (TTY — TUI, не-TTY — стрим): `/metrics` (`llamacpp:*`), host `/sys`/`/proc` (RAM, hwmon-температуры), `podman logs -f`. Блоки: «Движок» (model, uptime, cache tok, draft-приём), «Скорость» (predict_per_second последнего запроса), «Память», «Логи». Клавиши `q`/`+`/`-`/`p` |
| `gfctl on` / `off` | Автозапуск вкл (юниты+linger) / стоп + снятие (linger off). Файлы/веса/образ целы |
| `gfctl bench` | Фикстура merge_sort (`253c7ac5`) ×3 по HTTP: wall, decode tok/s |
| `gfctl smoke` | health + 3 запроса (код/проза/математика) + роут из лога (`speculative=dflash2\|mtp`) |
| `gfctl agent-check` | **Агентская самопроверка** (см. §7): сессия 15 ходов, follow-up-лестница 5k/25k/100k, [док][вопрос], рестарт-restore — wall-цифры + сравнение с референсами (WARN при регрессии >25%) |
| `gfctl cache [--verify]` | Сводка кэша из логов (configured/skipped/evicted) + `/metrics` cached_total; `--verify` — контрольный follow-up + рестарт-проба |
| `gfctl doctor` | Диагностика без записи: ОС, /dev/kfd, render-группа, memlock, linger, RAM-гейты всех профилей (цифрами), диск под веса, порт, **gpu-lock** (кто держит /dev/kfd — предупреждение о hfctl-проде) |
| `gfctl models [--check-types]` | Скачано vs требуется по профилям, sha-статус, свободное место; `--check-types [сет|профиль]` — pre-check GGUF-типов (низкобитные IQ — IQ1_S/IQ1_M/IQ2_*/IQ3_XXS —, BF16/MXFP4/неизвестные в FFN → КРАСНЫЙ «не загрузится»; display-имена — канон ggml enum, BF16=30 — F20, 4.2; 41/42=Q1_0/Q2_0 — форк движка (ggml.h:431–432, 4.3); лишние аргументы → die) |
| `gfctl uninstall [--purge-models] [--purge-image]` | Слоёная зачистка: контейнер, юниты, `~/gufo` (модели щадятся по умолчанию); `limits.d/99-gfctl-memlock.conf` НЕ трогается (4.1-F2: безвреден, переживает uninstall ради будущих relogin) |

## 4 · Модель состояний

1. **Профиль** (`install --profile` / `use`) — канон в `~/gufo/.env`
   (`GFCTL_PROFILE` + зафиксированный sessions/context); boot-юнит и
   вотчдог поднимают его, ничего не пересчитывая.
2. **Вкл/выкл** (`on`/`off`) — autostart + linger; `off` ставит маркер
   `.gfctl-stopped`.

`gfctl status` первой строкой: `профиль: 27b-single | health: ok |
автозапуск: вкл | роут: dflash2, sessions 1, ctx 262144 | кэш: … |
веса 27b: 2/2` (синхронизировано с реализацией 1.2, 2026-11-17).

## 5 · Профили (числа — из AGENT-CONFIGS; расхождение без нового окна запрещено)

### `27b-single` ⭐ default (машина ≥56 GiB: evo 60 / FAEX 128)
- Веса: jpetrina `qwen3.8-27b-IQ4_XS-pure.gguf` (14,534,384,640 B,
  sha `ea5a3c45…`) + `Qwen3.8-27B-DFlash2-Q4_K_M.gguf` (1,143,006,816 B,
  sha `1a25c568…`).
- Serve: `--speculative dflash2 --sessions 1 --context 262144
  --cache-ram-bytes 12884901888 --cache-disk <cache> --cache-disk-bytes
  68719476736`.
- Референсы: фикстура **76.9 t/s** (draft 98.5%); agent-check (EXP-007
  evo, 2026-11-18, тёплая машина): сессия 15 ходов **30.44 с**, follow-up
  25k **3.00 с** (k5 3.03 / k100 4.59), [док 25k][q2] **3.60 с**,
  рестарт-restore **2.85 с** reuse=disk. (Прежние 23.8/1.7/0.81 —
  смешение окон flash-next, заменены живым снятием.)

### `27b-multi` (машина ≥56 GiB)
- Веса те же. Serve: `--speculative dflash2 --sessions 2 --context
  **163840**` (проверено на Q4_K_XL в окне G8–G12: влезает с живым кэшем;
  на IQ4_XS веса легче на 3.9 GiB — запас больше), cache-ram 4 GiB.
- **Probe-лестница контекста** (по умолчанию): 196608 → 163840 → 131072;
  первый загрузившийся = канон. Референс: агрегат 2-пар **29.5 tok/s**.
- `2×262144` — движок отказывает (документировано), в лестницу не входит.

### `flash-multi` (только машина ≥110 GiB; flash-соло удалён)
- Веса: unsloth `UD-Q4_K_XL` 4 шара (111.3 GB) + `MTP/…-shared-Q8_0.gguf`
  (2.79 GiB). Serve: `--speculative mtp --mtp-model <MTP> --sessions 2
  --context <максимум по памяти>`, cache-ram 4 GiB, cache-disk 64 GiB.
- **Probe-лестница контекста при фиксированных 2 сессиях**: 262144 →
  229376 → 196608 → 163840 → 131072 (floor, проверен: 2×131072 = 56.1
  агрегат, host_available 28 GiB). Цель пользователя: «2 или больше сессий,
  максимальные полноразмерные контексты, и чтобы на кэш осталось».
  `--sessions 4` → та же лестница на 4 сессии (проверен floor 4×65536 = 77.3).
- **Агентские референсы flash-multi подлежат снятию заново** (окно FX мерило
  соло-конфиг) — DoD этапа 2.
- Память (бюджет): веса+MTP 105.7 GiB + working ~2.7 + cache-ram 4 + хост
  ≥8 → на KV остаётся по эмпирике ≥7 GiB (2×131072) и запас ~20 GiB до
  floors хоста — лестница должна дойти до ≥196608 (не подтверждено —
  probe и есть испытание).

### Константы запуска (все профили)
Образ `gufo-runtime:latest`, порт **8080** (дефолт, решение пользователя),
`--host 0.0.0.0`, podman: `--device /dev/kfd --device /dev/dri
--group-add keep-groups --ipc=host --ulimit memlock=-1:-1
--userns=keep-id:uid=1000,gid=1000`, тома `models:ro` + `cache:<профиль>`.

**Запреты (hard rules):**
- unsloth UD-* GGUF для 27B — запрещены (не грузятся); flash-next
  UD-Q4_K_XL — единственный разрешённый UD; при смене ревизии —
  обязательный `gfctl models --check-types` (GGUF-типы: низкобитные IQ/
  BF16/MXFP4/неизвестные в FFN → отказ; IQ2_S/IQ3_XXS — валидированные
  убийцы, F3/F20).
- `mmproj` не качается (агентский профиль текстовый; `--with-vision` — бэклог).
- RAM-гейты: `flash-multi` <110 GiB — отказ ДО трафика (на 64 GB машине
  flash невозможен: только веса 111 GB); `27b-*` <56 GiB — отказ.

## 6 · Роут и health

gufo не имеет hipfire-формата /health; роут читается из лога
`load_completed` (`speculative=…, sessions=…, context_tokens=…`) —
предикат печатает после install/use; `status` включает. Смоук-ретрай через
15 с (прогрев ядер) — как в hfctl.

## 7 · `gfctl agent-check` — агентская самопроверка

1. **Сессия 15 ходов** (doc ~6.6k + Q→A, greedy, 128 ток, reasoning off) —
   total wall; референсы (EXP-007, живое снятие): 27b-single 30.44 с,
   flash-multi 17.22 с (±25% → WARN).
2. **Follow-up-лестница 5k/25k/100k**: turn2 wall (референсы: 27b-single
   3.00 с @25k; flash-multi 1.58 с).
3. **[док 25k][q1] → [док 25k][q2]**: q2 wall (референсы: 27b-single
   3.60 с; flash-multi 10.44 с).
4. **Рестарт-restore**: рестарт контейнера → ход того же разговора
   (референсы: 27b-single 2.85 с reuse=disk; flash-multi 1.89 с;
   проверяет cache-disk).
5. Сводка PASS/WARN/FAIL + подсказка причины (WARN follow-up → проверить
   `--cache-ram-bytes`/`--cache-disk`).

## 8 · Отличия от hfctl

| | hfctl (hipfire) | gfctl (gufo) |
|---|---|---|
| Деплой | podman-compose + .env + config-plane движка | прямой `podman run -d`, конфиг = аргументы serve из профильной таблицы; recreate = rm+run |
| Веса | реестр hipfire, качает init-контейнер | качает gfctl (curl + sha256; `gufo model` в релизном образе отсутствует) |
| Драфт | env HIPFIRE_DFLASH_DRAFT | отдельный GGUF: `--dflash-model` (27B) / `--mtp-model` (flash) |
| Контекст мульти | константа профиля | **probe-подбор максимума** с фиксацией в каноне |
| Автоподъём | compose-unit + watchdog timer | serve-unit (oneshot up) + watchdog timer 1 мин, маркер `.gfctl-stopped` |
| watch | /stats + /metrics hipfire | /metrics gufo (`llamacpp:*`) + логи (draft-приём) |
| Агентский профиль | нет | `agent-check` + cache-disk по умолчанию |
| Порт | 11435 | 8080 |
| Дистрибуция | GitHub public | **локальный перенос каталога** |

Переиспользуем 1:1: preflight-гейты, linger/watchdog-паттерн, models-учёт
sha256, doctor-структуру, bench-фикстуру (`253c7ac5`), TUI-каркас watch.

## 9 · Ограничения / риски

- **Соседство с hfctl-продом**: GPU один; `gfctl up` при живом hfctl-проде
  = load_failed. doctor/status предупреждают; переключение — руками
  (`hfctl off` / `gfctl off`); автоматический takeover НЕ делается
  (решение пользователя 2026-11-17).
- `--userns=keep-id:uid=1000,gid=1000` — preflight проверяет uid/render.
- Смена ревизии unsloth весов (flash) — обязательный `--check-types` до `use`.
- Probe-подбор контекста тратит время загрузки (94 с × несколько попыток в
  худшем случае) — логируется каждая попытка, результат кэшируется в каноне,
  повторный `use` без `--no-probe` использует зафиксированное значение.
