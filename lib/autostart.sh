# shellcheck shell=bash
# ── автозапуск: юниты+linger (on), стоп+снятие (off), up/down, вотчдог, boot ─
# Паттерн hfctl (F16): rootless-контейнер не имеет живого наблюдателя после
# `podman run -d` — автоподнятие = systemd timer 1 мин → `gfctl _watchdog`;
# явная остановка только через `gfctl off` (маркер .gfctl-stopped, вотчдог
# уважает его ПЕРВОЙ проверкой). linger off — только в явном off/uninstall
# (F11). Порядок off ФИКСИРОВАННЫЙ: маркер ДО всего (вотчдог оглушён даже
# при сбое). Модуль читает UNIT_NAME/UNIT_DIR/CONTAINER/STOP_MARKER/
# STACK_DIR/LOGS_DIR (диспетчер), cur_profile (profiles.sh), container_up/
# container_stop/gpu_nodes_present/container_state (serve.sh), wait_health
# (health.sh), install_units (units.sh); пишет через log/warn/die/echo.

# Назначение: включить автозапуск — install_units (перерендер, идемпотентно);
#   systemctl --user daemon-reload; enable gfctl-serve.service +
#   gfctl-watchdog.timer; start таймера; rm -f STOP_MARKER; sudo loginctl
#   enable-linger "$USER"; итоговая строка.
#
# Побочные эффекты: юнит-файлы в $UNIT_DIR (перезапись); systemctl
#   daemon-reload/enable/start; маркер снят; linger юзера включён
#   (sudo — точечное повышение, AGENTS).
#
# Ограничения/допущения: enable ≠ немедленный пуск serve-юнита: он стартует
#   при boot (_boot ждёт GPU-ноды), таймер активен сразу (первый тик
#   OnBootSec=2min); поднять сервер СЕЙЧАС — cmd_on (autostart_on + cmd_up).
#   По set -e сбой любого незаглушённого шага завершает процесс. Живые
#   вызовы: cmd_on и cmd_install (кроме --no-autostart).
#
# @stdout string            # «автозапуск ВКЛ (serve-юнит + watchdog-таймер
#   1м, linger=yes)»
# @returns integer          # 0 при возврате — отказы это die/сбой set -e
autostart_on() {
  install_units
  systemctl --user daemon-reload
  systemctl --user enable "$UNIT_NAME-serve.service" "$UNIT_NAME-watchdog.timer"
  systemctl --user start "$UNIT_NAME-watchdog.timer"
  rm -f "$STOP_MARKER"
  sudo loginctl enable-linger "${USER:-$(id -un)}"
  echo "автозапуск ВКЛ (serve-юнит + watchdog-таймер 1м, linger=yes)"
}

# Назначение: `gfctl up` (скрытый алиас): поднять канон-профиль сейчас —
#   снять явный маркер остановки + container_up + wait_health 300.
#   Автозапуск НЕ трогает.
#
# Побочные эффекты: rm -f маркера (вотчдог снова может поднимать);
#   container_up (podman rm+run, каталог кэша; die при исчерпании попыток);
#   wait_health — поллинг логов и /ready до 300 с.
#
# Ограничения/допущения: требует cur_profile (канон .env уже записан
#   install/use) и wait_health (health.sh); юниты systemd не переключает —
#   «on» для автозапуска. Сбой container_up/wait_health завершает процесс
#   по set -e с их rc.
#
# @stdout string            # ход container_up + строки wait_health
# @returns integer          # 0 — поднят и здоров; 1 — отказ health
#   (по set -e процесс завершается этим rc)
cmd_up() {
  rm -f "$STOP_MARKER"
  container_up "$(cur_profile)"
  wait_health 300
}

# Назначение: `gfctl on`: включить автозапуск (юниты + таймер + linger) и
#   поднять канон-профиль прямо сейчас; smoke НЕ зовётся — on быстрый
#   (полная проверка остаётся за install/use).
#
# Побочные эффекты: всё из autostart_on и cmd_up.
#
# Ограничения/допущения: порядок фиксирован — сначала autostart_on (юниты
#   должны быть установлены до поднятия; заодно снимает маркер), затем
#   cmd_up. Сбой первого этапа завершает процесс до поднятия.
#
# @stdout string            # строка autostart_on + ход cmd_up
# @returns integer          # как у cmd_up
cmd_on() { autostart_on; cmd_up; }

