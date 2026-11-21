# Task: 5.1-parity-preflight            Design: architect

## Scope and DoD

Цель — довести поставку gfctl до инвариантов И1–И3 (D7): `git clone →
./gfctl use <профиль>` работает на голой Ubuntu (apt-декларации + GPU-
подготовка хоста), класс AppArmor/pasta teardown снят CONTAINERS_CONF-скоупом
slirp4netns (EXP-012/013 llm-lab), судьба orphan-heal решена (здесь,
ратифицирует пользователь), сценарные последовательности И2 зафиксированы
EXP-скриптами (созданы, НЕ запущены — D6). Живая приёмка — окно, два
отдельных GO (FAEX, evo) — вне этого подэтапа.

**DoD (пересчитан по brief.md: фактических пунктов 7, не 8):**

1. **Preflight apt**: идемпотентная установка apt-пятёрки (`podman
   podman-compose containers-storage psmisc curl` — И1; passt/slirp4netns/
   uidmap приезжают Depends podman) одним `sudo apt-get update -qq &&
   sudo apt-get install -y -qq <список>` ТОЛЬКО при непустом списке
   недостающих; всё на месте → sudo/apt не вызываются вовсе. Нет
   sudo/apt-get/сети → громкий отказ (rc≠0, FATAL с внятным рецептом
   ручной установки), НЕ тихий skip.
2. **GPU-подготовка**: группы render+video (`sudo usermod -aG render,video`)
   с гейтом по `/dev/kfd` ИЛИ `/dev/dri`; при фактичном добавлении — честное
   «группы применятся только после перезахода» + exit 42; обе есть → no-op
   без sudo. limits.d НЕ дублируется: один файл
   `/etc/security/limits.d/99-gfctl-memlock.conf`, владелец = существующий
   memlock-гейт (порог 8388608, exit 42, 4.1-F2) — семантика кодов выхода
   прежняя байт-в-байт; GPU-prep второй файл не пишет (merge-логика).
3. **Slirp-скоуп**: все podman-вызовы gfctl (включая _boot/_watchdog из
   юнитов) идут с `CONTAINERS_CONF=$STACK_DIR/.gfctl-containers.conf`
   (содержимое = проверенный EXP-013: `[network]
   default_rootless_network_cmd = "slirp4netns"`); env процессный — hfctl на
   машине env не получает, глобальный ~/.config/containers не трогается;
   хранилище общее (graphRoot, EXP-013); файл поставляется bootstrap'ом
   каждый запуск (идемпотентно, из tpl/).
4. **Orphan-heal — решение зафиксировано** (пользователь ратифицирует на
   эскалации, см. Open questions): РЕКОМЕНДАЦИЯ = отклонить продукт-код
   (первопричина — pasta teardown signal-deny — уходит со скоупом; gfctl без
   compose, rm-в-попытке fix-r2 покрывает libpod-класс), fallback —
   строка-рецепт в die-сообщении container_up.
5. **Сценарный контракт И2**: EXP-скрипты фиксированных последовательностей
   созданы, НЕ запущены: bare-install (фазы, из GitHub-клона — И3),
   `gfctl off; hfctl on`, обратная; только диагностические ЧТЕНИЯ
   (podman ps/inspect/info, curl, journalctl, pgrep) — никаких ручных
   мутаций вне последовательности. **Поправка (ратифицировано 2026-11-21,
   Round 2): EXP-013 bare-install — created/DEFERRED** (заготовка на будущее
   окно, ресурс не выделен); окно 5.1 закрывает EXP-014/015 + EXP-010/011/012
   + ребут/рестарт-приёмы fix-r2.
6. **Батарея**: новые faux-ассерты (apt-мок, группа-мок, скоуп-файл контент
   + env, doctor-вывод, коды выходов 42/1/0) — зелёные; существующие 381
   не сломаны (сценарии use/install получают шимы НОВЫХ гейтов — ulimit/
   группы — сами ассерты не ослабляются); `bash -n`; `py_compile`.
7. **SPEC honesty той же дельтой**: §2 (apt/GPU-шаги первичной установки,
   «вне каталога» + группа video + conf-файл), §3 (install/use — обновлённый
   preflight), «Инварианты» — соответствие gfctl И1 «частично» → полное
   (дата ревизии), чек-лист «Этап 5» — кодовые пункты отмечены (приёмочные —
   после окна); `spec_validate`; AGENTS.md bootstrap-абзац — обновить
   (bootstrap теперь ставит и conf-файл).

**Out of scope** (явно): живая приёмка — окно/два GO по D6 (EXP-013/014/015
+ хвосты EXP-010/011/012 + ребут/рестарт-приёмы fix-r2 — всё в окне этапа 5,
не здесь); hfctl-код и его .dev — не трогаем (только ЧТЕНИЕ /workspace/
llm-lab, /workspace/hfctl); миграция/ревизия /home/ai — фаза D; AppArmor-
профиль pasta (дистрибутивный фикс — отдельное решение пользователя, EXP-012);
замер скорости pull под slirp4netns (EXP-хвост окна; план Б host-network);
preflight в `on`/`up`/`_watchdog` (работают на установленном стеке — GPU-prep
уже сделан install/use; прецедент hfctl 13.2); doctor-расширение за пределы
перечисленного в Design; python (shell = оркестратор apt/systemctl/файлы —
принцип 4.4).

