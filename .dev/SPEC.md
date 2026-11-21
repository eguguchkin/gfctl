# Спецификация UX / CLI: gfctl (установка и управление gufo-сервером)

Статус: **DRAFT v2 — к согласованию** (2026-11-17; решения пользователя:
дистрибуция локальная, порт 8080 дефолт, takeover не нужен, flash — только
мульти с максимизацией контекстов). Основание: исследование движков
(окна FX/HX/HX-A/CX, отчёт `llm-lab/flash-next-engines.md`) и свод
конфигураций `llm-lab/.dev/AGENT-CONFIGS.md`. Целевые машины: che-evo
(60 GiB) и che-FAEX1 (128 GB); формат зеркалирует hfctl SPEC.

## 1 · Цели и принципы

1. Путь новичка — **4 команды от клонирования до работающего gufo-сервера
   с автозапуском** (`git clone && cd gfctl` → `./gfctl use <профиль>` →
   проверка; лейаут 4.4: install.sh упразднён, bootstrap первого запуска —
   сам диспетчер).
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

## 2 · Дистрибуция и первичная установка (лейаут 4.4)

**Дистрибуция — git-клон** (локально: rsync/scp/git по LAN или GitHub),
клон = стек = место запуска:

```bash
cd gfctl
./gfctl use 27b-single    # bootstrap .data/ → веса → юниты → старт → health → smoke
gfctl status              # проверка
```

- `STACK_DIR` = каталог gfctl-файла (`readlink -f`; запуск из любого
  подкаталога клона; `GFCTL_DIR` переопределяет). `install.sh` упразднён
  (4.4): bootstrap первого запуска — сам диспетчер (любой вызов создаёт
  каркас `.data/` и доставляет `.gfctl-containers.conf` — скоуп
  slirp4netns для podman-вызовов gfctl, `export CONTAINERS_CONF` с гвардом
  на файл; 5.1; юниты НЕ ставит).
