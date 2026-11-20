#!/usr/bin/env bash
# EXP-009-reboot — ребут-приёмка (этап 4, PLAN п.3): gfctl-сервер обязан
# подняться САМ после перезагрузки машины (serve-юнит oneshot + watchdog
# timer, SPEC §2), hfctl-прод возвращается после.
#
# REPLANNED 2026-11-18 ai-расклад (дельта: .dev/tasks/4/4.2-EXP-replan.md):
#   - машины ai-owned: юзер ai (uid 1002, sudo NOPASSWD, linger on); юзер
#     hipfire retired — НЕ использовать; все пути /home/ai/*;
#   - ФАЗА 1 ПЕРЕПРОЕКТИРОВАНА (дефект старой заготовки, окно не
#     исполнялось): было `gfctl off` → ребут, но off СНИМАЕТ юниты и
#     выключает linger (autostart.sh cmd_off) — после такого ребута
#     подниматься нечему. Стало: hfctl off (под ai) → вернуть linger →
#     `gfctl on` → ребут; enabled-юниты + linger = источник самоподъёма;
#   - RAM-конфликт одновременного автоподъёма обоих стеков решён маркером:
#     hfctl off выключает юниты hipfire → после ребута поднимается ТОЛЬКО
#     gufo; возврат hfctl-прода — в конце фазы verify;
#   - грабля hfctl device-mismatch (podman-снэпшот /dev/dri, card0/card1
#     меняется между бутами — repro на evo 2026-11-18) gfctl-стеку НЕ
#     грозит по дизайну: container_up — единственный путь подъёма и ВСЕГДА
#     rm+run со свежим --device /dev/dri (serve.sh «recreate = rm+run»);
#     фаза verify это контролирует (grep journal), ручная recreate-
#     процедура оставлена только как контингентная оговорка в чек-листе;
#     код-бэклог gfctl (recreate-on-device-mismatch) НЕ требуется — в
#     отличие от hfctl, где свежий container-up-код потребовался;
#   - ранний автостарт до драйвера: gfctl-serve может стартовать раньше
#     amdgpu — штатно: cmd_boot ждёт GPU-ноды (бюджет 420 с, попытка
#     каждые 10 с; исчерпание → Restart=on-failure RestartSec=30), поэтому
#     ожидание готовности 3–10 мин — норма, а не подвисание; фаза verify
#     ждёт статус в wait-loop до 12 мин;
#   - 2026-11-20 (лейаут 4.4): стек = клон ~/gfctl — GFCTL_DIR/GFCTL_MODELS
#     не задаются (диспетчер сам детектит каталог gfctl-файла); логи
#     watchdog — ~/gfctl/.data/logs/watchdog.log.
#
# ВАЖНО: скрипт НЕ УМЕЕТ РЕБУТИТЬ и не переживает ребут — он двухфазный
# чек-лист для ручной приёмки с пользователем у машины. ЭТА ЗАГОТОВКА В
# РЕПО НЕ ИСПОЛНЯЕТСЯ (bash -n only).
#
#   Фаза 1 (`bash EXP-009-reboot.sh prep`):
#     - `hfctl off` ОТ ИМЕНИ ai (юниты disabled → после ребута hipfire НЕ
#       встанет; маркер .hipfire-стека);
#     - `sudo loginctl enable-linger ai` — hfctl off погасил linger
#       (linger=no), вернуть ОБЯЗАТЕЛЬНО: без него юзер-менеджер на ребуте
#       не поднимется и gfctl не вскочит; без него же гаснет и ssh-якорь
#       окна (~10 с, GOTCHAS llm-lab);
#     - `gfctl on` (юниты enabled + linger=yes + контейнер поднят).
#   РУЧНЫЕ ШАГИ ПОСЛЕ ФАЗЫ 1:
#     (1) перезагрузи машину;
#     (2) жди 3–10 мин (не логинься: linger уже включён);
#     (3) запусти `bash EXP-009-reboot.sh verify`.
#   Фаза 2 (`bash EXP-009-reboot.sh verify`):
#     - сервер поднялся САМ: юниты active, статус health: ok (wait-loop до
#       12 мин), journal БЕЗ device-mismatch, рук. команд 0;
#     - `gfctl smoke` (SMOKE: OK + роут из лога);
#     - `hfctl on` + проверка hfctl-прода (healthy; он вернёт linger).
#
# PREREQ:
#   - ЯВНЫЙ GO пользователя на ЭТО окно (ребут — событие машины);
#   - env: GF_ACC_HOST (обязателен: ai@192.168.1.254 evo 60 GiB |
#     ai@192.168.1.249 FAEX 128 GB), GF_ACC_USER (дефолт ai),
#     GF_ACC_KEY (дефолт ~/.ssh/strix_halo_key);
#   - на машине стоит рабочий gfctl (этап 4.1: после EXP-008 или
#     прод-инсталляции); hfctl-прод перед окном ЖИВ — его гасит фаза 1.
#
# RUN (две фазы, см. выше):
#   GF_ACC_HOST=ai@192.168.1.254 bash EXP-009-reboot.sh prep
#   … ребут руками …
#   GF_ACC_HOST=ai@192.168.1.254 bash EXP-009-reboot.sh verify
#   Весь вывод → EXP-009-reboot.result.txt (дописывается), финальная строка
#   «RESULT: PASS|FAIL|ERROR — …».
#
# PASS-критерий:
#   1) verify: юнит gfctl-serve active, статус дошёл до health: ok, 
#      «DEVICE_MISMATCH: нет», «роут:» из лога (сервер сам загрузил модель),
#      «SMOKE: OK»;
#   2) hfctl-прод: HFCTL_HEALTH=health: ok (или absent — если hfctl на
#      машине нет) + linger=yes.
set -uo pipefail
: "${GF_ACC_HOST:?задай GF_ACC_HOST (ai@192.168.1.254 evo | ai@192.168.1.249 FAEX)}"
GF_ACC_USER="${GF_ACC_USER:-ai}"
GF_ACC_KEY="${GF_ACC_KEY:-$HOME/.ssh/strix_halo_key}"
PHASE="${1:?укажи фазу: prep | verify}"

