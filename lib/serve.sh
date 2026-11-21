# shellcheck shell=bash
# ── serve: командная строка контейнера из профильной таблицы + recreate ────
# Serve-командная строка собирается ТОЛЬКО из таблицы lib/profiles.sh (правило
# «Источники истины»: поля 1/3/4/5/6/7) + токены ролей @DRAFT@/@MTP@ →
# контейнерные пути /models/<файл> (маунт сета models:ro). Podman-префикс —
# F9 ровно (обязательные флаги rootless из проверенных запусков); recreate —
# ЕДИНСТВЕННЫЙ путь подъёма container_up = rm+run (SPEC §8), пауза/ретрай —
# F10. Модуль читает CONTAINER/IMAGE/STACK_DIR/MODELS_BASE (диспетчер),
# canon_*/write-функции (state.sh), profile_field/models_dir_for (profiles.sh),
# set_file_role (models.sh); пишет через log/warn/die.
# Этап 5.1 (D8): самолечение storage-сирот — mirror hf_orphan_heal (hfctl
# lib/autostart.sh:294–328, только ЧТЕНИЕ) 1:1 по духу gfctl-конвенций:
# gf_orphan_heal + кап GF_ORPHAN_HEALS/HEAL_MAX за процесс.

HEAL_MAX="${GFCTL_HEAL_MAX:-2}"        # кап самолечений storage-сирот за процесс (hook батареи)
GF_ORPHAN_HEALS=0                      # счётчик выполненных самолечений в этом процессе

# Назначение: напечатать аргументы движка (`gufo serve llm …`) ОДНОЙ строкой
#   для хвоста `podman run … <image> <serve-строка>`: --host 0.0.0.0 всегда
#   (F2: дефолт 127.0.0.1 в контейнере = мёртвый port-publish), --model =
#   файл роли main сета (у flash — ПЕРВЫЙ шард 00001-of-00004, остальные
#   gufo подхватывает сам, окно FX-W1b), поле 7 таблицы с подстановкой
#   @DRAFT@/@MTP@ → /models/<файл>, затем --sessions/--context (аргументы) и
#   кэш-тиры полей 5/6 (cache-disk всегда контейнерный /cache).
#
# Побочные эффекты: только печать в stdout; неизвестный токен роли (не
#   @DRAFT@/@MTP@) или отсутствие файла нужной роли в таблице сета — die().
#
# Ограничения/допущения: ЧИСТАЯ функция (ничего не поднимает) — батарея
#   сравнивает вывод байт-в-байт с каноном task.md; sessions/context передаются
#   аргументами (канон или таблица — решает вызывающий: container_up берёт
#   canon_sessions/canon_context). Неизвестный профиль — die через
#   profile_field (rc 1 без печати).
#
# @param 1: profile_id      # канонический id профиля
# @param 2: /^[0-9]+$/      # sessions
# @param 3: /^[0-9]+$/      # context (токенов)
# @stdout string            # «gufo serve llm --host 0.0.0.0 --model … …»
# @returns integer          # 0 — напечатано; die (exit 1) на битых токенах
serve_args() {
  local prof="$1" sessions="$2" context="$3" set_name extra model draft mtp
  set_name=$(profile_field "$prof" 1) || die "serve_args: неизвестный профиль '$prof' — доступно: $PROFILE_LIST"
  model=$(set_file_role "$set_name" main) || die "у сета $set_name нет файла роли main (--model не собрать)"
  draft=$(set_file_role "$set_name" draft) || true
  mtp=$(set_file_role "$set_name" mtp) || true
  extra=$(profile_field "$prof" 7)
  if [[ "$extra" == *@DRAFT@* ]]; then
    [ -n "$draft" ] || die "профиль $prof использует @DRAFT@, у сета $set_name нет draft-файла"
    extra="${extra//@DRAFT@//models/$draft}"
  fi
  if [[ "$extra" == *@MTP@* ]]; then
    [ -n "$mtp" ] || die "профиль $prof использует @MTP@, у сета $set_name нет mtp-файла"
    extra="${extra//@MTP@//models/$mtp}"
  fi
  if printf '%s' "$extra" | grep -qE '@[A-Z0-9_]+@'; then
    die "serve_args: неизвестный токен в serve_extra профиля $prof: $extra"
  fi
  printf 'gufo serve llm --host 0.0.0.0 --model /models/%s %s --sessions %s --context %s --cache-ram-bytes %s --cache-disk /cache --cache-disk-bytes %s\n' \
    "$model" "$extra" "$sessions" "$context" "$(profile_field "$prof" 5)" "$(profile_field "$prof" 6)"
}

