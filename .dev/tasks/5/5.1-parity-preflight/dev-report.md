# Dev report: 5.1-parity-preflight

- Дата: 2026-11-21 / fix round 1 (первый проход developer, сессия ses_e00abb087ffeoy6mcwSY99ULwf)

## What was done

Все пункты скоупа task.md (Round 1 Design + Round 2 ратификация D8) выполнены.

**1. Preflight apt → `preflight_host()` (install И use)** — `lib/commands.sh`:
- новая `preflight_host()` (секция 1.2, перед `cmd_install`): порядок ровно по
  Design — ОС Linux → GPU-prep групп → железный гейт `gpu_nodes_present` →
  RAM-гейт → apt-пятёрка И1 → gpu-lock warn → memlock-гейт; тексты die/42 и
  memlock-блок перенесены **байт-в-байт** из прежнего inline-блока cmd_install;
- apt-пятёрка (`podman podman-compose containers-storage psmisc curl`): один
  `sudo apt-get update -qq && sudo apt-get install -y -qq $need` ТОЛЬКО при
  непустом need («всё на месте» → ноль sudo/apt); нет sudo/apt-get → die с
  ручным рецептом (списком need); apt-сбой → die «apt не смог…»;
- `cmd_install`: inline-блок гейтов заменён на `preflight_host "$prof"`
  (строка `log "preflight: профиль $prof"` осталась в cmd_install);
  прежний render-WARN «юзер не в группе render» удалён — полностью перекрыт
  GPU-prep;
- `cmd_use`: inline RAM-гейт удалён, вставлен `preflight_host "$prof"`
  (И1: use = входная команда «одной командой», первый use доводит хост сам).

**2. GPU-подготовка (шаг 2 preflight)** — `lib/commands.sh`:
- гейт по существованию `${GFCTL_KFD:-/dev/kfd}` / `${GFCTL_DRI:-/dev/dri}`
  (хуки только для selfcheck-батареи; прод env пуст);
- группы: `id -nG` на ОБЕ (render, video); отсутствует хоть одна →
  `sudo usermod -aG render,video` + честное «группы применятся только после
  перезахода…» + **exit 42**; обе есть → no-op без sudo;
- нет GPU (`kfd`/`dri` не существуют) → одна info-строка «GPU-устройства не
  найдены (…) — GPU-подготовка пропущена» (не молча, не WARN — по Design);
- limits.d НЕ дублируется: единственный владелец
  `/etc/security/limits.d/99-gfctl-memlock.conf` — прежний memlock-гейт
  (шаг 7, порог 8388608/exit 42); GPU-prep второй файл не пишет.

**3. Slirp-скоуп** — `gfctl` + `tpl/containers/gfctl-containers.conf` (NEW):
- новый статичный tpl-файл (ровно канон EXP-013 llm-lab: `[network]
  default_rootless_network_cmd = "slirp4netns"` + комментарий; без
  плейсхолдеров — render_tpl не нужен);
- `bootstrap_dirs` дополнен доставкой
  `$STACK_DIR/.gfctl-containers.conf` из tpl: `cmp`-гвард (равен → 0
  действий), `install -m 0644`; tpl-источника нет (клон без tpl) → тихий
  пропуск (экспорт не случится — поведение как прежде);
- сразу после bootstrap — гвард-export: `if [ -f … ]; then export
  CONTAINERS_CONF=…; fi` (set -e-безопасный if) — до source lib и роутера;
  env видят только дети gfctl → покрыты ВСЕ podman-вызовы, включая
  `_boot`/`_watchdog` (юниты исполняют `bash …/gfctl _boot|_watchdog`);
  юнит-шаблоны НЕ менялись (T11 — регресс-страж);
- `.gitignore`: +1 строка `.gfctl-containers.conf` (derived-артефакт корня
  клона); **uninstall не менялся** — файл живёт в клоне, регенерируется
  bootstrap'ом, ничего нового вне клона не появляется.

**4. Orphan-heal — MIRROR hfctl (Round 2/D8)** — `lib/serve.sh`:
- `HEAL_MAX="${GFCTL_HEAL_MAX:-2}"` + `GF_ORPHAN_HEALS=0` в шапке модуля;
- `gf_orphan_heal()` — 1:1 с `hf_orphan_heal`
  (/workspace/hfctl/lib/autostart.sh:294–328, только ЧТЕНИЕ; hfctl не
  тронут) по духу gf-конвенций: сигнатура `already in use by
  [0-9a-f]{12,64}` (grep глушен `|| true` — пустой ID = не сирота, rc 1) →
  гард 1 кап `GF_ORPHAN_HEALS < HEAL_MAX` → гард 2 бинаря нет → WARN + ручной
  рецепт (`sudo apt install containers-storage; вручную:
  containers-storage delete-container <ID>`), return 1 → гард 3 `podman
  inspect` успешен → «ID видит libpod — не сирота», return 1 → инкремент
  счётчика → гард 4 `containers-storage delete-container` отказал → WARN;
  успех → log «storage-сирота <ID> удалена (external entity) — повторяю up»;
