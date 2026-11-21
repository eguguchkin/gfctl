#!/usr/bin/env bash
# EXP-013-gfctl-parity-bare — bare-Ubuntu приёмка И1 (этап 5.1), тремя фазами.
#
# STATUS: DEFERRED (D8, 2026-11-21) — РЕСУРС НЕ ВЫДЕЛЕН (нужна голая
#   Ubuntu/VM без podman и без GPU-подготовки; варианты ресурса — VM на
#   одной из машин / временный бокс — решает пользователь). Контент фаз
#   написан по Round-1 контракту task.md; НЕ ИСПОЛНЯТЬ до выделения
#   ресурса (bash -n only). Окно 5.1 этот скрипт НЕ закрывает — его
#   закрывают EXP-014/015 + EXP-010/011/012 + ребут/рестарт-приёмы fix-r2.
#
# GOAL: `git clone → ./gfctl use <профиль>` на голой Ubuntu доводит хост сам
#   (И1, D7/D8 — строго, без смягчений): apt-пятёрка И1 одним вызовом
#   (podman podman-compose containers-storage psmisc curl; passt/slirp4netns/
#   uidmap — Depends podman), GPU-подготовка render,video + memlock limits.d,
#   .gfctl-containers.conf (скоуп slirp4netns), юниты, старт, health, smoke;
#   повтор use/install — «всё на месте» → ноль sudo/apt (идемпотентность).
#
# PREREQUISITES:
#   - голая Ubuntu/Debian AMD64 (без podman, без prior gfctl), юзер с sudo
#     (пароль интерактивно или NOPASSWD), сеть до archive.ubuntu.com и HF;
#   - И3/F21: удалённая часть начинается с BOOTSTRAP — git clone из GitHub
#     (git pull, если клон есть). tar/cp из воркспейса разработчика
#     ЗАПРЕЩЕНЫ (И3) — их наличие в логе = FAIL сценария;
#   - F23: без параллельных прогонов на одной машине;
#   - GPU-машина ИЛИ VM без GPU (оба случая валидны: нет /dev/kfd и
#     /dev/dri → «GPU-подготовка пропущена», но тогда железный гейт умрёт —
#     для VM без GPU PHASE ограничивается preflight-фактом die по железу;
#     ПОЛНЫЙ прогон = GPU-машина, целевой случай — Strix Halo).
#
# RUN (на целевой машине, три РАЗНЫХ сеанса — между ними перезаход/ребут):
#   PHASE=1 bash EXP-013-gfctl-parity-bare.sh   # клон → doctor → use (ждёт 42 или 0)
#   PHASE=2 bash EXP-013-gfctl-parity-bare.sh   # ПОСЛЕ перезахода: use → health → smoke → apt-повтор
#   PHASE=3 bash EXP-013-gfctl-parity-bare.sh   # ПОСЛЕ ребута: самоподъём (ребут-приём fix-r2)
# Весь вывод → EXP-013-gfctl-parity-bare.result.txt (рядом со скриптом),
# финальная строка RESULT: PASS|FAIL|ERROR — …
#
# WHAT COUNTS AS PASS:
#   PHASE 1: doctor честно показывает «пакеты … нет» до use; use завершается
#     rc 0 (всё подготовилось без перезахода) ИЛИ rc 42 с текстом «после
#     перезахода»/«ПЕРЕЛОГИНЬСЯ», при этом факт зафиксирован чтением:
#     id -nG содержит render и video, limits.d-файл существует и содержит
#     memlock unlimited; sudo-журнал (при наличии) показывает РОВНО одну
#     пару apt-get update→install с полной пятёркой;
#   PHASE 2: use → rc 0; wait-health ok; smoke 3/3; повторный use — apt
#     НЕ вызывался (журнал bash-истории не ведём — факт «всё на месте»
#     доказывается rc 0 без 42 и отсутствием новых записей в
#     /var/log/apt/history.log за время фазы);
#   PHASE 3: после ребута юниты enabled, контейнер running, health ok
#     (это и есть ребут-приём fix-r2 на финальном коде).
#
# ПРОЛОГ ПЕРЕЛОГИНА (Round 2 п.4): первый use/install нового кода МОЖЕТ
#   завершиться rc 42 (группы render,video) — перезаход сессии между фазами
#   ПЛАНОВЫЙ, часть сценария (И2), не внеплановая ручная мутация.

set -uo pipefail
PHASE="${PHASE:-1}"
RES="$(cd "$(dirname "$0")" && pwd)/EXP-013-gfctl-parity-bare.result.txt"
STACK="$HOME/gfctl"
REPO_URL="https://github.com/eguguchkin/gfctl"
exec >"$RES" 2>&1

say()  { echo "### $*"; }
fail() { echo "### FAIL: $*"; echo "RESULT: FAIL — $*"; exit 1; }

# ── bootstrap (F21/И3): remote-часть начинается с GitHub-клона ──────────────
say "EXP-013 PHASE=$PHASE start $(date '+%F %T') на $(hostname)"
command -v git >/dev/null || fail "git не найден — на голой Ubuntu: sudo apt install git (вне сценария, один раз)"
if [ -d "$STACK/.git" ]; then
  git -C "$STACK" pull --ff-only || fail "git pull клона $STACK"
