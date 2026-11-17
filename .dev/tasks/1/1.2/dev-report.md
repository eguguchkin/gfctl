# Dev report: 1.2 жизненный цикл — serve-юниты + install/use/on/off/uninstall + smoke/logs + watchdog/boot

- Дата: 2026-11-17 · fix round: 1 (первая реализация, round 0/3)

## What was done

Реализовано строго по `.dev/tasks/1/1.2/task.md` (Design + Test strategy);
открытые вопросы закрыты решениями оркестратора (gpu-lock → WARN+continue,
`--no-probe` → WARN no-op, `down` = `off`, load_failed-порог 20 с).

**Новые lib-модули (5):**
- `lib/state.sh` — канон профиля `~/gufo/.env`: `canon_get` (приоритет
  env > .env > дефолт), `canon_sessions/canon_context` (дефолт — поля 3/4
  таблицы), `canon_port/canon_bind` (дефолт — глобалы диспетчера),
  `write_canon` — render `tpl/env/env.tpl` в `.env.tmp` + `mv` (атомарно);
  единственный писатель .env.
- `lib/serve.sh` — `serve_args` (чистая печать `gufo serve llm …`: `--host
  0.0.0.0` всегда (F2), `--model` = файл роли main (flash — первый шард
  00001), `@DRAFT@`/`@MTP@` → `/models/<файл>`, неизвестный токен → die,
  кэш-тиры полей 5/6); `gpu_nodes_present` (выделена под battery-оверрайд);
  `container_state`/`container_stop`; `container_up <профиль>` — ЕДИНСТВЕННЫЙ
  путь подъёма: rm → mkdir cache → пауза `GFCTL_RECREATE_PAUSE_S` (F10) → до
  `GFCTL_RUN_ATTEMPTS` попыток `podman run` с F9-флагами ровно, маунт
  каталога-сета `models:ro` и cache-тома; неудача всех → хвост логов + die.
- `lib/units.sh` — `render_tpl` (1:1 из hfctl stack_files.sh, die на
  нераскрытых `__X__`), `install_units` — 3 юнита в `~/.config/systemd/user/`
  (`gfctl-serve.service`, `gfctl-watchdog.service`, таймер — статичный
  `install -m 0644`).
- `lib/health.sh` — `parse_route` (чистый фильтр stdin → ROUTE_SPEC/SESSIONS/
  CTX/MODEL, последняя `event=load_completed` побеждает), `wait_load`
  (таймаут 180 с, шаг `GFCTL_HEALTH_POLL`, прогресс-печатка, ранний выход по
  `load_failed` после `GFCTL_LOADFAIL_AFTER`=20 c с хвостом логов),
  `http_ready` (curl `/ready`), `wait_health` (load → http-поллинг до 30 с →
  печать «роут: …»), `smoke` (3 запроса код/проза/математика с
  `"model":"$ROUTE_MODEL"`; ретрай РОВНО первого через
  `GFCTL_SMOKE_RETRY_S`=15 (F15); валидация `tpl/python/smoke_resp.py`).
- `lib/autostart.sh` — `autostart_on` (units → daemon-reload → enable
  serve+timer → start timer → rm маркера → `enable-linger`), `cmd_on` =
  autostart_on + cmd_up (без smoke), `cmd_up` (скрытый `up`: маркер + recreate
  + wait_health 300), `cmd_off` (скрытый `down`; порядок фиксированный:
  touch-маркер ДО container_stop → disable → rm юнитов → daemon-reload →
  `disable-linger` (F11)), `cmd_watchdog` (маркер — ПЕРВАЯ проверка (F16),
  затем canon .env, затем state ≠ running → лог-строка в
  `logs/watchdog.log` + `container_up || true`; rc всегда 0), `cmd_boot
  [deadline=420] [sleep=10]` (цикл gpu_nodes_present → container_up → state
  = running; исчерпан бюджет → rc 1 для Restart=on-failure).

**tpl/ (4 шаблона + 1 python):**
- `tpl/systemd/gfctl-serve.service.tpl` — oneshot + RemainAfterExit=yes +
  KillMode=process + TimeoutStartSec=900 + Restart=on-failure/30;
  ExecStart=`bash $STACK/gfctl _boot` (serve-юнит И ЕСТЬ boot-юнит),
  ExecStop=`podman rm -f` (страховка); маркеры `__STACK_DIR__`,
  `__PODMAN_BIN__`, `__CONTAINER__`.
- `tpl/systemd/gfctl-watchdog.service.tpl` (oneshot+KillMode=process,
  `_watchdog`), `tpl/systemd/gfctl-watchdog.timer.tpl` (OnBootSec=2min,
  OnUnitActiveSec=1min, RandomizedDelaySec=10).
