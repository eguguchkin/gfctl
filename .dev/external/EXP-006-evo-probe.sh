#!/usr/bin/env bash
# EXP-006-evo-probe — мини-окно на evo: живой probe-подбор 27b-multi
# (196608 → 163840 → 131072) + bench ×3 + статус.
#
# ВАЖНО (инцидент 2026-11-18): remote-часть ОБЯЗАНА начинаться с bootstrap
# install.sh — без него use идёт из СТАРОГО ~/gfctl-acc (1.2-код без probe)
# и молча поднимает дефолт профиля (163840), маскируя probe (F21).
#
# Внешний эксперимент (BLOCKED-EXTERNAL): исполняется ТОЛЬКО на evo и ТОЛЬКО
# по отдельному явному GO пользователя НА ЭТО окно — D6: любой запуск на evo
# (даже read-only) требует явного «да»; «машина свободна» — информация, не
# разрешение.
#
# GOAL:
#   - bootstrap: перенос дерева gfctl (2.1: probe+bench) в ~/gfctl-acc-src →
#     ~/gfctl-acc (изолированная приёмочная инсталляция — как EXP-002..004);
#   - СБРОС канона пары ПЕРЕД probe (ловушка task.md/dev-report): после
#     EXP-004 на evo стоит 1.2-канон 27b-multi×2 (GFCTL_PROFILE=27b-multi,
#     GFCTL_SESSIONS=2, GFCTL_CONTEXT=163840), а canon_pair_context 2.1
#     читает его как канон пары («миграция чтением») → probe НЕ запустится
#     (SPEC §9: канон выигрывает). Скрипт удаляет из ~/gfctl-acc/.env строки
#     ^GFCTL_CTX_27b_multi_ (пар-ключи) и ^GFCTL_CONTEXT= (ломает
#     1.2-fallback — без этого сброс неполон), показывая .env до/после;
#   - цифры отказа 196608: ДО probe — явная попытка
#     `use 27b-multi --context 196608`; при отказе admission-цифры снимаются
#     из podman logs (ПЛАН DoD: отказ 196608 с цифрами — тоже результат;
#     D5: 196608 — первый кандидат; F7: на Q4_K_XL «впритык», IQ4_XS легче
#     на 3.9 GiB — может и загрузиться). Канон этой попытки СБРАСЫВАЕТСЯ
#     повторно перед честным probe;
#   - `use 27b-multi` — probe-лестница: попытка 196608 (вердикт в журнале
#     logs/probe-27b-multi-2.log); при отказе — 163840 (проверенная точка
#     F7/F18); канон пары = фактический максимум (GFCTL_CTX_27b_multi_2);
#   - `gfctl bench` — прогрев + 3 замера фикстуры 253c7ac5. ВАЖНО: bench —
#     СОЛО-замер (1 запрос, 256 completion-ток); с EXP-004 числа НЕ
#     сравнивать напрямую (там парный агрегат 2×600 ток merge/quick sort,
#     F18) — зафиксировать в отчёте отдельно;
#   - статус; в конце `gfctl off` (дорога hfctl on).
#
# PREREQ:
#   - ЯВНЫЙ GO пользователя на ЭТО окно (D6);
#   - env: GF_ACC_HOST, GF_ACC_USER, GF_ACC_KEY;
#   - hfctl-прод evo ОСТАНОВЛЕН перед окном (`hfctl off` + НЕМЕДЛЕННЫЙ
#     `loginctl enable-linger` — user manager умирает ~10 с), после окна
#     вернуть: скрипт сам делает `gfctl off` → ты: `hfctl on` → healthy +
#     smoke (правило llm-lab);
#   - веса 27b уже в ~/gfctl-acc-models/27b (EXP-002) — скачки в этом EXP
#     нет (докачку use не запускает: set полный → SKIP);
#   - паузы recreate (F10) встроены в gfctl; загрузка на тёплой evo ~15 с
#     (F17/F18), худший случай ступени — 180 с → окно в tmux / долгой
#     ssh-сессии.
#
# RUN:  GF_ACC_HOST=… GF_ACC_USER=… GF_ACC_KEY=… bash EXP-006-evo-probe.sh
#   Весь вывод → EXP-006-evo-probe.result.txt, финальная строка
#   «RESULT: PASS|FAIL|ERROR — …».
#
# PASS-критерий:
#   1) .env: строка GFCTL_CTX_27b_multi_2=<N>, N ∈ {196608, 163840, 131072}
#      (канон пары зафиксирован = фактический максимум);
#   2) журнал probe: ≥1 строка «ступень …: попытка загрузки» + вердикт
#      каждой попытки (OK — канон / ОТКАЗ — причина);
#   3) ЛИБО «ступень 196608: OK — канон» в журнале, ЛИБО отказ 196608
#      задокументирован цифрами admission (блок «admission-цифры 196608» в
#      result) — по ПЛАНУ «это тоже результат»;
#   4) bench: «прогрев:», 3 строки «прогон N:», «медиана:» — числа записаны;
#   5) статус «health: ok».
set -uo pipefail
: "${GF_ACC_HOST:?задай GF_ACC_HOST (приёмочная машина — см. hosts-профиль llm-lab)}"
: "${GF_ACC_USER:?задай GF_ACC_USER}"
: "${GF_ACC_KEY:?задай GF_ACC_KEY}"

cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
RES="EXP-006-evo-probe.result.txt"
SSH="ssh -i $GF_ACC_KEY -o BatchMode=yes -o ConnectTimeout=10"

exec > >(tee "$RES") 2>&1

echo "== EXP-006: перенос дерева (без .git/.dev)"
$SSH "$GF_ACC_USER@$GF_ACC_HOST" 'rm -rf ~/gfctl-acc-src && mkdir -p ~/gfctl-acc-src' || {
  echo "RESULT: ERROR — ssh не прошёл"; exit 1; }
tar -C "$ROOT" --exclude=.git --exclude=.dev -cf - . | \
  $SSH "$GF_ACC_USER@$GF_ACC_HOST" 'tar -C ~/gfctl-acc-src -xf -' || {
  echo "RESULT: ERROR — ssh не прошёл"; exit 1; }

$SSH "$GF_ACC_USER@$GF_ACC_HOST" 'bash -s' <<'REMOTE' || {
  set -u
  export GFCTL_DIR="$HOME/gfctl-acc" GFCTL_MODELS="$HOME/gfctl-acc-models" GFCTL_YES=1
  GF="$HOME/gfctl-acc/gfctl"
  ENVF="$HOME/gfctl-acc/.env"

  echo "== gfctl install.sh — bootstrap (ОБЯЗАТЕЛЬНО: без него работает старый 1.2-код — F21)"
  bash "$HOME/gfctl-acc-src/install.sh" || { echo "RESULT: FAIL — bootstrap rc=$?"; exit 51; }

  reset_pair_canon() {
    echo "--- .env до сброса:"; cat "$ENVF" 2>/dev/null || echo "(нет .env)"
    sed -i -e '/^GFCTL_CTX_27b_multi_/d' -e '/^GFCTL_CONTEXT=/d' "$ENVF" 2>/dev/null || true
    echo "--- .env после сброса:"; cat "$ENVF" 2>/dev/null || echo "(нет .env)"
  }

  echo "== сброс канона пары (1.2-канон EXP-004 иначе побеждает — SPEC §9)"
  reset_pair_canon

  echo "== явная попытка 2×196608 (документирование цифр отказа/успеха, D5/F7)"
  "$GF" use 27b-multi --context 196608; top_rc=$?
  echo "TOP_STEP_RC=$top_rc"
  if [ "$top_rc" != 0 ]; then
    echo "== admission-цифры 196608 (podman logs, хвост):"
    podman logs gufo 2>&1 | tail -40
  fi

  echo "== повторный сброс канона пары (явная попытка его записала)"
  reset_pair_canon

  echo "== probe-лестница: use 27b-multi (196608→163840→131072)"
  "$GF" use 27b-multi || exit 42

  echo "== журнал попыток probe:"
  cat "$HOME/gfctl-acc/logs/probe-27b-multi-2.log" 2>/dev/null || echo "(журнала нет)"
  echo "== канон пары:"
  grep '^GFCTL_CTX_27b_multi_2=' "$ENVF" || exit 47

  echo "== bench на probe-каноне (прогрев + 3 замера; СОЛО-замер — с EXP-004 не сравнивать)"
  "$GF" bench || exit 48

  echo "== статус"
  "$GF" status

  echo "== завершение окна: gfctl off (дорога hfctl on)"
  "$GF" off || true
  echo "--- EXP-006 remote done ---"
REMOTE
  rc=$?
  echo "RESULT: FAIL — remote-часть rc=$rc (42=use/probe, 47=канон, 48=bench)"; exit 1; }

echo "== EXP-006: критерии PASS"
canon=$(sed -n 's/^GFCTL_CTX_27b_multi_2=\([0-9][0-9]*\)$/\1/p' "$RES" | head -n1)
case "$canon" in
  196608|163840|131072) echo "канон пары: $canon" ;;
  *) echo "RESULT: FAIL — канон пары не зафиксирован/вне лестницы ('$canon')"; exit 1 ;;
esac
grep -q 'ступень .*: попытка загрузки' "$RES" \
  || { echo "RESULT: FAIL — журнал попыток пуст"; exit 1; }
if ! grep -q 'ступень 196608: OK — канон' "$RES"; then
  grep -q 'admission-цифры 196608' "$RES" \
    || { echo "RESULT: FAIL — 196608 ни ОК, ни задокументирован цифрами"; exit 1; }
  grep -q 'ступень 196608: ОТКАЗ' "$RES" \
    || { echo "RESULT: FAIL — отказ 196608 не отражён в журнале"; exit 1; }
fi
grep -q '^прогрев: wall ' "$RES" && [ "$(grep -c '^прогон [123]: wall ' "$RES")" = 3 ] \
  && grep -q '^медиана: wall ' "$RES" \
  || { echo "RESULT: FAIL — bench-числа не записаны"; exit 1; }
grep -q 'health: ok' "$RES" || { echo "RESULT: FAIL — статус не ok"; exit 1; }
echo "RESULT: PASS — probe 27b-multi: канон пары $canon зафиксирован, попытки журналированы; отказ 196608 (если был) задокументирован цифрами (PLAN: это тоже результат); bench-числа записаны (соло-замер, с EXP-004 не сравнивать)"
