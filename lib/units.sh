# shellcheck shell=bash
# ── файлы systemd-user: render_tpl (плейсхолдеры __X__) + install_units ────
# Юниты рендерятся из tpl/systemd/*.tpl в $UNIT_DIR (~/.config/systemd/user,
# SPEC §2 «вне каталога»); таймер — статичный (плейсхолдеров нет).
# serve-юнит = boot-юнит (отдельного gfctl-boot НЕТ: SPEC §2 «юниты
# gfctl-serve*», второй boot-юнит дрался бы за контейнер). Модуль читает
# UNIT_DIR/UNIT_NAME/CONTAINER/STACK_DIR/MODELS_BASE/TPL_DIR (диспетчер); die — из
# диспетчера. Вызывается из install/use (install_units) и on (autostart_on).

# Назначение: отрендерить один шаблон из tpl/: прочитать файл $1, заменить в
#   его тексте плейсхолдеры __NAME__ на пары NAME=value (rest-аргументы) и
#   записать результат в $out (1:1 из hfctl lib/stack_files.sh).
#
# Побочные эффекты: пишет файл $out (truncate, новый inode, владелец —
#   текущий юзер); читает файл-шаблон $1 (cat). Нераскрытые плейсхолдеры —
#   FATAL die() в stderr и выход процесса.
#
# Ограничения/допущения: подстановка наивная ${tpl//__NAME__/value} —
#   значение не экранируется (пути/числа); порядок пар ВАЖЕН — имена
#   передавать в порядке убывания длины (защита от вложенных совпадений).
#   Остаточный паттерн __[A-Z0-9_]+__ после подстановки = чужой/опечатанный
#   плейсхолдер → die (батарея проверяет на синтетическом шаблоне).
#
# @param 1: string       # путь файла-шаблона .tpl (читается cat целиком)
# @param 2: string       # путь файла назначения (перезаписывается целиком)
# @param 3..N: string[]  # rest пары NAME=value (после shift 2)
# @returns integer       # всегда 0 при возврате — нераскрытые плейсхолдеры
#   завершают процесс die (exit 1), сбой чтения $1 — через set -e
render_tpl() {
  local tpl out tpl_path="$1"; tpl="$(cat "$1")"; out="$2"; shift 2
  local kv name value
  # имена передавать в порядке убывания длины (длинное раньше короткого)
  for kv in "$@"; do
    name="${kv%%=*}"; value="${kv#*=}"
    tpl="${tpl//__${name}__/${value}}"
  done
  if printf '%s' "$tpl" | grep -qE '__[A-Z0-9_]+__'; then
    # путь шаблона захвачен ДО shift 2 (после него $1 = первая пара)
    die "нераскрытые плейсхолдеры в шаблоне $tpl_path"
  fi
  printf '%s\n' "$tpl" > "$out"
}

# Назначение: установить/обновить systemd-user юниты gfctl — mkdir -p
#   $UNIT_DIR; render трёх юнитов (идемпотентная перезапись, дублей имён
#   не бывает): gfctl-serve.service (markers __STACK_DIR__/__PODMAN_BIN__/
#   __CONTAINER__; oneshot + RemainAfterExit + KillMode=process — без него
#   systemd убивает cgroup вместе с контейнером; ExecStart = bash
#   $STACK_DIR/gfctl _boot; ExecStop = podman rm -f — страховка, рабочий
#   stop — cmd_off: у завершённого oneshot ExecStop не стреляет), 
#   gfctl-watchdog.service (__STACK_DIR__ + Environment=GFCTL_DIR/GFCTL_MODELS —
#   ре-рендер реальных значений: без них _boot/_watchdog при ребуте взяли бы
#   дефолты (каталог gfctl-файла) — дефект EXP-009) и gfctl-watchdog.timer — статичный
#   tpl без плейсхолдеров, install -m 0644 (OnUnitActiveSec=1min).
#   enable/start/linger — НЕ здесь (autostart_on).
#
# Побочные эффекты: mkdir -p $UNIT_DIR; запись трёх файлов в $UNIT_DIR.
#   В stdout не печатает.
#
# Ограничения/допущения: PODMAN_BIN = `command -v podman` В МОМЕНТ рендера —
#   в батарее это PATH-заглушка (абс-путь faux), в проде /usr/bin/podman;
#   юниты исполняют $STACK_DIR/gfctl — дерево в стеке = сам git-клон
#   (STACK_DIR = каталог gfctl-файла, 4.4; install.sh упразднён). Живые
#   вызовы: cmd_install/cmd_use (install_units) и autostart_on (перед enable).
#
# @returns integer       # всегда 0 при возврате — die render_tpl и сбои
#   mkdir/install завершают процесс по set -e
install_units() {
  local bin
  bin="$(command -v podman)" || die "podman не найден в PATH — юниты не собрать"
  mkdir -p "$UNIT_DIR"
  render_tpl "$TPL_DIR/systemd/gfctl-serve.service.tpl" "$UNIT_DIR/$UNIT_NAME-serve.service" \
    GFCTL_MODELS="$MODELS_BASE" PODMAN_BIN="$bin" GFCTL_DIR="$STACK_DIR" \
    STACK_DIR="$STACK_DIR" CONTAINER="$CONTAINER"
  render_tpl "$TPL_DIR/systemd/gfctl-watchdog.service.tpl" "$UNIT_DIR/$UNIT_NAME-watchdog.service" \
    GFCTL_MODELS="$MODELS_BASE" GFCTL_DIR="$STACK_DIR" STACK_DIR="$STACK_DIR"
  # таймер — статичный (плейсхолдеров нет): копировать как есть
  install -m 0644 "$TPL_DIR/systemd/gfctl-watchdog.timer.tpl" "$UNIT_DIR/$UNIT_NAME-watchdog.timer"
}