# Назначение: предикат «GPU-ноды на месте» — /dev/kfd и /dev/dri/renderD*
#   (ROCm ядро; у Halo card0 может не быть вовсе — нумерация renderD с 1).
#   Выделена отдельной функцией ради battery-оверрайда (заглушка в субшелле).
#
# Побочные эффекты: только чтение /dev; в stdout не печатает.
#
# Ограничения/допущения: без параметров; compgen -G — bash-glob предикат
#   (отсутствие renderD* — rc 1, не краш под set -e, т.к. вызывается в if).
#
# @returns integer          # 0 — и kfd, и renderD* есть; 1 — чего-то нет
gpu_nodes_present() {
  [ -e /dev/kfd ] && compgen -G '/dev/dri/renderD*' >/dev/null
}

# Назначение: самолечение storage-сироты «already in use by an external
#   entity» (рассинхрон libpod-БД и storage-слоя podman; класс наблюдён в
#   окнах 2026-11-21, D8 — mirror hfctl 13.1): вынуть ID контейнера-сироты
#   из вывода podman run, удалить его containers-storage delete-container и
#   вернуть 0 — вызывающий (container_up) делает один retry попыткой цикла.
#   Гард'ы: пустой ID (сигнатуры нет) → rc 1 молча; кап HEAL_MAX за процесс
#   (GF_ORPHAN_HEALS); бинаря containers-storage нет → WARN с ручной
#   командой, поведение как прежде (Variant B); ID, видимый libpod, — НЕ
#   сирота, трогать нельзя (страховка от удаления живого контейнера при
#   обратном рассинхроне); delete-container отказался → WARN.
#
# Побочные эффекты: при успехе — containers-storage delete-container <ID>
#   (самолечение засчитано в глобал GF_ORPHAN_HEALS) и log-строка; при
#   отказе хила — warn-строка в stderr. Ничего не удаляет, кроме сироты
#   из текста ошибки.
#
# Ограничения/допущения: требует глобалы GF_ORPHAN_HEALS/HEAL_MAX (шапка
#   модуля) и log/warn (диспетчер). Синтаксис хила —
#   containers-storage-delete-container(1) (флагов -f нет; отказ → WARN,
#   поведение = прежнее). ID ищется по сигнатуре «already in use by
#   <12..64-hex>»; grep глушен `|| true` — пустой ID = не сирота (rc 1).
#   Вызывается из container_up только при отказе podman run (happy-path
#   не зовёт).
#
# @param 1: string  # полный вывод неудачного `podman run` (2>&1)
# @stdout string   # log-строка при успехе; warn-строки при отказе (stderr)
# @returns integer # 0 — сирота найдена и удалена; 1 — сигнатуры нет / кап /
#   бинаря нет / ID видит libpod / delete-container отказался
gf_orphan_heal() {
  local id
  id=$(printf '%s' "$1" | { grep -oE 'already in use by [0-9a-f]{12,64}' || true; } | head -1 | awk '{print $5}')
  [ -n "$id" ] || return 1
  [ "$GF_ORPHAN_HEALS" -lt "$HEAL_MAX" ] || return 1        # кап за процесс
  command -v containers-storage >/dev/null || { warn "containers-storage нет в PATH — самолечение невозможно: sudo apt install containers-storage; вручную: containers-storage delete-container $id"; return 1; }
  podman inspect -f '{{.State.Status}}' "$id" >/dev/null 2>&1 && { warn "ID $id видит libpod — не сирота, самолечение отменено"; return 1; }
  GF_ORPHAN_HEALS=$((GF_ORPHAN_HEALS + 1))
  containers-storage delete-container "$id" || { warn "containers-storage delete-container $id отказался"; return 1; }
  log "storage-сирота $id удалена (external entity) — повторяю up"
}

# Назначение: состояние контейнера — stdout `podman inspect -f
#   '{{.State.Status}}'` (running/exited/created/…) либо строка `missing`
#   при недоступном контейнере (fallback `|| echo missing`, как в hfctl
#   cmd_watchdog).
#
# Побочные эффекты: только печать состояния; подпроцесс podman inspect.
#
# Ограничения/допущения: требует глобал CONTAINER; пустой вывод при rc 0
#   (экзотический сбой) трактуется вызывающими как «не running» — missing
#   только при честном отказе inspect.
#
# @stdout string            # состояние podman или «missing»
# @returns integer          # rc inspect/echo — потребители сравнивают stdout
container_state() {
  podman inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo missing
}

# Назначение: остановить контейнер — `podman rm -f` (обои: контейнер и его
#   логи удаляются; recreate ниже всё равно rm+run — SPEC §8).
#
# Побочные эффекты: podman rm -f $CONTAINER (сбой глушится — нет контейнера
#   = цель уже достигнута). В stdout не печатает.
#
# Ограничения/допущения: требует глобал CONTAINER; вызывается cmd_off и
#   cmd_uninstall (в слое «контейнер»).
#
# @returns integer          # всегда 0 — отказ rm не интересен (idempotent)
container_stop() {
  podman rm -f "$CONTAINER" >/dev/null 2>&1 || true
  return 0
}

