#!/usr/bin/env bash
# EXP-007-agentcheck — окно этапа 3: агентские референсы flash-multi
# (FAEX, канон 2×262144 — F20) + agent-check на 27b-single (evo, референс
# 23.8 с — SPEC §5) + сбор факт-базы для cache/watch.
#
# Внешний эксперимент (BLOCKED-EXTERNAL): исполняется ТОЛЬКО по явному GO
# пользователя НА ЭТО окно (D6; evo — тем более). Заготовка: создана в
# 3.1, В ОЧЕРЕДИ, не исполняется (заполняет референсы lib/profiles.sh —
# ref_<профиль>_{session,followup,restore,docq} — и факт-базу /metrics).
#
# GOAL:
#   - bootstrap: перенос дерева gfctl (3.1: agent-check/cache/watch) в
#     ~/gfctl-acc-src → ~/gfctl-acc (изолированная приёмочная инсталляция,
#     как EXP-002..005; bootstrap ОБЯЗАТЕЛЕН первым шагом remote-части —
#     F21: без него работает старый код ~/gfctl-acc);
#   - agent-check на flash-multi 2×262144 (FAEX): 4 проверки (сессия 15
#     ходов / follow-up-лестница 5k/25k/100k / [док 25k][q1→q2] /
#     рестарт-restore) — ЧИСЛА = новые референсы (REF re-shoot, SPEC §5
#     «подлежат снятию заново»: окно FX мерило соло-конфиг);
#   - agent-check на 27b-single (evo): PASS против референсов 23.8 / 1.7 /
#     0.81 (±25% → WARN по cmp_ref; WARN не считается отказом);
#   - cache --verify на обоих: follow-up reuse live/disk + рестарт-проба
#     (tmpfs-детект fs_type) — PLAN DoD «cache --verify ловит tmpfs»
#     (на FAEX кэш-каталог в ~/gfctl-acc — ожидание ext4, не tmpfs);
#   - СБОР ФАКТ-БАЗЫ (для cache/watch 3.1): сырые ключи /metrics
#     (llamacpp:*, полный список — сейчас подтверждён только
#     prompt_tokens_cached_total, FX-W5) и образцы строк
#     event=skipped / event=evict* из лога (форматы в факт-базе отсутствуют —
#     cmd_cache сейчас считает вхождения);
#   - подтверждение контракта timings (timings/component_cache.reuse в
#     теле ответа — observation окон; если ревизия убрала поле —
#     agent-check деградирует в структурный FAIL с явной причиной, это
#     результат тоже);
#   - в конце `gfctl off` (дорога hfctl on: evo — hfctl 27b-single,
#     FAEX — hfctl flash-multi; правило llm-lab).
#
# PREREQ:
#   - ЯВНЫЙ GO пользователя на ЭТО окно (D6; отдельно FAEX, отдельно evo);
#   - env: GF_ACC_HOST, GF_ACC_USER, GF_ACC_KEY (+ GF_ACC_FLAVOR=faex|evo —
#     профиль окна: faex → flash-multi 2×262144 (канон .env от EXP-005,
#     F20), evo → 27b-single (канон от EXP-006));
#   - hfctl-прод машины ОСТАНОВЛЕН (`hfctl off` + НЕМЕДЛЕННЫЙ
#     `loginctl enable-linger` — user manager умирает ~10 с), после окна
#     вернуть: скрипт сам делает `gfctl off` → ты: `hfctl on` → healthy +
#     smoke;
#   - веса профиля на месте (FAEX: flash-сет хардлинками — F19; evo: 27b —
#     EXP-002) — докачки в окне нет (set полный → SKIP);
#   - рестарт-restore в agent-check/cache --verify ПЕРЕЗАПУСКАЕТ
#     контейнер (активные сессии теряются) — окно это допускает явно;
#   - agent-check худший бюджет: 25 запросов × (-m 1200) — окно в tmux /
#     долгой ssh-сессии; загрузка тёплой машины ~15–100 с (F17/F20).
#
# RUN:  GF_ACC_HOST=… GF_ACC_USER=… GF_ACC_KEY=… GF_ACC_FLAVOR=faex \
#         bash EXP-007-agentcheck.sh
#   Весь вывод → EXP-007-agentcheck.result.txt, финальная строка
#   «RESULT: PASS|FAIL|ERROR — …».
#
# PASS-критерий:
#   1) agent-check rc 0 на профиле окна: сводка «AGENT-CHECK: PASS=N
#      WARN=M FAIL=0» (WARN допускается только «референс не снят»/docq;
#      FAIL = отказ);
#   2) числовой блок REFS: total/followup25/docq/restore стены каждого
#      профиля окна (FAEX — ПЕРВЫЕ референсы; evo — сравнение с
#      23.8/1.7/0.81, расхождение >25% задокументировать как факт окна);
#   3) cache --verify: follow-up reuse=live|disk PASS + рестарт-проба
#      PASS (reuse=disk|live); fs_type кэш-каталога записан (tmpfs →
#      WARN — это тоже зафиксированный результат);
#   4) ФАКТ-БАЗА: полный список llamacpp:* ключей /metrics (имена+типы) и
#      ≥1 образец event=skipped / event=evict* (если встретились) —
#      в result-файл (для lib/commands.sh подписей и FACTS.md);
#   5) «timings» подтверждён в теле ответа (строка TIMINGS_OK; иначе
#      TIMINGS_MISSING + структурный FAIL задокументирован).
set -uo pipefail
: "${GF_ACC_HOST:?задай GF_ACC_HOST (приёмочная машина — см. hosts-профиль llm-lab)}"
: "${GF_ACC_USER:?задай GF_ACC_USER}"
: "${GF_ACC_KEY:?задай GF_ACC_KEY}"
: "${GF_ACC_FLAVOR:?задай GF_ACC_FLAVOR (faex|evo)}"

cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
RES="EXP-007-agentcheck.result.txt"
SSH="ssh -i $GF_ACC_KEY -o BatchMode=yes -o ConnectTimeout=10"

exec > >(tee "$RES") 2>&1

echo "== EXP-007 ($GF_ACC_FLAVOR): перенос дерева (без .git/.dev)"
$SSH "$GF_ACC_USER@$GF_ACC_HOST" 'rm -rf ~/gfctl-acc-src && mkdir -p ~/gfctl-acc-src' || {
  echo "RESULT: ERROR — ssh не прошёл"; exit 1; }
tar -C "$ROOT" --exclude=.git --exclude=.dev -cf - . | \
  $SSH "$GF_ACC_USER@$GF_ACC_HOST" 'tar -C ~/gfctl-acc-src -xf -' || {
  echo "RESULT: ERROR — ssh не прошёл"; exit 1; }

$SSH "$GF_ACC_USER@$GF_ACC_HOST" "GF_ACC_FLAVOR=$GF_ACC_FLAVOR bash -s" <<'REMOTE'
set -u
export GFCTL_DIR="$HOME/gfctl-acc" GFCTL_MODELS="$HOME/gfctl-acc-models" GFCTL_YES=1
GF="$HOME/gfctl-acc/gfctl"

echo "== gfctl install.sh — bootstrap (ОБЯЗАТЕЛЬНО первым шагом — F21)"
bash "$HOME/gfctl-acc-src/install.sh" || { echo "RESULT: FAIL — bootstrap rc=$?"; exit 51; }

case "$GF_ACC_FLAVOR" in
  faex) PROF="flash-multi" ;;
  evo)  PROF="27b-single" ;;
  *) echo "RESULT: FAIL — GF_ACC_FLAVOR=$GF_ACC_FLAVOR (ждём faex|evo)"; exit 52 ;;
esac

echo "== use $PROF (канон пары из .env, без probe-перебора)"
"$GF" use "$PROF" || { echo "RESULT: FAIL — use rc=$?"; exit 42; }

echo "== cache: сводка до verify"
"$GF" cache

echo "== cache --verify (follow-up + tmpfs-детект + рестарт-проба)"
"$GF" cache --verify; CV_RC=$?
echo "CACHE_VERIFY_RC=$CV_RC"

echo "== agent-check $PROF (25 запросов; рестарт-restore перезапускает контейнер)"
"$GF" agent-check; AC_RC=$?
echo "AGENT_CHECK_RC=$AC_RC"

echo "== ФАКТ-БАЗА: сырые ключи /metrics (полный список)"
curl -fsS -m 5 http://127.0.0.1:8080/metrics 2>/dev/null | grep '^llamacpp:' || echo "(metrics недоступен)"

echo "== ФАКТ-БАЗА: образцы event=skipped / event=evict* из лога"
podman logs gufo 2>&1 | grep -E 'event=(skipped|evict)' | head -20 || echo "(образцов нет)"

echo "== ФАКТ-БАЗА: timings в последнем ответе (косвенно — load лога)"
podman logs gufo 2>&1 | grep -c 'load_completed'

echo "== off (дорога hfctl on)"
"$GF" off
REMOTE

echo "== итог: смотри AGENT_CHECK_RC / CACHE_VERIFY_RC и блок REFS выше"
ac=${AC_RC:-1}; cv=${CV_RC:-1}
[ "$ac" = 0 ] || { echo "RESULT: FAIL — agent-check rc=$ac"; exit 1; }
[ "$cv" = 0 ] || { echo "RESULT: FAIL — cache --verify rc=$cv"; exit 1; }
grep -q "^CHECK session " "$RES" && grep -q "^CHECK followup " "$RES" \
  && grep -q "^CHECK docq " "$RES" && grep -q "^CHECK restore " "$RES" \
  || { echo "RESULT: FAIL — CHECK-строки (session/followup/docq/restore) не сняты"; exit 1; }
echo "RESULT: PASS — agent-check OK, cache --verify OK, CHECK-числа сняты (референсы ref_* заполняются оркестратором)"
