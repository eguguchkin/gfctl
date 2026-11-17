#!/usr/bin/env bash
# EXP-002-dl27b-faex — реальный download 27b-сета с HF + sha256-verify.
#
# Внешний эксперимент (BLOCKED-EXTERNAL): исполняется ТОЛЬКО на приёмочной
# машине (≥128 GB, быстрый диск) и ТОЛЬКО с явным GO пользователя. Роли gfctl
# ssh наружу не делают (AGENTS.md hygiene); приёмка — этап 1 (PLAN DoD:
# «веса докачаны (sha PASS)» — на каркасе 1.1 проверяем транспорт).
#
# GOAL:
#   - pre-flight цифрами ДО трафика: строка «нужно <X> GiB (остаток), свободно
#     <Y> GiB» печатается раньше любой строки «качаю …»;
#   - транспорт curl до huggingface.co жив: оба файла 27b-сета
#     (15 677 391 456 B суммарно) скачаны, sha256-verify = PASS ×2;
#   - inventory после: «есть, размер OK, sha OK» ×2;
#   - check-types 27b (jpetrina pure-IQ4_XS) → «зелёный», rc 0
#     (санитарный контрпример к правилу UD-*, F3);
#   - идемпотентность: повторный download → SKIP ×2, сети не было.
#
# PREREQ:
#   - GO пользователя; приёмочная машина 128 GB со свободным диском ≥20 GiB
#     (сет 27b = 14.6 GiB); env: GF_ACC_HOST, GF_ACC_USER, GF_ACC_KEY;
#   - окно запускать в tmux/долгой ssh-сессии (15–49 GB качаются десятки минут);
#   - ЭКОНОМИЯ: качается ТОЛЬКО 27b-сет (~15 GB). flash-сет (111 GB) в этом EXP
#     НЕ качать. Скачанные модели НЕ удалять — пригодятся этапу 2 (в отчёте
#     окна указать каталог $HOME/gfctl-acc-models/27b).
#
# RUN:  GF_ACC_HOST=… GF_ACC_USER=… GF_ACC_KEY=… bash EXP-002-dl27b-faex.sh
#   Весь вывод → EXP-002-dl27b-faex.result.txt, финальная строка
#   «RESULT: PASS|FAIL|ERROR — …».
set -uo pipefail
: "${GF_ACC_HOST:?задай GF_ACC_HOST (приёмочная машина — см. hosts-профиль llm-lab)}"
: "${GF_ACC_USER:?задай GF_ACC_USER}"
: "${GF_ACC_KEY:?задай GF_ACC_KEY}"

cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
RES="EXP-002-dl27b-faex.result.txt"
SSH="ssh -i $GF_ACC_KEY -o BatchMode=yes -o ConnectTimeout=10"

exec > >(tee "$RES") 2>&1

echo "== EXP-002: перенос дерева и докачка 27b-сета (--yes: согласие явное)"
$SSH "$GF_ACC_USER@$GF_ACC_HOST" 'rm -rf ~/gfctl-acc-src && mkdir -p ~/gfctl-acc-src' || {
  echo "RESULT: ERROR — ssh не прошёл"; exit 1; }
tar -C "$ROOT" --exclude=.git --exclude=.dev -cf - . | \
  $SSH "$GF_ACC_USER@$GF_ACC_HOST" 'tar -C ~/gfctl-acc-src -xf -' || {
  echo "RESULT: ERROR — ssh не прошёл"; exit 1; }

$SSH "$GF_ACC_USER@$GF_ACC_HOST" 'bash -s' <<'REMOTE' || {
  set -u
  export GFCTL_DIR="$HOME/gfctl-acc" GFCTL_MODELS="$HOME/gfctl-acc-models"
  df -h "$HOME" | tail -1          # фиксируем свободное место ДО трафика
  bash "$HOME/gfctl-acc-src/install.sh"
  "$GFCTL_DIR/gfctl" models download 27b --yes
  echo "--- inventory после ---"
  "$GFCTL_DIR/gfctl" models
  echo "--- check-types 27b ---"
  "$GFCTL_DIR/gfctl" models --check-types 27b; echo "check-types rc=$?"
  echo "--- повторный download (идемпотентность) ---"
  "$GFCTL_DIR/gfctl" models download 27b --yes
  echo "--- EXP-002 remote done ---"
REMOTE
  echo "RESULT: ERROR — удалённая сессия упала (частичный .part остаётся для докачки — это штатно)"; exit 1; }

echo "== EXP-002: критерии PASS"
fail=0
# pre-flight до трафика: первая «нужно … GiB (остаток)» раньше первой «качаю»
need_ln=$(grep -n 'нужно [0-9.]* GiB (остаток)' "$RES" | head -1 | cut -d: -f1)
get_ln=$(grep -n 'качаю (попытка' "$RES" | head -1 | cut -d: -f1)
if [ -n "$need_ln" ] && [ -n "$get_ln" ] && [ "$need_ln" -lt "$get_ln" ]; then
  echo "OK: pre-flight («строка $need_ln») до трафика («строка $get_ln»)"
else
  echo "FAIL: pre-flight-строка не найдена или напечатана после начала трафика"; fail=1
fi
grep -q 'PASS: qwen3.8-27b-IQ4_XS-pure.gguf (sha OK)' "$RES" \
  || { echo "FAIL: main-файл без sha-PASS"; fail=1; }
grep -q 'PASS: Qwen3.8-27B-DFlash2-Q4_K_M.gguf (sha OK)' "$RES" \
  || { echo "FAIL: draft без sha-PASS"; fail=1; }
[ "$(grep -c 'есть, размер OK, sha OK' "$RES")" = 2 ] \
  || { echo "FAIL: inventory не показывает «sha OK» ×2"; fail=1; }
grep -q 'зелёный — сет 27b можно грузить' "$RES" \
  || { echo "FAIL: check-types 27b не «зелёный»"; fail=1; }
[ "$(grep -c '^SKIP:' "$RES")" = 2 ] \
  || { echo "FAIL: повторный download не дал SKIP ×2"; fail=1; }
grep -q 'SHA-MISMATCH' "$RES" && { echo "FAIL: SHA-MISMATCH в живой докачке"; fail=1; }
if grep -qi 'traceback' "$RES"; then echo "FAIL: traceback"; fail=1; fi
[ "$fail" = 0 ] && echo "RESULT: PASS — транспорт HF, pre-flight до трафика, sha-verify и идемпотентность подтверждены на живом 27b-сете" \
               || echo "RESULT: FAIL — см. FAIL-строки выше"
