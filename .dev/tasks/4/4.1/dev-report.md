# Dev report: 4.1 хардening + локальная доставка (этап 4, код-часть)

- Дата: 2026-11-18 · fix round: 1 (первый проход)
- Исполнитель: developer (сабстэдж 4.1; task-документ = brief.md, Design-наброски внутри)

## What was done

**1. doctor: блок «соседние артефакты»** (`lib/commands.sh`, `cmd_doctor`)
- После gpu-lock печатается блок из 7 путей: `~/gufo-models`, `~/gufo-exp`,
  `~/halogen-models`, `~/halogen-cache` (окна исследований) +
  `~/gfctl-acc{,-src,-models}` (приёмочные) — «обнаружен/не обнаружен».
  Пути от `$HOME` (не задан → блок пропускается, doctor остаётся
  не-крашащимся). Приписка: «uninstall НЕ трогает никогда: ~/gufo-models
  ~/gufo-exp ~/halogen-*; приёмочные ~/gfctl-acc{,-src} удаляет,
  ~/gfctl-acc-models — только с --purge-models». Доктор как был read-only.
- Детерминизм на хосте без артефактов: все 7 строк «не обнаружен»
  (батарея §39 на пустом faux-HOME).

**2. install идемпотентность поверх работающего** (`cmd_install`)
- Новый предикат: `port_open(canon_port)` + `container_state == running` +
  `load_completed` в логе (parse_route) → healthy-ветка: печатается
  «healthy — recreate не нужен (веса SKIP, юниты перегенерированы,
  podman run: 0)»; выполняются ТОЛЬКО до-проверка весов (SKIP по готовым),
  install_units (перегенерация юнитов), write_canon, автозапуск
  (по --no-autostart). НОЛЬ podman-вызовов (ни run, ни rm) — сервер не
  трогается. Порт наш, но роут не загружен (загружается/упал) или dead →
  штатный путь (recreate → wait_health 180 → smoke) без изменений.

