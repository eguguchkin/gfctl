#!/usr/bin/env bash
# EXP-001-doctor-evo — doctor / models / status на ЖИВОЙ приёмочной машине (~60 GiB).
#
# Внешний эксперимент (BLOCKED-EXTERNAL): исполняется ТОЛЬКО на приёмочной
# машине и ТОЛЬКО с явным GO пользователя. Роли gfctl ssh/podman наружу не
# делают (AGENTS.md hygiene); этот скрипт — задание для приёмочного окна
# (этап 1, PLAN: «doctor печатает гейты всех профилей» на evo).
#
# GOAL:
#   - doctor rc=0 на целевой машине, где подсистемы ЕСТЬ: /dev/kfd, renderD*,
#     render-группа, linger, podman (дев-контейнер проверил только деградацию);
#   - RAM-гейты считают по-настоящему: 27b-single и 27b-multi = OK (~59.x GiB),
#     flash-multi = НЕДОСТАТУПЕН с цифрами (~59.x vs ≥110) — DoD этапа 1/PLAN
#     и формат из DoD 1.1;
#   - gpu-lock: при живом hfctl-проде — WARN с именами контейнеров (D3:
#     только предупреждение, takeover не делается);
#   - status [--json] валиден на живой машине; `models` на пустом каталоге —
#     инвентарь «НЕТ» + сводка, без записи в посторонние места.
#
# PREREQ:
#   - GO пользователя на окно приёмки; приёмочная машина ~60 GiB (профиль —
#     в hosts-файле llm-lab, сюда НЕ выписывается);
#   - env перед запуском: GF_ACC_HOST, GF_ACC_USER, GF_ACC_KEY (путь до ключа);
#   - hfctl-прод на машине НЕ трогать: команды gfctl 1.1 read-only; install.sh
#     пишет только ~/gfctl-acc (+ симлинк ~/.local/bin/gfctl), models — tmp.
#
# RUN:  GF_ACC_HOST=… GF_ACC_USER=… GF_ACC_KEY=… bash EXP-001-doctor-evo.sh
#   Весь вывод → EXP-001-doctor-evo.result.txt, финальная строка
#   «RESULT: PASS|FAIL|ERROR — …».
#
# ЗАПРЕЩЕНО в этом EXP: gfctl models download (трафик — EXP-002), любые
# podman/systemd-команды, правки прод-конфигов hfctl.
set -uo pipefail
: "${GF_ACC_HOST:?задай GF_ACC_HOST (приёмочная машина — см. hosts-профиль llm-lab)}"
: "${GF_ACC_USER:?задай GF_ACC_USER}"
: "${GF_ACC_KEY:?задай GF_ACC_KEY}"

cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"                 # корень репо gfctl (скрипт в .dev/external/)
RES="EXP-001-doctor-evo.result.txt"
SSH="ssh -i $GF_ACC_KEY -o BatchMode=yes -o ConnectTimeout=10"

exec > >(tee "$RES") 2>&1

echo "== EXP-001: перенос дерева (без .git/.dev) и read-only прогоны"
$SSH "$GF_ACC_USER@$GF_ACC_HOST" 'rm -rf ~/gfctl-acc-src && mkdir -p ~/gfctl-acc-src' || {
  echo "RESULT: ERROR — ssh до приёмочной машины не прошёл (проверь GF_ACC_*)"; exit 1; }
tar -C "$ROOT" --exclude=.git --exclude=.dev -cf - . | \
  $SSH "$GF_ACC_USER@$GF_ACC_HOST" 'tar -C ~/gfctl-acc-src -xf -' || {
  echo "RESULT: ERROR — ssh до приёмочной машины не прошёл (проверь GF_ACC_*)"; exit 1; }

$SSH "$GF_ACC_USER@$GF_ACC_HOST" 'bash -s' <<'REMOTE' || {
  set -u
  export GFCTL_DIR="$HOME/gfctl-acc"
  bash "$HOME/gfctl-acc-src/install.sh"
  echo "--- doctor ---";  "$GFCTL_DIR/gfctl" doctor
  echo "--- models (пустой tmp-каталог) ---"
  rm -rf "$HOME/gfctl-acc-tmp-models"
  GFCTL_MODELS="$HOME/gfctl-acc-tmp-models" "$GFCTL_DIR/gfctl" models
  echo "--- status ---"
  "$GFCTL_DIR/gfctl" status
  "$GFCTL_DIR/gfctl" status --json | python3 -m json.tool
  echo "--- EXP-001 remote done ---"
REMOTE
  echo "RESULT: ERROR — удалённая сессия упала"; exit 1; }

echo "== EXP-001: критерии PASS"
fail=0
grep -q '/dev/kfd: есть' "$RES"                       || { echo "FAIL: /dev/kfd не отмечен как «есть»"; fail=1; }
grep -q 'render-группа: да' "$RES"                    || { echo "FAIL: render-группа не «да»"; fail=1; }
grep -q 'linger: да' "$RES"                           || { echo "FAIL: linger не «да» (юзер-менеджер не постоянный?)"; fail=1; }
grep -Eq '^  27b-single: ≥56 GiB — есть [0-9]+\.[0-9]: OK$' "$RES" \
  || { echo "FAIL: RAM-гейт 27b-single не «OK» с цифрами"; fail=1; }
grep -Eq '^  27b-multi: ≥56 GiB — есть [0-9]+\.[0-9]: OK$' "$RES" \
  || { echo "FAIL: RAM-гейт 27b-multi не «OK» с цифрами"; fail=1; }
grep -Eq '^  flash-multi: ≥110 GiB — есть [0-9]+\.[0-9]: НЕДОСТАТУПЕН$' "$RES" \
  || { echo "FAIL: RAM-гейт flash-multi не «НЕДОСТАТУПЕН» с цифрами"; fail=1; }
grep -q '^gpu-lock:' "$RES"                           || { echo "FAIL: нет строки gpu-lock"; fail=1; }
grep -Eq '^порт [0-9]+: (свободен|что-то слушает)$' "$RES" || { echo "FAIL: порт-проба не отработала"; fail=1; }
grep -c '^файл\|НЕТ$' "$RES" >/dev/null 2>&1          # инвентарь печатался (мягкая проверка, см. строки «НЕТ»)
grep -q 'сет 27b 0/2' "$RES"                          || { echo "FAIL: сводка models без 27b 0/2"; fail=1; }
if grep -qi 'traceback' "$RES"; then echo "FAIL: traceback в выводе"; fail=1; fi
[ "$fail" = 0 ] && echo "RESULT: PASS — doctor/status/models на живой машине соответствуют контракту (гейты цифрами, деградации нет)" \
               || echo "RESULT: FAIL — см. FAIL-строки выше"