# Назначение: ЕДИНСТВЕННЫЙ путь подъёма контейнера (install/use/on/up/
#   _watchdog/_boot; SPEC §8 «recreate = rm+run»: конфиг контейнера не
#   переиспользуется никогда — заодно иммунно к перенумерации renderD*
#   между ребутами, поэтому hfctl-деление boot/recreate не нужно):
#   1) mkdir -p cache/<профиль>; пауза GFCTL_RECREATE_PAUSE_S (дефолт 3 с,
#      F10: rootless podman медленно освобождает порт);
#   2) до GFCTL_RUN_ATTEMPTS попыток `podman rm -f` + `podman run -d …`
#      (rm ВНУТРИ цикла, ПЕРЕД каждым run — единственный rm: каждая попытка
#      — чистый слейт, иначе run попыток 2/3 бил в «container already in
#      use» — teardown loading-контейнера медленнее пауз; EXP-009
#      evo-повтер, рестарт-restore; F9-флаги ровно, -p bind:port:port
#      по канону, маунты: каталог-сет → /models:ro
#      (контейнерные пути весов = /models/<файл>, как задуманы токены
#      profiles.sh) и .data/cache/<профиль> → /cache; хвост — serve_args из
#      канона); успех → выход; неудача → пауза 5 с и повтор (занятый порт
#      и прочие транзитивные отказы, F10); отказ run с сигнатурой
#      «already in use by <ID>» → gf_orphan_heal (самолечение storage-сироты,
#      D8/mirror hfctl 13.1) до следующей попытки; все попытки неудачны →
#      хвост podman logs + die (с ручным рецептом для сироты).
#
# Побочные эффекты: podman rm/run; создание каталога кэша профиля; sleep
#   пауз; возможное containers-storage delete-container (gf_orphan_heal);
#   при исчерпании попыток — FATAL die (exit 1).
#
# Ограничения/допущения: требует глобалы CONTAINER/IMAGE/STACK_DIR и
#   canon_sessions/canon_context/canon_port/canon_bind (state.sh) — канон
#   .env должен быть записан ДО вызова (install/use пишут write_canon
#   раньше; boot/watchdog читают готовый). $(serve_args …) без кавычек —
#   осознанный word-split одной строки в аргументы (globs в аргументах
#   serve нет). `if podman run …` — отказ не роняет set -e внутри цикла.
#
# @param 1: profile_id      # канонический id профиля (каталог кэша и сет)
# @returns integer          # 0 — контейнер запущен; die при исчерпании попыток
container_up() {
  local prof="$1" set_name cache_dir attempt attempts="${GFCTL_RUN_ATTEMPTS:-3}" args run_out
  set_name=$(profile_field "$prof" 1) || die "container_up: неизвестный профиль '$prof'"
  cache_dir="$STACK_DIR/.data/cache/$prof"
  mkdir -p "$cache_dir"
  sleep "${GFCTL_RECREATE_PAUSE_S:-3}"
  args=$(serve_args "$prof" "$(canon_sessions "$prof")" "$(canon_context "$prof")")
  for attempt in $(seq 1 "$attempts"); do
    log "podman run (попытка $attempt/$attempts): профиль $prof"
    # каждая попытка — чистый слейт: teardown loading-контейнера медленнее
    # пауз, без этого run 2/3 бил в «container already in use» (EXP-009 evo-повтер)
    podman rm -f "$CONTAINER" >/dev/null 2>&1 || true
    # shellcheck disable=SC2086 — serve_args отдаёт ровно одну строку аргументов
    if run_out=$(podman run -d --name "$CONTAINER" \
      --device /dev/kfd --device /dev/dri --group-add keep-groups \
      --ipc=host --ulimit memlock=-1:-1 \
      --userns=keep-id:uid=1000,gid=1000 \
      -p "$(canon_bind):$(canon_port):$(canon_port)" \
      -v "$(models_dir_for "$set_name"):/models:ro" \
      -v "$cache_dir:/cache" \
      "$IMAGE" $args 2>&1); then
      return 0
    fi
    # отказ с сигнатурой «already in use by <ID>» → самолечение сироты
    # (D8, mirror hfctl 13.1) ДО следующей попытки; хил не сработал →
    # печатаем ошибку попытки как прежде (диагностика не глотается)
    if ! gf_orphan_heal "$run_out"; then
      [ -n "$run_out" ] && printf '%s\n' "$run_out" >&2
    fi
    [ "$attempt" -lt "$attempts" ] && sleep 5
  done
  podman logs --tail 30 "$CONTAINER" 2>&1 | tail -30 || true
  die "podman run не удался за $attempts попыток (занятый порт/транзитивный отказ — F10; освободи порт или проверь: gfctl doctor). Если в ошибке выше «…already in use by <ID>…», а ID не виден в podman ps -a — это storage-сирота: containers-storage delete-container <ID>"
}