**3. uninstall границы** (`cmd_uninstall`)
- Без флагов (к прежним слоям): дерево стека (веса щадятся) +
  **`~/gfctl-acc{,-src}`** — приёмочные инсталляции удаляются всегда
  (rm -rf с guard'ом на пустой `$HOME`).
- `~/gfctl-acc-models` — ТОЛЬКО с `--purge-models` (там докачанные
  15–110 GB); вместе с базой весов `$MODELS_BASE`.
- `~/gufo-models`, `~/gufo-exp`, `~/halogen-models`, `~/halogen-cache` —
  НИКОГДА; в конце uninstall печатается строка «остались нетронутыми
  (uninstall их не трогает никогда): …» со всеми четырьмя путями.
- Образ — только `--purge-image` (как было). ask-сообщение уточнено
  (acc-слои + смысл purge-models). Нумерация слоёв сохранена (5/5,
  acc-зачистка внутри слоя 5).

**4. README quickstart финал** (`README.md`)
- Quickstart = ровно 4 команды от клонирования (SPEC §1): `git clone … &&
  cd gfctl` → `./install.sh` → `gfctl install` → `gfctl status`; локальная
  дистрибуция (D1) — в комментарии первой строки. Все упомянутые команды
  существуют (батарея §38 сверяет каждую строку с роутером gfctl /
  наличием install.sh / git).
- Сняты устаревшие статусы: блок-цитата «каркас этапа 1» → «этапы 1–3
  закрыты, все команды SPEC §3 живы»; параграф «Полная карта команд
  (итог этапа 1)» без пометки про rc=1 заглушек + добавлены
  подготовительные команды (doctor / check-types / models download).

**5. EXP-заготовки** (`.dev/external/`, оба bash -n, НЕ исполнялись)
- `EXP-008-delivery.sh` — «доставка с нуля»: гейты `GF_ACC_HOST/USER/KEY/
  FLAVOR` (`:?`), tar-перенос без .git/.dev → bootstrap-FIRST (F21:
  install.sh до всяких действий) → снятие старой приёмочной без purge →
  хардлинки весов из `~/gufo-models` по именам-пинам (нет источников —
  скачает `gfctl install`) → `gfctl install` (докачка только недостающего)
  → `use $GF_ACC_FLAVOR` → `agent-check` (rc фиксируется в
  AGENT_CHECK_RC) → `gfctl off`. PASS: `SMOKE: OK` + `роут:` +
  `AGENT_CHECK_RC=0`; финальная строка RESULT по протоколу.
- `EXP-009-reboot.sh` — двухфазный чек-лист ребут-приёмки (скрипт НЕ
  ребутит): фаза `off` — `gfctl off` на прод-инсталляции `~/gufo` + печать
  чек-листа пользователю (ребут руками → фаза 2); фаза `verify` — сервер
  сам healthy (status + smoke: `SMOKE: OK` + `роут:`), затем `hfctl on` +
  hfctl healthy (HFCTL_HEALTH=ok; hfctl нет на машине → помечается absent).
  Гейты `GF_ACC_*`, RESULT-строка, результат дописывается (обе фазы).

**6. Батарея** (`tests/run_checks.sh`, секции 38–41, +23 пункта)
- §38 README quickstart: 4 команды + существование каждой.
- §39 doctor-артефакты: пустой HOME → 7×«не обнаружен» (детерминизм),
  ложных «обнаружен» нет, приписки на месте; faux-артефакты → 7×«обнаружен».
- §40 install: healthy (faux: port_open+running+LOGOK) → rc 0, «healthy —
  recreate не нужен», podman run = 0, podman rm = 0, веса SKIP, юниты
  перегенерированы, linger включён; dead → штатный путь (SMOKE OK,
  ровно 1 run).
- §41 uninstall: faux-артефакты созданы → после uninstall acc{,-src}
  удалены, acc-models ЖИВ, gufo-models/gufo-exp/halogen-* нетронуты,
  список напечатан, rmi нет; `--purge-models` → acc-models удалён,
  gufo-models жив. `--purge-image` — регресс §24 (rmi в логе).

## How it was checked internally

| проверка | команда | результат |
|---|---|---|
| батарея целиком | `bash tests/run_checks.sh` | **ИТОГО: PASS=312 FAIL=0** (было 289; +23, регресс 1.1–3.1 цел — секции 1–37 зелёные) |
| синтаксис диспетчера/lib | `bash -n gfctl lib/*.sh` | OK |
| синтаксис EXP-заготовок | `bash -n .dev/external/EXP-008-delivery.sh .dev/external/EXP-009-reboot.sh` | OK (оба) |
| python-харнесы | `python3 -m py_compile tpl/python/*.py` | OK |
| md5 bench-фикстуры | `md5sum tpl/bench/merge_sort_thinking_off.txt` | `253c7ac5…` — канон не тронут |
| usage rc=1 / status --json на мёртвом порте | батарея §2, §12 | PASS |
|чистота скоупа| `git status --short` | ровно 3 правки + 2 новых EXP; STATE/history/чужие EXP не тронуты, коммитов нет |

## Not checked internally (BLOCKED-EXTERNAL)

- **EXP-008/EXP-009 живьём** — по определению заготовки (brief: «не
  исполняются»); требуют машины + GO. Подтверждение: окно доставки
  (`GF_ACC_*` + FLAVOR) → result-файл с RESULT: PASS; ребут-приёмка —
  две фазы с пользователем у машины.
- **Healthy-ветка install на живом сервере** — проверена только на
  faux-уровне (podman/systemctl заглушены). Подтвердить на машине:
  после `gfctl install` повторный `gfctl install` → строка «healthy —
  recreate не нужен», `podman ps` не показывает рестарта (uptime контейнера
  не сбрасывается).
- **doctor на машине с реальными артефактами окон** — детерминизм
  «не обнаружен» проверен на faux-HOME; «обнаружен» — на faux-каталогах.
  Живой прогон — любой doctor на evo/FAEX в EXP-008/009.

## Known limitations / assumptions

- Пути артефактов считаются от `$HOME` вызывающего юзера (rootless-модель
  проекта); `$HOME` пуст → doctor пропускает блок, uninstall пропускает
  acc-слои (rm -rf с пустым корнем недопустим).
- Healthy-предикат install = порт наш + running + load_completed. Сервер,
  застрявший «загружается», уходит в штатный recreate — сознательно
  (dead → штатный путь, brief).
- Healthy-ветка НЕ гонит smoke (краткий список действий из brief;
  полная проверка остаётся за `gfctl status`/`smoke`) — отличие от
  dead-пути зафиксировано в выводе («podman run: 0»).
- Нумерация слоёв uninstall сохранена 5/5 (acc-зачистка внутри слоя 5) —
  чтобы не ломать сложившийся язык слоёв 1.2.
- EXP-009: hfctl-гейт парсит `health: <слово>` из `hfctl status`; при
  смене формата hfctl гейт честно упадёт в result (не тихо).

## Out-of-scope proposals

- doctor-блоку артефактов можно добавить размеры (`du -sh`) — полезно для
  «сколько места осталось от окон»; не спрашивали.
- EXP-008 мог бы принимать GF_ACC_BIND/PORT — не спрашивали; канон 8080.
- «Backlog из STATE»: install-probe (SPEC §3), авто-переход
  27b-multi↔single — остаются оркестратору.

## Round 1 (2026-11-18): 4.1-F1 — зеркало весов + архив образа

Добавка пользователя (страховка от смерти HF/ghcr). Правки строго по
списку задачи; STATE/history/чужие EXP не тронуты, коммитов нет.

### Что было сделано

**1. GFCTL_MIRROR_BASE (lib/models.sh, download_file)**
- Если env непуст — ПЕРВАЯ попытка качает `"$GFCTL_MIRROR_BASE/<basename
  dest>"`; отказ зеркала = `curl rc≠0` **ИЛИ** итоговый http-код ≥400
  (ловится `-w '%{http_code}'`: rc 0 с кодом ≥400/пустым — тоже фоллбэк) →
  WARN «зеркало не ответило годным файлом (rc=…, http=…) — фоллбэк на
  пин-URL»; попытки 2–3 — сразу пин-URL (HF), как раньше.
- Зеркальная попытка без `--retry` (fail-fast: живой фоллбэк сам ретраит
  4×) и с коротким `--connect-timeout 10` — мёртвый NAS не съедает окно.
- Битый/частичный хвост зеркала НЕ ломает resume пин-URL: `.part`
  восстанавливается до размера до попытки (`truncate`/`rm`) — иначе
  HTML-тело 404 дописалось бы в `.part` и испортило докачку.
- Финальный арбитр по-прежнему sha256: зеркальный файл, прошедший
  http-гейт, но битый по содержимому, словит SHA-MISMATCH → удаление.
  http-код «000» (file:// — батарея/LAN-схема) трактуется как годный.
- Докстринг «почему»: страховка от недоступности HF; зеркалом может быть
  NAS/LAN-сервер с теми же именами файлов, что в пинах таблицы.
- **doctor**: строка «зеркало весов (GFCTL_MIRROR_BASE): …» печатается
  только если env задан (без него — строки нет).
- **usage/env-шапка** диспетчера: GFCTL_MIRROR_BASE добавлен в перечень
  env-конфигурации («пусто = пин-URL HF»).

**2. EXP-008-delivery.sh — шаг «архив образа» (после healthy)**
- `podman save $IMG -o ~/gfctl-image-backup.tar` (существующий архив
  перезаписывается), печать размера (`ls -lh`); сбой → exit 54 (легенда
  rc дополнена).
- Подсказка digest-пина: `podman inspect --format '{{.Image}}'` → строка
  «запинить: GFCTL_IMAGE=<образ>@sha256:… (подсказка НА ГЛАЗ — канон
  gfctl не меняется)».

**3. Батарея (секция §42, +21 пункт)**
- mirror-first (реальный curl, file:// зеркало, http-код «000»): rc 0,
  контент = зеркало, в логе зеркало-URL, пин-URL НЕ дёргался, pre-flight
  на месте, без фоллбэка.
- зеркало-нет (файл в зеркале отсутствует → curl rc≠0): фоллбэк докачал с
  пина, в логе обе попытки, WARN фоллбэка (в stderr — захвачено 2>&1),
  `.part`-хвоста не осталось.
- faux mirror 200 (rc 0, код 2xx): лог содержит mirror-URL и НЕ содержит
  HF-URL (DoD); контент зеркала.
- faux mirror 404 (rc 0 + код 404 ≥400 — эмуляция «http≥400 при rc 0»):
  фоллбэк, WARN, контент = пин (404-мусор не пережил), `.part` чист.
- mirror-off (пустая строка) → прежнее поведение: пин-URL, ни слова про
  зеркало; регресс §9 (без env) цел.
- doctor: строка зеркала есть при заданном env / нет без него.
- Faux-curl дополнен download-веткой: маркеры ТОЛЬКО в URL (последний
  аргумент, схемы `dlmirror://`/`dlpin://`) — `-o`-путь намеренно не
  участвует в матчинге (первая попытка с маркером по `$*` коллидировала с
  именем деста — поймано батареей, исправлено на URL-матчинг).

### Как проверено внутри
- `bash tests/run_checks.sh` → **ИТОГО: PASS=333 FAIL=0** (было 312, +21;
  два прогона подряд — стабильно; регресс 1.1–3.1 и 4.1-§38–41 цел).
- `bash -n gfctl lib/*.sh tests/run_checks.sh` + оба EXP — OK;
  `py_compile` OK; md5 фикстуры `253c7ac5…` не тронут.

### Не проверено внутри (BLOCKED-EXTERNAL)
- Реальное зеркало по http/https (NAS) — в батарее file:// и faux; на
  машине подтвердить: `GFCTL_MIRROR_BASE=https://nas.lan/gguf gfctl
  models download 27b --yes` → строка «(попытка 1/3, зеркало)» и SKIP/PASS.
- `podman save` живого образа + digest-подсказка — только в EXP-008
  (окно доставки по GO).

### Ограничения / допущения раунда
- http-гейт зеркала смотрит финальный код после `-L` (редиректы
  проследованы); «200 с мусором» отсекает sha256, не http-код.
- Restore `.part` через `truncate` — coreutils (Ubuntu/Debian — есть).
- README-строку env-конфигурации не правил (в scope задачи входила только
  usage-шапка диспетчера) — см. Out-of-scope.

### Out-of-scope (раунд)
- README: добавить GFCTL_MIRROR_BASE в строку «Конфигурация env'ами» —
  одна строка, при следующем касании README.
- doctor: печатать размер архива образа, если `~/gfctl-image-backup.tar`
  существует (симметрия к блоку артефактов).