cd "$(dirname "$0")"
RES="EXP-009-reboot.result.txt"
SSH="ssh -i $GF_ACC_KEY -o BatchMode=yes -o ConnectTimeout=10"

exec > >(tee -a "$RES") 2>&1

case "$PHASE" in
  prep)
    echo "== EXP-009 фаза 1 (prep): hfctl off под ai → linger → gfctl on ($(date -Is))"
    $SSH "$GF_ACC_USER@$GF_ACC_HOST" 'bash -s' <<'REMOTE' || {
      set -u
      GF="$HOME/gfctl/gfctl"
      echo "== hfctl-прод: гасим ОТ ИМЕНИ ai (юниты disabled → после ребута не встанет; RAM остаётся gufo)"
      if command -v hfctl >/dev/null 2>&1; then
        hfctl off || exit 41
      else
        echo "hfctl отсутствует — пропускаю (окно только про gfctl)"
      fi
      echo "== linger: hfctl off погасил (linger=no) — возвращаем, иначе юзер-менеджер на ребуте не поднимется"
      sudo loginctl enable-linger "${USER:-ai}" || exit 41
      echo "== gfctl on: юниты enabled + linger=yes + контейнер поднят (источник самоподъёма)"
      GFCTL_YES=1 "$GF" on || { echo "gfctl on не прошёл — gfctl установлен? см. EXP-008"; exit 45; }
      "$GF" status
      echo "--- EXP-009 prep done ---"
REMOTE
      rc=$?
      echo "RESULT: FAIL — prep rc=$rc (41=hfctl off/linger, 45=gfctl on)"; exit 1; }
    cat <<'CHECKLIST'
== ЧЕК-ЛИСТ ребут-приёмки (руками, скрипт ребутить не умеет):
  (1) перезагрузи машину;
  (2) НЕ логинься заранее: linger включён (prep) — юзер-менеджер поднимется
      сам; gfctl-serve может стартовать раньше amdgpu — это ШТАТНО: cmd_boot
      ждёт GPU-ноды до 7 мин (Restart=on-failure/30 с) + загрузка модели
      ~2 мин; ориентир готовности 3–10 мин — не паникуй раньше;
  (3) запусти фазу 2:
      GF_ACC_HOST=… GF_ACC_USER=ai GF_ACC_KEY=~/.ssh/strix_halo_key \
        bash EXP-009-reboot.sh verify
  Ожидание: gfctl-сервер поднялся САМ (serve-юнит + watchdog), рук. команд 0;
  hfctl-прод после ребута НЕ встанет (его юниты disabled off-ом) — так и
  задумано, вернём в verify.
  Контингентная оговорка (по дизайну НЕ должна сработать): container_up
  gfctl всегда rm+run со свежим --device /dev/dri — device-mismatch
  (podman-снэпшот card0/card1, грабля hfctl на evo) gfctl не грозит.
  Если в journal всё же появится «cannot stat /dev/dri» — ручная процедура:
    systemctl --user stop gfctl-serve.service
    podman rm -f gufo
    systemctl --user start gfctl-serve.service
  …и запиши находку в отчёт окна (бэклог-кандидат gfctl).
