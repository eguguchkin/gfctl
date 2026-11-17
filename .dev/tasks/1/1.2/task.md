# Task: 1.2 жизненный цикл — serve-юниты + install/use/on/off/uninstall + smoke/logs + watchdog/boot   Design: architect

## Scope and DoD

Goal (из brief): на каркасе 1.1 работает полный жизненный цикл сервера как
ЕДИНЫЙ локальный флоу; вся podman/systemd/loginctl/curl-логика тестируется
PATH-заглушками (реальный прогон — EXP этапа 1, не в этом сабстэдже).

DoD (чек-лист приёмки; полный текст — brief.md):
1. Команды `install` / `use` / `on` / `off` / `uninstall` / `logs` / `smoke` /
   `_watchdog` (+ скрытые `up|down`, внутренние `_boot`) реализованы; die-заглушки
   1.1 сняты РОВНО для них (`watch|bench|cache|agent-check` остаются заглушками).
2. tpl/: 4 шаблона (serve-юнит, watchdog .service+.timer, env) — генерация
   юнитов с подстановкой профиля/порт/путей (см. Design).
3. Serve-командная строка собирается ИЗ профильной таблицы: токены
   @DRAFT@/@MTP@ → контейнерные пути `/models/<файл>`, `--model` = main-файл
   сета, флаги F9 ровно, порт D2/`--port`.
4. Health-предикат: поллинг `podman logs` до `event=load_completed`
   (таймаут 180 с) + HTTP-проба `/ready`; печать роута.
5. Порядок фиксированный: смена конфига = recreate → health → smoke.
6. `off` → вотчдог НЕ воскрешает (маркер проверяется раньше подъёма);
   `on` возвращает всё (юниты+timer+linger).