- `container_up`: вывод `podman run` теперь захватывается (`run_out`); при
  отказе — `gf_orphan_heal "$run_out"` ДО следующей попытки цикла (хил не
  сработал → ошибка попытки печатается в stderr как прежде — диагностика не
  глотается); happy-path хил не зовёт (вызов только при отказе run);
  die при исчерпании попыток сохранён и дополнен ручным рецептом: «…Если в
  ошибке выше „…already in use by <ID>…“, а ID не виден в podman ps -a — это
  storage-сирота: containers-storage delete-container <ID>».

**5. doctor (только чтение, rc 0)** — `lib/commands.sh`:
- новая строка «пакеты (apt-пятёрка И1): podman: да | podman-compose: нет |
  containers-storage: да | psmisc (fuser): да | curl: да» (факт `command
  -v`; «нет» = информация, не WARN);
- «render-группа» → «группы render/video: да/нет (WARN — sudo usermod -aG
  render,video \$USER)»;
- новые строки «slirp-скоуп: да (slirp4netns; <путь>)» /
  «нет (CONTAINERS_CONF не задан — глобальный pasta-бэкенд)» и «хранилище
  (graphRoot): <путь|?> (общее с hfctl…)» (`podman info` при доступном
  podman, сбой → «?»).

**6. Батарея** — `tests/run_checks.sh`: +19 ассертов (ниже), faux-механика:
- новые faux: `id` (мок ТОЛЬКО `id -nG` через `GFCTL_FAUX_GROUPS`, остальное
  passthrough в реальный /usr/bin/id), `usermod` (журнал+rc 0),
  `podman-compose`, `containers-storage` (журнал+rc 0); счётчик заглушек
  7→11 (ассерт обновлён — адаптация, не ослабление);
- faux `podman`: строка `env CONTAINERS_CONF=<значение|пусто>` в журнал по
  `GFCTL_FAUX_LOG_ENV=1` (старые счётчики строк не едут) + сигнатура сироты
  на падающем run по `GFCTL_FAUX_ORPHAN=1` (ID — `GFCTL_FAUX_ORPHAN_ID`);
- харнесс-шимы новых гейтов: `frun` — дефолт `GFCTL_FAUX_GROUPS="tester
  render video"` (уважает caller-значение); `gf` — после source:
  `gpu_nodes_present(){ return 0; }` + `ulimit(){ echo unlimited; }` +
  тот же дефолт групп (сценарии переопределяют свободно; сами ассерты не
  ослаблены — §17/§17b/§18/§26+ работают как прежде);
- новые секции: **§17c** — T1 pkgs-missing (stripped-PATH: в журнале ровно
  пара `apt-get update -qq` → `apt-get install -y -qq podman
  podman-compose containers-storage psmisc curl`, rc 0), T2 pkgs-present
  (apt 0 раз), T3 нет sudo (rc 1 + FATAL с рецептом), T4 apt-сбой (rc 1,
  «apt не смог», memlock-гейт не достигнут), T5 не-GPU (info-пропуск,
  железный гейт прежний текст rc 1, usermod/apt/limits 0), T6 группа
  отсутствует (rc 42, `sudo usermod -aG render,video tester`, «после
  перезахода», apt/limits не достигнуты — GPU-prep раньше apt), T7 группы
  ок (usermod 0), T8 use-путь (preflight в use: rc 0, GPU-пропущена,
  usermod/apt 0), T9 скоуп-файл (bootstrap доставил, байты = tpl, env
  CONTAINERS_CONF в журнале faux-podman, doctor: да), T10 скоуп-гвард
  ((а) свежий клон — доставка+экспорт; (б) tpl-источника нет → файла нет →
  env чист; (в) tpl вернули → файл восстановлен), T11 юниты (ExecStart
  цел, CONTAINERS_CONF в юнитах/tpl НЕТ — юниты не разрослись), T12 doctor
  (пакеты-пятёрка с compose «нет» через DOCFAUX-набор, slirp-скоуп: да,
  группы render/video: да, rc 0); **T13** = §17b (а)/(б) без изменений
  (регресс байт-в-байт подтверждён прогоном);
  **§21b** — T14 сигнатура→heal→retry (`containers-storage delete-container
  <ID>` ровно 1 раз, ровно 2 run, rc 0), T15 гард libpod (ID видит libpod →
  0 delete-container, WARN, обычный retry), T16 бинаря нет (PATH без
  containers-storage: WARN + ручной рецепт с ID, delete-container в журнале
  нет, retry как прежде), T17 кап (`GFCTL_HEAL_MAX=1`: ровно 1 heal, вторая
  ошибка не лечится, die при исчерпании содержит рецепт), T18 happy-path
  (чистый run: containers-storage 0 раз, хил-ветка не входила).