- `tpl/env/env.tpl` — канон `GFCTL_PROFILE/SESSIONS/CONTEXT/PORT/BIND/
  MODELS/IMAGE`, маркеры `__X__`, шапка «правки конфига — через install/use».
- `tpl/python/smoke_resp.py` — копия 1:1 из hfctl.

**Правки существующих:**
- `gfctl` — глобалы `CONTAINER`, `UNIT_NAME`, `LOGS_DIR`, `UNIT_DIR`;
  source-порядок profiles→models→state→serve→units→health→autostart→commands;
  роутер: `install|use|logs|on|off|up|down|uninstall|smoke` живые, скрытые
  `_watchdog`/`_boot`, die-заглушки остались РОВНО у `watch|bench|cache|
  agent-check`; пометки «[этап 1.2]» в usage сняты.
- `lib/models.sh` — extract `ensure_weights <сет>` (ask только при
  недостающих файлах, объём недостающего; download_file по каждому,
  полные — SKIP без сети); `cmd_models download` зовёт её (одна семантика
  согласия).
- `lib/commands.sh` — `port_open` принимает аргумент (живые вызовы —
  canon_port); `cmd_status` живой режим (роут из лога через parse_route,
  autostart через `systemctl --user is-enabled`, версия через
  `podman inspect -f '{{.ImageName}}'`, кэш через `du -sb`; при мёртвом
  порте route/autostart/version/cache = null — схема 1.1 не сломана, ключ
  `cache` добавлен В КОНЕЦ JSON); новые `cmd_install` (preflight-гейты с
  gpu-lock WARN+continue (D3) и memlock exit 42 → ensure_weights →
  install_units → write_canon → recreate → health 180 → smoke →
  autostart/--no-autostart), `cmd_use` (гейты → ленивый добор → канон →
  recreate → health → smoke; `--no-probe` = WARN no-op; overrides
  sessions/context в канон), `cmd_logs` (-f/--tail, missing → die),
  `cmd_smoke`, `cmd_uninstall` (5 слоёв ПО ПОРЯДКУ; модели и образ по
  умолчанию живы; `find -mindepth 1` не сносит базу весов внутри стека).
- `tests/run_checks.sh` — п.0 Test strategy: секция 2 замещена (заглушки
  rc=1 «этап» остались только у watch/bench/cache/agent-check; install/use/
  logs/on/off/up/down/uninstall/smoke проверены «не die-заглушки»), ассерт
  секции 12 заменён на живой формат человекостроки (+cache:null в
  python-схеме мёртвого порта); НОВЫЕ секции 14–25: faux-bin каталог
  (podman/systemctl/loginctl/sudo/curl/sleep с построчным логом
  `$GFCTL_FAUX_LOG` и env-сценариями `GFCTL_FAUX_*`), harness-функция `gf`
  (мини-диспетчер в субшелле: глобалы диспетчера + все lib + faux-PATH,
  оверрайды гейт-функций кодом) и `frun` (процессный запуск с PATH-заглушками),
  фикстуры лога движка; ассерты: write_canon байт-в-байт с env.tpl,
  canon_get-приоритет, serve_args байт-в-байт канону Design, install
  happy-path (podman run байт-в-байт канону с реальными $TMP-путями,
  3 юнита с контент-грепами, порядок recreate→health→smoke по faux-логу,
  идемпотентность повтора), use-флоу (канон, оверрайды, no-autostart,
  die-ветки), health (parse_route «последняя побеждает», wait_load
  таймаут/load_failed-ранний выход, wait_health + роут-строка, http-отказ),
  boot (GPU-ноды не появились → rc 1; появились со 2-й проверки → 1 run),
  watchdog (маркер-раньше-подъёма, .env-гейт, exited → 1 run + лог-событие),
  off (touch РАНЬШЕ rm/disable по логу, юниты сняты, linger off), on/up
  (enable-набор, маркер снят, on без smoke), recreate-ретрай (1 падение →
  ровно 2 run; все attempts → die с run=attempts), logs (порядок флагов,
  missing → die), smoke (3 вызова; ретрай первого 2+1+1=4 c WARN; провал →
  rc 1), uninstall (слои, веса/образ живы по умолчанию, purge-флаги,
  отказ без GFCTL_YES ничего не удаляет), status живой (человекострока с
  роутом/кэшем, JSON route/autostart/version/cache + старые ключи и типы).
- `tpl/python/smoke_resp.py` — добавлен (копия hfctl).

Итого 13 файлов: 5 lib + 4 tpl + 1 python + `gfctl` + батарея (+ report).

## How it was checked internally

- `bash tests/run_checks.sh` → **ИТОГО: PASS=180 FAIL=0** (3 прогона
  подряд, ~4.6 с каждый — стабильно). Регресс 1.1: секции 3–11, 13
  нетронуты и зелёные (93 прежних ассерта за вычетом п.0-замещений: секция 2
  «заглушки» и человекострока секции 12 заменены осознанно по п.0 Test
  strategy — в 1.1 их было 12+1=13, теперь 17+1=17 в тех же секциях).