7. `uninstall` без флагов оставляет модели и образ.
8. `status [--json]` живой режим: роут из лога, автозапуск, версия образа,
   кэш-каталог; схема 1.1 расширяется без ломания (null'ы при мёртвом сервере).
9. Внутренние проверки зелёные; регресс 1.1 не сломан (все ассерты, чьи
   контракты ещё живы, проходят; обновления батареи — только там, где 1.2
   замещает заглушку/placeholder, см. Test strategy п.0).

Out of scope (этапы 2–3, не трогать): probe-подбор контекста (лестница
читается из поля 8, но не исполняется), `bench`, `agent-check`, `cache`,
`watch` (TUI), ротация логов, `--with-vision`, `/metrics`-интеграция в
status/watch.

## Design

### Глобалы диспетчера (`gfctl`) и source-порядок

Добавить к существующим: `CONTAINER="${GFCTL_CONTAINER:-gufo}"`,
`UNIT_NAME=gfctl` (юниты `gfctl-serve.service`, `gfctl-watchdog.service/.timer`),
`LOGS_DIR="$STACK_DIR/logs"`, `UNIT_DIR="$HOME/.config/systemd/user"`.
Case-роутер: `install|use|logs|on|off|uninstall|smoke|up|down` → cmd_* из
commands.sh/autostart.sh; `_watchdog` / `_boot` → скрытые (в usage не
появляются). Пометки «[этап 1.2]» в шапке-usage снимаются.
Source-порядок: profiles → models → state → serve → units → health →
autostart → commands (модули содержат только функции, порядок — читаемость).

**Test seams** (единственные, все с прод-дефолтами; для батареи):
`GFCTL_HEALTH_POLL` (5 с), `GFCTL_SMOKE_RETRY_S` (15), `GFCTL_RECREATE_PAUSE_S`
(3, F10), `GFCTL_RUN_ATTEMPTS` (3); `cmd_boot` берёт дедлайн/паузу аргументами.

### lib/state.sh — канон профиля `~/gufo/.env`

Формат canon: `KEY=VALUE` построчно (grep-парсинг, как cur_profile 1.1).
Ключи: `GFCTL_PROFILE`, `GFCTL_SESSIONS`, `GFCTL_CONTEXT`, `GFCTL_PORT`,
`GFCTL_BIND`, `GFCTL_MODELS` (база весов), `GFCTL_IMAGE`. Приоритет чтения:
процесс-env (явный оверрайд) > .env > дефолт диспетчера/таблицы — тогда
`GFCTL_PORT=8198 ./gfctl status` из батареи 1.1 продолжает работать, а
`install --port 8090` живёт без env.

- `write_canon <profile> <sessions> <context>` — render `tpl/env/env.tpl` во
  `$STACK_DIR/.env.tmp` + `mv` (атомарно: вотчдог/boot не читают полуфайл).
  port/bind/models/image — из актуальных globals/args. Полная перезапись:
  единственный писатель .env — write_canon.
- `canon_get <KEY> <default>` → `${!KEY:-}` непуст → он; иначе
  `grep '^KEY=' .env | tail -1 | cut -d= -f2-`; иначе default.
- `canon_sessions <profile>` / `canon_context <profile>` →
  `canon_get GFCTL_SESSIONS "$(profile_field P 3)"` (и 4).
- `canon_port` / `canon_bind` → `canon_get GFCTL_PORT "$PORT"` (и BIND).
  ВСЕ runtime-потребители порта (serve/http/smoke/logs/status) идут через
  canon_port — не через сырой global.

### lib/serve.sh — сборка командной строки и recreate

- `serve_args <profile> <sessions> <context>` → печатает аргументы `gufo serve llm`
  ОДНОЙ строкой: `--host 0.0.0.0` (F2, всегда) + `--model /models/<set_file_role set main>`
  + поле 7 таблицы с подстановкой `@DRAFT@`→`/models/<set_file_role set draft>`,
  `@MTP@`→`/models/<set_file_role set mtp>` (неизвестный токен → die) +
  `--sessions S --context C --cache-ram-bytes <поле5> --cache-disk /cache
  --cache-disk-bytes <поле6>`. Чистая функция (только печать) — батарея
  сравнивает байт-в-байт. Flash-шарды: `--model` = ПЕРВЫЙ main-файл
  (00001-of-00004), остальные gufo подхватывает сам (проверено окном FX-W1b).
- `gpu_nodes_present()` → rc 0 при `[ -e /dev/kfd ]` и renderD* (выделена
  ради battery-оверрайда).
- `container_up <profile>` — ЕДИНСТВЕННЫЙ путь подъёма, используется
  install/use/on/up/_watchdog/_boot (SPEC §8 «recreate = rm+run»; заодно
  иммунно к перенумерации renderD* между ребутами — конфиг контейнера не
  переиспользуется никогда, поэтому hfctl-деление boot/recreate не нужно):
  1. `podman rm -f "$CONTAINER"` (вывод заглушён, `|| true`);
  2. `mkdir -p "$STACK_DIR/cache/<profile>"`; пауза `GFCTL_RECREATE_PAUSE_S` (F10);
  3. до `GFCTL_RUN_ATTEMPTS` раз: `podman run -d --name gufo … "$IMAGE" $(serve_args …)`;
     rc=0 → выход; иначе пауза 5 с и повтор (занятый порт и прочие
     транзитивные отказы — F10); последняя попытка неудачна → die «порт/запуск…»
     + хвост `podman logs`.
  Podman-префикс (F9 ровно, константы SPEC §5):
  `--device /dev/kfd --device /dev/dri --group-add keep-groups --ipc=host
  --ulimit memlock=-1:-1 --userns=keep-id:uid=1000,gid=1000
  -p "$(canon_bind):$(canon_port):$(canon_port)"
  -v "$(models_dir_for <set>):/models:ro"
  -v "$STACK_DIR/cache/<profile>:/cache"`.
  МАУНТ МОДЕЛЕЙ — каталог-сет (не база): тогда контейнерные пути весов =
  `/models/<файл>` (так задуманы токены profiles.sh).
- `container_state()` → `podman inspect -f '{{.State.Status}}' "$CONTAINER"`
  или `missing` (fallback `|| echo missing`, как в hfctl cmd_watchdog).
- `container_stop()` → `podman rm -f "$CONTAINER" 2>/dev/null || true`.

**Каноническая serve-командная строка 27b-single** (образец; все профили —
та же схема, значения из полей таблицы; байт-в-байт ассерт батареи):

```
podman run -d --name gufo \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --ipc=host --ulimit memlock=-1:-1 \
  --userns=keep-id:uid=1000,gid=1000 \
  -p 0.0.0.0:8080:8080 \
  -v <MODELS_BASE>/27b:/models:ro \
  -v <STACK_DIR>/cache/27b-single:/cache \
  ghcr.io/gufo-org/toolboxes/gufo-runtime:latest \
  gufo serve llm --host 0.0.0.0 \
    --model /models/qwen3.8-27b-IQ4_XS-pure.gguf \
    --speculative dflash2 --dflash-model /models/Qwen3.8-27B-DFlash2-Q4_K_M.gguf \
    --sessions 1 --context 262144 \
    --cache-ram-bytes 12884901888 --cache-disk /cache --cache-disk-bytes 68719476736
```

### lib/units.sh + tpl/ — генерация systemd-user юнитов

- `render_tpl <tpl> <out> NAME=VALUE…` — 1:1 из hfctl/lib/stack_files.sh:
  подстановка `__NAME__`, `die` при нераскрытом `__[A-Z0-9_]+__`.
- `install_units` — mkdir -p UNIT_DIR; рендер трёх юнитов (идемпотентная
  перезапись, дублей имен не бывает). Вызывается install и on (до enable).
  enable/start/linger — НЕ здесь (autostart_on).
- tpl-файлы (маркеры — стиль hfctl `__X__`, набор фиксирovан):
  1. `tpl/systemd/gfctl-serve.service.tpl` — markers `__STACK_DIR__`,
     `__PODMAN_BIN__`, `__CONTAINER__`. Type=oneshot RemainAfterExit=yes
     KillMode=process (без него systemd убивает cgroup с контейнером),
     ExecStart=`/usr/bin/env bash __STACK_DIR__/gfctl _boot`,
     ExecStop=`__PODMAN_BIN__ rm -f __CONTAINER__` (страховка; рабочий stop —
     cmd_off, юнит-ExecStop у завершённого oneshot не стреляет),
     TimeoutStartSec=900, Restart=on-failure RestartSec=30,
     After=podman-user-wait-network-online.service, WantedBy=default.target.
     ЭТО И ЕСТЬ boot-юнит: отдельных `gfctl-boot.service` НЕТ (SPEC §2
     «юниты gfctl-serve*»; второй boot-юнит дрался бы за контейнер).
  2. `tpl/systemd/gfctl-watchdog.service.tpl` — markers `__STACK_DIR__`;
     oneshot, KillMode=process, ExecStart=`bash __STACK_DIR__/gfctl _watchdog`.
  3. `tpl/systemd/gfctl-watchdog.timer.tpl` — без маркеров (статичный,
     install -m 0644): OnBootSec=2min OnUnitActiveSec=1min
     RandomizedDelaySec=10, WantedBy=timers.target.
  4. `tpl/env/env.tpl` — markers `__PROFILE__ __SESSIONS__ __CONTEXT__
     __PORT__ __BIND__ __MODELS_DIR__ __IMAGE__`; шапка-комментарий
     «сгенерировано gfctl; правки конфига — через gfctl install/use».

### lib/health.sh — health-предикат, роут, smoke

- `parse_route` — ЧИСТЫЙ фильтр: текст лога на stdin; берёт ПОСЛЕДНЮЮ строку
  с `event=load_completed`, извлекает `speculative=`, `sessions=`,
  `context_tokens=`, `model=` (grep -o + cut -d=); пишет globals
  ROUTE_SPEC/ROUTE_SESSIONS/ROUTE_CTX/ROUTE_MODEL ('' = нет). Формат строки
  движка подтверждён окнами IX/FX (`… speculative=dflash2 … sessions=1
  context_tokens=262144 …`).
- `wait_load [timeout=180]` — цикл с шагом GFCTL_HEALTH_POLL: `podman logs
  "$CONTAINER" 2>&1 | parse_route`; ROUTE_SPEC непуст → печать
  «загрузка завершена после Ns» + rc 0. Ранний выход: с 20-й секунды
  `grep load_failed` в логе → warn + хвост 30 строк + rc 1 (без ожидания
  всего таймаута). Прогресс-печатка «жду загрузки… Ns» каждая итерация.
  Таймаут → warn + хвост логов + rc 1.
- `http_ready` → `curl -fsS -m 5 "http://127.0.0.1:$(canon_port)/ready"`
  (эндпоинт подтверждён окнами IX). rc 0/1.
- `wait_health [timeout]` = wait_load → затем поллинг http_ready (шаг 2 с,
  до 30 с: после load_completed сокету нужно время) → печать роута строкой
  `роут: <spec>, sessions <n>, ctx <c>`; rc 1 при любом отказе (вызывающий
  install/use завершается по set -e).
- `smoke` — 3 запроса POST /v1/chat/completions (curl -m 300): код
  («Напиши одну строку python: print('hello world')»), проза («Ответь
  ровно: ок»), математика («Сколько будет 2+2? Ответь одним числом.»);
  `"model":"$ROUTE_MODEL"` (имя движка из load_completed; пуст → die
  «health не выполнен»). РЕТРАЙ РОВНО ПЕРВОГО запроса: одна повторная
  попытка через GFCTL_SMOKE_RETRY_S (F15). Ответ валиден, если
  `tpl/python/smoke_resp.py` (копия 1:1 из hfctl) извлёк непустой content.
  Успех → печать роута + «SMOKE: OK»; провал → die (rc 1).

### lib/autostart.sh — on/off/up/down/_watchdog/_boot

- `autostart_on` — install_units; `systemctl --user daemon-reload`; enable
  `gfctl-serve.service gfctl-watchdog.timer`; start timer; `rm -f STOP_MARKER`;
  `sudo loginctl enable-linger "$USER"`; печать «автозапуск ВКЛ…».
- `cmd_on` = autostart_on + cmd_up (smoke НЕ зовётся — on быстрый).
- `cmd_up` (алиас `up`) — `rm -f STOP_MARKER` + container_up $(cur_profile) +
  wait_health 300. Автозапуск не трогает.
- `cmd_off` (алиас `down`) — ПОРЯДОК ФИКСИРОВАННЫЙ (маркер ДО всего — вотчдог
  оглушён даже при сбое, hfctl-правило): `touch STOP_MARKER` → container_stop
  → `systemctl --user disable gfctl-serve.service gfctl-watchdog.timer` (`|| true`)
  → `rm -f` трёх юнит-файлов → daemon-reload → `sudo loginctl disable-linger
  "$USER"` (F11: linger off только в явном off/uninstall). Итоговые 2 строки
  («ВЫКЛ…», «Вернуть: gfctl on»).
- `cmd_watchdog` — `[ -f STOP_MARKER ] && return 0` (ПЕРВАЯ проверка, F16);
  canon .env отсутствует → return 0 (поднимать нечего); container_state ≠
  running → строка `date -Is … state=<st> -> up` >> `$LOGS_DIR/watchdog.log`
  (mkdir -p; сбой дописи `|| true`) + `container_up $(cur_profile) || true`;
  rc всегда 0.
- `cmd_boot [deadline_s=420] [sleep_s=10]` — цикл: gpu_nodes_present? нет →
  sleep и повтор до дедлайна; да → container_up + container_state=running →
  rc 0; иначе повтор. Дедлайн исчерпан → stderr-сообщение, rc 1 (systemd
  Restart=on-failure перезапустит). smoke/health из boot НЕ зовутся
  (TimeoutStartSec=900 покрывает бюджет ~7 мин + хвост).

### lib/commands.sh — новые cmd_* и живой status

- `cmd_install [--profile P] [--port N] [--bind A] [--models-dir D]
  [--no-autostart]` (неизвестный флаг → die; N — isint):
  1. Preflight-гейты: ОС без Linux → die; `gpu_nodes_present` нет → die;
     RAM-гейт профиля (ram_gate_line verdict НЕДОСТАТУПЕН) → die с цифрами;
     render-группа нет → WARN; gpu-lock (podman ps непуст) → WARN «переключение
     руками, D3» + продолжить; memlock ≠ unlimited и
     `/etc/security/limits.d/*gfctl*` нет → `sudo tee` файла
     `99-gfctl-memlock.conf` + WARN «перелогинься» + **exit 42** (ребут-код
     из PLAN этапа 1); port: canon_port слушается и container_state=running →
     идемпотентный путь (рекрейт ниже всё равно rm+run), слушается чужое → die.
  2. Веса: `ensure_weights <set>` (см. ниже) после ask «Скачать веса сета X
     (N.N GiB)? [y/N]» (не-TTY без GFCTL_YES → rc 1 авто-нет; уже скачанные
     файлы — SKIP без вопросов).
  3. `install_units` (рендер юнитов — всегда, даже с --no-autostart).
  4. `write_canon <profile> <sessions=таблица> <context=таблица>` (+ port/bind).
  5. container_up → wait_health 180 → печать роута → smoke.
  6. `--no-autostart`? → печать «автозапуск выключен (включить: gfctl on)» :
     autostart_on.
  Идемпотентность: повтор поверх работающего = SKIP весов + перерендер юнитов
  (те же имена) + recreate + health + smoke; дублей нет.
- `cmd_use <profile> [--sessions N] [--context N] [--no-probe]`:
  resolve_profile (алиасы) → die при неизвестном; N — isint, иначе die;
  `--no-probe` — WARN «probe-подбора в 1.2 нет (этап 2)» и no-op (грамматика
  1.1 флаг содержит; семантически он уже истинен). Далее: RAM-гейт целевого
  профиля → ensure_weights (ленивый добор: недостающие файлы сета — с ask,
  полные SKIP) → write_canon (overrides или значения таблицы) → container_up
  → wait_health 180 → smoke → печать роута + строки канона.
- `cmd_logs [-f] [N]` — разбор: `-f` → `podman logs -f`; числовой N →
  `--tail N` (дефолт 100). Контейнера нет (container_state=missing) → die
  «контейнера нет». Передача вывода как есть.
- `cmd_smoke` — container_state ≠ running → die; иначе parse_route из лога →
  smoke (роут+SMOKE: OK; rc 1 при отказе).
- `cmd_uninstall [--purge-models] [--purge-image]`: ask «Удалить gfctl и
  контейнер gufo (модели [НЕ] удаляются, образ [НЕ] удаляется)? [y/N]»
  (не-TTY без GFCTL_YES → rc 1 — удаление данных только с согласия);
  слои ПО ПОРЯДКУ: STOP_MARKER touch + container_stop → disable+rm юнитов +
  daemon-reload → linger off (`|| true` на каждый systemd-шаг) → limits.d
  (`sudo rm -f /etc/security/limits.d/99-gfctl-memlock.conf || true`) →
  дерево `$STACK_DIR`: всё, КРОМЕ `$MODELS_BASE`, если база весов внутри
  (`find -maxdepth 1 ! -path "$MODELS_BASE" -exec rm -rf {} +`); база вне —
  `rm -rf "$STACK_DIR"`. `--purge-models` → `rm -rf "$MODELS_BASE"`;
  `--purge-image` → `podman rmi "$IMAGE" || true`. Итоговая сводка слоёв.
- `cmd_status` живой режим — источники полей (только лог+файлы, /metrics —
  этап 3): profile=cur_profile; порт/бинд=canon_*; health: порт мёртв →
  «не запущен» (как 1.1); жив → `podman logs | parse_route`: ROUTE_SPEC непуст
  → «ok», пуст → «загружается». route=из ROUTE_*; autostart =
  `systemctl --user is-enabled gfctl-serve.service` (enabled→вкл/true,
  иначе выкл/false; systemctl нет → «?»/null); version =
  `podman inspect -f '{{.ImageName}}' gufo` (нет контейнера → null);
  cache = `$STACK_DIR/cache/<profile>` + `du -sb` (нет → null).
  JSON: существующие ключи и их типы НЕ менять (route/autostart/version были
  null — теперь заполняются, null сохраняется при мёртвом сервере), новый
  ключ `cache` добавляется В КОНЕЦ. Человекострока:
  `профиль: X | health: ok | автозапуск: вкл | роут: dflash2, sessions 1, ctx 262144 | кэш: <dir> (<N.N> GiB) | веса 27b: 2/2`.

### lib/models.sh — единственная правка

Extract цикла докачки из cmd_models download в `ensure_weights <set>`:
ask (если есть недостающие файлы) → download_file по каждому битому/(
отсутствующему. cmd_models download и install/use зовут её (одна семантика
согласия, дублирование убрать).

## Test strategy

**п.0. Регресс-базис**: батарея (tests/run_checks.sh) расширяется, а две её
секции 1.2 по определению замещает: (а) секция 2 «заглушка → rc=1» снимается
для install/use/logs/on/off/uninstall/smoke (watch/bench/cache/agent-check
остаются); (б) ассерт секции 12 про «автозапуск: — (этап 1.2)» заменяется
ассертом живого формата. Это ОБНОВЛЕНИЕ батареи, не регресс-поломка; все
прочие 93 ассерта (грамматика, таблицы, models, check-types, doctor,
install.sh, json-схема мёртвого порта) остаются нетронутыми и зелёными.

PATH-заглушки — каталог `$TMP/faux` (как 1.1, но шире), каждая пишет
`$GFCTL_FAUX_LOG` построчно «<cmd> <args…>» и сценарится env-флагами:
`podman` (run/logs/inspect/rm/rmi/ps — инварианты ниже; сценарии: run-fail-N
раз, logs=фикстурный лог, inspect=state), `systemctl` (лог
daemon-reload/enable/start/disable/is-enabled), `loginctl` (enable-linger/
disable-linger/show-user), `sudo` (лог + passthrough-нет: rc 0), `curl`
(лог URL; /ready → rc 0, chat-completions → скриптовый JSON),
`sleep` (мгновенный — батарея быстрая). Прогон команды:
`PATH="$TMP/faux:$PATH" GFCTL_DIR="$TMP/stack" GFCTL_YES=1 ./gfctl …`.

| DoD | internal check (новые секции батареи) |
|---|---|
| 1 команды реализованы, заглушки сняты ровно | секция «заглушки»: `watch/bench/cache/agent-check` → rc=1 «этап»; остальные команды не die-заглушки (у install/use см. ниже) |
| 2 tpl/ юниты | install с faux-bin → в `$TMP/stack`-HOME unit_dir лежат 3 юнита + .env; grep: serve-юнит содержит `ExecStart=.*gfctl _boot`, `KillMode=process`, `TimeoutStartSec=900`; timer содержит `OnUnitActiveSec=1min`; watchdog-юнит — `_watchdog`; render_tpl die на шаблоне с чужим `__X__` (синтетический tpl) |
| 3 serve из таблицы, F9 ровно | install happy-path → строка `podman run` в faux-логе байт-в-байт = канонической строке Design (подставлены реальные пути $TMP); `serve_args 27b-multi 2 163840` содержит `/models/<draft-файл>` и `--sessions 2 --context 163840`; два вызова serve_args — идентичный вывод; flash: `--model` = 00001-шард + `--mtp-model /models/mtp-…`; неизвестный токен → die |
| 4 health | фикстурный лог с `event=load_completed … speculative=dflash2 sessions=1 context_tokens=262144 model=X` на stdin → parse_route выставляет ROUTE_*; wait_load(4) с stub-podman logs + GFCTL_HEALTH_POLL=1 → rc 0 + строка «роут: dflash2, sessions 1, ctx 262144»; лог БЕЗ load_completed, timeout 3 → rc 1 + хвост логов; ранний выход на load_failed проверяется unit-вызовом wait_load с пониженным порогом GFCTL_LOADFAIL_AFTER (seam, дефолт 20); curl-stub /ready rc≠0 → wait_health rc 1 |
| 5 recreate→health→smoke порядок | install happy-path faux-лог: порядок вызовов `podman rm` → `podman run` → `podman logs` → `curl …/ready` → `curl …/chat/completions` (grep -n по логу, индексы возрастают); use — тот же порядок |
| 6 off/watchdog-marker | off с faux-bin: в faux-логе `touch`-эффект (маркер-файл существует) РАНЬШЕ `podman rm` и `systemctl disable`; есть `loginctl disable-linger`; юнит-файлы удалены. `_watchdog` при маркере → ноль вызовов podman run, rc 0. `_watchdog` без маркера + inspect=exited → ровно один run. `on` → enable serve+timer + `enable-linger` + маркер снят + run |
| recreate ретрай | stub podman: run падает 1 раз → ровно 2 вызова run, rc 0; падает GFCTL_RUN_ATTEMPTS раз → die rc 1, вызовов run = attempts |
| 7 uninstall слои | uninstall без флагов (GFCTL_YES=1): файл весов на месте, `podman rmi` ОТСУТСТВУЕТ в логе, дерево стека удалено кроме models; `--purge-models --purge-image` → веса удалены + `podman rmi` в логе; не-TTY без --yes → rc 1 и НИЧЕГО не удалено |
| logs | `logs 50 -f` → в faux-логе `podman logs -f --tail 50`; missing-контейнер → die rc 1 |
| smoke | stub curl chat → валидный JSON → «SMOKE: OK» rc 0; первый запрос неудачен, повтор ок (GFCTL_SMOKE_RETRY_S=0) → curl-вызовов ровно 4 (2+1+1), rc 0; все три неудачны → rc 1 |
| 8 status живой | stub logs с load_completed + curl ok → человекострока с «роут: dflash2…» + `--json`: route={speculative,sessions,context,model}, autostart=true, version=строка, cache.dir; python-ассерт: старые ключи/типы на месте; мёртвый порт → route/autostart/version=null (схема 1.1 не сломана — прежний ассерт секции 12 остаётся) |
| canon .env | write_canon → файл байт-в-байт с env-шаблоном; canon_get: env-оверрайд > .env > default; кривой GFCTL_PROFILE в .env → дефолт (как cur_profile 1.1) |
| install use flows | use на неизвестный профиль → die; use --sessions abc → die; use happy-path: .env перезаписан с новым профилем, ровно один run, один enable-набор не дублирован (install поверх работающего: юнит-файлы те же 3, run ровно 1) |
| boot | subshell-перезагрузка lib/serve.sh + autostart.sh с оверрайдом gpu_nodes_present (как секция 6 батареи): нода «появилась» со 2-й проверки → run вызван, rc 0; нода не появляется, deadline=2,sleep=1 → rc 1 |
| регресс | полный прогон run_checks.sh: PASS≥93 прежних (за вычетом п.0-замещений) + новые все зелёные; `bash -n`; py_compile |

External (не в DoD 1.2, блокирует только приёмку этапа 1 — оркестратор):
реальный podman run + health + smoke на evo (EXP-003+, создание — этап
приёмки), ребут-подъём через юниты, поведение watchdog в 70 c после off.

## Risks and rollback

- **rm+run теряет логи прежнего контейнера** (`podman logs` после rm пуст) —
  принято: роут всегда из ПОСЛЕДНЕГО load_completed, cache-disk в volume,
  state в canon; риск только для ручного чтения истории — `~/gufo/logs/`
  хранит watchdog/boot-события, контейнерные логи — через живой `logs`.
- `sudo`-шаги (limits.d, linger) на машинах без точечного sudo → install
  падает на 42/linger: сообщение-подсказка, доког в EXP приёмки.
- Гонка .env (watchdog читает во время write_canon) закрыта mv-атомарностью.
- Строки движка (`load_completed`, `/ready`) могут смениться в будущих
  ревизиях gufo — парсинг изолирован в parse_route/http_ready (одно место
  правки); факты подтверждены окнами IX/FX (FACTS-даты).
- JSON-экранирование строк из лога (backlog 1.1) — route.model от движка,
  кавычки не содержит; остаётся non-critical backlog.
- Откат: `git revert` коммита сабстэджа; контракты 1.1 не ломаются
  (замещения батареи — п.0 Test strategy).

## References

- SPEC §2 (стек ~/gufo), §3 (команды), §4 (модель состояний, канон .env),
  §5 (профильная таблица + константы запуска), §6 (роут/health из лога,
  смоук-ретрай), §8 (отличия: прямой podman run, recreate=rm+run, serve-unit
  + watchdog timer, маркер), §9 (gpu-lock/D3, userns-гейт).
- FACTS: F1 (веса качает gfctl), F2 (--host 0.0.0.0), F9 (podman-флаги ровно),
  F10 (пауза recreate), F11 (linger off только в off), F15 (ретрай 15 с),
  F16 (watchdog-паттерн, маркер). DECISIONS: D1 (локальная дистрибуция),
  D2 (порт 8080), D3 (без takeover — только WARN).
- Код: `gfctl` (роутер, globals), `lib/profiles.sh` (поля 1–9,
  @DRAFT@/@MTP@, cur_profile), `lib/models.sh` (weights_for/set_file_role/
  download_file), `lib/commands.sh` (cmd_models/cmd_doctor/cmd_status 1.1),
  `tests/run_checks.sh` (faux-bin паттерн секций 9–13).
- hfctl-образцы: `lib/autostart.sh` (cmd_on/off/up/watchdog/boot, маркер ДО
  stop), `lib/health.sh` (wait_health/smoke-ретрай), `lib/stack_files.sh`
  (render_tpl), `tpl/systemd/*.tpl` (KillMode=process, таймер 1 мин).

## Open questions

1. **install при живом hfctl-проде (gpu-lock)** — WARN+продолжать
   (рекомендация: D3-совместимо, нагрузка честно упадёт на load_failed с
   внятным логом) vs abort до скачивания весов. НЕ блокирует (по умолчанию
   WARN+continue).
2. **use --no-probe в 1.2** — accept+WARN no-op (рекомендация: грамматика
   1.1 флаг содержит; семантически «no probe» в 1.2 уже истинен) vs die.
   НЕ блокирует (по умолчанию WARN no-op).
3. **Семантика `down`** — brief: «down = off» (рекомендую: краткая форма,
   полное снятие автозапуска) vs hfctl-паритет «down = стоп с маркером, юниты
   остаются enabled». НЕ блокирует (по умолчанию down = off).
4. **Ранний выход wait_load на load_failed** — порог 20 c до проверки
   (рекомендация: не ловить ложный load_failed при старте podman) vs 0 c.
   НЕ блокирует; тестовый seam GFCTL_LOADFAIL_AFTER для батареи.
