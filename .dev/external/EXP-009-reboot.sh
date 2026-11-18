#!/usr/bin/env bash
# EXP-009-reboot — ребут-приёмка (этап 4, PLAN п.3): gfctl-сервер обязан
# подняться САМ после перезагрузки машины (serve-юнит oneshot + watchdog
# timer, SPEC §2), hfctl-прод возвращается после.
#
# ВАЖНО: скрипт НЕ УМЕЕТ РЕБУТИТЬ и не переживает ребут — он двухфазный
# чек-лист для ручной приёмки с пользователем у машины. ЭТА ЗАГОТОВКА В
# РЕПО НЕ ИСПОЛНЯЕТСЯ (bash -n only).
#
#   Фаза 1 (`bash EXP-009-reboot.sh off`):
#     - `gfctl off` (остановка + снятие с автозапуска; linger off);
#     - печать чек-листа для пользователя.
#   РУЧНЫЕ ШАГИ ПОСЛЕ ФАЗЫ 1:
#     (1) перезагрузи машину;
#     (2) дождись загрузки (2–3 мин);
#     (3) запусти `bash EXP-009-reboot.sh verify`.
#   Фаза 2 (`bash EXP-009-reboot.sh verify`):
#     - сервер поднялся САМ: healthy (роут в логе; рук. команд 0);
#     - `gfctl smoke`;
#     - `hfctl on` + проверка hfctl-прода (healthy + smoke).
#
# PREREQ:
#   - ЯВНЫЙ GO пользователя на ЭТО окно (ребут — событие машины);
#   - env: GF_ACC_HOST, GF_ACC_USER, GF_ACC_KEY;
#   - на машине стоит рабочий gfctl (этап 4.1: после EXP-008 или прод-инсталляции).
#
# RUN (две фазы, см. выше):
#   GF_ACC_HOST=… GF_ACC_USER=… GF_ACC_KEY=… bash EXP-009-reboot.sh off
#   … ребут руками …
#   GF_ACC_HOST=… GF_ACC_USER=… GF_ACC_KEY=… bash EXP-009-reboot.sh verify
#   Весь вывод → EXP-009-reboot.result.txt (дописывается), финальная строка
#   «RESULT: PASS|FAIL|ERROR — …».
#
# PASS-критерий:
#   1) verify: «роут:» из лога (сервер сам загрузил модель), «SMOKE: OK»;
#   2) hfctl-прод: HFCTL_HEALTH=ok + hfctl smoke OK (если hfctl на машине).
set -uo pipefail
: "${GF_ACC_HOST:?задай GF_ACC_HOST (приёмочная машина — см. hosts-профиль llm-lab)}"
: "${GF_ACC_USER:?задай GF_ACC_USER}"
: "${GF_ACC_KEY:?задай GF_ACC_KEY}"
PHASE="${1:?укажи фазу: off | verify}"

cd "$(dirname "$0")"
RES="EXP-009-reboot.result.txt"
SSH="ssh -i $GF_ACC_KEY -o BatchMode=yes -o ConnectTimeout=10"

exec > >(tee -a "$RES") 2>&1

case "$PHASE" in
  off)
    echo "== EXP-009 фаза 1: gfctl off ($(date -Is))"
    $SSH "$GF_ACC_USER@$GF_ACC_HOST" 'GFCTL_YES=1 "$HOME/gufo/gfctl" off' || {
      echo "RESULT: ERROR — gfctl off не прошёл (gfctl установлен? см. EXP-008)"; exit 1; }
    cat <<'CHECKLIST'
== ЧЕК-ЛИСТ ребут-приёмки (руками, скрипт ребутить не умеет):
  (1) перезагрузи машину;
  (2) дождись загрузки (2–3 мин; юзер-менеджер поднимется по linger —
      НЕ логинься заранее: enable-linger уже включён gfctl on/install);
  (3) запусти фазу 2:
      GF_ACC_HOST=… GF_ACC_USER=… GF_ACC_KEY=… bash EXP-009-reboot.sh verify
  Ожидание: gfctl-сервер поднялся САМ (serve-юнит + watchdog), рук. команд 0.
CHECKLIST
    echo "RESULT: PASS — фаза 1 (gfctl off) выполнена; жду ребут и фазу verify"
    ;;
  verify)
    echo "== EXP-009 фаза 2: сервер сам healthy после ребута ($(date -Is))"
    $SSH "$GF_ACC_USER@$GF_ACC_HOST" 'bash -s' <<'REMOTE' || {
      set -u
      GF="$HOME/gufo/gfctl"
      echo "== gfctl status (сервер обязан быть поднятым юнитами, рук. команд 0)"
      "$GF" status
      echo "== healthy-гейт: роут в логе (load_completed) + /ready"
      "$GF" smoke || exit 42
      echo "== hfctl-прод: возвращаем"
      if command -v hfctl >/dev/null 2>&1; then
        hfctl on || exit 43
        sleep 5
        hfctl status || exit 43
        HFCTL_HEALTH=$(hfctl status 2>/dev/null | grep -oE 'health: [a-z]+' | head -n1)
        echo "HFCTL_HEALTH=$HFCTL_HEALTH"
      else
        echo "HFCTL_HEALTH=absent (hfctl на машине нет — окно только про gfctl)"
      fi
      echo "--- EXP-009 remote done ---"
REMOTE
      rc=$?
      echo "RESULT: FAIL — remote-часть rc=$rc (42=smoke gfctl, 43=hfctl on/status)"; exit 1; }
    grep -q '^SMOKE: OK' "$RES" || { echo "RESULT: FAIL — gfctl smoke не прошёл после ребута"; exit 1; }
    grep -q '^роут: ' "$RES" || { echo "RESULT: FAIL — роут не напечатан (сервер не поднялся сам)"; exit 1; }
    grep -qE '^HFCTL_HEALTH=(health: ok|absent)' "$RES" \
      || { echo "RESULT: FAIL — hfctl-прод не вернулся healthy (см. result)"; exit 1; }
    echo "RESULT: PASS — после ребута gfctl сам healthy + smoke; hfctl-прод возвращён"
    ;;
  *)
    echo "неизвестная фаза '$PHASE' — доступно: off | verify" >&2
    exit 1
    ;;
esac
