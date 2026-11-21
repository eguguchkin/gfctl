#!/usr/bin/env bash
# EXP-014-gfctl-off-hfctl-on — сценарная приёмка И2 (этап 5.1): «gfctl off →
#   hfctl on» на живой машине (FAEX или evo, где gfctl-стек поднят/может быть
#   поднят). PASS = hfctl-прод вернулся здоровым без «already in use» и с
#   восстановленным linger (F11).
#
# STATUS: created (2026-11-21, этап 5.1). НЕ ЗАПУЩЕН — окно этапа 5 по D6:
#   запуск ТОЛЬКО с явного GO пользователя (два отдельных GO: FAEX и evo;
#   F23 — без параллельных прогонов на одной машине).
#
# PREREQUISITES:
#   - машина с обоими клонами: ~/gfctl и ~/hfctl (И3/F21: удалённая часть
#     начинается с BOOTSTRAP — git pull обоих клонов из GitHub; tar/cp из
#     воркспейса запрещены — их след в логе = FAIL);
#   - sudo без пароля или интерактивный запуск (loginctl-linger под sudo —
#     поведение обвязок);
#   - gfctl-стек в состоянии «может быть остановлен» (данные/веса целы);
#   - сеть до registry (hfctl on тянет образ при отсутствии).
#
# RUN (на целевой машине):
#   bash EXP-014-gfctl-off-hfctl-on.sh
# Весь вывод → EXP-014-gfctl-off-hfctl-on.result.txt (рядом), финал
# RESULT: PASS|FAIL|ERROR — …
#
# WHAT COUNTS AS PASS:
#   1) gfctl off: маркер .gfctl-stopped появился, юниты сняты, linger=no,
#      контейнер gufo отсутствует (podman ps -a);
#   2) диагностические ЧТЕНИЯ между шагами: podman ps -a, pgrep pasta/slirp,
#      loginctl show-user Linger — только чтение (И2);
#   3) hfctl on: hfctl-прод здоров (curl /ready + health-маркер), в выводе
#      нет «already in use» и нет «kill network process»;
#   4) linger hfctl-юзера восстановлен = yes (F11: hfctl off снимает linger;
#      on обязан вернуть — иначе юзер-менеджер гаснет с ssh-якорем).
#
# ПРОЛОГ ПЕРЕЛОГИНА (Round 2 п.4, И2): если в сценарии встретится use/install
#   нового кода gfctl, он МОЖЕТ завершиться rc 42 (группы render,video после
#   обновления кода) — тогда: перезайти в сессию, повторить шаг; перезаход —
#   ПЛАНОВАЯ часть сценария, не внеплановая мутация. Сам `gfctl off` preflight
#   не зовёт (preflight — install/use; on/up/_watchdog работают на
#   установленном стеке — прецедент hfctl 13.2), поэтому 42 здесь не ждём,
#   но сценарий обязан зафиксировать план на случай появления.

set -uo pipefail
RES="$(cd "$(dirname "$0")" && pwd)/EXP-014-gfctl-off-hfctl-on.result.txt"
exec >"$RES" 2>&1
GF="$HOME/gfctl"; HF="$HOME/hfctl"
GUFO_PORT=8080; HF_PORT=11435
say()  { echo "### $*"; }
fail() { echo "### FAIL: $*"; echo "RESULT: FAIL — $*"; exit 1; }
rd()   { echo "--- $* (чтение)"; }

say "EXP-014 start $(date '+%F %T') на $(hostname)"
# ── bootstrap (F21/И3): pull обоих клонов из GitHub ──────────────────────────
for d in "$GF" "$HF"; do
  [ -d "$d/.git" ] || fail "нет клона $d (деплой = git clone из GitHub, И3)"
  git -C "$d" pull --ff-only || fail "git pull $d"
  say "$(basename "$d") commit: $(git -C "$d" rev-parse --short HEAD)"
done

# ── шаг 1: gfctl off (если стек поднят — off идемпотентен) ───────────────────
say "шаг 1: gfctl off"
bash "$GF/gfctl" off || fail "gfctl off rc≠0"
[ -f "$GF/.gfctl-stopped" ] || fail "маркер .gfctl-stopped не появился"
[ ! -e "$HOME/.config/systemd/user/gfctl-serve.service" ] || fail "serve-юнит не снят off'ом"

rd "podman ps -a (gufo должен исчезнуть; контейнеры hfctl не тронуты)"
podman ps -a --format '{{.Names}} {{.Status}}'
podman ps -a --format '{{.Names}}' | grep -qx gufo && fail "контейнер gufo жив после gfctl off"
rd "pgrep pasta/slirp (гласс-класс teardown — базовая линия перед hfctl on)"
echo "pasta=$(pgrep -c pasta 2>/dev/null || echo 0) slirp=$(pgrep -c slirp4netns 2>/dev/null || echo 0)"
rd "linger gfctl-юзера после off (ждём no — F11)"
loginctl show-user "$(id -un)" -p Linger

# ── шаг 2: hfctl on ──────────────────────────────────────────────────────────
say "шаг 2: hfctl on (прод вернётся)"
OUT=$(bash "$HF/hfctl" on 2>&1) || fail "hfctl on rc≠0: $OUT"
grep -qi 'already in use' <<<"$OUT" && fail "«already in use» в hfctl on"
grep -qi 'kill network process' <<<"$OUT" && fail "AppArmor-класс «kill network process» в hfctl on"
say "$OUT"

say "шаг 3: wait-health hfctl (до 300 с, только curl)"
for i in $(seq 1 60); do
  curl -fsS "http://127.0.0.1:$HF_PORT/ready" >/dev/null 2>&1 && break
  sleep 5
done
curl -fsS "http://127.0.0.1:$HF_PORT/ready" >/dev/null || fail "hfctl /ready не ответил за 300 с"
rd "podman ps (hfctl-контейнер running)"
podman ps --format '{{.Names}} {{.Status}}'

say "шаг 4: linger восстановлен (F11)"
LING=$(loginctl show-user "$(id -un)" -p Linger | cut -d= -f2)
[ "$LING" = "yes" ] || fail "linger=$LING после hfctl on (F11 нарушен — юзер-менеджер погаснет с сессией)"

echo "RESULT: PASS — gfctl off → hfctl on: hfctl-прод здоров, «already in use» нет, linger=yes"
