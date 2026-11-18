#!/usr/bin/env bash
# EXP-008-delivery — «доставка с нуля» (этап 4, PLAN п.2): полный цикл
# локальной дистрибуции (D1) на приёмочной машине: tar-перенос дерева →
# install.sh (bootstrap-FIRST — урок F21) → gfctl install (докачка только
# недостающих весов) → use канон → agent-check → gfctl off.
#
# Внешний эксперимент (BLOCKED-EXTERNAL): исполняется ТОЛЬКО на приёмочной
# машине (che-evo 60 GiB / che-FAEX1 128 GB) и ТОЛЬКО с явным GO
# пользователя. Живой hfctl-прод машины останавливается ТОЛЬКО внутри окна
# (см. PREREQ). ЭТА ЗАГОТОВКА В РЕПО НЕ ИСПОЛНЯЕТСЯ (bash -n only).
#
# GOAL:
#   - tar-перенос дерева репо (без .git/.dev) в ~/gfctl-acc-src;
#   - bootstrap-first: install.sh → ~/gfctl-acc (F21: каждый EXP начинает
#     remote-часть с bootstrap — приёмка всегда идёт свежим кодом);
#   - предусловие «gfctl не установлен или uninstall'нут»: старая приёмочная
#     инсталляция ~/gfctl-acc снимается БЕЗ purge (модели/образ щадятся);
#   - веса: хардлинки уже скачанных файлов из ~/gufo-models (как EXP-005;
#     если источников нет — gfctl install скачает сам, трафик по пинам);
#   - `gfctl install` — идемпотентная полная постановка: preflight → веса
#     (докачка ТОЛЬКО недостающего: SKIP по готовым) → юниты → recreate →
#     health → smoke → автозапуск;
#   - архив образа (страховка от смерти ghcr): `podman save $IMG -o
#     ~/gfctl-image-backup.tar` (существующий архив перезаписывается,
#     печатается размер) + подсказка digest-пина
#     «GFCTL_IMAGE=<образ>@sha256:…» — НА ГЛАЗ, канон gfctl не меняется;
#   - `gfctl use $GF_ACC_FLAVOR` — канон профиля окна;
#   - `gfctl agent-check` — агентская самопроверка (SPEC §7, 25 запросов);
#   - `gfctl off` — завершение окна (дорога hfctl on).
#
# PREREQ:
#   - ЯВНЫЙ GO пользователя на ЭТО окно;
#   - env: GF_ACC_HOST, GF_ACC_USER, GF_ACC_KEY, GF_ACC_FLAVOR
#     (27b-single | 27b-multi | flash-multi; на 60 GiB flash-multi невозможен
#     — RAM-гейт отсечёт до трафика);
#   - hfctl-прод машины ОСТАНОВЛЕН перед окном (`hfctl off` + НЕМЕДЛЕННЫЙ
#     `loginctl enable-linger`), после окна: скрипт сам делает `gfctl off`
#     → ты: `hfctl on` → healthy + smoke;
#   - окно в tmux / долгой ssh-сессии (установка весов с нуля — десятки ГБ).
#
# RUN:  GF_ACC_HOST=… GF_ACC_USER=… GF_ACC_KEY=… GF_ACC_FLAVOR=27b-single \
#       bash EXP-008-delivery.sh
#   Весь вывод → EXP-008-delivery.result.txt, финальная строка
#   «RESULT: PASS|FAIL|ERROR — …».
#
# PASS-критерий (brief 4.1):
#   1) healthy: «роут:» + «SMOKE: OK» от install (сервер поднят и здоров);
#   2) smoke повторно не нужен — use/agent-check прошли rc 0;
#   3) agent-check: «AGENT-CHECK:» сводка, AGENT_CHECK_RC=0.
set -uo pipefail
: "${GF_ACC_HOST:?задай GF_ACC_HOST (приёмочная машина — см. hosts-профиль llm-lab)}"
: "${GF_ACC_USER:?задай GF_ACC_USER}"
: "${GF_ACC_KEY:?задай GF_ACC_KEY}"
: "${GF_ACC_FLAVOR:?задай GF_ACC_FLAVOR (27b-single | 27b-multi | flash-multi)}"

cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
RES="EXP-008-delivery.result.txt"
SSH="ssh -i $GF_ACC_KEY -o BatchMode=yes -o ConnectTimeout=10"

exec > >(tee "$RES") 2>&1

echo "== EXP-008: снос СТАРОЙ инсталляции (uninstall снесёт acc/acc-src — поэтому ДО tar)"
$SSH "$GF_ACC_USER@$GF_ACC_HOST" 'if [ -x "$HOME/gfctl-acc/gfctl" ]; then GFCTL_YES=1 "$HOME/gfctl-acc/gfctl" uninstall; else echo "(не было — чистая машина)"; fi' || {
  echo "RESULT: ERROR — uninstall старой инсталляции не прошёл"; exit 1; }