- Вся инсталляция в клоне: диспетчер + `lib/` + `tpl/`; данные — в
  `.data/` (вне git): модели `.data/models/<сет>/`, кэш
  `.data/cache/<профиль>/`, логи `.data/logs/`; канон `.env`, маркер
  `.gfctl-stopped` и derived-конфиг `.gfctl-containers.conf` (5.1,
  регенерируется bootstrap'ом из tpl при каждом запуске) — в корне клона.
  `.gitignore` репо игнорит `.data/`, `logs/` и `.gfctl-containers.conf` →
  `git clean -fd` безопасен; **`git clean -fdx` запрещён**
  (удалит данные; bootstrap при нарушении `.gitignore` печатает warn).
- **Первичная установка — preflight хоста (5.1, И1)**: первый
  `use`/`install` сам доводит голую Ubuntu (`preflight_host()`, единый
  блок для обеих команд): apt-пятёрка И1 — `podman podman-compose
  containers-storage psmisc curl` одним `sudo apt-get update+install`
  ТОЛЬКО при непустом need-списке («всё на месте» → ноль sudo/apt-вызовов;
  passt/slirp4netns/uidmap приезжают Depends podman; нет sudo/apt-get/сети →
  громкий отказ с ручным рецептом); GPU-подготовка — группы render,video
  (`sudo usermod -aG render,video`) при наличии `/dev/kfd`|`/dev/dri`
  (нет GPU → info-пропуск), при фактичном добавлении — «применятся только
  после перезахода» + exit 42; limits.d НЕ дублируется (владелец —
  memlock-гейт, один файл). Порядок: ОС → GPU-prep → железо → RAM → apt →
  gpu-lock → memlock (тексты/коды 42 прежние байт-в-байт).
- Вне каталога (исключения инварианта): systemd-user юниты
  `gfctl-serve.service` (oneshot, ExecStart=`gfctl _boot`) +
  `gfctl-watchdog.service/.timer` (1 мин) — отдельного boot-юнита нет
  (решение 1.2: serve-юнит сам поднимает канон), образ ghcr,
  `limits.d/99-gfctl-memlock.conf`, группы render/video (5.1),
  apt-пятёрка в системе (5.1, И1 — тот же список нужен hfctl), linger.
  Юниты ставятся при первом `use`/`install` (после записи канона,
  идемпотентно); daemon-reload/enable/старт таймера — при `use`/`install`/
  `on` (fix-r2, инцидент evo EXP-009-хвост: без enable после ребута юниты
  disabled); linger — только `on`/`install`.

## 3 · Карта команд

| Команда | Действие |
|---|---|
| `gfctl install [--profile P] [--port N] [--bind A] [--models-dir D] [--no-autostart]` | Preflight (`preflight_host`, 5.1: ОС → GPU-подготовка групп render,video при наличии GPU → железный гейт → RAM-гейт → apt-пятёрка И1 одним вызовом при непустом need → gpu-lock → memlock-гейт по порогу достаточности 8388608 kB (4.1-F2, не по «unlimited»): ml ≥ порога → limits.d-файл перезаписан + WARN, install продолжается; ml < порога или нечитаемый → файл + WARN «перелогинься» + exit 42; нет sudo/apt/сети → громкий отказ с ручным рецептом) → скачивание весов профиля (размер + sha256 до и после) → **probe-подбор контекста** (для мульти-профилей; при уже зафиксированном каноне пары или на healthy-повторе — пропускается: идемпотентность; 4.2) → генерация юнитов → старт → health → smoke → **автозапуск** (если не `--no-autostart`). Идемпотентен |
| `gfctl use 27b-single\|27b-multi\|flash-multi [--sessions N] [--context N] [--no-probe]` | Preflight хоста (`preflight_host` — тот же блок, что у install; И1: первый use на голой машине сам ставит пакеты/группы, 5.1) → ленивый добор весов → **probe-подбор** (если не `--no-probe`) → перегенерация юнита → recreate → health → smoke. Канон профиля заменяется |
| `gfctl status [--json]` | Профиль, health, **фактический роут** (speculative=mtp/dflash2, sessions, context — из лога `load_completed`), состояние кэша (ram/disk), автозапуск, версия образа |
| `gfctl logs [-f] [N]` | Логи контейнера |
| `gfctl watch [--interval N]` | Живой дашборд (TTY — TUI, клавиши `q`/`+`/`-`/`p`; не-TTY — стрим). Блоки: **Железо** — GPU из sysfs (первая карта vendor 0x1002: temp = MAX по её `temp1_input`, sclk/power/busy, VRAM/GTT), CPU Tctl (k10temp), device-lost (из `/metrics`, красный при >0); **Память** — RAM (MemTotal/MemAvailable, цвет по заполнению) + VRAM/GTT; **Движок** — вычисляемые из кумулятивных `llamacpp:*`/`gufo:*` (генерация и prefill: средняя по счётчикам + speed-gauge «последний», кэш-эффект = cached/(prompt+cached), спекуляция accepted % по draft-токенам, KV %/пик, очередь, префил «обработано+из кэша»/сгенерировано; prompt-lookup при ненулевых), роут из лога `load_completed`, режим — `/ready` + `configured`; **Скорость** — sparkline Δ за тик («пульс», не скорость; token-счётчики движутся live); **Логи** — `podman logs` БЕЗ `-t` (время в строках движка), TZ-конверсия UTC→локальный в слое watch. Мёртвый сервер — строка «недоступен» без спама |
| `gfctl on` / `off` | Автозапуск вкл (юниты+linger) / стоп + снятие (linger off). Файлы/веса/образ целы |
| `gfctl bench` | Фикстура merge_sort (`253c7ac5`) ×3 по HTTP: wall, decode tok/s |
| `gfctl smoke` | health + 3 запроса (код/проза/математика) + роут из лога (`speculative=dflash2\|mtp`) |
| `gfctl agent-check` | **Агентская самопроверка** (см. §7): сессия 15 ходов, follow-up-лестница 5k/25k/100k, [док][вопрос], рестарт-restore — wall-цифры + сравнение с референсами (WARN при регрессии >25%) |
| `gfctl cache [--verify]` | Сводка кэша из логов (configured/skipped/evicted) + `/metrics` cached_total; `--verify` — контрольный follow-up + рестарт-проба |
| `gfctl doctor` | Диагностика без записи: ОС, пакеты apt-пятёрки И1 (5.1), /dev/kfd, /dev/dri/renderD*, группы render/video (5.1), memlock, linger, RAM-гейты всех профилей (цифрами), диск под веса, порт, **gpu-lock** (кто держит /dev/kfd — предупреждение о hfctl-проде), **slirp-скоуп** (CONTAINERS_CONF + файл; 5.1) и **хранилище** graphRoot (общее с hfctl; 5.1) |
| `gfctl models [--check-types]` | Скачано vs требуется по профилям, sha-статус, свободное место; `--check-types [сет|профиль]` — pre-check GGUF-типов (низкобитные IQ — IQ1_S/IQ1_M/IQ2_*/IQ3_XXS —, BF16/MXFP4/неизвестные в FFN → КРАСНЫЙ «не загрузится»; display-имена — канон ggml enum, BF16=30 — F20, 4.2; 41/42=Q1_0/Q2_0 — форк движка (ggml.h:431–432, 4.3); лишние аргументы → die) |
| `gfctl uninstall` | v2 (лейаут 4.4): снимает контейнер + юниты + watchdog + linger + `limits.d/99-gfctl-memlock.conf`; данные (`.data/` — модели/кэш/логи) и podman-образ НЕ трогает (данные — инвариант; purge-флаги упразднены — полный снос руками: `rm -rf` клона + `podman rmi`). «Слоёный» снос дерева `~/gufo` и приёмочных `~/gfctl-acc*` упразднён |

## 4 · Модель состояний

1. **Профиль** (`install --profile` / `use`) — канон в `<клон>/.env`
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
| watch | /stats + /metrics hipfire | /metrics gufo (вычисляемые из `llamacpp:*`+`gufo:*`) + sysfs-железо + логи (TZ-конверсия) |
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

## Инварианты поставки (утверждены пользователем 2026-11-21; действуют для hfctl и gfctl)

**И1 — «голая Ubuntu одной командой».** Установка на чистую Ubuntu — одна
команда пользователя после получения кода (git clone не считается): gfctl —
первый `gfctl use <профиль>` (bootstrap силами gfctl, 4.4); hfctl —
`./install.sh`. Обвязка сама декларирует и ставит (идемпотентно): podman,
podman-compose, containers-storage, psmisc, curl; GPU-подготовка хоста
(группы render/video, limits.d memlock) — только при наличии
`/dev/kfd`/`/dev/dri`, с честным «требуется перелогин/ребут».

**И2 — «сценарная приёмка без ручных корректировок».** Пройденным считается
только сценарий-последовательность команд обвязок (`gfctl off; hfctl on; …`)
+ диагностические ЧТЕНИЯ (podman ps/inspect, curl, journalctl). Внеплановая
мутационная ручная команда = **сценарий НЕ ПРОЙДЕН** + дефект в бэклог;
повторная приёмка — чистой последовательностью. (Окно 2026-11-21: прод evo
поднимали руками 3 часа — по И2 это FAIL, дефекты стали hfctl 13.1.)

**И3 — «деплой и прогоны на машину всегда из GitHub».** gfctl: клон
`~/gfctl` → `git pull` → стек = клон (лейаут v2 так и устроен). hfctl:
клон `~/hfctl` → pull → синк производных файлов в стек. tar/cp из
локального воркспейса разработчика запрещены — в том числе в тестовых
прогонах (EXP): сценарий гоняется из GitHub-производного кода.

Соответствие gfctl (ревизия 2026-11-21, код этапа 5.1; живая приёмка —
окно этапа 5 по D6): И1 — **по коду полное** (preflight_host на install И
use: apt-пятёрка одним вызовом при непустом need, GPU-подготовка групп
render,video + memlock, slirp-скоуп CONTAINERS_CONF), **честная оговорка**:
bare-Ubuntu приёмка отложена — ресурс не выделен (D8), EXP-013 создан как
заготовка (deferred), живьём код не подтверждён до окна. И2 — **частично,
расширено**: rm-в-попытке (fix-r2) + `gf_orphan_heal` (mirror hfctl 13.1,
D8 — самолечение storage-сироты «already in use by <ID>» с капом и
гвардиями) покрывают класс «already in use»; slirp-скоуп убирает первопричину
teardown-падений (живой приём — EXP-015 в окне). Сценарные
последовательности И2 — EXP-014/015 созданы, не запущены (D6).

## Этап 5 (план): паритет поставки — bare-Ubuntu одна команда + сценарная приёмка

- [x] preflight `use`/`install` (`preflight_host`, 5.1): apt-пятёрка И1
      (`podman podman-compose containers-storage psmisc curl`; одним
      update+install при непустом need; passt/slirp4netns/uidmap —
      Depends podman) — код готов, живая приёмка EXP-013 (deferred, D8)
- [x] GPU-подготовка: группы render/video (`usermod -aG` + «после
      перезахода» + exit 42), limits.d memlock — гейт по
      /dev/kfd|/dev/dri, нет GPU → info-пропуск (зеркало hfctl 13.2);
      limits.d не дублируется (владелец — memlock-гейт 4.1-F2);
      живьём — EXP-013/окно
- [x] CONTAINERS_CONF-скоуп slirp4netns для gfctl-стека: bootstrap ставит
      `.gfctl-containers.conf` (tpl/containers), диспетчер экспортирует
      CONTAINERS_CONF с гвардом — покрывает все podman-вызовы gfctl,
      включая `_boot`/`_watchdog` (юниты зовут диспетчер); хранилище
      общее (graphRoot, EXP-013 llm-lab); живой приём — EXP-015 (окно)
- [x] orphan-heal — РЕШЕНО (D8, Round 2): MIRROR hfctl 13.1 —
      `gf_orphan_heal` (lib/serve.sh): сигнатура «already in use by
      <12..64-hex>» + 4 гвардии (кап GF_ORPHAN_HEALS/HEAL_MAX; нет
      containers-storage → WARN + ручной рецепт; ID видит libpod → не
      сирота; delete-container отказал → WARN), вызов из container_up при
      отказе run до retry; die при исчерпании — с ручным рецептом
- [x] Сценарная приёмка — СЦЕНАРИИ созданы (EXP-013 bare — deferred,
      EXP-014 «gfctl off; hfctl on», EXP-015 обратная + slirp-ассерты;
      пролог перелогина в 014/015; из GitHub-клона — И3; не запущены,
      D6); приёмочные прогоны — окно этапа 5 (два GO: FAEX, evo) +
      хвосты EXP-010/011/012 + ребут/рестарт-приёмы fix-r2