- `bash -n gfctl lib/*.sh` ✓ и `python3 -m py_compile tpl/python/*.py` ✓
  (секции 1 батареи).
- AGENTS internal checks покрыты батареей: bare → usage rc=1 ✓; `status
  --json` при мёртвом порте → валидный JSON, null'ы схемы 1.1 ✓.
- Гигиена: роль не делает реальных podman/systemd/loginctl/sudo вызовов —
  все внешние бинари в батарее через faux-PATH (в контейнере их и нет);
  сеть — только localhost (file://-curl секции 9 и слушатель 127.0.0.1:8080
  на python-stdlib в секции 25, гасится по завершении); HOME/GFCTL_DIR
  прогонов — в mktemp-каталоге.

## Not checked internally

- Реальный `podman run` с F9-флагами, реальный systemd-user юниты (enable/
  start/linger), реальный rootless-порт-ретрай F10 и поведение вотчдога в
  70 с после `off` — **не проверяемо в dev-контейнере**; подтверждается
  EXP-приёмкой этапа 1 на che-evo (EXP-003+, GO пользователя).
- Реальная строка `load_completed` и `/ready` движка 0.34.x — парсинг
  изолирован в `parse_route`/`http_ready`, фикстуры батареи сняты с окон
  IX/FX (FACTS-даты); живое подтверждение — в EXP.
- memlock-ветка `install` (sudo tee limits.d + exit 42) на реальной машине —
  в батарее sudo-заглушка; живой прогон — EXP (машина может требовать
  перелогин — сообщение WARN напечатано).

## Known limitations / assumptions

- `parse_route`/`smoke` требуют, чтобы ROUTE_* заполнялись В ТОМ ЖЕ
  процессе — поэтому `podman logs | parse_route` заменён на
  `parse_route < <(podman logs …)` (правая часть пайпа — субшелл, глобалы
  бы потерялись; найдено батареей на первом прогоне).
- `cmd_use` НЕ перерендеривает юниты (в task.md Design их перечня нет:
  serve-юнит не содержит профильных данных — serve-строка собирается из
  канона в момент container_up/_boot; «перегенерация юнита» из brief
  вырождается в identity). Если reviewer сочтёт нужным literal-render —
  это одна строка `install_units` в cmd_use.
- Человекострока status: порядок полей `профиль | health | автозапуск |
  роут | кэш | веса` и слово `health:` соответствуют замороженному
  контракту батареи 1.1 и task.md Design, но отличаются от эскиза SPEC §4
  (`автозапуск` вторым, «healthy:»). Оркестратору: скорректировать эскиз
  SPEC §4 или завести notes — в этот сабстэдж SPEC править не стал (не
  граница, а формат строки; контракты 1.1 важнее).
- Конфликт «GFCTL_PORT в env + install --port N»: env побеждает
  (canon-приоритет env > .env по Design) — аргумент молча затеняётся;
  консистентно во всех потребителях порта. Не ловится WARN — предложено
  в out-of-scope.
- `wait_load` печатает прогресс каждую итерацию в stdout (по Design) —
  при живой загрузке ~90 с это ~18 строк; в logs не пишется.

## Out-of-scope proposals

- WARN при одновременном env-оверрайде порта и `--port` (молчаливое
  затенение аргумента) — одна строка в cmd_install/cmd_use.
- `logs` без `-f` с большим N при мёртвом контейнере: podman вернёт пусто
  с rc 0 — можно добавить WARN «контейнер exited» (сейчас только missing
  даёт die).
- JSON-экранирование `route.model`/`cache.dir` (backlog 1.1, остаётся).
- Секция 19: таймаут-ветки wait_load опрашивают faux-лог мгновенно (sleep-
  заглушка); реальный ритм опроса на живой загрузке ~180 с — только в EXP.

## Files

- Новые: `lib/state.sh`, `lib/serve.sh`, `lib/units.sh`, `lib/health.sh`,
  `lib/autostart.sh`, `tpl/env/env.tpl`,
  `tpl/systemd/gfctl-serve.service.tpl`,
  `tpl/systemd/gfctl-watchdog.service.tpl`,
  `tpl/systemd/gfctl-watchdog.timer.tpl`, `tpl/python/smoke_resp.py`.
- Изменены: `gfctl`, `lib/models.sh`, `lib/commands.sh`,
  `tests/run_checks.sh`.
- Не тронуты: `.dev/STATE.md`, `.dev/history/`, `install.sh`,
  `tests/make_fixtures.py`, `tests/fixtures/`, `tpl/bench/`,
  `tpl/python/gguf_type_check.py`, секции 3–13 батареи (кроме п.0-замещений).