## Design

### Файлы диффа (ровно)

| Файл | Ответственность |
|---|---|
| `gfctl` | bootstrap: доставка `.gfctl-containers.conf` из tpl + `export CONTAINERS_CONF` (гвард `[ -f ]`) — до source lib, до роутера |
| `lib/commands.sh` | НОВАЯ `preflight_host()` (все гейты хоста одним блоком); `cmd_install`/`cmd_use` зовут её; doctor: пакеты-пятёрка + slirp-скоуп + группы render/video |
| `lib/serve.sh` | die-сообщение container_up: + строка-рецепт «already in use by <ID> → containers-storage delete-container <ID>» (если orphan-heal отклонён) |
| `tpl/containers/gfctl-containers.conf` | НОВЫЙ статичный файл (без плейсхолдеров), содержимое EXP-013 |
| `.gitignore` | +1 строка `.gfctl-containers.conf` (derived-артефакт в корне клона) |
| `tests/run_checks.sh` | faux id/usermod + CONTAINERS_CONF-лог в faux podman + stripped-PATH-набор + ~12–15 новых ассертов + шимы новых гейтов в §17/§18 |
| `.dev/SPEC.md`, `AGENTS.md` | spec-honesty (п.7 DoD) |
| `.dev/external/EXP-013…015-*.sh` | НОВЫЕ скрипты (созданы, не запущены) |

