#!/usr/bin/env bash
# EXP-015-hfctl-off-gfctl-on — сценарная приёмка И2 (этап 5.1): «hfctl off →
#   gfctl on» + slirp-ассерты скоупа CONTAINERS_CONF (этап 5.1) на живой
#   машине (FAEX или evo). PASS = gfctl-стек здоров под slirp4netns-скоупом
#   (pasta не растёт от gfctl-операций, graphRoot общий, «kill network
#   process» = 0), обратный hfctl on здоров (бэкенды сосуществуют).
#
# STATUS: created (2026-11-21, этап 5.1). НЕ ЗАПУЩЕН — окно этапа 5 по D6:
#   отдельный GO (F23 — самостоятельный вызов, не подмес в чужие прогоны;
#   без параллельных прогонов на одной машине).
#
# PREREQUISITES:
#   - машина с обоими клонами: ~/gfctl и ~/hfctl (И3/F21: bootstrap = git
#     pull обоих клонов; tar/cp из воркспейса запрещены);
#   - веса gfctl на месте (.data/models), hfctl-прод работает перед стартом;
#   - sudo без пароля или интерактивный запуск;
#   - в том же окне (не этот подэтап) закрываются EXP-010/011/012 и
#     ребут/рестарт-приёмы fix-r2 — этот скрипт проектируется отдельным
#     вызовом, чтобы не подмешивать чужие прогоны.
#
# RUN (на целевой машине):
#   bash EXP-015-hfctl-off-gfctl-on.sh
# Весь вывод → EXP-015-hfctl-off-gfctl-on.result.txt (рядом), финал
# RESULT: PASS|FAIL|ERROR — …
#
# WHAT COUNTS AS PASS:
#   (а) pgrep: slirp4netns-процесс gfctl-контейнера ЕСТЬ; pasta-каунт НЕ
#       растёт от gfctl-операций (базовая линия до, факт после);
#   (б) recreate/off-циклы gfctl БЕЗ «kill network process: permission
#       denied» в выводе и в journalctl (AppArmor/pasta-класс снят скоупом);
#   (в) graphRoot с env gfctl и без — ИДЕНТИЧЕН (podman info, чтение;
#       хранилище общее с hfctl — образы/контейнеры видимы из обоих);
#   (г) повторный hfctl on здоров (бэкенды сосуществуют — EXP-012/013
#       llm-lab-механика на живой машине); linger восстановлен (F11).
#
# ПРОЛОГ ПЕРЕЛОГИНА (Round 2 п.4, И2): `gfctl on` preflight не зовёт
#   (on/up/_watchdog — установленный стек), но если по плану окна перед этим
#   прогоном выполнялся use/install нового кода и он упал с rc 42 («группы
#   применятся только после перезахода») — перезайти в сессию и повторить
#   шаг: перезаход = ПЛАНОВАЯ часть сценария (И2), не ручная мутация.

set -uo pipefail
RES="$(cd "$(dirname "$0")" && pwd)/EXP-015-hfctl-off-gfctl-on.result.txt"
exec >"$RES" 2>&1
GF="$HOME/gfctl"; HF="$HOME/hfctl"
GF_PORT=8080; HF_PORT=11435
CONF="$GF/.gfctl-containers.conf"
say()  { echo "### $*"; }
fail() { echo "### FAIL: $*"; echo "RESULT: FAIL — $*"; exit 1; }
rd()   { echo "--- $* (чтение)"; }
pasta_ct()   { pgrep -c pasta 2>/dev/null || echo 0; }
slirp_ct()   { pgrep -c slirp4netns 2>/dev/null || echo 0; }

say "EXP-015 start $(date '+%F %T') на $(hostname)"
# ── bootstrap (F21/И3) ───────────────────────────────────────────────────────
for d in "$GF" "$HF"; do
  [ -d "$d/.git" ] || fail "нет клона $d (деплой = git clone из GitHub, И3)"
  git -C "$d" pull --ff-only || fail "git pull $d"
  say "$(basename "$d") commit: $(git -C "$d" rev-parse --short HEAD)"
done

# ── шаг 0: базовые линии (чтения) ────────────────────────────────────────────
PASTA0=$(pasta_ct); SLIRP0=$(slirp_ct)
say "базовая линия: pasta=$PASTA0 slirp=$SLIRP0 (hfctl-прод под pasta)"
[ -f "$CONF" ] || fail "нет $CONF — скоуп-файл не доставлен bootstrap'ом (запусти ./gfctl once перед EXP)"
rd "graphRoot без env (глобальный) и с env gfctl (скоуп) — ждём ИДЕНТИЧНЫЕ (в)"
GR_NOENV=$(podman info --format '{{.store.graphRoot}}' 2>/dev/null)
GR_ENV=$(CONTAINERS_CONF="$CONF" podman info --format '{{.store.graphRoot}}' 2>/dev/null)
echo "graphRoot без env: $GR_NOENV"; echo "graphRoot с env:   $GR_ENV"
[ -n "$GR_NOENV" ] && [ "$GR_NOENV" = "$GR_ENV" ] || fail "graphRoot разошёлся ($GR_NOENV ≠ $GR_ENV) — скоуп создал второе хранилище"