# Назначение: `gfctl off` (скрытый алиас `down`): остановить сервер и
#   ПОЛНОСТЬЮ снять автозапуск — юниты удалены, linger выключен; файлы/
#   веса/образ целы. ПОРЯДОК ФИКСИРОВАННЫЙ (маркер ДО всего — вотчдог
#   оглушён даже при сбое остановки): touch STOP_MARKER → container_stop →
#   systemctl disable (|| true) → rm -f трёх юнит-файлов → daemon-reload →
#   sudo loginctl disable-linger (F11: linger off только в явном off/
#   uninstall). Итоговые 2 строки.
#
# Побочные эффекты: маркер $STACK_DIR/.gfctl-stopped создан; контейнер
#   удалён (podman rm -f); юниты disabled и файлы удалены; linger юзера
#   выключен (юзер-менеджер гаснет после закрытия сессий).
#
# Ограничения/допущения: контейнер останавливаем НАПРЯМУЮ (container_stop),
#   не через юнит — oneshot контейнера не держит, ExecStop у завершённого
#   юнита не сработает (hfctl-правило); disable и rm файлов заглушены —
#   off должен доходить до linger даже на поломанном systemd; daemon-reload
#   и disable-linger без заглушек (сбой завершает процесс — юниты к тому
#   моменту уже сняты).
#
# @stdout string            # «ВЫКЛ: …» + «Файлы, модели и образ целы.
#   Вернуть: gfctl on»
# @returns integer          # 0 — дошёл до конца
cmd_off() {
  mkdir -p "$STACK_DIR"
  touch "$STOP_MARKER"
  container_stop
  systemctl --user disable "$UNIT_NAME-serve.service" "$UNIT_NAME-watchdog.timer" 2>/dev/null || true
  rm -f "$UNIT_DIR/$UNIT_NAME-serve.service" \
        "$UNIT_DIR/$UNIT_NAME-watchdog.service" \
        "$UNIT_DIR/$UNIT_NAME-watchdog.timer"
  systemctl --user daemon-reload
  # linger глушим: в выключенном состоянии сервер не должен вскакивать при boot.
  sudo loginctl disable-linger "${USER:-$(id -un)}"
  echo "ВЫКЛ: сервер остановлен, с автозапуска снят (юниты удалены, linger off)."
  echo "Файлы, модели и образ целы. Вернуть: gfctl on"
}

# Назначение: внутренняя команда `_watchdog` таймера (1 мин): если маркера
#   остановки НЕТ и контейнер не running — поднять канон-профиль. ПЕРВАЯ
#   проверка — маркер (F16: явный off глушит вотчдог); вторая — canon .env
#   (поднимать нечего, профиль ещё не установлен); rc всегда 0.
#
# Побочные эффекты: при подъёме — mkdir -p $LOGS_DIR и допись строки
#   «<iso-date> watchdog: container state=<st> -> up» в
#   $LOGS_DIR/watchdog.log (сбой дописи глушен || true) + container_up
#   (podman rm+run; rc заглушен || true — вотчдог всегда rc 0, чтобы таймер
#   не считал его неудачей).
#
# Ограничения/допущения: вызывается только из systemd (ExecStart
#   gfctl-watchdog.service), не пользовательская команда; st ≠ running
#   (exited/created/missing/…) — всё считается падением; smoke/health из
#   вотчдога НЕ зовутся (он про «поднять», не про «проверить»).
#
# @returns integer          # всегда 0 — все отказные rc заглушены
cmd_watchdog() {
  [ -f "$STOP_MARKER" ] && return 0
  [ -f "$STACK_DIR/.env" ] || return 0
  local st
  st=$(container_state)
  if [ "$st" != running ]; then
    mkdir -p "$LOGS_DIR"
    echo "$(date -Is) watchdog: container state=$st -> up" >> "$LOGS_DIR/watchdog.log" 2>/dev/null || true
    container_up "$(cur_profile)" || true
  fi
  return 0
}

# Назначение: внутренняя команда `_boot` serve-юнита (ExecStart; systemd
#   стартует юзер-менеджер раньше появления GPU-нод): цикл с шагом sleep_s
#   до deadline_s — gpu_nodes_present? нет → sleep и повтор; да →
#   container_up + container_state = running → rc 0; иначе повтор.
#   Бюджет исчерпан → stderr-сообщение, rc 1 (юнит Restart=on-failure
#   RestartSec=30 перезапустит). smoke/health из boot НЕ зовутся
#   (TimeoutStartSec=900 покрывает бюджет ~7 мин + хвост).
#
# Побочные эффекты: container_up в каждой живой попытке (podman rm+run,
#   каталог кэша); date +%s (дедлайн); sleep по аргументу.
#
# Ограничения/допущения: аргументы — тестовый шов (живой вызов из юнита без
#   аргументов: deadline 420 с / sleep 10 с, ~48 попыток-потолок цикла —
#   страховка от стоящих часов); container_up под || true — die при
#   исчерпании его попыток не убивает boot: живой state-контроль решает
#   (run может упереться в занятый порт и поднять на следующей итерации).
#   Требует cur_profile (канон .env уже записан install/use).
#
# @param 1: integer         # дедлайн бюджета в секундах (дефолт 420)
# @param 2: integer         # пауза между попытками (дефолт 10)
# @returns integer          # 0 — контейнер running; 1 — бюджет исчерпан
cmd_boot() {
  local deadline=$(( $(date +%s) + ${1:-420} )) pause="${2:-10}" i
  for i in $(seq 1 48); do
    [ "$(date +%s)" -ge "$deadline" ] && break
    if ! gpu_nodes_present; then sleep "$pause"; continue; fi
    container_up "$(cur_profile)" || true
    if [ "$(container_state)" = running ]; then return 0; fi
    sleep "$pause"
  done
  echo "boot: контейнер так и не запущен в бюджет — systemd перезапустит юнит" >&2
  return 1
}