Юнит-шаблоны НЕ меняются: serve/watchdog юниты исполняют `bash $STACK_DIR/
gfctl _boot|_watchdog` — диспетчерский export покрывает их процессы
автоматически (у hfctl такой фокус не вышел бы — там compose() внутри
stack.sh, потому Environment= в tpl; у gfctl ЕДИНАЯ точка входа диспетчера
= меньший дифф). `uninstall` НЕ меняется: conf-файл в клоне (derived,
переживает — регенерируется bootstrap'ом, безвреден), ничего нового вне
клона он снимать не должен (см. Risks).

### 1. Slirp-скоуп: где живёт файл и как скоупится

- Канон содержимого (ровно то, что проверен EXP-013, ничего лишнего;
  статичный файл без плейсхолдеров — render_tpl не нужен):
  ```toml
  # gfctl: скоуп containers.conf только для стека (CONTAINERS_CONF) — обход
  # AppArmor pasta-бага teardown netns; глобальный конфиг не трогается.
  [network]
  default_rootless_network_cmd = "slirp4netns"
  ```
- Путь: `$STACK_DIR/.gfctl-containers.conf` — корень клона, рядом с каноном
  `.env` и маркером `.gfctl-stopped` (прецедент hfctl
  `.hfctl-containers.conf`). НЕ в `.data/`: это derived-конфиг из tpl, не
  данные сервера; регенерируется каждым запуском.
- Доставка: расширение `bootstrap_dirs` (вызывается при КАЖДОМ запуске
  диспетчера до source lib): `if ! cmp -s tpl → install -m 0644` (гвард
  cmp = «уже стоит → 0 действий», идемпотентность брифа). TPL_DIR уже
  определён к точке вызова (строка 64 диспетчера).
- Скоуп: сразу после bootstrap_dirs, в верхнеуровневом скоупе диспетчера:
  ```bash
  if [ -f "$STACK_DIR/.gfctl-containers.conf" ]; then
    export CONTAINERS_CONF="$STACK_DIR/.gfctl-containers.conf"
  fi
  ```
  Файла нет (экзотика: клон без tpl) → env чист → поведение как прежде
  (гвард обязателен: set -e-безопасный if, не `[ -f ] &&`).
- Радиус: ВСЕ podman-вызовы gfctl — container_up (run/rm), container_stop,
  container_state (inspect), logs, doctor/status (ps/inspect), EXP-прогоны —
  и процессы `_boot`/`_watchdog` через юниты. Сетевой бэкенд значим при
  create/netns; storage общий — inspect/logs/ps с env и без видят одно и то
  же (EXP-013: graphRoot идентичен).
- Границы доверия: env наследуют только дети gfctl-процесса. hfctl
  (compose-процессы, юниты hipfire) env НЕ получает — pasta-прод hfctl не
  тронут. Второго хранилища не возникает: override меняет только
  `[network]`, graphRoot/образы/контейнеры видимы из обоих бэкендов.
- AGENTS.md bootstrap-абзац: «любой вызов ./gfctl создаёт каркас .data/» →
  дополнить «+ ставит .gfctl-containers.conf (скоуп slirp4netns)».

### 2. preflight_host(): новый порядок гейтов хоста

Новая функция в `lib/commands.sh` (секция 1.2, перед cmd_install). Единая
точка гейтов хоста — вызывается cmd_install (замена inline-блока 425–469) и
cmd_use (ДОБАВЛЯЕТСЯ: use = входная команда И1 «одной командой» — на голой
машине первый use обязан сам довести хост до готовности; сегодня use гейтов
хоста не имеет вовсе). Параметр: профиль (для RAM-гейт-строки).

Порядок (зеркало hfctl 13.2 + gfctl-специфика):

```
1. ОС Linux → die (текст байт-в-байт прежний)
2. GPU-подготовка: гейт kfd|dri → группы render,video | info-пропуск
3. железный гейт: gpu_nodes_present || die (текст прежний)
4. RAM-гейт профиля: НЕДОСТАТУПЕН/НЕИЗВЕСТНО → die; иначе echo-строка
5. apt-пятёрка (один need-список; sudo/apt/network → громкий отказ)
6. gpu-lock warn (podman ps непуст → WARN «переключение руками», D3)
7. memlock-гейт: unlimited → PASS; «?»/<8388608 → ml_write + WARN + exit 42;
   ≥8388608 → ml_write + WARN «достаточно», продолжаем  — тексты и коды
   прежние байт-в-байт (4.1-F2)
```

Обоснования порядка: GPU-prep до apt (не делать sudo-apt на машине, которая
сейчас уйдёт в exit 42 по группам — меньше sudo-работы до перелогина, как в
hfctl 13.2); apt после железного/RAM-гейтов (не ставить пакеты машине,
которая всё равно умрёт по железу/RAM); gpu-lock после apt (на голой машине
podman появляется здесь — проверка становится осмысленной); memlock-гейт
последний из sudo-шагов (его exit 42 = «перелогинься» — к этому моменту и
пакеты, и группы уже обработаны; повторный invoke после перелогина: apt —
«всё на месте, 0 действий», группы — no-op).

### 3. GPU-подготовка (шаг 2) — точный контракт

```bash
local kfd="${GFCTL_KFD:-/dev/kfd}" dri="${GFCTL_DRI:-/dev/dri}"
# GPU-подготовка хоста (И1): группы только при наличии GPU; не-GPU — info-пропуск
if [ -e "$kfd" ] || [ -e "$dri" ]; then
  if ! id -nG 2>/dev/null | tr ' ' '\n' | grep -qx render \
     || ! id -nG 2>/dev/null | tr ' ' '\n' | grep -qx video; then
    log "добавляю ${USER} в группы render,video (sudo точечно)"
    sudo usermod -aG render,video "${USER:-$(id -un)}"
    warn "группы применятся только после перезахода. Выйди и зайди снова (новая ssh-сессия годится), затем повтори команду."
    exit 42
  fi
else
  log "GPU-устройства не найдены ($kfd, $dri) — GPU-подготовка пропущена"
fi
```

- **Хуки** `GFCTL_KFD`/`GFCTL_DRI` — только selfcheck (батарея; прод env
  пуст). Это path-хуки существования — НЕ те же дефолты, что
  gpu_nodes_present (там compgen-глоб renderD*); оба механизма живут рядом
  без конфликта (железный гейт шага 3 остаётся на gpu_nodes_present).
- **limits.d — merge-логика**: GPU-prep НЕ пишет limits-файл. Единственный
  владелец `/etc/security/limits.d/99-gfctl-memlock.conf` — существующий
  memlock-гейт (шаг 7; `ml_write`, «* soft/hard memlock unlimited»).
  Позиция шага 7 ПОСЛЕ железного гейта сохраняет прежнее свойство: на
  машине без GPU файл не пишется (die раньше). Крайний случай kfd-нет +
  dri-есть: группы применятся (идемпотентная безвредная мутация, машина
  подготовлена к починке драйвера — прецедент hfctl 13.2), затем громкий
  die железного гейта.
- **GPU-отсутствие — не молча и не WARN**: одна info-строка
  «GPU-подготовка пропущена». Обоснование: отсутствие GPU для gfctl —
  фатально (шаг 3 die через строку), WARN вводил бы в заблуждение
  («предупреждение» = «можно продолжать»), полная тишина противоречит
  «никаких сюрпризов» (SPEC §1.3); прецедент hfctl 13.2 — info-пропуск.
- **Группа не применилась до перелогина**: честный механизм — после
  usermod НЕТ фейк-зелёного: exit 42 (тот же ребут/перелогин-код, что и у
  memlock-гейта — единая семантика «перезагрузи сессию, повтори»). Повтор
  после перезахода: `id -nG` видит группы → no-op → поток идёт дальше.
  «Честная диагностика id -nG, не фейк-зелёный» — гейт читает реальный
  `id -nG` каждый раз; батарея подменяет его только в тестовом процессе.
- **usermod отказал** (нет группы render/video в системе — экзотика;
  Ubuntu/Debian обе имеют): set -e громко роняет процесс с rc usermod —
  честный отказ, ок.
- Прежний render-WARN cmd_install (строки 434–435 «юзер не в группе
  render») УДАЛЯЕТСЯ — полностью перекрыт GPU-prep (тот же случай, тот же
  sudo usermod, но с exit 42 и обеими группами; двойное сообщение = шум).

### 4. apt-пятёрка (шаг 5) — точный контракт

```bash
local need=""
command -v podman             >/dev/null || need+=" podman"
command -v podman-compose     >/dev/null || need+=" podman-compose"
command -v containers-storage >/dev/null || need+=" containers-storage"
command -v fuser              >/dev/null || need+=" psmisc"
command -v curl               >/dev/null || need+=" curl"
if [ -n "$need" ]; then
  command -v sudo    >/dev/null || die "sudo не найден — поставь пакеты руками:$need (apt-get install -y …) и повтори"
  command -v apt-get >/dev/null || die "apt-get не найден (нужна Ubuntu/Debian) — поставь пакеты руками:$need"
  log "установка пакетов:$need (sudo точечно; passt/slirp4netns/uidmap — Depends podman)"
  sudo apt-get update -qq && sudo apt-get install -y -qq $need \
    || die "apt не смог (сеть? репозитории? — apt-get update/install выше); поставь вручную:$need и повтори"
fi
```

- `need` — строка с пробелами, разбиение намеренное (имена пакетов без
  пробелов; shellcheck-baseline требует — read -ra массив, семантика та же).
- **Идемпотентность**: всё на месте → `need` пуст → НОЛЬ sudo/apt-вызовов
  (никаких «повторных apt-get update без нужды» — дорогой сетевой шаг
  только при недостающем пакете; граница брифа).
- **Громкий отказ**: нет sudo/apt-get → die с рецептом ручной установки;
  apt-сбой (нет сети) → die с рецептом. Никогда не «выдумывать результат»:
  продолжение возможно только при rc 0 apt.
- **Состав пятёрки** — И1-инвариант («действуют для hfctl и gfctl»):
  podman (движок), podman-compose (не используется serve-путём gfctl, но
  инвариант перечисляет для обеих обвязок — машины поочерёдно живут обоими
  стеками, один apt закрывает hfctl-потребность тоже), containers-storage
  (orphan-рецепт в die-сообщении + И1), psmisc (fuser — диагностические
  ЧТЕНИЯ сценариев И2; И1), curl (уже нужен models-модулю).
- Заметка: sudo-пароль на голой машине — интерактивная сессия пользователя
  (flow user-run); EXP-скрипты — prerequisite «sudo без пароля или
  интерактивный запуск».

### 5. doctor — что нового (только чтение, rc 0)

Три аддитивные правки в `cmd_doctor`:

1. Строка «render-группа» → «группы render/video: да/нет (WARN — sudo
   usermod -aG render,video $USER)» — предикат по `id -nG` на ОБЕ группы.
2. Новая секция «пакеты (apt-пятёрка И1)»: по `command -v` — `podman: да |
   podman-compose: нет | containers-storage: да | psmisc (fuser): да |
   curl: да` (отсутствие → «нет» — информация, не WARN: doctor работает и
   на голой машине до всего).
3. Новая строка «slirp-скоуп»: `[ -f $STACK_DIR/.gfctl-containers.conf ] &&
   export-переменная задана → «да (slirp4netns; <путь>)»`, иначе «нет
   (CONTAINERS_CONF не задан — глобальный pasta-бэкенд)». Отдельно строка
   «хранилище»: `podman info --format '{{.store.graphRoot}}'` при
   доступном podman (диагностика «общее хранилище с hfctl»), сбой → «?».

### 6. container_up die-сообщение (fallback orphan-рецепта)

Хвост die в `container_up` дополняется одной строкой-рецептом (продукт-кода
самолечения НЕТ — решение в Open questions): «если в ошибке "…already in
use by <ID>…" и ID не виден podman ps — это storage-сирота: containers-
storage delete-container <ID>». Гарантии безопасности рецепта (для текста):
ID берётся только из ошибки, перед ручным удалением проверяется `podman ps
-a` (ID не должен быть живым контейнером). Существующие попытки/паузы/хвост
логов не меняются (F10, fix-r2).

### 7. EXP-скрипты (созданы, НЕ запущены — D6)

Все в `.dev/external/`, формат по скиллу: шапка (цель, пререквизиты,
запуск, что counts PASS), весь вывод в `EXP-<id>…result.txt`, финал
`RESULT: PASS|FAIL|ERROR — …`. Общие правила F21 (remote-часть начинается
с bootstrap — git clone из GitHub, И3; tar/cp из воркспейса запрещены),
F23 (без параллельных прогонов на одной машине), F11 (linger восстанавливать
в последовательностях), диагностические ЧТЕНИЯ только (И2).

- **EXP-013-gfctl-parity-bare.sh** — bare-Ubuntu (ресурс решает пользователь,
  фазы): `PHASE=1` — клон GitHub → `./gfctl doctor` (пакеты «нет», GPU-строки
  честные) → `./gfctl use 27b-single --no-probe`: PASS-ветки = rc 0 (всё
  подготовлено) ИЛИ rc 42 с сообщением «перезахода»/«ПЕРЕЛОГИНЬСЯ» и
  записанными limits.d-файлом и группами (проверка grep group + cat файла —
  чтения); `PHASE=2` (после перезахода/ребута) — use → rc 0 → health ok →
  smoke 3/3 → apt повтор = 0 вызовов (проверка по факту: «всё на месте»);
  `PHASE=3` (после ребута) — самоподъём: юниты enabled, контейнер running,
  health ok (это и есть ребут-приём fix-r2 на финальном коде). Фазы
  раздельные, т.к. перезаход/ребут вне скрипта.
- **EXP-014-gfctl-off-hfctl-on.sh** — FAEX или evo (где живой gfctl-стек):
  `gfctl off` (если стек поднят; маркер+linger off) → диагностические чтения
  (podman ps, pgrep pasta/slirp, linger) → `hfctl on` → wait-health → smoke →
  linger hfctl=yes. PASS = hfctl-прод вернулся здоровым, «already in use»
  нет, linger восстановлен (F11).
- **EXP-015-hfctl-off-gfctl-on.sh** — обратная последовательность + slirp-
  ассерты: `hfctl off` → `gfctl on` → wait-health → smoke; в процессе:
  (а) pgrep: slirp4netns-процесс gfctl-контейнера есть, pasta-каунт не растёт
  от gfctl-операций; (б) recreate/off-циклы без «kill network process:
  permission denied» в выводе/логах; (в) graphRoot с env gfctl и без —
  идентичен (podman info, чтение); (г) повторный hfctl on здоров (бэкенды
  сосуществуют, EXP-012/013-механика на живой машине).
  В том же окне (не этот подэтап) закрываются EXP-010/011/012 и
  ребут/рестарт-приёмы fix-r2 — EXP-015 проектируется так, чтобы его прогон
  был отдельным вызовом (F23), не подмесом в чужие скрипты.

## Test strategy

Батарея `tests/run_checks.sh`, gf/frun-харнесс как есть. Новые faux:
- `id`: `-nG` → `$GFCTL_FAUX_GROUPS` (если задано), иначе passthrough
  `/usr/bin/id "$@"`; `GFCTL_FAUX_GROUPS` ДЕФОЛТ `tester render video` в
  обоих харнессах (frun/gf) — иначе новые гейты в существующих сценариях
  словят usermod/42.
- `usermod`: журнал, rc 0.
- faux `podman`: + одна строка `env CONTAINERS_CONF=<значение|пусто>` в
  журнал (по `GFCTL_FAUX_LOG_ENV=1`, чтобы старые счётчики строк не поехали).
- stripped-PATH-набор (для сценариев «пакеты отсутствуют»): $TMP/stripped с
  симлинками базовых утилит (grep/tr/id→faux/usermod→faux/sudo→faux/uname/
  mktemp/cmp/install) БЕЗ podman/podman-compose/containers-storage/fuser/
  curl/apt-get; сценарий «всё на месте» — обычный FAUX-набор (+команда
  `command -v` видит faux-бинари).

Сценарии (preflight гоняется через gf-харнесс с оверрайдами гейтов —
прецедент §17b: gpu_nodes_present/ram_gate_line/ulimit подменяются в коде
сценария; GPU-хуки через GFCTL_KFD=$TMP/kfd touch-файл):

| # | Сценарий | Ассерты |
|---|---|---|
| T1 | pkgs-missing: stripped-PATH (без пяти), kfd-хук есть, группы ок, ulimit→unlimited, `preflight_host 27b-single` | в журнале sudo ровно `apt-get update -qq` + `apt-get install -y -qq podman podman-compose containers-storage psmisc curl` (одна пара, порядок update→install); rc 0 |
| T2 | pkgs-present: FAUX-набор со всеми пятью, прочие гейты шимы | `apt-get` в журнале 0 раз; rc 0 (идемпотентность «уже стоит → 0 действий») |
| T3 | нет sudo: stripped без sudo, need непуст | FATAL «sudo не найден» + рецепт, rc 1 (громкий отказ — DoD 1) |
| T4 | apt-сбой: faux sudo rc 1 на apt-get install | FATAL «apt не смог» + рецепт, rc 1; НЕ продолжил поток |
| T5 | не-GPU: GFCTL_KFD/GFCTL_DRI → несуществующие, gpu_nodes_present → die | out содержит «GPU-подготовка пропущена»; в журнале НЕТ usermod/apt/limits; rc 1 «нет /dev/kfd или /dev/dri» (железный гейт прежний текст) |
| T6 | группа отсутствует: kfd-хук есть, GFCTL_FAUX_GROUPS=`tester render` | журнал `sudo usermod -aG render,video tester`; out «после перезахода»; rc 42; apt/limits не достигнуты (порядок GPU-prep раньше apt) |
| T7 | группы ок: обе в GFCTL_FAUX_GROUPS | usermod 0 раз; rc 0; полный no-op sudo по группам |
| T8 | use-путь: gf `cmd_use 27b-single --no-probe` + шимы (группы ок, ulimit→unlimited, kfd нет) | preflight отработал: rc 0; «GPU-подготовка пропущена»; usermod/apt 0 раз; прежние ассерты use (канон/юниты/run) живы |
| T9 | скоуп-файл: frun `./gfctl doctor` в свежем $TMP/stack | файл `$TMP/stack/.gfctl-containers.conf` создан bootstrap'ом; `cmp` с tpl-оригиналом — байты равны; в журнале faux podman строка `env CONTAINERS_CONF=$TMP/stack/.gfctl-containers.conf` |
| T10 | скоуп-гвард: файл удалить из стека, frun снова | файла нет → env в журнале podman пуст (`env CONTAINERS_CONF=`); повторный frun файл восстановил (bootstrap идемпотентен) |
| T11 | юнит-путь: faux systemctl пишет wants (прецедент fix-r2), frun `use` → юнит ExecStart = bash …gfctl _boot | в юнит-файле НЕТ Environment=CONTAINERS_CONF (экспорт диспетчерский, tpl не тронуты — регресс-страж «юниты не разрослись») |
| T12 | doctor: пакеты-строки + slirp-строка + группы render/video | out содержит «podman: да», «podman-compose: нет» (stripped-набор без него), «slirp-скоуп: да», «группы render/video: да»; rc 0 |
| T13 | memlock-регресс: §17b (а)/(б) без изменений | прежние ассерты зелёные байт-в-байт (exit 42 + запись файла; «достаточно» + продолжение) |

Обязательные шимы СУЩЕСТВУЮЩИХ сценариев (не ослабление ассертов —
адаптация к новым гейтам на use-пути): §18 (use) — добавить
`ulimit(){ echo unlimited; }` и дефолт GFCTL_FAUX_GROUPS (иначе реальный
ocbox-ulimit < порога → exit 42 сломает happy-path); §17 install — то же
проверить (там ulimit уже оверрайдится в in2; первый сценарий §17 —
добавить шим ulimit/групп при необходимости). Счётчик: FAIL=0, PASS =
381-базлайн + ≥12 новых.

Мутационные проверки НЕ вводятся (домашняя конвенция gfctl — прямые
ассерты, маркеров `# fix:` в батарее нет).

Внешние проверки (окно этапа 5, D6 — НЕ этот подэтап):

| DoD | что доказывать живьём |
|---|---|
| 1 apt | EXP-013 PHASE=1/2: голая машина — apt-пятёрка одним вызовом; повтор — 0 apt |
| 2 GPU | EXP-013 PHASE=1: usermod render,video + exit 42 → перезаход → no-op; limits.d один файл (grep limits.d | wc = 1); FAEX/evo: preflight = полный no-op без sudo |
| 3 slirp | EXP-015 (а)–(г): скоуп slirp4netns у gfctl-контейнера, pasta не растёт, graphRoot общий, hfctl on здоров после (прод не задет); класс signal deny/teardown = 0 вхождений |
| 4 orphan | отклонение: EXP-015 recreate/off-циклы без «already in use» — обоснование подтверждено; если сирота вдруг воспроизведётся — die-рецепт снимается диагностическим чтением, дефект в бэклог |
| 5 сценарии | EXP-014/015 прогнаны как ЕДИНСТВЕННЫЕ мутации окна (И2): «gfctl off; hfctl on» и обратная —healthy+smoke; внеплановых ручных команд нет |
| И3 | все EXP из GitHub-клона (F21/F24): git clone → git pull; tar/cp из воркспейса = FAIL сценария |
| fix-r2 хвосты | EXP-013 PHASE=3 = ребут-приём (юниты enabled после ребута, самоподъём); рестарт-приём recreate — прогоном use дважды в PHASE=2 |

## Risks and rollback

- **Откат**: `git revert` одного коммита. tpl/containers — новый файл
  (удаление безопасно: читает только bootstrap); preflight_host — новая
  функция (вызовы возвращаются к прежним inline-гейтам revert'ом). Ни
  state (.env/маркер), ни модели, ни образ не меняются.
- **Что остаётся на машине после revert** (пополнение таблицы исключений
  4.4 — SPEC §2 «вне каталога»): apt-пятёрка в системе (безвредно — тот же
  список нужен hfctl по И1); membership юзера в группах render/video
  (безвредно, GPU-доступ); limits.d-файл — как прежде (uninstall снимает,
  гейт существовал и до этого); `.gfctl-containers.conf` в клоне (derived,
  регенерируется, безвредно); env CONTAINERS_CONF исчезает вместе с
  revert'нутым диспетчером. Глобальный ~/.config/containers не пишется
  НИКОГДА — hfctl-прод не задет ни при деплое, ни при откате.
- **slirp4netns может просесть скорость pull** (EXP-хвост окна; план Б —
  host-network, правка портов/изоляции — отдельное решение пользователя,
  EXP-012). Код не блокирует этот план: скоуп = один конфиг-файл.
- **usermod → exit 42 на существующей машине**, если у юзера нет video
  (render, по данным llm-lab host_prep, есть на обеих): первый use/install
  после деплоя кода завершится 42 с честным сообщением — деплой-окно
  должно это предвидеть (перезаход между фазами). На FAEX/evo ожидался
  полный no-op.
- **apt-get update на машинах со stale-листами/без сети** — громкий die с
  рецептом; окна приёмки онлайн по определению. Ложный «need» невозможен:
  command -v проверяет факт, не версию.
- **use-путь получил новые гейты** — изменение наблюдаемого поведения use
  (раньше use не проверял железо/memlock): это цель И1 («первый use
  доводит хост»), но оно же — риск регрессии существующих сценариев
  (closed sub-stage-контракты 1.2/4.1/4.2). Погашение: шимы батареи (T8),
  §17b-регресс байт-в-байт (T13), SPEC §3 use-строка обновляется той же
  дельтой (DoD 7).
- **RAM-гейт до apt**: слабая машина умирает до установки пакетов —
  намеренно (не ставить софт машине, которая не пройдёт гейты), но
  диагностика «почему нет podman» на такой машине — doctor (покажет
  «пакеты: нет»).

## References

- Спека: `.dev/SPEC.md` — §1 (цель 1 «4 команды»), §2 (лейаут 4.4,
  «вне каталога»-исключения), §3 (install/use, memlock-гейт 8388608/exit 42),
  §9 (соседство с hfctl, D3), «Инварианты поставки И1–И3» (D7),
  «Соответствие gfctl на 2026-11-21» (И1 = частично: нет apt/GPU/netns-класс),
  «Этап 5 (план)».
- hfctl-канон (только ЧТЕНИЕ): `/workspace/hfctl/.dev/tasks/13/13.1/task.md`
  (orphan-класс «already in use by <ID> … external entity», синтаксис
  containers-storage delete-container, кап самолечений, guard libpod-видимости),
  `13/13.2/task.md` (apt-пятёрка одним списком, GPU-гейт kfd|dri +
  info-пропуск, usermod render,video + exit 42, порядок preflight,
  stripped-PATH-метод батареи, faux id/usermod).
- EXP-механика скоупа: `/workspace/llm-lab/.dev/experiments/
  EXP-012-rootless-netns.md` (корень AppArmor pasta denied signal; матрица;
  graphRoot идентичен), `/workspace/llm-lab/scripts/exp013_containers_conf_scope.sh`
  (точный формат conf-файла, S1–S5 проверки).
- Решения: DECISIONS D6 (окно = два отдельных GO), D7 (И1–И3 ратифицированы
  2026-11-21, поставка из GitHub).
- Факты: FACTS F9 (podman-флаги rootless — не меняются), F10 (медленный порт
  — паузы recreate не трогаем), F11 (linger-восстановление в
  последовательностях), F17 (EXP-транспорт tar|ssh — устарело к И3: теперь
  GitHub-клон; rsync нет — F17-примечание), F21 (remote-часть с bootstrap),
  F23 (без параллельных прогонов), F24 (канон миграции: стек из git, sed
  рендер-артефактов запрещён).
- Код (проверен живьём, рабочее дерево): `gfctl` (bootstrap_dirs:164–173,
  TPL_DIR:64, роутер:231), `lib/commands.sh` (cmd_install гейты:425–469,
  cmd_use:673–735, cmd_doctor:171–249, cmd_uninstall:1119–1138),
  `lib/serve.sh` (gpu_nodes_present:66–68, container_up:132–159),
  `lib/autostart.sh` (cmd_on:78, cmd_off:102–115, юнит-пути через диспетчер),
  `lib/units.sh` (install_units:77–93 — юниты без CONTAINERS_CONF),
  `tests/run_checks.sh` (faux:65–228, frun/gf:232–270, §17b memlock:760–778,
  §18 use:780–827).
- STATE: «План — пересмотр 2026-11-21» (порядок B→C→A(в C), одно окно
  закрывает хвосты A).

## Open questions

Нет — все ратифицированы 2026-11-21 (орфан-хил = MIRROR, bare-ресурс =
отложен, И1 без смягчений). Детали и следствия — «## Round 2» ниже.

## Round 2 (2026-11-21): ратификация пользователем

Все четыре открытых вопроса Round 1 закрыты решениями пользователя; тело
Round 1 не переписывалось — поправки здесь (маркер в DoD п.5 внесён той же
дельтой).

### 1. Orphan-heal — НЕ отклонение, а MIRROR hfctl (рекомендация Round 1
отвергнута пользователем)

Перенос `hf_orphan_heal` из `/workspace/hfctl/lib/autostart.sh:294–328`
(сверен по коду, Round 2) в gfctl 1:1 по духу со ВСЕМИ гвардиями:

- имя `gf_orphan_heal` (конвенция gf-префикса lib-модулей), глобал
  `GF_ORPHAN_HEALS`, константа `HEAL_MAX="${GFCTL_HEAL_MAX:-2}"` — кап
  самолечений за процесс (живёт в модуле container_up — `lib/serve.sh`,
  шапка модуля);
- гард 1: кап — `[ "$GF_ORPHAN_HEALS" -lt "$HEAL_MAX" ] || return 1`;
- гард 2: бинаря `containers-storage` нет → WARN с ручным рецептом
  (`sudo apt install containers-storage; вручную: containers-storage
  delete-container <ID>`), поведение как прежде — return 1;
- гард 3: `podman inspect -f '{{.State.Status}}' <ID>` успешен → «ID видит
  libpod — не сирота, самолечение отменено» (страховка от удаления живого
  контейнера при обратном рассинхроне) — return 1;
- гард 4: `containers-storage delete-container <ID>` отказался → WARN —
  return 1; успех → log-строка + счётчик, вызывающий делает ОДИН retry;
- сигнатура ID: `already in use by [0-9a-f]{12,64}` (grep глушен `|| true`
  — пустой ID = не сирота, rc 1);
- вызов ТОЛЬКО при контейнере ≠ running (happy-path не зовёт): в
  container_up при отказе `podman run` с сигнатурой ошибки — до следующей
  попытки цикла; die при исчерпании попыток СОХРАНЯЕТ ручной рецепт
  (строка-рецепт из Design §6 Round 1 остаётся).

Обоснование пользователя: машины/хранилище общие с hfctl-продом — класс
сирот может укусить gfctl (общий storage рассинхронизируется одинаково);
консистентность сестринских продуктов сложением, не вычитанием; И2-сценарии
получают самовосстановление. hfctl НЕ трогаем (зеркало — только чтение).
Следствие: `containers-storage` в apt-пятёрке несёт теперь продуктовую
нагрузку (не только рецепт), отсутствие бинаря = Variant-B деградация
(WARN + ручной рецепт) — как в hfctl 13.1 Ф2.

### 2. Bare-Ubuntu приёмка — ОТЛОЖЕНА пользователем

- EXP-013 (bare-install фазами) — создаётся как ЗАГОТОВКА «на будущее окно,
  ресурс не выделен», помечена deferred в шапке скрипта (STATUS: deferred;
  PHASE=1..3 контент по Round 1 — написать сейчас, запускать когда ресурс
  появится).
- Окно 5.1 закрывает: EXP-014/015 (сценарные последовательности на живых
  машинах + slirp-ассерты) + существующие EXP-010/011/012 + ребут/рестарт-
  приёмы fix-r2 — как в Round 1.
- DoD п.5 — помечен «EXP-013 created/deferred» (маркер внесён в тело DoD
  той же дельтой).

### 3. И1 — строго, без смягчений (ратифицировано)

apt-пятёрка целиком (`podman podman-compose containers-storage psmisc
curl`), новые хост-гейты на install И use — Open questions 3/4 Round 1
закрыты в пользу Design как есть (никакого «gfctl-минимума», никакого
«только install»).

### 4. exit 42 на существующих машинах (video-группа) — остаётся риском окна

Doctor уже читает честный `id -nG` (Round 1, Design §5) — добавок не нужно.
EXP-014/015 дополняются ПРОЛОГОМ «идем через перелогин»: сценарий объявляет,
что первый use/install после обновления кода может завершиться rc 42
(группы render,video) — перезаход сессии между шагами сценария, повтор
команды, и только затем health+smoke-ассерты. Пролог фиксирует это как ПЛАН
последовательности (И2: перезаход = часть сценария, не внеплановая ручная
мутация).

### 5. SPEC-honesty — дополнение к DoD 7

Строка «Соответствие gfctl на 2026-11-21» в SPEC: developer обновляет
«И2 — частично» с учётом mirror-хила (самолечение storage-сироты входит в
соответствие И2 наряду с rm-в-попытке fix-r2) — в составе той же дельты
DoD 7. hfctl-строку SPEC не трогать.

### Тест-стратегия — добавка (mirror-хил)

Faux-ассерты в батарею (faux `containers-storage` — новый в $FAUX):
| # | Сценарий | Ассерты |
|---|---|---|
| T14 | сигнатура ошибки: faux podman run#1 печатает «…already in use by <64-hex> … external entity» (rc 1), run#2 ок, faux inspect ID → missing, faux containers-storage rc 0 | в журнале `containers-storage delete-container <ID>` ровно 1 раз; ровно 2 вызова run (heal → retry); rc 0 |
| T15 | guard libpod: faux podman inspect ID → running | delete-container НЕ вызван; WARN «не сирота»; цикл идёт как прежде (2 run: обычный retry) |
| T16 | бинаря нет: stripped-PATH без containers-storage | WARN «containers-storage нет» + ручной рецепт с ID; delete-container отсутствует в журнале |
| T17 | кап: обе попытки run с сигнатурой (GFCTL_HEAL_MAX=1) | ровно 1 heal; вторая ошибка НЕ лечится; die при исчерпании попыток содержит ручной рецепт |
| T18 | happy-path не зовёт хил: чистый run rc 0 | containers-storage в журнале 0 раз; хил-ветка не входила |

Счётчик батареи: PASS = 381-базлайн + ≥17 новых (12 Round 1 + 5 Round 2),
FAIL=0.

### Что изменилось в файле диффа (сводка Round 2)

- `lib/serve.sh` — не только строка-рецепт, а полный mirror-хил
  (`gf_orphan_heal` + `GF_ORPHAN_HEALS`/`HEAL_MAX`, интеграция в цикл
  container_up до retry, die с рецептом при исчерпании).
- `tests/run_checks.sh` — +faux containers-storage, +T14–T18.
- `tpl/containers/gfctl-containers.conf`, `.gitignore`, `gfctl`
  (bootstrap+export), `lib/commands.sh` (preflight_host/doctor) — без
  правок относительно Round 1.
- EXP-013 — deferred-статус в шапке; EXP-014/015 — пролог перелогина;
  hfctl не тронут.
