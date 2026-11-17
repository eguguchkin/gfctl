#!/usr/bin/env bash
# EXP-003-life-evo — ПОЛНЫЙ жизненный цикл gfctl на ЖИВОЙ приёмочной машине
# (~60 GiB, профиль — в hosts-файле llm-lab, сюда НЕ выписывается).
#
# Внешний эксперимент (BLOCKED-EXTERNAL, приёмка этапа 1 — PLAN DoD
# «install на голом каталоге: healthy, smoke, роут dflash2 sessions 1
# ctx 262144, автозапуск вкл» + «off: вотчдог не воскрешает (70 c); on —
# всё вернулось»). Роли gfctl ssh/podman наружу не делают (AGENTS.md
# hygiene); скрипт исполняет ОПЕРАТОР окна приёмки с GO пользователя.
#
# GOAL:
#   - install на живой машине (или use при уже скачанных весах): реальные
#     podman/systemd/loginctl шаги, F9-флаги в реальном `podman run`;
#   - healthy: строка «роут: dflash2, sessions 1, ctx 262144» из РЕАЛЬНОГО
#     лога движка (load_completed; F2: publish работает только с --host
#     0.0.0.0 — живой curl /ready это доказывает);
#   - smoke: «SMOKE: OK» (ретрай первого запроса при холодном старте — F15,
#     в логе окна видно по строке «повторяю через 15с», её наличие НЕ
#     обязательно — это WARN-ветка);
#   - off: маркер .gfctl-stopped, юниты сняты (is-enabled = disabled/ошибка),
#     linger=no, контейнера нет;
#   - вотчдог 70 c НЕ воскрешает: и за 70 c ожидания (таймер снят), и по
#     ЯВНОМУ вызову `gfctl _watchdog` (маркер — первая проверка, F16)
#     контейнер не появляется;
#   - on: юниты+timer снова enabled, linger=yes, recreate (rm+run) +
#     health — статус «health: ok», роут той же строкой (PLAN: «on —
#     всё вернулось»).
#
# PREREQ:
#   - GO пользователя на окно приёмки этапа 1; машина ~60 GiB (evo);
#   - env перед запуском: GF_ACC_HOST, GF_ACC_USER, GF_ACC_KEY (путь до
#     ключа);
#   - СОСЕДСТВО (GPU один): перед окном остановить hfctl-прод (`hfctl off`),
#     ПОСЛЕ окна вернуть (`hfctl on` + healthy + smoke) — правило llm-lab
#     «живой прод останавливается только внутри приёмки этапа»; иначе
#     ожидаем load_failed с внятным логом (двигаться нечем) — это FAIL окна,
#     а не бага gfctl;
#   - веса 27b: если EXP-002 уже скачал их в $HOME/gfctl-acc-models/27b —
#     скрипт идёт быстрым путём `use` (SKIP докачки); иначе `install`
#     скачает ~15 GB сам (окно в tmux/долгой ssh-сессии);
#   - memlock: если limits.d ещё не настроен и юзер не перелогинился,
#     install выйдет с кодом 42 («ПЕРЕЛОГИНЬСЯ») — перелогиниться и
#     повторить (штатная ветка, не бага).
#
# RUN:  GF_ACC_HOST=… GF_ACC_USER=… GF_ACC_KEY=… bash EXP-003-life-evo.sh
#   Весь вывод → EXP-003-life-evo.result.txt, финальная строка
#   «RESULT: PASS|FAIL|ERROR — …».
#
# PASS-критерий (все обязательны, проверка грепами по result-файлу):
#   1) строка «роут: dflash2, sessions 1, ctx 262144» присутствует;
#   2) «SMOKE: OK» присутствует;
#   3) после off: маркер есть, is-enabled НЕ «enabled», Linger=no,
#      `podman inspect` контейнера — отказ;
#   4) после 70 c и явного `_watchdog`: контейнера ПО-ПРЕЖНЕМУ нет, rc 0;
#   5) после on: is-enabled = enabled, Linger=yes, inspect = running,
#      status показывает «health: ok» и тот же роут;
#   6) ни одного traceback.
set -uo pipefail
: "${GF_ACC_HOST:?задай GF_ACC_HOST (приёмочная машина — см. hosts-профиль llm-lab)}"
: "${GF_ACC_USER:?задай GF_ACC_USER}"
: "${GF_ACC_KEY:?задай GF_ACC_KEY}"

cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"                 # корень репо gfctl (скрипт в .dev/external/)
RES="EXP-003-life-evo.result.txt"
SSH="ssh -i $GF_ACC_KEY -o BatchMode=yes -o ConnectTimeout=10"

exec > >(tee "$RES") 2>&1

echo "== EXP-003: перенос дерева (без .git/.dev)"
$SSH "$GF_ACC_USER@$GF_ACC_HOST" 'rm -rf ~/gfctl-acc-src && mkdir -p ~/gfctl-acc-src' || {
  echo "RESULT: ERROR — ssh до приёмочной машины не прошёл (проверь GF_ACC_*)"; exit 1; }
tar -C "$ROOT" --exclude=.git --exclude=.dev -cf - . | \
  $SSH "$GF_ACC_USER@$GF_ACC_HOST" 'tar -C ~/gfctl-acc-src -xf -' || {
  echo "RESULT: ERROR — ssh до приёмочной машины не прошёл (проверь GF_ACC_*)"; exit 1; }