echo "== EXP-008: tar-перенос дерева (без .git/.dev)"
$SSH "$GF_ACC_USER@$GF_ACC_HOST" 'rm -rf ~/gfctl-acc-src && mkdir -p ~/gfctl-acc-src' || {
  echo "RESULT: ERROR — ssh не прошёл"; exit 1; }
tar -C "$ROOT" --exclude=.git --exclude=.dev -cf - . | \
  $SSH "$GF_ACC_USER@$GF_ACC_HOST" 'tar -C ~/gfctl-acc-src -xf -' || {
  echo "RESULT: ERROR — ssh не прошёл"; exit 1; }

$SSH "$GF_ACC_USER@$GF_ACC_HOST" "GF_ACC_FLAVOR=$GF_ACC_FLAVOR bash -s" <<'REMOTE' || {
  set -u
  export GFCTL_DIR="$HOME/gfctl-acc" GFCTL_MODELS="$HOME/gfctl-acc-models" GFCTL_YES=1
  GF="$HOME/gfctl-acc/gfctl"

  echo "== bootstrap-first (F21): install.sh (свежее дерево из src)"
  bash "$HOME/gfctl-acc-src/install.sh" || exit 44

  echo "== веса: хардлинки из ~/gufo-models, если источник есть (иначе скачает install)"
  setname=${GF_ACC_FLAVOR%%-*}
  mkdir -p "$HOME/gfctl-acc-models/$setname"
  n=0
  for src in "$HOME"/gufo-models/*/*.gguf "$HOME"/gufo-models/*/*/*.gguf; do
    [ -f "$src" ] || continue
    base=$(basename "$src")
    # имена файлов источников = пинам таблицы set_* (F8) — линкуем по совпадению
    if [ ! -e "$HOME/gfctl-acc-models/$setname/$base" ]; then
      ln -f "$src" "$HOME/gfctl-acc-models/$setname/$base" 2>/dev/null && n=$((n + 1))
    fi
  done
  echo "HARDLINKED=$n (0 — окно с нуля: скачает gfctl install)"

  echo "== gfctl install: гейты → докачка ТОЛЬКО недостающего → recreate → health → smoke → автозапуск"
  "$GF" install --profile "$GF_ACC_FLAVOR" || exit 46

  echo "== архив образа (страховка от смерти ghcr): podman save → ~/gfctl-image-backup.tar (перезапись)"
  IMG="ghcr.io/gufo-org/toolboxes/gufo-runtime:latest"
  podman save "$IMG" -o "$HOME/gfctl-image-backup.tar" || exit 54
  ls -lh "$HOME/gfctl-image-backup.tar" | awk 'NR==1{next} {print "размер архива:", $5}'
  echo "запинить: GFCTL_IMAGE=$IMG@$(podman inspect --format '{{.ImageDigest}}' gufo)  (digest манифеста — канон gfctl не меняется)"

  echo "== use $GF_ACC_FLAVOR (канон; уже healthy — идемпотентно)"
  "$GF" use "$GF_ACC_FLAVOR" || exit 47

  echo "== agent-check (SPEC §7)"
  set +e; "$GF" agent-check; AGENT_CHECK_RC=$?; set -e
  echo "AGENT_CHECK_RC=$AGENT_CHECK_RC"
  [ "$AGENT_CHECK_RC" = 0 ] || exit 48

  echo "== статус"
  "$GF" status

  echo "== завершение окна: gfctl off (дорога hfctl on)"
  "$GF" off || true
  echo "--- EXP-008 remote done ---"
REMOTE
  rc=$?
  echo "RESULT: FAIL — remote-часть rc=$rc (44=bootstrap, 45=uninstall, 46=install, 54=podman save, 47=use, 48=agent-check)"; exit 1; }

echo "== EXP-008: критерии PASS"
grep -q '^SMOKE: OK' "$RES" || { echo "RESULT: FAIL — install не дошёл до SMOKE: OK"; exit 1; }
grep -q '^роут: ' "$RES" || { echo "RESULT: FAIL — роут не напечатан (не healthy)"; exit 1; }
arc=$(sed -n 's/^AGENT_CHECK_RC=\([0-9][0-9]*\)$/\1/p' "$RES" | head -n1)
[ "$arc" = 0 ] || { echo "RESULT: FAIL — agent-check rc=${arc:-?} (ждём 0)"; exit 1; }
echo "RESULT: PASS — доставка с нуля: healthy + smoke, agent-check rc 0 (детали окна — в result-файле)"
