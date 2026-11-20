#!/usr/bin/env bash
# EXP-008-delivery — «доставка с нуля» (этап 4, PLAN п.2): полный цикл
# локальной дистрибуции на приёмочной машине: tar-перенос дерева (клона) в
# ~/gfctl → gfctl install (bootstrap .data/ первого запуска — сам диспетчер,
# лейаут 4.4: install.sh упразднён; юниты при install/use) → use канон →
# agent-check → gfctl off.
#
# REPLANNED 2026-11-18 ai-расклад (дельта: .dev/tasks/4/4.2-EXP-replan.md):
#   - машины ai-owned: юзер ai (uid 1002, sudo NOPASSWD, linger on); юзер
#     hipfire retired (логин заблокирован) — НЕ использовать; все пути
#     /home/ai/*;
#   - 2026-11-20 (лейаут 4.4): стек = клон ~/gfctl (GFCTL_DIR/GFCTL_MODELS
#     не задаются — диспетчер сам детектит каталог gfctl-файла; данные
#     ~/gfctl/.data: модели .data/models/<сет>, логи .data/logs); пулы
#     ~/gufo-models и ~/gfctl-acc-models — источники хардлинков до миграции;
#   - hfctl-прод (порт 11435) гасится ДО окна `hfctl off` ОТ ИМЕНИ ai с
#     ОБЯЗАТЕЛЬНЫМ возвратом linger (`sudo loginctl enable-linger ai`):
#     после off linger=no и юзер-менеджер гаснет ~10 с (GOTCHAS llm-lab),
#     конмон/контейнеры живут под ним — без linger окно умрёт вместе с
#     ssh-якорем; gufo-порт 8080 с hfctl не конфликтует, RAM-конфликт
#     исключён остановкой hfctl;
#   - хардлинк-источники весов: ~/gufo-models (пул закачек) И
#     ~/gfctl-acc-models (сеты прошлых EXP-004/005/006) — оба пула в цикле
#     линковки; хардлинки `ln -f`, НЕ симлинки (F19: симлинки не видны в
#     bind-маунте контейнера);
#   - ai-миграция перенесла данные rsync'ом — имена файлов-пинов (F8)
#     сохранены; реальный состав пулов печатает сам скрипт (du + ls) —
#     сверка на месте, без догадок.
#
# Внешний эксперимент (BLOCKED-EXTERNAL): исполняется ТОЛЬКО на приёмочной
# машине (che-evo 60 GiB = ai@192.168.1.254 / che-FAEX1 128 GB =
# ai@192.168.1.249, ключ ~/.ssh/strix_halo_key) и ТОЛЬКО с явным GO
# пользователя. ЭТА ЗАГОТОВКА В РЕПО НЕ ИСПОЛНЯЕТСЯ (bash -n only).
#
# GOAL:
#   - tar-перенос дерева репо (без .git/.dev/.data) в ~/gfctl (клон = стек);
#   - bootstrap первого запуска (лейаут 4.4): ./gfctl сам создаёт каркас
#     .data/ при любом вызове — отдельного install.sh больше нет; юниты
#     ставит первый install/use (после канона);
#   - предусловие «gfctl не установлен или uninstall'нут»: старая приёмочная
#     инсталляция ~/gfctl-acc снимается uninstall'ом + rm -rf руками
#     (uninstall v2 дерево не трогает);
#   - веса: хардлинки уже скачанных файлов из ~/gufo-models и
#     ~/gfctl-acc-models (как EXP-005; если источников нет — gfctl install
#     скачает сам, трафик по пинам);
#   - `gfctl install` — идемпотентная полная постановка: preflight → веса
#     (докачка ТОЛЬКО недостающего: SKIP по готовым) → юниты → recreate →
#     health → smoke → автозапуск (autostart сам включает linger — memlock-
#     гейт по порогу 8388608: relogin-WARN «перелогинься» install НЕ
#     прерывает, exit 42 только ниже порога, 4.1-F2);
#   - архив образа (страховка от смерти ghcr): `podman save $IMG -o
#     ~/gfctl-image-backup.tar` (существующий архив перезаписывается,
#     печатается размер) + подсказка digest-пина
#     «GFCTL_IMAGE=<образ>@sha256:…» — НА ГЛАЗ, канон gfctl не меняется;
#   - `gfctl use $GF_ACC_FLAVOR` — канон профиля окна;
#   - `gfctl agent-check` — агентская самопроверка (SPEC §7, референсы
#     EXP-007: 27b-single 30.44/3.00/3.60/2.85; flash-multi 17.22/1.58/
#     10.44/1.89, ±25% → WARN);
#   - `gfctl off` — завершение окна (дорога hfctl on).
#
# PREREQ:
#   - ЯВНЫЙ GO пользователя на ЭТО окно;
#   - env: GF_ACC_HOST (обязателен: ai@192.168.1.254 evo 60 GiB |
#     ai@192.168.1.249 FAEX 128 GB), GF_ACC_USER (дефолт ai),
#     GF_ACC_KEY (дефолт ~/.ssh/strix_halo_key), GF_ACC_FLAVOR
#     (27b-single | 27b-multi | flash-multi; на 60 GiB flash-multi
#     невозможен — RAM-гейт отсечёт до трафика);
#   - hfctl-прод машины ОСТАНОВЛЕН перед окном ОТ ИМЕНИ ai с возвратом
#     linger (одной командой с машины оператора):
#       ssh -i ~/.ssh/strix_halo_key ai@HOST \
#         'hfctl off && sudo loginctl enable-linger ai'
#     после окна: скрипт сам делает `gfctl off` → ты: `hfctl on` (он вернёт
#     linger) → healthy + smoke;
#   - окно в tmux / долгой ssh-сессии (установка весов с нуля — десятки ГБ).
#
# RUN:  GF_ACC_HOST=ai@192.168.1.254 GF_ACC_FLAVOR=27b-single \
#       bash EXP-008-delivery.sh
#   Весь вывод → EXP-008-delivery.result.txt, финальная строка
#   «RESULT: PASS|FAIL|ERROR — …».
#
# PASS-критерий (brief 4.1):
#   1) healthy: «роут:» + «SMOKE: OK» от install (сервер поднят и здоров);
#   2) smoke повторно не нужен — use/agent-check прошли rc 0;
#   3) agent-check: «AGENT-CHECK:» сводка, AGENT_CHECK_RC=0.
set -uo pipefail
: "${GF_ACC_HOST:?задай GF_ACC_HOST (ai@192.168.1.254 evo | ai@192.168.1.249 FAEX)}"
GF_ACC_USER="${GF_ACC_USER:-ai}"
GF_ACC_KEY="${GF_ACC_KEY:-$HOME/.ssh/strix_halo_key}"
: "${GF_ACC_FLAVOR:?задай GF_ACC_FLAVOR (27b-single | 27b-multi | flash-multi)}"

cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
RES="EXP-008-delivery.result.txt"
SSH="ssh -i $GF_ACC_KEY -o BatchMode=yes -o ConnectTimeout=10"

exec > >(tee "$RES") 2>&1

echo "== EXP-008: снос СТАРОЙ инсталляции (uninstall v2: юниты/контейнер/linger/limits.d; дерево сносится руками — 4.4)"
$SSH "$GF_ACC_USER@$GF_ACC_HOST" 'if [ -x "$HOME/gfctl-acc/gfctl" ]; then GFCTL_YES=1 "$HOME/gfctl-acc/gfctl" uninstall; rm -rf "$HOME/gfctl-acc"; else echo "(не было — чистая машина)"; fi' || {
  echo "RESULT: ERROR — uninstall старой инсталляции не прошёл"; exit 1; }

echo "== EXP-008: tar-перенос дерева-клона (без .git/.dev/.data) в ~/gfctl"
$SSH "$GF_ACC_USER@$GF_ACC_HOST" 'mkdir -p ~/gfctl' || {
  echo "RESULT: ERROR — ssh не прошёл"; exit 1; }
tar -C "$ROOT" --exclude=.git --exclude=.dev --exclude=.data -cf - . | \
  $SSH "$GF_ACC_USER@$GF_ACC_HOST" 'tar -C ~/gfctl -xf -' || {
  echo "RESULT: ERROR — ssh не прошёл"; exit 1; }