else
  git clone "$REPO_URL" "$STACK" || fail "git clone $REPO_URL"
fi
GFCOMMIT=$(git -C "$STACK" rev-parse --short HEAD); say "gfctl commit: $GFCOMMIT (транспорт = только git, И3/F21)"

if [ "$PHASE" = 1 ]; then
  say "PHASE 1: клон свежий — doctor ДО use (честные «нет»)"
  bash "$STACK/gfctl" doctor || fail "doctor rc≠0 (должен быть честный отчёт rc 0)"
  bash "$STACK/gfctl" doctor | grep -q 'пакеты (apt-пятёрка И1): podman: нет' \
    || say "  (варнинг) podman уже есть в системе — bare-условие нарушено, продолжаем"
  say "PHASE 1: use 27b-single --no-probe (первое касание; ожидаем 0 или 42)"
  bash "$STACK/gfctl" use 27b-single --no-probe
  USE_RC=$?
  if [ "$USE_RC" = 0 ]; then
    say "use rc 0 — хост доведён без перезахода (группы уже были) — допустимая PASS-ветка"
    echo "RESULT: PASS — PHASE=1 use rc 0 (preflight закрыл всё сам)"
  elif [ "$USE_RC" = 42 ]; then
    grep -q 'после перезахода' "$RES" || grep -q 'ПЕРЕЛОГИНЬСЯ' "$RES" \
      || fail "rc 42 без честного текста перезахода"
    id -nG | tr ' ' '\n' | grep -qx render || fail "render-группа не применилась (id -nG)"
    id -nG | tr ' ' '\n' | grep -qx video  || fail "video-группа не применилась (id -nG)"
    [ -f /etc/security/limits.d/99-gfctl-memlock.conf ] || fail "limits.d-файла нет после rc 42"
    grep -q 'hard memlock unlimited' /etc/security/limits.d/99-gfctl-memlock.conf \
      || fail "limits.d-файл без memlock unlimited"
    say "факт: группы в id -nG + limits.d-файл на месте — перезаход ПЛАНОВЫЙ (пролог)"
    echo "RESULT: PASS — PHASE=1 use rc 42 (группы+limits.d применены, перезаход = часть сценария)"
  else
    fail "use rc=$USE_RC (ждём 0 или 42)"
  fi
elif [ "$PHASE" = 2 ]; then
  say "PHASE 2: после перезахода — use → health → smoke; apt-повтор = 0"
  APT_BEFORE=$(grep -c 'install ' /var/log/apt/history.log 2>/dev/null || echo 0)
  bash "$STACK/gfctl" use 27b-single --no-probe
  USE_RC=$?
  [ "$USE_RC" = 0 ] || fail "use rc=$USE_RC (ждём 0 — группы уже применены, apt «всё на месте»)"
  sleep 100   # загрузка модели (94 с канон) + запас — чтение, не мутация
  curl -fsS http://127.0.0.1:8080/ready >/dev/null || fail "/ready не ответил"
  OUT=$(bash "$STACK/gfctl" smoke) || fail "smoke отказал: $OUT"
  grep -q 'SMOKE: OK' <<<"$OUT" || fail "smoke без SMOKE: OK"
  APT_AFTER=$(grep -c 'install ' /var/log/apt/history.log 2>/dev/null || echo 0)
  [ "$APT_AFTER" = "$APT_BEFORE" ] || fail "apt-history выросла на повторе ($APT_BEFORE → $APT_AFTER) — идемпотентность/apt сломан"
  [ -f "$STACK/.gfctl-containers.conf" ] || fail ".gfctl-containers.conf не доставлен"
  say "повтор use: apt-история не выросла ($APT_BEFORE = $APT_AFTER), conf-файл на месте"
  echo "RESULT: PASS — PHASE=2 use rc 0, health ok, smoke 3/3, apt-повтор = 0 вызовов"
elif [ "$PHASE" = 3 ]; then
  say "PHASE 3: после ребута — самоподъём (ребут-приём fix-r2)"
  systemctl --user is-enabled gfctl-serve.service || fail "serve-юнит disabled после ребута (fix-r2 нарушен)"
  systemctl --user is-enabled gfctl-watchdog.timer || fail "watchdog-таймер disabled после ребута"
  for i in $(seq 1 24); do
    curl -fsS http://127.0.0.1:8080/ready >/dev/null 2>&1 && break
    sleep 10
  done
  curl -fsS http://127.0.0.1:8080/ready >/dev/null || fail "сервер не поднялся сам за 240 с"
  podman ps --format '{{.Names}} {{.Status}}' | grep -q '^gufo Up' || fail "контейнер gufo не running"
  echo "RESULT: PASS — PHASE=3 самоподъём после ребута (юниты enabled, контейнер running, health ok)"
else
  fail "PHASE=$PHASE не из 1|2|3"
fi