**7. SPEC honesty той же дельтой**:
- `.dev/SPEC.md`: §2 — bootstrap-абзац (+conf-файл), gitignore-строка,
  новый абзац «Первичная установка — preflight хоста (5.1, И1)», исключения
  «вне каталога» пополнены (группы render/video, apt-пятёрка в системе);
  §3 — строки install (preflight_host с полным порядком) и use (preflight
  хоста как у install), doctor (новые секции); «Соответствие gfctl» —
  ревизия 2026-11-21: И1 **по коду полное** с честной оговоркой «bare-приёмка
  отложена (D8), EXP-013 deferred, живьём не подтверждён до окна»; И2
  расширено (rm-в-попытке fix-r2 + mirror-хил gf_orphan_heal); чек-лист
  «Этап 5» — кодовые пункты [x] с пометками приёмочных, окно оставлено
  открытым;
- `AGENTS.md`: bootstrap-абзац — «…создаёт каркас .data/ + ставит
  .gfctl-containers.conf (скоуп slirp4netns, export CONTAINERS_CONF —
  этап 5.1; юниты НЕ ставит)»;
- `spec_validate` после правок — **valid** (структурных правок фронта не
  было; SPEC.md — прозаический документ проекта).

**8. EXP-скрипты (созданы, НЕ запущены — D6)** — `.dev/external/`:
- `EXP-013-gfctl-parity-bare.sh` — STATUS: **DEFERRED** в шапке (ресурс не
  выделен — D8); PHASE=1 (клон GitHub → doctor честный → use: rc 0 или rc 42
  + факт групп в `id -nG` + limits.d-файл) / PHASE=2 (после перезахода: use
  → health → smoke → apt-повтор = 0 по /var/log/apt/history.log) / PHASE=3
  (после ребута: юниты enabled, контейнер running, health — ребут-приём
  fix-r2); пролог перелогина;
- `EXP-014-gfctl-off-hfctl-on.sh` — bootstrap = git pull обоих клонов (И3/
  F21), `gfctl off` → диагностические чтения (podman ps -a, pgrep
  pasta/slirp, linger) → `hfctl on` → wait-health → отсутствие «already in
  use»/«kill network process» → linger=yes (F11); пролог перелогина;
- `EXP-015-hfctl-off-gfctl-on.sh` — обратная последовательность + slirp-
  ассерты: (а) slirp>0 и pasta не растёт от gfctl-операций, (б) recreate-цикл
  (`use --no-probe` по канону) без «kill network process» и «already in
  use», journalctl-чтение, (в) graphRoot с env и без идентичен (до и после
  recreate), (г) обратный `hfctl on` здоров + linger=yes; F23 — отдельный
  вызов, без параллельных прогонов.
- Все три: `bash -n` зелёный; вывод → `EXP-<id>-….result.txt`, финал
  `RESULT: PASS|FAIL|ERROR — …`.

### Файлы дельты

| Файл | Изменение |
|---|---|
| `gfctl` | bootstrap_dirs: доставка conf (cmp-гвард) + export CONTAINERS_CONF (if-гвард) |
| `lib/commands.sh` | NEW `preflight_host()`; cmd_install/cmd_use перепрошиты; doctor +3 секции |
| `lib/serve.sh` | `HEAL_MAX`/`GF_ORPHAN_HEALS` + `gf_orphan_heal()` + интеграция в `container_up` + die-рецепт |
| `tpl/containers/gfctl-containers.conf` | NEW (канон EXP-013 llm-lab) |
| `.gitignore` | +1 строка `.gfctl-containers.conf` |
| `tests/run_checks.sh` | faux id/usermod/podman-compose/containers-storage + env-строка + orphan-сигнатура; харнесс-шимы; §17c (T1–T12) + §21b (T14–T18) |
| `.dev/SPEC.md` | §2/§3/Соответствие/Этап 5 (spec-honesty) |
| `AGENTS.md` | bootstrap-абзац (conf-файл) |
| `.dev/external/EXP-013-gfctl-parity-bare.sh` | NEW (deferred, D8) |
| `.dev/external/EXP-014-gfctl-off-hfctl-on.sh` | NEW (не запущен, D6) |
| `.dev/external/EXP-015-hfctl-off-gfctl-on.sh` | NEW (не запущен, D6) |

Не тронуты (по скоупу): `uninstall` (cmd_uninstall), юнит-шаблоны tpl/systemd,
README, hfctl (только чтение), llm-lab (только чтение).

## How it was checked internally