$SSH "$GF_ACC_USER@$GF_ACC_HOST" 'bash -s' <<'REMOTE' || {
  set -u
  export GFCTL_DIR="$HOME/gfctl-acc"
  MODELS="$HOME/gfctl-acc-models"
  export GFCTL_MODELS="$MODELS"   # иначе use не увидит скачанное и перекачает ~15 GiB (review 1.2 note#1)
  bash "$HOME/gfctl-acc-src/install.sh"
  export GFCTL_YES=1
  MAIN="$MODELS/27b/qwen3.8-27b-IQ4_XS-pure.gguf"
  DRAFT="$MODELS/27b/Qwen3.8-27B-DFlash2-Q4_K_M.gguf"
  if [ -f "$MAIN" ] && [ -f "$DRAFT" ]; then
    echo "--- веса на месте ($MODELS/27b) — быстрый путь: gfctl use 27b-single"
    "$GFCTL_DIR/gfctl" use 27b-single
  else
    echo "--- весов нет — полный путь: gfctl install --models-dir $MODELS"
    "$GFCTL_DIR/gfctl" install --models-dir "$MODELS"
  fi || { echo "RESULT: FAIL — install/use не дошёл до healthy+smoke"; exit 42; }
  echo "--- status (живой) ---"
  "$GFCTL_DIR/gfctl" status
  "$GFCTL_DIR/gfctl" status --json | python3 -m json.tool

  echo "--- off ---"
  "$GFCTL_DIR/gfctl" off
  [ -f "$HOME/gfctl-acc/.gfctl-stopped" ] && echo "маркер: ЕСТЬ" || echo "маркер: НЕТ (FAIL-критерий 3)"
  if systemctl --user is-enabled gfctl-serve.service >/dev/null 2>&1; then
    echo "is-enabled: enabled"
  else
    echo "is-enabled: НЕ-enabled"
  fi
  loginctl show-user "$USER" -p Linger 2>&1 || true
  podman inspect -f '{{.State.Status}}' gufo 2>&1 || echo "контейнера нет (после off) — ожидаемо"

  echo "--- вотчдог 70 c НЕ воскрешает ---"
  sleep 70
  podman inspect -f '{{.State.Status}}' gufo 2>&1 || echo "через 70 c контейнера нет — ожидаемо"
  "$GFCTL_DIR/gfctl" _watchdog; echo "explicit _watchdog rc=$?"
  podman inspect -f '{{.State.Status}}' gufo 2>&1 || echo "после явного _watchdog контейнера нет (маркер уважен) — ожидаемо"

  echo "--- on (recreate + health) ---"
  "$GFCTL_DIR/gfctl" on || { echo "RESULT: FAIL — on не вернул сервер"; exit 42; }
  if systemctl --user is-enabled gfctl-serve.service >/dev/null 2>&1; then
    echo "is-enabled: enabled"
  else
    echo "is-enabled: НЕ-enabled"
  fi
  loginctl show-user "$USER" -p Linger 2>&1 || true
  podman inspect -f '{{.State.Status}}' gufo 2>&1 || true
  "$GFCTL_DIR/gfctl" status
  echo "--- EXP-003 remote done ---"
REMOTE
  rc=$?
  if [ "$rc" = 42 ]; then exit 1; fi   # FAIL уже напечатан удалённой веткой
  echo "RESULT: ERROR — удалённая сессия упала (rc=$rc)"; exit 1; }

echo "== EXP-003: критерии PASS"
fail=0
grep -q 'роут: dflash2, sessions 1, ctx 262144' "$RES" \
  || { echo "FAIL: нет строки роута dflash2/1/262144"; fail=1; }
grep -q 'SMOKE: OK' "$RES"                 || { echo "FAIL: нет SMOKE: OK"; fail=1; }
grep -q 'маркер: ЕСТЬ' "$RES"              || { echo "FAIL: после off нет маркера"; fail=1; }
grep -q '^is-enabled: НЕ-enabled$' "$RES" || { echo "FAIL: после off юнит всё ещё enabled"; fail=1; }
grep -q '^Linger=no' "$RES"                || { echo "FAIL: после off linger не no"; fail=1; }
grep -q 'контейнера нет (после off)' "$RES" || { echo "FAIL: после off контейнер жив?"; fail=1; }
grep -q 'через 70 c контейнера нет' "$RES" || { echo "FAIL: вотчдог/что-то воскресило за 70 c"; fail=1; }
grep -q 'explicit _watchdog rc=0' "$RES"   || { echo "FAIL: явный _watchdog не rc 0"; fail=1; }
grep -q 'после явного _watchdog контейнера нет' "$RES" \
  || { echo "FAIL: _watchdog проигнорировал маркер (F16)"; fail=1; }
grep -q '^is-enabled: enabled$' "$RES"     || { echo "FAIL: после on is-enabled не enabled"; fail=1; }
grep -q '^Linger=yes' "$RES"               || { echo "FAIL: после on linger не yes"; fail=1; }
grep -q '^running' "$RES"                  || { echo "FAIL: после on контейнер не running"; fail=1; }
grep -q 'health: ok' "$RES"                || { echo "FAIL: статус после on не health: ok"; fail=1; }
if grep -qi 'traceback' "$RES"; then echo "FAIL: traceback в выводе"; fail=1; fi
[ "$fail" = 0 ] && echo "RESULT: PASS — полный жизненный цикл на живой машине: install/use → healthy+smoke → off → вотчдог 70 c молчит → on → recreate+health" \
               || echo "RESULT: FAIL — см. FAIL-строки выше"