CHECKLIST
    echo "RESULT: PASS — фаза 1 (prep) выполнена; жду ребут и фазу verify"
    ;;
  verify)
    echo "== EXP-009 фаза 2: сервер сам healthy после ребута ($(date -Is))"
    $SSH "$GF_ACC_USER@$GF_ACC_HOST" 'bash -s' <<'REMOTE' || {
      set -u
      GF="$HOME/gfctl/gfctl"
      echo "== юниты после ребута (подъём рук. командами = 0: только смотрим)"
      systemctl --user is-active gfctl-serve.service || true
      systemctl --user is-active gfctl-watchdog.timer || true
      tail -5 "$HOME/gfctl/.data/logs/watchdog.log" 2>/dev/null || true
      echo "== wait-loop до 12 мин: boot ждёт GPU-ноды (до 7 мин) + загрузка модели"
      ok=""
      for i in $(seq 1 36); do
        if "$GF" status 2>/dev/null | grep -q 'health: ok'; then ok=1; break; fi
        sleep 20
      done
      [ -n "$ok" ] || { echo "WAIT_TIMEOUT: статус не дошёл до health: ok за 12 мин"; exit 42; }
      echo "== device-mismatch контроль (ожидание: чисто — container_up всегда rm+run)"
      if journalctl --user -u gfctl-serve.service --since '-40 min' 2>/dev/null \
           | grep -F 'cannot stat /dev/dri'; then
        echo "DEVICE_MISMATCH: воспроизвёлся — ручная recreate-процедура из чек-листа + пометить бэклог gfctl"
        exit 44
      fi
      echo "DEVICE_MISMATCH: нет (чисто)"
      echo "== healthy-гейт: smoke (роут из лога + 3 запроса)"
      "$GF" smoke || exit 42
      echo "== hfctl-прод: возвращаем"
      if command -v hfctl >/dev/null 2>&1; then
        hfctl on || exit 43
        sleep 5
        hfctl status || exit 43
        HFCTL_HEALTH=$(hfctl status 2>/dev/null | grep -oE 'health: [a-z]+' | head -n1)
        echo "HFCTL_HEALTH=$HFCTL_HEALTH"
        loginctl show-user "${USER:-ai}" -p Linger 2>/dev/null || true
      else
        echo "HFCTL_HEALTH=absent (hfctl на машине нет — окно только про gfctl)"
      fi
      echo "--- EXP-009 remote done ---"
REMOTE
      rc=$?
      echo "RESULT: FAIL — verify rc=$rc (42=статус/smoke gfctl, 43=hfctl on/status, 44=device-mismatch)"; exit 1; }
    grep -q '^SMOKE: OK' "$RES" || { echo "RESULT: FAIL — gfctl smoke не прошёл после ребута"; exit 1; }
    grep -q '^роут: ' "$RES" || { echo "RESULT: FAIL — роут не напечатан (сервер не поднялся сам)"; exit 1; }
    grep -q '^DEVICE_MISMATCH: нет' "$RES" \
      || { echo "RESULT: FAIL — device-mismatch в journal (см. result; ручная recreate-процедура из чек-листа)"; exit 1; }
    grep -qE '^HFCTL_HEALTH=(health: ok|absent)' "$RES" \
      || { echo "RESULT: FAIL — hfctl-прод не вернулся healthy (см. result)"; exit 1; }
    echo "RESULT: PASS — после ребута gfctl сам healthy + smoke, device-mismatch нет; hfctl-прод возвращён"
    ;;
  *)
    echo "неизвестная фаза '$PHASE' — доступно: prep | verify" >&2
    exit 1
    ;;
esac
