#!/usr/bin/env bash
# EXP-004-multi-evo — 27b-multi (2×163840) на живой приёмочной машине (~60 GiB) + агрегат 2-пар на IQ4_XS.
#
# Внешний эксперимент (BLOCKED-EXTERNAL): исполняется ТОЛЬКО на приёмочной
# машине и ТОЛЬКО с явным GO пользователя. Ранний кусок этапа 2 (PLAN):
# профиль уже в таблице (этап 1), probe-лестницы ещё нет — проверяется
# честный «как есть»: фиксированный 2×163840 (проверенная точка F7 на
# Q4_K_XL; IQ4_XS легче на 3.9 GiB).
#
# GOAL:
#   - `gfctl use 27b-multi` на живой машине: роут «dflash2, sessions 2,
#     ctx 163840» + SMOKE: OK (гейт ≥56, recreate, health);
#   - живой status с кэшем и весами 2/2;
#   - агрегат 2-пар: 2 параллельных запроса ×≤600 completion-ток, 2 прогона
#     → tokens_total / wall; референс 29.5 tok/s снят на Q4_K_XL (F7) —
#     цифра IQ4_XS отсюда становится фактом AGENT-CONFIGS (±15% — ориентир
#     DoD этапа 2: ≥25);
#   - повторный use (идемпотентность recreate) — статус жив остаётся ok.
#
# PREREQ:
#   - GO пользователя; машина ~60 GiB; hfctl-прод ОСТАНОВЛЕН перед окном
#     (hfctl off + loginctl enable-linger), после окна — вернуть
#     (gfctl off → hfctl on → healthy + smoke);
#   - env: GF_ACC_HOST, GF_ACC_USER, GF_ACC_KEY; веса 27b уже на диске
#     (EXP-002: ~/gfctl-acc-models/27b) — скачки в этом EXP нет;
#   - python3 на машине (парсинг usage в API-ответах).
#
# RUN:  GF_ACC_HOST=… GF_ACC_USER=… GF_ACC_KEY=… bash EXP-004-multi-evo.sh
#   Весь вывод → EXP-004-multi-evo.result.txt, финальная строка
#   «RESULT: PASS|FAIL|ERROR — …».
#
# PASS-критерий:
#   1) строка «роут: dflash2, sessions 2, ctx 163840» присутствует;
#   2) «SMOKE: OK» присутствует;
#   3) PAIR_A и PAIR_B с agg>0 tok/s;
#   4) повторный use → статус «health: ok».
set -uo pipefail
: "${GF_ACC_HOST:?задай GF_ACC_HOST}"
: "${GF_ACC_USER:?задай GF_ACC_USER}"
: "${GF_ACC_KEY:?задай GF_ACC_KEY}"

cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
RES="EXP-004-multi-evo.result.txt"
SSH="ssh -i $GF_ACC_KEY -o BatchMode=yes -o ConnectTimeout=10"

exec > >(tee "$RES") 2>&1

echo "== EXP-004: перенос дерева (без .git/.dev)"
$SSH "$GF_ACC_USER@$GF_ACC_HOST" 'rm -rf ~/gfctl-acc-src && mkdir -p ~/gfctl-acc-src' || {
  echo "RESULT: ERROR — ssh не прошёл"; exit 1; }
tar -C "$ROOT" --exclude=.git --exclude=.dev -cf - . | \
  $SSH "$GF_ACC_USER@$GF_ACC_HOST" 'tar -C ~/gfctl-acc-src -xf -' || {
  echo "RESULT: ERROR — ssh не прошёл"; exit 1; }

$SSH "$GF_ACC_USER@$GF_ACC_HOST" 'bash -s' <<'REMOTE' || {
  set -u
  export GFCTL_DIR="$HOME/gfctl-acc" GFCTL_MODELS="$HOME/gfctl-acc-models" GFCTL_YES=1

  echo "== use 27b-multi"
  "$GFCTL_DIR/gfctl" use 27b-multi || exit 42

  echo "== status (живой)"
  "$GFCTL_DIR/gfctl" status

  echo "== пробный API-запрос (5 ток)"
  code=$(curl -s -o /tmp/gf4-probe.json -w '%{http_code}' \
    http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' \
    -d '{"model":"Qwen3.8-27B","messages":[{"role":"user","content":"скажи ок"}],"max_tokens":5}')
  echo "probe http=$code"; head -c 300 /tmp/gf4-probe.json; echo
  [ "$code" = "200" ] || exit 43

  run_pair () {
    local tag="$1" t0 t1
    echo "== пара $tag (2 запроса ×≤600 ток, параллельно)"
    t0=$(date +%s.%N)
    curl -s -o "/tmp/gf4-$tag-1.json" http://127.0.0.1:8080/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '{"model":"Qwen3.8-27B","messages":[{"role":"user","content":"Напиши реализацию merge sort на Python с подробными комментариями и примером использования"}],"max_tokens":600}' &
    curl -s -o "/tmp/gf4-$tag-2.json" http://127.0.0.1:8080/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '{"model":"Qwen3.8-27B","messages":[{"role":"user","content":"Напиши реализацию quick sort на Python с подробными комментариями и разбором сложности"}],"max_tokens":600}' &
    wait
    t1=$(date +%s.%N)
    python3 - "$t0" "$t1" "$tag" <<'PY'
import json, sys
t0, t1, tag = float(sys.argv[1]), float(sys.argv[2]), sys.argv[3]
tot = 0
for i in (1, 2):
    with open(f"/tmp/gf4-{tag}-{i}.json") as f:
        d = json.load(f)
    n = d["usage"]["completion_tokens"]
    tot += n
    print(f"  пара {tag} запрос{i}: completion_tokens={n}")
wall = t1 - t0
print(f"PAIR_{tag}: tokens_total={tot} wall={wall:.1f}s agg={tot / wall:.1f} tok/s")
PY
  }
  run_pair A
  run_pair B

  echo "== повторный use (идемпотентность recreate)"
  "$GFCTL_DIR/gfctl" use 27b-multi >/dev/null || exit 44
  "$GFCTL_DIR/gfctl" status | head -1
  echo "--- EXP-004 remote done ---"
REMOTE
  rc=$?
  echo "RESULT: FAIL — remote-часть rc=$rc (42=use, 43=probe, 44=re-use)"; exit 1; }

echo "== EXP-004: критерии PASS"
grep -q "роут: dflash2, sessions 2, ctx 163840" "$RES" || { echo "RESULT: FAIL — роут 2×163840 не найден"; exit 1; }
grep -q "SMOKE: OK" "$RES" || { echo "RESULT: FAIL — смоук не прошёл"; exit 1; }
grep -q "^PAIR_A:.*agg=[0-9]" "$RES" && grep -q "^PAIR_B:.*agg=[0-9]" "$RES" || { echo "RESULT: FAIL — пары не посчитаны"; exit 1; }
grep -q "health: ok" "$RES" || { echo "RESULT: FAIL — статус после re-use не ok"; exit 1; }
echo "RESULT: PASS — 27b-multi (2×163840) живой: use/роут/смок, 2 прогона пар, re-use идемпотентен"