# ── шаг 1: hfctl off ─────────────────────────────────────────────────────────
say "шаг 1: hfctl off"
bash "$HF/hfctl" off || fail "hfctl off rc≠0"
rd "linger после hfctl off (F11: ждём no — вернём hfctl on в шаге 4)"
loginctl show-user "$(id -un)" -p Linger

# ── шаг 2: gfctl on ──────────────────────────────────────────────────────────
say "шаг 2: gfctl on (диспетчер экспортирует CONTAINERS_CONF сам)"
OUT=$(bash "$GF/gfctl" on 2>&1) || fail "gfctl on rc≠0: $OUT"
say "$OUT"
grep -qi 'kill network process' <<<"$OUT" && fail "(б) «kill network process» в gfctl on"

say "шаг 3: wait-health gfctl (до 300 с)"
for i in $(seq 1 60); do
  curl -fsS "http://127.0.0.1:$GF_PORT/ready" >/dev/null 2>&1 && break
  sleep 5
done
curl -fsS "http://127.0.0.1:$GF_PORT/ready" >/dev/null || fail "gfctl /ready не ответил за 300 с"
SMOKE=$(bash "$GF/gfctl" smoke) || fail "gfctl smoke отказал"
grep -q 'SMOKE: OK' <<<"$SMOKE" || fail "smoke без SMOKE: OK"

# ── шаг 4: slirp-ассерты (а) ─────────────────────────────────────────────────
PASTA1=$(pasta_ct); SLIRP1=$(slirp_ct)
say "(а) pgrep после gfctl on: pasta=$PASTA1 slirp=$SLIRP1 (было pasta=$PASTA0 slirp=$SLIRP0)"
[ "$SLIRP1" -gt 0 ] || fail "(а) slirp4netns-процесса нет — gfctl-контейнер НЕ под скоупом"
[ "$PASTA1" -le "$PASTA0" ] || fail "(а) pasta-каунт вырос ($PASTA0 → $PASTA1) — gfctl-операция пошла в pasta"
rd "(б) recreate-цикл: use поверх работающего (recreate = rm+run) — снова без «kill network process»"
PROF=$(grep '^GFCTL_PROFILE=' "$GF/.env" 2>/dev/null | cut -d= -f2)
[ -n "$PROF" ] || fail "в $GF/.env нет GFCTL_PROFILE — канон не записан (use не выполнялся)"
OUT2=$(bash "$GF/gfctl" use "$PROF" --no-probe 2>&1) \
  || fail "recreate-use rc≠0: $OUT2"
grep -qi 'kill network process' <<<"$OUT2" && fail "(б) «kill network process» в recreate"
grep -qi 'already in use' <<<"$OUT2" && fail "(б) «already in use» в recreate (orphan-класс жив — дефект в бэклог)"
rd "(б) journalctl пользователя за окно прогона"
journalctl --user --since "10 min ago" 2>/dev/null | grep -ci 'kill network process' \
  || echo "  0 вхождений «kill network process» (чисто)"
rd "(в) graphRoot повторно (после recreate) — идентичность хранилища"
GR_ENV2=$(CONTAINERS_CONF="$CONF" podman info --format '{{.store.graphRoot}}' 2>/dev/null)
[ "$GR_ENV2" = "$GR_NOENV" ] || fail "(в) graphRoot разошёлся после recreate ($GR_NOENV ≠ $GR_ENV2)"

# ── шаг 5: обратный hfctl on (г) ─────────────────────────────────────────────
say "шаг 5 (г): gfctl off → hfctl on (бэкенды сосуществуют)"
bash "$GF/gfctl" off || fail "gfctl off rc≠0"
OUT3=$(bash "$HF/hfctl" on 2>&1) || fail "hfctl on rc≠0: $OUT3"
grep -qi 'already in use' <<<"$OUT3" && fail "(г) «already in use» в hfctl on"
for i in $(seq 1 60); do
  curl -fsS "http://127.0.0.1:$HF_PORT/ready" >/dev/null 2>&1 && break
  sleep 5
done
curl -fsS "http://127.0.0.1:$HF_PORT/ready" >/dev/null || fail "(г) hfctl /ready не ответил за 300 с"
LING=$(loginctl show-user "$(id -un)" -p Linger | cut -d= -f2)
[ "$LING" = "yes" ] || fail "linger=$LING после hfctl on (F11 нарушен)"
PASTA2=$(pasta_ct)
say "финал: hfctl-прод вернулся под pasta (pasta=$PASTA2 > 0 — норма), linger=yes"

echo "RESULT: PASS — hfctl off → gfctl on: slirp-скоуп жив (slirp>0, pasta не растёт, graphRoot общий), «kill network process»=0, recreate чист, hfctl on здоров, linger=yes"