$SSH "$GF_ACC_USER@$GF_ACC_HOST" "GF_ACC_FLAVOR=$GF_ACC_FLAVOR bash -s" <<'REMOTE' || {
  set -u
  export GFCTL_YES=1
  GF="$HOME/gfctl/gfctl"

  echo "== bootstrap первого запуска (лейаут 4.4 — сам диспетчер): ./gfctl status (каркас .data/; канона нет — честный отчёт)"
  "$GF" status || true

  echo "== веса: хардлинки из пулов ai — ~/gufo-models + ~/gfctl-acc-models (сеты прошлых EXP)"
  setname=${GF_ACC_FLAVOR%%-*}   # 27b | flash — имена каталогов-сетов MODELS_BASE (profiles.sh)
  tgt="$HOME/gfctl/.data/models/$setname"
  mkdir -p "$tgt"
  du -sh "$HOME/gufo-models" "$HOME/gfctl-acc-models" 2>/dev/null || true
  n=0
  for src in "$HOME"/gufo-models/*/*.gguf "$HOME"/gufo-models/*/*/*.gguf \
             "$HOME"/gfctl-acc-models/*/*.gguf; do
    [ -f "$src" ] || continue
    base=$(basename "$src")
    # имена файлов источников = пинам таблицы set_* (F8, ai-миграция их
    # сохранила); лишние .gguf пула (запасные руки квантов) линкуются тоже —
    # безвредно: 0 байт (тот же инод), движок грузит только файлы serve_args,
    # install SKIP-ит строго по своим пинам (размер+sha).
    if [ ! -e "$tgt/$base" ]; then
      ln -f "$src" "$tgt/$base" 2>/dev/null && n=$((n + 1))
    fi
  done
  echo "HARDLINKED=$n (0 — ок: сет уже в acc-models с прошлых EXP или будет докачан install)"
  echo "== состав целевого сета после линковки (сверка на месте): $tgt"
  ls -lh "$tgt"

  echo "== gfctl install: гейты → докачка ТОЛЬКО недостающего → recreate → health → smoke → автозапуск"
  "$GF" install --profile "$GF_ACC_FLAVOR" || exit 46

  echo "== архив образа (страховка от смерти ghcr): podman save → ~/gfctl-image-backup.tar (перезапись)"
  IMG="ghcr.io/gufo-org/toolboxes/gufo-runtime:latest"
  podman save "$IMG" -o "$HOME/gfctl-image-backup.tar" || exit 54
  ls -lh "$HOME/gfctl-image-backup.tar" | awk 'NR==1{next} {print "размер архива:", $5}'
  echo "запинить: GFCTL_IMAGE=$IMG@$(podman inspect --format '{{.ImageDigest}}' gufo)  (digest манифеста — канон gfctl не меняется)"

  echo "== use $GF_ACC_FLAVOR (канон; уже healthy — идемпотентно)"
  "$GF" use "$GF_ACC_FLAVOR" || exit 47

  echo "== agent-check (SPEC §7, референсы EXP-007)"
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
  echo "RESULT: FAIL — remote-часть rc=$rc (45=uninstall, 46=install, 54=podman save, 47=use, 48=agent-check)"; exit 1; }

echo "== EXP-008: критерии PASS"
grep -q '^SMOKE: OK' "$RES" || { echo "RESULT: FAIL — install не дошёл до SMOKE: OK"; exit 1; }
grep -q '^роут: ' "$RES" || { echo "RESULT: FAIL — роут не напечатан (не healthy)"; exit 1; }
arc=$(sed -n 's/^AGENT_CHECK_RC=\([0-9][0-9]*\)$/\1/p' "$RES" | head -n1)
[ "$arc" = 0 ] || { echo "RESULT: FAIL — agent-check rc=${arc:-?} (ждём 0)"; exit 1; }
echo "RESULT: PASS — доставка с нуля: healthy + smoke, agent-check rc 0 (детали окна — в result-файле)"
