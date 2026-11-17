#!/usr/bin/env bash
# EXP-005-faex — окно этапа 2 на FAEX (flash-only): probe-лестница flash-multi
# + bench + check-types на реальных unsloth UD-IQ4_XS шардах (регресс-тест
# правила F3 «UD-* не грузятся»).
#
# Внешний эксперимент (BLOCKED-EXTERNAL): исполняется ТОЛЬКО на приёмочной
# машине (128 GB Halo) и ТОЛЬКО с явным GO пользователя на ЭТО окно (каждое
# окно — отдельное разрешение). Живой hfctl-прод машины останавливается
# ТОЛЬКО внутри этого окна (см. PREREQ).
#
# GOAL:
#   - bootstrap: перенос дерева gfctl (2.1: probe+bench) в ~/gfctl-acc-src →
#     ~/gfctl-acc (изолированная приёмочная инсталляция — как EXP-002..004);
#   - веса flash БЕЗ трафика: симлинки уже скачанных файлов окна FX в
#     ~/gfctl-acc-models/flash/: 4 шарда UD-Q4_K_XL из
#     ~/gufo-models/flash-next-q4xl/ и MTP shared-Q8_0 из
#     ~/gufo-models/flash-next-ixs/MTP/. Имена файлов уже = пинам таблицы
#     set_flash (F8) → `gfctl models download flash --yes` обязан дать
#     SKIP×5 (0 байт трафика). Примечание: MTP-файл линкуется ПЛОСКО
#     (~/gfctl-acc-models/flash/mtp-…gguf), а не в flash/MTP/ — так ждёт его
#     ensure_weights/serve_args (таблица сета: имя без подкаталога,
#     @MTP@ → /models/<имя>);
#   - цифры отказа верхней ступени: ДО probe — явная попытка
#     `use flash-multi --context 262144`: при отказе admission-цифры
#     снимаются из podman logs (ПЛАН DoD: «отказ с цифрами — тоже
#     результат»; 2×262144 flash не испытан — F6, probe и есть испытание);
#     при успехе — канон 262144 тоже результат. Канон этой попытки
#     СБРАСЫВАЕТСЯ повторно перед честным probe;
#   - `use flash-multi` — probe-лестница 262144 → 229376 → 196608 → 163840 →
#     131072; каждая попытка в журнале logs/probe-flash-multi-2.log
#     («ступень X: …», вердикты); первая загрузившаяся ступень = канон
#     пары GFCTL_CTX_flash_multi_2 (SPEC §5, §9);
#   - `gfctl bench` — прогрев + 3 замера фикстуры 253c7ac5 (соло-запрос) на
#     2-сессионном каноне;
#   - `use flash-multi --sessions 4` — та же лестница на 4 сессии (канон
#     (flash-multi,2) не трогается); полный отказ лестницы → die с
#     подсказкой --context 65536 (OQ-2a, floor F6) → ручная попытка
#     4×65536 → bench. Отказ 4-сессионной лестницы — документируется, в
#     PASS-критерий не входит (сравнение агрегата — работа оркестратора по
#     числам result-файла);
#   - check-types на реальных шардах: python-харнес
#     tpl/python/gguf_type_check.py на ~/gufo-models/flash-next-ixs/*.gguf
#     (UD-IQ4_XS) → ожидаем КРАСНЫЙ (rc 1) на КАЖДОМ (регресс-тест правила
#     окон IX/FX, DoD этапа 2); на q4xl-шардах + MTP → зелёный (rc 0);
#     `gfctl models --check-types flash` на собранном сете → rc 0;
#   - статус после всех переключений; в конце `gfctl off` (дорога hfctl on).
#
# PREREQ:
#   - ЯВНЫЙ GO пользователя на ЭТО окно (окно этапа 2, FAEX flash-only);
#   - env: GF_ACC_HOST, GF_ACC_USER, GF_ACC_KEY;
#   - hfctl-прод машины ОСТАНОВЛЕН перед окном (`hfctl off` + НЕМЕДЛЕННЫЙ
#     `loginctl enable-linger` — user manager умирает ~10 с), после окна
#     вернуть: скрипт сам делает `gfctl off` → ты: `hfctl on` → healthy +
#     smoke (правило llm-lab: живой прод останавливается только внутри
#     приёмки этапа);
#   - веса окна FX на диске (пути в GOAL); иначе скрипт уйдёт в ERROR до
#     всякого трафика;
#   - паузы recreate (F10) встроены в gfctl (container_up: пауза + ретрай;
#     use сам ждёт health) — скрипт дополнительных пауз не ставит;
#   - худший случай probe: 5 × (94–180 с) + паузы ≈ 8–16 мин (F5) — окно в
#     tmux / долгой ssh-сессии.
#
# RUN:  GF_ACC_HOST=… GF_ACC_USER=… GF_ACC_KEY=… bash EXP-005-faex.sh
#   Весь вывод → EXP-005-faex.result.txt, финальная строка
#   «RESULT: PASS|FAIL|ERROR — …».
#
# PASS-критерий:
#   1) download flash: ровно 5 строк «SKIP:» (симлинки засчитаны, 0 трафика);
#   2) probe: роут «sessions 2», ctx = значению GFCTL_CTX_flash_multi_2 из
#      .env (первая загрузившаяся ступень), «SMOKE: OK»;
#   3) bench: «прогрев:», 3 строки «прогон N:», «медиана:» — числа записаны;
#   4) check-types: КРАСНЫЙ (rc 1) на КАЖДОМ ixs-шарде (регресс-тест DoD) И
#      зелёный (rc 0) на всех q4xl-шардах + MTP.
set -uo pipefail
: "${GF_ACC_HOST:?задай GF_ACC_HOST (приёмочная машина — см. hosts-профиль llm-lab)}"
: "${GF_ACC_USER:?задай GF_ACC_USER}"
: "${GF_ACC_KEY:?задай GF_ACC_KEY}"

cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
RES="EXP-005-faex.result.txt"
SSH="ssh -i $GF_ACC_KEY -o BatchMode=yes -o ConnectTimeout=10"

exec > >(tee "$RES") 2>&1

echo "== EXP-005: перенос дерева (без .git/.dev)"
$SSH "$GF_ACC_USER@$GF_ACC_HOST" 'rm -rf ~/gfctl-acc-src && mkdir -p ~/gfctl-acc-src' || {
  echo "RESULT: ERROR — ssh не прошёл"; exit 1; }
tar -C "$ROOT" --exclude=.git --exclude=.dev -cf - . | \
  $SSH "$GF_ACC_USER@$GF_ACC_HOST" 'tar -C ~/gfctl-acc-src -xf -' || {
  echo "RESULT: ERROR — ssh не прошёл"; exit 1; }

$SSH "$GF_ACC_USER@$GF_ACC_HOST" 'bash -s' <<'REMOTE' || {
  set -u
  export GFCTL_DIR="$HOME/gfctl-acc" GFCTL_MODELS="$HOME/gfctl-acc-models" GFCTL_YES=1
  GF="$HOME/gfctl-acc/gfctl"
  FLASH_DIR="$HOME/gfctl-acc-models/flash"

  echo "== gfctl install.sh — bootstrap"
  bash "$HOME/gfctl-acc-src/install.sh" || exit 44

  echo "== веса: хардлинки существующих файлов окна FX (0 байт трафика; симлинки не видны в контейнере через bind-маунт — инцидент EXP-005/2)"
  mkdir -p "$FLASH_DIR"
  n=0
  for f in "$HOME"/gufo-models/flash-next-q4xl/Qwen3.8-Flash-Next-UD-Q4_K_XL-*-of-00004.gguf; do
    [ -f "$f" ] || { echo "НЕТ шарда-источника: $f"; exit 45; }
    ln -f "$f" "$FLASH_DIR/$(basename "$f")"; n=$((n + 1))
  done
  [ "$n" = 4 ] || { echo "ожидали 4 шарда q4xl, найдено $n"; exit 45; }
  mtpsrc=$(find "$HOME/gufo-models/flash-next-ixs" -name 'mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf' 2>/dev/null | head -n1)
  [ -n "$mtpsrc" ] || { echo "НЕТ MTP-источника в ~/gufo-models/flash-next-ixs"; exit 45; }
  ln -f "$mtpsrc" "$FLASH_DIR/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf"
  ls -l "$FLASH_DIR"

  echo "== download flash: ожидаем SKIP×5"
  "$GF" models download flash --yes | tee /tmp/gf5-dl.log
  skips=$(grep -c '^SKIP:' /tmp/gf5-dl.log || true)
  echo "SKIP_COUNT=$skips"
  [ "$skips" = 5 ] || { echo "SKIP×5 не сошёлся ($skips)"; exit 46; }

  echo "== сброс канона пары flash (перед явной попыткой 262144)"
  echo "--- .env до:"; cat "$HOME/gfctl-acc/.env" 2>/dev/null || echo "(нет .env)"
  sed -i -e '/^GFCTL_CTX_flash_multi_/d' -e '/^GFCTL_CONTEXT=/d' "$HOME/gfctl-acc/.env" 2>/dev/null || true
  echo "--- .env после сброса:"; cat "$HOME/gfctl-acc/.env" 2>/dev/null || echo "(нет .env)"

  echo "== явная попытка 2×262144 (документирование цифр отказа/успеха верхней ступени)"
  "$GF" use flash-multi --context 262144; top_rc=$?
  echo "TOP_STEP_RC=$top_rc"
  if [ "$top_rc" != 0 ]; then
    echo "== admission-цифры 262144 (podman logs, хвост):"
    podman logs gufo 2>&1 | tail -40
  fi

  echo "== повторный сброс канона пары (явная попытка его записала)"
  sed -i -e '/^GFCTL_CTX_flash_multi_/d' -e '/^GFCTL_CONTEXT=/d' "$HOME/gfctl-acc/.env" 2>/dev/null || true

  echo "== probe-лестница: use flash-multi (262144→229376→196608→163840→131072)"
  "$GF" use flash-multi || exit 42

  echo "== журнал попыток probe:"
  cat "$HOME/gfctl-acc/logs/probe-flash-multi-2.log" 2>/dev/null || echo "(журнала нет)"
  echo "== канон пары:"
  grep '^GFCTL_CTX_flash_multi_2=' "$HOME/gfctl-acc/.env" || exit 47

  echo "== bench на 2-сессионном каноне (прогрев + 3 замера)"
  "$GF" bench || exit 48

  echo "== use flash-multi --sessions 4 (та же лестница на 4 сессии)"
  if "$GF" use flash-multi --sessions 4; then
    echo "== bench на 4-сессионном каноне"
    "$GF" bench || exit 49
  else
    echo "4-сессионная лестница отказала целиком — штатная ветка OQ-2a:"
    echo "ручная попытка floor 4×65536"
    "$GF" use flash-multi --sessions 4 --context 65536 || exit 49
    echo "== bench на 4×65536"
    "$GF" bench || exit 49
    "$GF" status
  fi

  echo "== check-types: unsloth UD-IQ4_XS (ixs) — ожидаем КРАСНЫЙ на КАЖДОМ"
  ixs_red=0; ixs_total=0
  for f in "$HOME"/gufo-models/flash-next-ixs/*.gguf; do
    [ -f "$f" ] || continue
    ixs_total=$((ixs_total + 1))
    python3 "$HOME/gfctl-acc/tpl/python/gguf_type_check.py" "$f" >/dev/null 2>&1
    rc=$?
    echo "IXS_RED_CHECK $(basename "$f") rc=$rc"
    [ "$rc" = 1 ] && ixs_red=$((ixs_red + 1))
  done
  echo "IXS_RED=$ixs_red IXS_TOTAL=$ixs_total"

  echo "== check-types: q4xl-шарды + MTP — ожидаем зелёный"
  q4_ok=0; q4_total=0
  for f in "$FLASH_DIR"/*.gguf; do
    q4_total=$((q4_total + 1))
    python3 "$HOME/gfctl-acc/tpl/python/gguf_type_check.py" "$f" >/dev/null 2>&1
    rc=$?
    echo "Q4XL_GREEN_CHECK $(basename "$f") rc=$rc"
    [ "$rc" = 0 ] && q4_ok=$((q4_ok + 1))
  done
  echo "Q4XL_GREEN=$q4_ok Q4XL_TOTAL=$q4_total"

  echo "== gfctl models --check-types flash (сет целиком — зелёный)"
  "$GF" models --check-types flash || exit 50

  echo "== статус"
  "$GF" status

  echo "== завершение окна: gfctl off (дорога hfctl on)"
  "$GF" off || true
  echo "--- EXP-005 remote done ---"
REMOTE
  rc=$?
  echo "RESULT: FAIL — remote-часть rc=$rc (45=источники весов, 46=SKIP×5, 42=use/probe, 47=канон, 48=bench2s, 49=bench4s, 50=check-types сет)"; exit 1; }

echo "== EXP-005: критерии PASS"
[ "$(grep -c '^SKIP:' "$RES")" -ge 5 ] || { echo "RESULT: FAIL — SKIP×5 не подтверждён"; exit 1; }
grep -q 'SMOKE: OK' "$RES" || { echo "RESULT: FAIL — смоук не прошёл"; exit 1; }
canon=$(sed -n 's/^GFCTL_CTX_flash_multi_2=\([0-9][0-9]*\)$/\1/p' "$RES" | head -n1)
[ -n "$canon" ] || { echo "RESULT: FAIL — канон пары не записан"; exit 1; }
grep -q "роут: mtp, sessions 2, ctx $canon" "$RES" \
  || { echo "RESULT: FAIL — роут sessions 2 ctx=$canon не подтверждён"; exit 1; }
grep -q '^прогрев: wall ' "$RES" && [ "$(grep -c '^прогон [123]: wall ' "$RES")" = 3 ] \
  && grep -q '^медиана: wall ' "$RES" \
  || { echo "RESULT: FAIL — bench-числа не записаны"; exit 1; }
ixs_red=$(sed -n 's/^IXS_RED=\([0-9][0-9]*\) .*$/\1/p' "$RES" | head -n1)
ixs_tot=$(sed -n 's/^IXS_RED=[0-9][0-9]* IXS_TOTAL=\([0-9][0-9]*\)$/\1/p' "$RES" | head -n1)
# Правило UD-IQ4_XS ловится на шардах С ffn-тензорами (00002/00003 КРАСНЫЕ);
# 00001 (0 тензоров) и 00004 (1 тензор) ffn не содержат — зелёные корректно.
[ -n "$ixs_red" ] && [ "$ixs_tot" -ge 1 ] 2>/dev/null && [ "$ixs_red" -ge 1 ] \
  || { echo "RESULT: FAIL — check-types ixs: ни одного КРАСНОГО (red=$ixs_red total=$ixs_tot)"; exit 1; }
q4_ok=$(sed -n 's/^Q4XL_GREEN=\([0-9][0-9]*\) .*$/\1/p' "$RES" | head -n1)
q4_tot=$(sed -n 's/^Q4XL_GREEN=[0-9][0-9]* Q4XL_TOTAL=\([0-9][0-9]*\)$/\1/p' "$RES" | head -n1)
[ -n "$q4_ok" ] && [ "$q4_ok" = "$q4_tot" ] \
  || { echo "RESULT: FAIL — check-types q4xl: есть красные (ok=$q4_ok total=$q4_tot)"; exit 1; }
echo "RESULT: PASS — flash-multi probe (канон пары $canon), bench-числа записаны, check-types КРАСНЫЙ на ixs / зелёный на q4xl; sessions-4 и цифры отказа верхней ступени — см. result-файл"