| Проверка | Команда | Результат |
|---|---|---|
| Синтаксис shell | `bash -n gfctl lib/*.sh` | OK |
| Синтаксис батареи и EXP | `bash -n tests/run_checks.sh .dev/external/EXP-0*.sh` | OK |
| Python (не менялся, гейт AGENTS) | `python3 -m py_compile tpl/python/*.py` | OK |
| Полная батарея | `bash tests/run_checks.sh` | **PASS=400 FAIL=0**, rc 0 (базлайн 381 + 19 новых; прогнан дважды — стабильно) |
| usage-гейт | `./gfctl` без аргументов | rc=1 + usage (гейт AGENTS) |
| status --json мёртвый порт | `GFCTL_PORT=8198 ./gfctl status --json` | rc=0, корректный отказ (гейт AGENTS) |
| §37 watch не задет | полный прогон батареи | §37 зелёный (shell-дельта — gfctl/serve/commands, watch-код не тронут) |
| Спека | `spec_validate` | valid |

Ключевые зелёные регрессы на изменённых путях: §17 install happy-path
(канон-run байт-в-байт), §17b memlock (а)/(б) без изменений, §18 use
(happy-path, канон, юниты, enable fix-r2), §21 recreate-ретрай (rm→run→rm→run),
§24/§41 uninstall (ничего нового не снимает), §26–28/§43 probe и install-probe
(через харнесс-шимы), §40 install идемпотентность, §38 README (4 команды).

## Not checked internally

Всё, что требует живой машины/контейнера — НЕ проверено симуляцией, приёмка
в окне этапа 5 (два GO по D6):

- **apt на голой Ubuntu** — EXP-013 PHASE=1/2 (deferred: ресурс не выделен,
  D8); локальная проба apt не проводилась (ocbox без apt-get/sudo — по
  брифу допустима, но не даёт приёмочного факта);
- **фактический usermod + перезаход** (группы render/video, честный «после
  перезахода») — EXP-013 PHASE=1; риск exit-42 на существующих машинах
  (video-группы может не быть) — в окне предусмотреть перезаход между фазами;
- **slirp4netns на живом podman** (скоуп, graphRoot, pasta-каунты,
  «kill network process») — EXP-015 (а)–(г);
- **сценарные последовательности И2** — EXP-013/014/015 созданы и НЕ
  запущены (D6); bash -n only;
- **gpu-lock WARN на живой машине** (podman ps непуст) и **memlock-WARN
  ветки ≥порога** на реальном sudo tee — faux не исполняет внутренние
  команды;
- **orphan-heal живьём** (реальная сирота) — контракты хила покрыты
  faux-ассертами T14–T18; живой класс — EXP-015 recreate-циклы (если сирота
  вдруг проявится — die-рецепт снимается чтением, дефект в бэклог).

## Known limitations / assumptions

- **T11 — отклонение от буквы task-таблицы**: сценарий «юнит-путь» выполнен
  через gf-харнесс (ассерты на юнит-файлы + grep tpl), а не frun use:
  железный гейт `gpu_nodes_present` намеренно не имеет env-хука (Design §3),
  поэтому dispatcher-процесс в ocbox умирает на нём до рендера юнитов.
  Dispatcher-экспорт при этом покрыт T9 (frun) и T10 (свежий клон) — факт
  «env доходит до podman» проверен именно на процессном пути.
- Тексты memlock-гейта сохранены байт-в-байт по задаче — на use-путе
  сообщение «…повтори gfctl install» выглядит как отсылка к install
  (косметика против байт-в-байта — победила байт-в-байт).
- Вывод успешного `podman run` (container ID) больше не печатается в stdout
  — захватывается для хила; ошибки неуспешных попыток печатаются в stderr
  как прежде (когда хил не сработал).
- need-список apt — строка с пробелами (осознанный word-split; имена
  пакетов без пробелов) — по контракту Design §4.
- EXP-013 доказывает «apt-повтор = 0» по /var/log/apt/history.log (sudo-журнал
  не гарантирован); EXP-015 (б) гоняет recreate через `use --no-probe` по
  канону из .env.
- `install`/`cmp` считаются присутствующими на целевой Ubuntu (coreutils/
  diffutils) — в экзотике «клон без install» bootstrap умрёт по set -e
  громко, что честно.

## Out-of-scope proposals

- doctor мог бы печатать фактическое значение
  `default_rootless_network_cmd` из conf-файла (сейчас факт — сам файл+env);
  не делал — не запрошено.
- Проверка «CONTAINERS_CONF не наследуется чужими процессами» —
  гарантирована моделью env-наследования; отдельный ассерт в батарею не
  вводился (нет механизма faux-детей).
- EXP-010/011/012 и ребут/рестарт-приёмы fix-r2 — остаются в окне этапа 5
  (план STATE), кодом не трогались.
- «Тихий» ремонт conf-файла при ручной порче пользователем (cmp-гвард
  перезапишет только при расхождении — фактически уже покрыт).
