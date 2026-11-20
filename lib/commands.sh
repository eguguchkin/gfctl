# shellcheck shell=bash
# ── команды диспетчера (1.1: models / doctor / status; 1.2: install / use /
#    logs / smoke / uninstall; 2.1: probe-подбор контекста в use + bench) ────
# Живой сервер собирается из модулей serve/state/units/health/autostart:
#   эта программа — cmd_*-обёртки с гейтами и фиксированным порядком
#   «смена конфига = recreate → health → smoke» (правило AGENTS/llm-lab).
# Все функции читают глобалы диспетчера (PORT, STACK_DIR, TPL_DIR, ASSUME_YES,
# CONTAINER, UNIT_NAME, UNIT_DIR) и модулей (PROFILE_LIST, set_*) — ничего
# не переопределяют.

# Назначение: нормализовать аргумент «сет|профиль» в каталог-сет весов:
#   27b|flash — напрямую; иначе resolve_profile → поле 1 таблицы профилей.
#
# Побочные эффекты: только печать сета в stdout; при неизвестном значении —
#   die() (exit 1) со списком допустимых.
#
# Ограничения/допущения: пустой аргумент НЕ валиден — вызывающий решает
#   дефолт (у download — отказ, у --check-types — сет активного профиля).
#
# @param 1: string          # сет (27b|flash), алиас или канон профиля
# @stdout weight_set        # '27b' | 'flash' (при отказе процесс завершён)
# @returns integer          # не возвращается при отказе (die); иначе 0
resolve_set() {
  case "$1" in
    27b|flash) echo "$1" ;;
    *) local prof
       prof=$(resolve_profile "$1") || die "неизвестный сет/профиль '$1' — доступно: 27b | flash | $PROFILE_LIST"
       profile_field "$prof" 1 ;;
  esac
}

# Назначение: экранирование строки для безопасной вставки в JSON-вывод
#   (status --json; review 1.1 №9 / бэклог 4.2 п.6): \ → \\, " → \",
#   таб/перевод строки/CR → \t/\n/\r — спецсимволы в именах/путях (env
#   GFCTL_BIND/GFCTL_DIR, имя модели из лога) больше не ломают документ.
#
# Побочные эффекты: только печать в stdout; ничего не меняет.
#
# Ограничения/допущения: чистая функция; прочие управляющие символы (< 0x20)
#   не экранируются (в именах моделей/путях инсталляции не встречаются —
#   живой источник кавычек/пробелов — имена gufo, F20).
#
# @param 1: string    # исходная строка
# @stdout string     # содержимое JSON-строки (БЕЗ обрамляющих кавычек)
# @returns integer   # всегда 0
json_str() {
  local s="$1"
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}
  printf '%s' "$s"
}

# Назначение: TCP-проба порта сервера — 0, если что-то слушает на
#   127.0.0.1:$1 (health «отвечает»), 1 иначе («не запущен»).
#
# Побочные эффекты: подпроцесс timeout+bash с /dev/tcp; файлов и глобалов не
#   меняет.
#
# Ограничения/допущения: порт — аргумент (живые вызовы передают canon_port;
#   дефолт — глобал PORT для doctor); GNU timeout (целевые машины — GNU);
#   проба ТОЛЬКО локального loopback — ответ порта ≠ healthy (полный health
#   — wait_health), это лишь «слушает/не слушает».
#
# @param 1: /^[0-9]+$/       # порт (опционально; дефолт — глобал PORT)
# @returns integer           # 0 — соединение установилось; 1 — отказ/таймаут
port_open() {
  local p="${1:-$PORT}"
  timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/$p" 2>/dev/null
}

# Назначение: cmd models — без аргументов: инвентарь обоих сетов + сводка
#   «по профилям» (сет N/M файлов, докачать X GiB, свободно Y:
#   OK/НЕДОСТАТУЧНО), rc 0; `download <сет|профиль> [--yes]`: pre-flight и
#   download_file по каждому отсутствующему/битому файлу сета после согласия
#   ask (SPEC: веса качаются только после согласия; не-TTY без --yes —
#   авто-нет rc 1); `--check-types [сет|профиль]`: pre-check GGUF-типов
#   (дефолт — сет активного профиля). Неизвестный аргумент — die со списком.
#
# Побочные эффекты: download — файлы весов + сеть (после ask); остальные
#   ветки — чтение + mkdir -p каталогов сетов (free_disk_gib); stdout —
#   инвентарь/сводка/ход скачивания.
#
# Ограничения/допущения: глобалы PROFILE_LIST, MODELS_BASE, TPL_DIR,
#   ASSUME_YES; вывод curl без прогресс-метра (флаги task.md); сводка считает
#   «докачать» по пин-размерам файлов с отсутствием/битым размером (sha-битые
#   размер-корректные файлы считает годными — честный статус даёт inventory).
#
# @param 1..N: string[]     # subcommand и флаги (см. Назначение)
# @stdout string[]          # инвентарь / сводка / ход download / вердикт check-types
# @returns integer          # 0 — успех; 1 — отказ download/check-types (die — exit 1)
cmd_models() {
  local sub="${1:-}"
  case "$sub" in
    "")
      local set_name
      for set_name in 27b flash; do
        log "сет $set_name — инвентарь"
        inventory "$set_name"
      done
      log "сводка по профилям"
      local p stats present total missing missing_gib free_gib verdict
      for p in $PROFILE_LIST; do
        set_name=$(profile_field "$p" 1)
        read -r present total missing <<<"$(set_stats "$set_name")"
        missing_gib=$(awk -v b="$missing" 'BEGIN{printf "%.1f", b/1073741824}')
        free_gib=$(free_disk_gib "$(models_dir_for "$set_name")")
        if [ "$missing" = 0 ]; then
          verdict="OK (веса на месте)"
        elif awk -v m="$missing_gib" -v f="$free_gib" 'BEGIN{exit !(m<=f)}'; then
          verdict="OK"
        else
          verdict="НЕДОСТАТУЧНО места"
        fi
        printf '%s: сет %s %s/%s файлов, докачать %s GiB, свободно %s GiB: %s\n' \
          "$p" "$set_name" "$present" "$total" "$missing_gib" "$free_gib" "$verdict"
      done
      ;;
    download)
      shift
      local target="" a set_name
      for a in "$@"; do
        case "$a" in
          --yes) ASSUME_YES=1 ;;
          *) target="$a" ;;
        esac
      done
      [ -n "$target" ] || die "укажи сет или профиль: 27b | flash | $PROFILE_LIST"
      set_name=$(resolve_set "$target")
      log "сет $set_name — докачка недостающих весов"
      ensure_weights "$set_name"
      ;;
    --check-types)
      shift
      local target="${1:-}" set_name
      # review 1.1 №8 (бэклог 4.2 п.5): лишний аргумент после [сет|профиль]
      # молча игнорировался — теперь die, единообразно с status
      [ -n "${2:-}" ] && die "models --check-types: лишние аргументы после '${1:-}' — доступно: --check-types [сет|профиль]"
      if [ -z "$target" ]; then
        set_name=$(profile_field "$(cur_profile)" 1)
      else
        set_name=$(resolve_set "$target")
      fi
      log "check-types сета $set_name (GGUF-типы тензоров, без GPU)"
      check_types "$set_name"
      ;;
    *)
      die "неизвестный аргумент 'models $sub' — доступно: (пусто) | download <сет|профиль> [--yes] | --check-types [сет|профиль]"
      ;;
  esac
}

# Назначение: cmd doctor — диагностика БЕЗ записи, rc 0 всегда: ОС, /dev/kfd,
#   /dev/dri/renderD*, render-группа, memlock (+limits.d/*gfctl*), linger,
#   RAM-гейты всех профилей цифрами, диск под веса (обои сета), порт, gpu-lock
#   (WARN: кто держит GPU — соседство с hfctl-продом, D3: переключение руками),
#   зеркало весов (GFCTL_MIRROR_BASE задан → строка; 4.1-F1), соседние
#   артефакты (~/gufo-models ~/gufo-exp ~/halogen-* ~/gfctl-acc* —
#   «обнаружен/не обнаружен»; 4.1).
#
# Побочные эффекты: только чтение системы + mkdir -p каталогов сетов
#   (free_disk_gib); печать в stdout, WARN в stderr; ничего не меняет.
#
# Ограничения/допущения: отсутствие команды/устройства/файла — значение «?»
#   или WARN, НЕ краш (dev-контейнер и «голая» машина до host_prep — рабочие
#   случаи); podman ps — локальная read-only проба; порт-проба loopback
#   («слушает/не слушает», не health).
#
# @stdout string[]          # секции диагностики
# @stderr string            # WARN gpu-lock при занятом GPU
# @returns integer          # всегда 0
cmd_doctor() {
  echo "== gfctl doctor — диагностика (только чтение)"
  local pretty="?" rd lim ml ling names p set_name need_b need_gib free_gib verdict
  if [ -r /etc/os-release ]; then
    pretty=$(grep '^PRETTY_NAME=' /etc/os-release | cut -d= -f2- | tr -d '"' || true)
  fi
  echo "ОС: ${pretty:-?}"
  if [ -e /dev/kfd ]; then echo "/dev/kfd: есть"; else echo "/dev/kfd: ? (нет — ROCm/GPU-ускорение недоступно)"; fi
  rd=$(compgen -G '/dev/dri/renderD*' 2>/dev/null | head -n 1 || true)
  if [ -n "$rd" ]; then
    echo "/dev/dri: есть ($(compgen -G '/dev/dri/renderD*' 2>/dev/null | wc -l) renderD*)"
  else
    echo "/dev/dri: ? (нет renderD*)"
  fi
  if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx render; then
    echo "render-группа: да"
  else
    echo "render-группа: нет (WARN — на целевой машине: sudo usermod -aG render \$USER)"
  fi
  ml=$(ulimit -l 2>/dev/null || echo "?")
  lim="нет"; compgen -G '/etc/security/limits.d/*gfctl*' >/dev/null 2>&1 && lim="есть"
  if [ "$ml" = "unlimited" ]; then
    echo "memlock: unlimited | limits.d/*gfctl*: $lim"
  else
    echo "memlock: ${ml} kB | limits.d/*gfctl*: $lim — WARN (не unlimited; юнит этапа 1.2 потребует limits.d)"
  fi
  ling="?"
  if command -v loginctl >/dev/null 2>&1; then
    ling=$(loginctl show-user "${USER:-$(id -un)}" -p Linger 2>/dev/null | cut -d= -f2 || true)
    case "$ling" in
      yes) ling="да" ;;
      no)  ling="нет" ;;
      *)   ling="?" ;;
    esac
  fi
  echo "linger: $ling (автозапуск юзер-менеджера)"
  echo "RAM-гейты профилей:"
  for p in $PROFILE_LIST; do
    printf '  %s\n' "$(ram_gate_line "$p")"
  done
  local mbase="${GFCTL_MIRROR_BASE:-}"
  if [ -n "$mbase" ]; then
    echo "зеркало весов (GFCTL_MIRROR_BASE): $mbase (первая попытка докачки; пусто/не задано — пин-URL HF)"
  fi
  for set_name in 27b flash; do
    need_b=$(set_total_bytes "$set_name")
    need_gib=$(awk -v b="$need_b" 'BEGIN{printf "%.1f", b/1073741824}')
    free_gib=$(free_disk_gib "$(models_dir_for "$set_name")")
    if awk -v n="$need_gib" -v f="$free_gib" 'BEGIN{exit !(n<=f)}'; then
      verdict="OK"
    else
      verdict="НЕДОСТАТУЧНО"
    fi
    echo "диск [$set_name]: нужно ${need_gib} GiB — свободно ${free_gib} GiB: $verdict"
  done
  if port_open; then echo "порт $PORT: что-то слушает"; else echo "порт $PORT: свободен"; fi
  if command -v podman >/dev/null 2>&1; then
    names=$(podman ps --format '{{.Names}}' 2>/dev/null || true)
    if [ -n "$names" ]; then
      warn "GPU может быть занят контейнерами: $(echo "$names" | tr '\n' ' ')— переключение движков руками, без takeover (D3; SPEC §9)"
    else
      echo "gpu-lock: контейнеров podman нет"
    fi
  else
    echo "gpu-lock: ? (podman недоступен — проверь на целевой машине)"
  fi
  # этап 4.1: «соседние» артефакты — что осталось от окон исследований
  # (~/gufo-*, ~/halogen-*) и приёмок (~/gfctl-acc*); только чтение.
  local home="${HOME:-}" art
  if [ -n "$home" ]; then
    echo "соседние артефакты (окна исследований и приёмки):"
    for art in gufo-models gufo-exp halogen-models halogen-cache \
               gfctl-acc gfctl-acc-src gfctl-acc-models; do
      if [ -e "$home/$art" ]; then echo "  ~/$art: обнаружен"; else echo "  ~/$art: не обнаружен"; fi
    done
    echo "  примечание: uninstall (v2, 4.4) не трогает НИКАКИЕ данные: дерево клона с .data/ и podman-образ остаются; полный снос — руками (rm -rf клона + podman rmi)"
  fi
  return 0
}

# Назначение: cmd status [--json] — живой режим 1.2 + честный отчёт при
#   мёртвом сервере, rc 0 всегда. Источники полей — только лог+файлы
#   (/metrics — этап 3): профиль cur_profile; порт/бинд canon_*; порт мёртв →
#   health «не запущен» и route/autostart/version/cache = null (схема 1.1 не
#   ломается); жив → `podman logs | parse_route`: ROUTE_SPEC непуст → «ok»,
#   пуст → «загружается»; autostart = `systemctl --user is-enabled
#   gfctl-serve.service` (enabled → вкл/true, иначе выкл/false; systemctl
#   нет → «?»/null); version = `podman inspect -f {{.ImageName}}` (нет
#   контейнера → null); cache = $STACK_DIR/.data/cache/<профиль> + `du -sb`
#   (нет → null). JSON: ключи/типы 1.1 НЕ меняются (route/autostart/version
#   были null — теперь заполняются живыми значениями), новый ключ `cache`
#   добавлен В КОНЕЦ. Человекострока — одна строка:
#   `профиль: X | health: ok | автозапуск: вкл | роут: dflash2, sessions 1,
#   ctx 262144 | кэш: <dir> (<N.N> GiB) | веса 27b: 2/2`.
#
# Побочные эффекты: только чтение (.env стека, stat весов, /proc/meminfo,
#   порт-проба, podman logs/inspect, systemctl is-enabled, du кэша) + печать
#   в stdout. ПИШЕТ глобалы ROUTE_* (через parse_route).
#
# Ограничения/допущения: живой роут печатается только при живом порте
#   (мёртвый сервер → null'ы — контракт схемы 1.1); отсутствие podman/
#   systemctl — деградация в null/«?», не краш; sha весов не проверяется
#   (цена статуса — stat; честный sha-статус — inventory); лишние
#   аргументы — die.
#
# @param 1: [--json]        # единственный допустимый аргумент
# @stdout string            # статусная строка или JSON-документ
# @returns integer          # всегда 0 (честный отчёт и на мёртвом порте)
cmd_status() {
  if [ -n "${2:-}" ]; then die "status: лишние аргументы после '${1:-}' — доступно: --json"; fi
  local json="" prof set_name stats present total health stack gates p need have_dec have verdict p27 t27 m27 pf tf mf c27 cf
  local port bind auto_h auto_j version version_j route_j route_line cache_dir cache_line cache_j cache_b
  case "${1:-}" in
    "")     ;;
    --json) json=1 ;;
    *)      die "status: неизвестный аргумент '${1:-}' — доступно: --json" ;;
  esac
  prof=$(cur_profile)
  set_name=$(profile_field "$prof" 1)
  stats=$(set_stats "$set_name")
  read -r present total _ <<<"$stats"
  port=$(canon_port); bind=$(canon_bind)
  cache_j="null"; cache_line="—"; cache_b=""
  cache_dir="$STACK_DIR/.data/cache/$prof"
  if port_open "$port"; then
    ROUTE_SPEC=""; ROUTE_SESSIONS=""; ROUTE_CTX=""; ROUTE_MODEL=""
    if command -v podman >/dev/null 2>&1; then
      parse_route < <(podman logs "$CONTAINER" 2>&1)   # не пайп: ROUTE_* нужны здесь
    fi
    if [ -n "$ROUTE_SPEC" ]; then health="ok"; else health="загружается"; fi
  else
    health="не запущен"
    ROUTE_SPEC=""; ROUTE_SESSIONS=""; ROUTE_CTX=""; ROUTE_MODEL=""
  fi
  if [ -n "$ROUTE_SPEC" ] && [ -n "$ROUTE_SESSIONS" ] && [ -n "$ROUTE_CTX" ]; then
    route_j="{\"speculative\":\"$(json_str "$ROUTE_SPEC")\",\"sessions\":$ROUTE_SESSIONS,\"context\":$ROUTE_CTX,\"model\":\"$(json_str "$ROUTE_MODEL")\"}"
    route_line="$ROUTE_SPEC, sessions $ROUTE_SESSIONS, ctx $ROUTE_CTX"
  else
    route_j="null"; route_line="—"
  fi
  if [ "$health" = "не запущен" ]; then
    # мёртвый сервер: null'ы схемы 1.1 сохраняются (route/autostart/version/cache)
    auto_h="—"; auto_j="null"; version="" ; cache_dir=""
  else
    if command -v systemctl >/dev/null 2>&1; then
      if systemctl --user is-enabled "$UNIT_NAME-serve.service" >/dev/null 2>&1; then
        auto_h="вкл"; auto_j="true"
      else
        auto_h="выкл"; auto_j="false"
      fi
    else
      auto_h="?"; auto_j="null"
    fi
    version=""
    if command -v podman >/dev/null 2>&1; then
      version=$(podman inspect -f '{{.ImageName}}' "$CONTAINER" 2>/dev/null || true)
    fi
  fi
  if [ -n "$version" ]; then version_j="\"$(json_str "$version")\""; else version_j="null"; fi
  if [ -n "$cache_dir" ] && [ -d "$cache_dir" ]; then
    cache_b=$(du -sb "$cache_dir" 2>/dev/null | awk '{print $1}') || true
    if [ -n "$cache_b" ]; then
      local cache_gib; cache_gib=$(awk -v b="$cache_b" 'BEGIN{printf "%.1f", b/1073741824}')
      cache_j="{\"dir\":\"$(json_str "$cache_dir")\",\"bytes\":$cache_b,\"gib\":$cache_gib}"
      cache_line="$cache_dir ($cache_gib GiB)"
    fi
  fi
  if [ -n "$json" ]; then
    stack="не установлен"
    [ -x "$STACK_DIR/gfctl" ] && stack="установлен"
    have_dec=$(ram_pool_gib_dec)
    have="${have_dec%%.*}"
    gates=""
    for p in $PROFILE_LIST; do
      need=$(profile_field "$p" 2)
      if [ -n "$have" ] && [ "$have" -ge "$need" ]; then verdict="OK"; else verdict="НЕДОСТАТУПЕН"; fi
      gates="$gates\"$p\":\"$verdict\","
    done
    gates="${gates%,}"
    read -r p27 t27 m27 <<<"$(set_stats 27b)"
    read -r pf tf mf <<<"$(set_stats flash)"
    if [ "$p27" = "$t27" ]; then c27=true; else c27=false; fi
    if [ "$pf" = "$tf" ]; then cf=true; else cf=false; fi
    printf '{"profile":"%s","stack":"%s","bind":"%s","port":%s,"health":"%s","route":%s,"autostart":%s,"version":%s,"gates":{%s},"models":{"27b":{"present":%s,"total":%s,"complete":%s},"flash":{"present":%s,"total":%s,"complete":%s}},"cache":%s}\n' \
      "$(json_str "$prof")" "$(json_str "$stack")" "$(json_str "$bind")" "$port" \
      "$(json_str "$health")" "$route_j" "$auto_j" "$version_j" "$gates" \
      "$p27" "$t27" "$c27" "$pf" "$tf" "$cf" "$cache_j"
  else
    printf 'профиль: %s | health: %s | автозапуск: %s | роут: %s | кэш: %s | веса %s: %s/%s\n' \
      "$prof" "$health" "$auto_h" "$route_line" "$cache_line" "$set_name" "$present" "$total"
  fi
  return 0
}

# ── 1.2: install / use / logs / smoke / uninstall ───────────────────────────

# Назначение: cmd install — полная постановка сервера (идемпотентен; SPEC §3):
#   preflight-гейты (ОС Linux → die; GPU-ноды → die; RAM-гейт профиля
#   НЕДОСТАТУПЕН → die с цифрами; render-группа → WARN; gpu-lock (podman ps
#   непуст) → WARN «переключение руками», D3: без takeover; memlock-гейт по
#   порогу 8388608 kB (4.1-F2, EXP-008: в средах без pam_limits unlimited
#   недостижим, relogin ulimit не меняет): unlimited → PASS без WARN;
#   ≥ порога → limits.d-файл (для будущих relogin) + WARN «достаточно»,
#   install ПРОДОЛЖАЕТ; < порога или нечитаемый «?» → файл + WARN
#   «перелогинься» + exit 42 (ребут-код PLAN этапа 1; «?» — консервативно,
#   как раньше); canon_port слушает
#   наше → идемпотентный путь, слушает чужое → die) → ветка 4.1:
#   наш контейнер healthy (порт + running + load_completed в логе) → БЕЗ
#   recreate («healthy — recreate не нужен»: до-проверка весов SKIP, юниты
#   перегенерируются, автозапуск — НОЛЬ podman run; мёртвый/загружающийся
#   сервер → штатный путь ниже) → ensure_weights (ask, полные сеты — SKIP
#   без вопросов) → SPEC §3 probe-подбор контекста (4.2 п.1): мульти-профиль
#   (лестница есть) + НЕ healthy + канона пары нет → probe_context (лестница,
#   каждая попытка env-оверрайд, канон на диске не меняется; отказ всей
#   лестницы = die «это тоже результат», как в use); канон пары есть →
#   «probe пропущен»; single/healthy → поле 4 таблицы (write_canon не
#   регрессирует найденный ранее канон: ctx = probe > канон пары > поле 4) →
#   install_units (рендер юнитов — всегда, даже с
#   --no-autostart) → write_canon → контейнер: probe-путь УЖЕ поднят
#   (env-оверрайд) → wait_health без recreate (как use); healthy →
#   «recreate не нужен»; иначе container_up → wait_health 180 (роут
#   печатает) → smoke → --no-autostart? «автозапуск выключен» :
#   autostart_on. Повтор поверх работающего healthy = SKIP весов +
#   перерендер юнитов + автозапуск, контейнер не тронут.
#
# Побочные эффекты: веса (после ask), юнит-файлы, .env канона, каталог кэша,
#   контейнер (podman rm+run), limits.d-файл (sudo; пишется всегда, кроме
#   unlimited; exit 42 — только ml<8 GiB или «?»),
#   autostart (systemctl/linger) — по флагу.
#
# Ограничения/допущения: требует gpu_nodes_present/ram_gate_line (profiles.sh,
#   serve.sh), ensure_weights (models.sh), install_units (units.sh),
#   write_canon/canon_* (state.sh), container_up (serve.sh), wait_health/smoke
#   (health.sh), autostart_on (autostart.sh). --port/--bind/--models-dir
#   ставят ГЛОБАЛЫ диспетчера ДО write_canon (canon = актуальные значения);
#   exit 42 — штатный код «нужен ребут/перелогин» (PLAN), не отказ.
#
# @param 1..N: string[]     # --profile P | --port N | --bind A |
#   --models-dir D | --no-autostart (неизвестный флаг → die; N — isint)
# @stdout string            # ход этапов; роут + SMOKE: OK
# @returns integer          # 0 — установлен и здоров; 1/42 — отказы гейтов
#   (die/exit 42)
cmd_install() {
  local prof="$PROFILE_DEFAULT" no_autostart=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile)     prof=$(resolve_profile "${2:-}") || die "install: неизвестный профиль '${2:-}' — доступно: $PROFILE_LIST (алиасы single/multi/flash)"; shift 2 ;;
      --port)        isint "${2:-}" || die "install: --port ждёт число, получено '${2:-}'"; PORT="$2"; shift 2 ;;
      --bind)        BIND="${2:-}"; shift 2 ;;
      --models-dir)  MODELS_BASE="${2:-}"; shift 2 ;;
      --no-autostart) no_autostart=1; shift ;;
      *)             die "install: неизвестный аргумент '$1' — доступно: --profile P --port N --bind A --models-dir D --no-autostart" ;;
    esac
  done
  log "preflight: профиль $prof"
  [ "$(uname -s)" = "Linux" ] || die "нужна Linux-машина (Ubuntu/Debian), сейчас: $(uname -s)"
  gpu_nodes_present || die "нет /dev/kfd или /dev/dri/renderD* — GPU недоступен (preflight; проверь: gfctl doctor)"
  local gate; gate=$(ram_gate_line "$prof")
  case "$gate" in
    *": НЕДОСТАТУПЕН") die "RAM-гейт: $gate — отказ ДО трафика (SPEC §5)" ;;
    *": НЕИЗВЕСТНО")   die "RAM-гейт: $gate — MemTotal не читается" ;;
  esac
  echo "RAM-гейт: $gate"
  id -nG 2>/dev/null | tr ' ' '\n' | grep -qx render \
    || warn "юзер не в группе render — доступ к /dev/dri может отказать (на целевой машине: sudo usermod -aG render \$USER)"
  if command -v podman >/dev/null 2>&1; then
    local names; names=$(podman ps --format '{{.Names}}' 2>/dev/null || true)
    [ -n "$names" ] && warn "GPU может быть занят контейнерами: $(echo "$names" | tr '\n' ' ')— gfctl не делает takeover (D3): переключение движков руками (hfctl off / gfctl off)"
  fi
  # memlock-гейт по порогу ДОСТАТОЧНОСТИ (4.1-F2, EXP-008/FAEX), не по
  # «unlimited»: в средах без pam_limits (ssh + podman-run) unlimited
  # недостижим, а relogin ulimit не меняет — прежний гейт циклился
  # (install: файл+exit 42 ↔ uninstall: файл снесён). Порог 8388608 kB
  # (8 GiB) — нижняя граница: все живые окна (F20/F23 105 GiB, EXP-002..007
  # FAEX 1318060032 kB) грузили движок при ulimit кратно выше. ml=unlimited
  # → PASS без WARN; ml ≥ порога → файл (переза)писывается для будущих
  # relogin + WARN «достаточно», install ПРОДОЛЖАЕТ; ml < порога → файл +
  # WARN «перелогинься» + exit 42 (там relogin реально нужен); ml=«?»
  # (нечитаемый) → прежний exit 42 — консервативно: не зная лимита,
  # молча продолжать нельзя.
  local ml; ml=$(ulimit -l 2>/dev/null || echo "?")
  ml_write() {  # один и тот же файл во всех ветках гейта — ради будущих relogin
    printf '# gfctl: memlock unlimited для ROCm/podman (SPEC §2)\n* soft memlock unlimited\n* hard memlock unlimited\n' \
      | sudo tee /etc/security/limits.d/99-gfctl-memlock.conf >/dev/null
  }
  if [ "$ml" = "unlimited" ]; then
    :  # PASS без WARN
  elif [ "$ml" = "?" ]; then
    ml_write
    warn "memlock не читается (ulimit -l) — записан /etc/security/limits.d/99-gfctl-memlock.conf; ПЕРЕЛОГИНЬСЯ (или ребутни) и повтори gfctl install"
    exit 42
  elif [ "$ml" -ge 8388608 ]; then
    ml_write
    warn "memlock ${ml} kB — достаточно (порог 8388608 kB); limits.d/99-gfctl-memlock.conf перезаписан для будущих relogin"
  else
    ml_write
    warn "memlock ${ml} kB < порога 8388608 kB — записан /etc/security/limits.d/99-gfctl-memlock.conf; ПЕРЕЛОГИНЬСЯ (или ребутни) и повтори gfctl install"
    exit 42
  fi
  local healthy=0
  if port_open "$(canon_port)"; then
    if [ "$(container_state)" = running ]; then
      # 4.1 идемпотентность: наш контейнер + роут загружен = healthy →
      # recreate НЕ делаем (ноль podman run — сервер не трогаем);
      # порт наш, но роута нет (загружается/упал) — штатный recreate ниже.
      ROUTE_SPEC=""; ROUTE_SESSIONS=""; ROUTE_CTX=""; ROUTE_MODEL=""
      parse_route < <(podman logs "$CONTAINER" 2>&1)
      if [ -n "$ROUTE_SPEC" ]; then
        healthy=1
        echo "порт $(canon_port) держит наш контейнер, сервер healthy"
      else
        echo "порт $(canon_port) держит наш контейнер, но роут не загружен — штатный recreate ниже"
      fi
    else
      die "порт $(canon_port) уже слушает ЧУЖОЕ — освободи порт или выбери другой: gfctl install --port N"
    fi
  fi
  local set_name eff_sessions ctx probe_path=0 ladder
  set_name=$(profile_field "$prof" 1)
  eff_sessions=$(profile_field "$prof" 3)
  log "веса: сет $set_name"
  ensure_weights "$set_name" || die "веса сета $set_name не докачаны/битые — см. WARN выше (повтор: gfctl models download $set_name)"
  # SPEC §3 «probe-подбор контекста (для мульти-профилей)» (4.2 п.1, backlog
  # review 2.1): лестница есть (мульти), сервер ещё НЕ поднят (healthy-путь
  # идемпотентности не трогаем — 0 podman run) и канона пары нет (повторный
  # install не пере-перебирает найденное probe'ом, как и use). Порядок
  # SPEC-строки соблюдён: веса → probe → юниты → write_canon → старт.
  ladder=$(profile_field "$prof" 8)
  ctx=$(canon_pair_context "$prof" "$eff_sessions")
  if [ "$healthy" = 0 ] && [ -n "$ladder" ] && [ "$ladder" != "-" ] && [ -z "$ctx" ]; then
    log "install: канона пары ($prof × $eff_sessions) нет — probe-подбор по лестнице: $ladder"
    probe_context "$prof" "$eff_sessions"
    ctx="$PROBE_CTX"
    probe_path=1
  elif [ -n "$ctx" ]; then
    log "install: канон пары ($prof × $eff_sessions): context $ctx — probe пропущен"
  else
    ctx=$(profile_field "$prof" 4)
  fi
  install_units
  write_canon "$prof" "$eff_sessions" "$ctx"
  if [ "$healthy" = 1 ]; then
    echo "healthy — recreate не нужен (веса SKIP, юниты перегенерированы, podman run: 0)"
  elif [ "$probe_path" = 1 ]; then
    log "контейнер поднят probe-попыткой (env-оверрайд) — recreate не нужен, health сразу"
    wait_health 180
    smoke
  else
    log "старт контейнера (recreate = rm+run)"
    container_up "$prof"
    wait_health 180
    smoke
  fi
  if [ "$no_autostart" = 1 ]; then
    echo "автозапуск выключен (--no-autostart; включить: gfctl on)"
  else
    autostart_on
  fi
  echo "готово — проверь: gfctl status"
}

# ── 2.1: probe-подбор контекста (SPEC §1 п.6, §5, §9) ────────────────────────

PROBE_CTX=""   # контекст успешной probe-попытки (глобал для cmd_use, как ROUTE_* в health.sh)

# Назначение: строка попытки probe — ЖУРНАЛ ($PROBE_JOURNAL, append) + та же
#   строка в stdout («ступень X: …» — прогресс худшего случая 94 с × 5, F5).
#
# Побочные эффекты: допись строки в журнал и печать в stdout.
#
# Ограничения/допущения: зовётся только из probe_context (журнал открыт);
#   PROBE_JOURNAL не задан → ошибка ${:?} (не тихая потеря лога).
#
# @param 1..N: string[]     # текст строки (аргументы соединяются через "$*")
# @stdout string           # та же строка, что ушла в журнал
# @returns integer         # 0 при возврате — сбой печати/дописи ловит set -e
probe_log() { printf '%s\n' "$*" | tee -a "${PROBE_JOURNAL:?probe_log: журнал не открыт}"; }

# Назначение: probe-подбор контекста (SPEC §1 п.6, §5, §9; этап 2.1) — перебор
#   лестницы поля 8 профильной таблицы ПО УБЫВАНИЮ: каждая попытка поднимает
#   контейнер env-оверрайдом GFCTL_SESSIONS/GFCTL_CONTEXT (canon_get: env >
#   .env — канон на диске НЕ меняется ни при отказе попытки, ни при отказе
#   всего probe; вотчдог/boot после смерти probe поднимут прежнее) и ждёт
#   загрузку wait_load 180. Вердикты попытки: load_failed (ранний выход 20 с,
#   GFCTL_LOADFAIL_AFTER — решено в 1.2), таймаут 180с, успех (wait_load
#   rc 0 — «загрузилась»; /ready+smoke идут в общем флоу cmd_use). Успех
#   сверяется с заказом: ROUTE_CTX (факт из load_completed) ≠ заказанная
#   ступень → канон = ФАКТ + WARN, лестница СТОП (страховка 2.1-F4; урезаний
#   движок НЕ делает — F21: расхождение заказа с фактом наблюдено только со
#   старым кодом диспетчера на машине, EXP-006 без bootstrap).
#   Загрузившаяся ступень (или факт) → глобал PROBE_CTX + rc 0. Все отказали →
#   таблица попыток + хвосты движковых логов (журнал) в stderr + die с
#   подсказкой --context (sessions=4 →
#   --context 65536: floor 4×65536 проверен (F6), но 65536 в лестнице нет —
#   OQ-2a). Отказ podman run за GFCTL_RUN_ATTEMPTS — infra-отказ (занятый
#   порт и т.п.): container_up сам die, в таблицу попыток не попадает.
#
# Побочные эффекты: mkdir -p $LOGS_DIR; журнал попыток
#   $LOGS_DIR/probe-<профиль>-<sessions>.log (обнуляется на старте; probe_log
#   дублирует каждую строку в stdout; после ОТКАЗа ступени в журнал
#   дописывается хвост движкового лога — 4.2 п.2); podman rm/run на каждую
#   попытку (пауза F10 — встроенная в container_up); ПИШЕТ глобалы
#   PROBE_CTX/PROBE_JOURNAL.
#
# Ограничения/допущения: зовётся из cmd_use только когда канона пары нет и
#   --no-probe нет; лестница '-' → rc 1 без действий (вызов на single —
#   ошибка вызывающего); худший случай = 5 × (94–180 с) + паузы (F5/F13) —
#   прогресс печатается по ступеням, не hang.
#
# @param 1: profile_id      # канонический id профиля (лестница — поле 8)
# @param 2: /^[0-9]+$/      # sessions пары (адмиссия попыток; лестница та же)
# @stdout string            # строки попыток («ступень X: …»)
# @returns integer          # 0 — ступень загрузилась (PROBE_CTX задан);
#   1 — лестницы нет; die (exit 1) при полном отказе лестницы
probe_context() {
  local prof="$1" sessions="$2" ladder step verdict
  ladder=$(profile_field "$prof" 8)
  if [ -z "$ladder" ] || [ "$ladder" = "-" ]; then return 1; fi
  PROBE_CTX=""
  PROBE_JOURNAL="$LOGS_DIR/probe-${prof}-${sessions}.log"
  mkdir -p "$LOGS_DIR"
  : > "$PROBE_JOURNAL"
  for step in $ladder; do
    probe_log "ступень $step: попытка загрузки (sessions $sessions)"
    if GFCTL_SESSIONS="$sessions" GFCTL_CONTEXT="$step" container_up "$prof" && wait_load 180; then
      # 2.1-F4 — страховка «канон = факт» (EXP-006 evo): ROUTE_CTX заполнил
      # последний parse_route в wait_load; факт ≠ заказ → канон = ФАКТ,
      # лестницу не продолжаем: факт и есть фактическое состояние сервера.
      # ВАЖНО (F21, переписано): УРЕЗАНИЙ движок НЕ делает — проверена вся
      # цепочка gufo (serve → runner): только валидация с явным отказом,
      # load_completed печатает ровно заказанное; наблюдённое расхождение
      # (196608 → 163840) — СТАРЫЙ код диспетчера на машине (EXP-006, окно
      # до лейаута 4.4), не движок. факт > заказ невозможен, но
      # принимается так же (ветка симметрична).
      if [ -n "$ROUTE_CTX" ] && [ "$ROUTE_CTX" != "$step" ]; then
        probe_log "ступень $step: движок поднял фактический $ROUTE_CTX — принимаю факт"
        warn "probe: заказан контекст $step, сервер поднялся на $ROUTE_CTX — расхождение заказа с фактом; движок урезаний НЕ делает (F21: только валидация с явным отказом) — типичная причина: на машине старый код диспетчера, обнови дерево (git pull клона); канон $ROUTE_CTX, большие ступени лестницы не продолжаю"
        PROBE_CTX="$ROUTE_CTX"
        return 0
      fi
      PROBE_CTX="$step"
      probe_log "ступень $step: OK — канон"
      return 0
    fi
    if podman logs "$CONTAINER" 2>&1 | grep -q 'load_failed'; then
      verdict="load_failed (admission/отказ загрузки)"
    else
      verdict="таймаут 180с"
    fi
    probe_log "ступень $step: ОТКАЗ — $verdict"
    # 4.2 п.2: admission-цифры/причина отказа живут в движковом логе —
    # дописываем хвост в журнал (в stdout wait_load его уже показал), иначе
    # следующая попытка перезатирает лог контейнера и цифры теряются
    podman logs --tail 12 "$CONTAINER" 2>&1 | sed 's/^/  лог: /' >> "$PROBE_JOURNAL" || true
  done
  echo "попытки probe (журнал: $PROBE_JOURNAL):" >&2
  sed 's/^/  /' "$PROBE_JOURNAL" >&2
  if [ "$sessions" = 4 ]; then
    die "probe: все ступени лестницы отказали (профиль $prof × sessions $sessions) — это тоже результат (PLAN); 65536 в лестнице нет — задай вручную: gfctl use $prof --sessions 4 --context 65536"
  fi
  die "probe: все ступени лестницы отказали (профиль $prof × sessions $sessions) — это тоже результат (PLAN); задай контекст явно: gfctl use $prof --sessions $sessions --context N"
}

# Назначение: cmd use <профиль> — переключить профиль (SPEC §3; этап 2.1):
#   resolve (алиасы) → die при неизвестном; --sessions/--context — isint;
#   RAM-гейт целевого профиля → die при НЕДОСТАТУПЕН; ensure_weights
#   (ленивый добор) → выбор контекста (дерево решений, одно, без веток
#   «по настроению»): --context N задан → он (WARN и от --no-probe, если он
#   тоже задан — OQ-3); иначе canon_pair_context(prof, sessions): непуст +
#   нет --no-probe → «канон пары … — probe пропущен»; непуст + --no-probe →
#   WARN «беру канон пары»; пуст + --no-probe → WARN «беру последнюю
#   ступень лестницы» (загрузка НЕ проверена); пуст + лестница '-' → поле 4
#   таблицы (27b-single, как 1.2); иначе probe_context (перебор лестницы,
#   первая загрузившаяся ступень; при расхождении заказа с фактом канон =
#   фактический ROUTE_CTX — страховка 2.1-F4, урезаний движок не делает,
#   F21). Затем write_canon (ОБА представления:
#   активные поля + пара-ключ) → install_units (лейаут 4.4: юниты ставятся
#   при первом use — ПОСЛЕ записи канона, до него поднимать нечего;
#   идемпотентный рендер; enable/linger — только on/install) → контейнер:
#   probe-путь УЖЕ поднят попыткой
#   (env-оверрайд дал байт-в-байт ту же serve-строку) → wait_health сразу,
#   БЕЗ второго recreate (экономия до 94 с загрузки, F5); остальные пути —
#   container_up → wait_health 180 → smoke (порядок 1.2) → печать канона.
#
# Побочные эффекты: веса (после ask при недостающих), .env канона
#   (перезапись + пар-блок), журнал попыток logs/probe-<профиль>-<sessions>.log
#   (probe-путь), каталог кэша целевого профиля, контейнер (recreate на
#   не-probe путях), юнит-файлы в $UNIT_DIR (install_units, идемпотентно).
#
# Ограничения/допущения: порядок recreate → health → smoke фиксированный
#   (правило AGENTS); юниты перерендеряются идемпотентно (4.4: ставятся при
#   каждом use после канона; enable не трогается), serve-строка собирается
#   из канона в момент container_up/boot; повторный use с каноном пары =
#   ровно ОДНА загрузка (container_up единственный, пере-перебора нет);
#   probe НЕ пишет канон между попытками — отказ всех ступеней оставляет
#   прежний .env нетронутым; сбой health/smoke завершает процесс по set -e
#   (канон уже записан — повторный use докатит recreate).
#
# @param 1: profile_id|алиас # целевой профиль (unknown → die)
# @param 2..N: string[]      # --sessions N | --context N | --no-probe
# @stdout string             # ход этапов; попытки probe; роут + строка канона
# @returns integer           # 0 — переключено и здорово; 1 — отказы гейтов
cmd_use() {
  local prof a sessions="" context="" no_probe=0
  prof=$(resolve_profile "${1:-}") || die "use: неизвестный профиль '${1:-}' — доступно: $PROFILE_LIST (алиасы single/multi/flash)"
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --sessions)  isint "${2:-}" || die "use: --sessions ждёт число, получено '${2:-}'"; sessions="$2"; shift 2 ;;
      --context)   isint "${2:-}" || die "use: --context ждёт число, получено '${2:-}'"; context="$2"; shift 2 ;;
      --no-probe)  no_probe=1; shift ;;
      *)           die "use: неизвестный аргумент '$1' — доступно: --sessions N --context N --no-probe" ;;
    esac
  done
  log "use: профиль $prof"
  local gate; gate=$(ram_gate_line "$prof")
  case "$gate" in
    *": НЕДОСТАТУПЕН") die "RAM-гейт: $gate — отказ ДО трафика (SPEC §5)" ;;
    *": НЕИЗВЕСТНО")   die "RAM-гейт: $gate — MemTotal не читается" ;;
  esac
  echo "RAM-гейт: $gate"
  local set_name eff_sessions ctx probe_path=0 ladder
  set_name=$(profile_field "$prof" 1)
  ensure_weights "$set_name" || die "веса сета $set_name не докачаны (ленивый добор не удался)"
  eff_sessions="${sessions:-$(profile_field "$prof" 3)}"
  if [ -n "$context" ]; then
    ctx="$context"
    [ "$no_probe" = 1 ] && warn "--no-probe: контекст задан явно (--context $ctx) — перебор неуместен, беру $ctx (OQ-3)"
    log "контекст задан явно (--context $ctx) — probe пропущен"
  else
    ladder=$(profile_field "$prof" 8)
    ctx=$(canon_pair_context "$prof" "$eff_sessions")
    if [ -n "$ctx" ] && [ "$no_probe" = 0 ]; then
      log "канон пары ($prof × $eff_sessions): context $ctx — probe пропущен"
    elif [ -n "$ctx" ]; then
      warn "--no-probe: беру канон пары ($prof × $eff_sessions): context $ctx"
    elif [ "$no_probe" = 1 ]; then
      if [ "$ladder" = "-" ] || [ -z "$ladder" ]; then
        ctx=$(profile_field "$prof" 4)
      else
        ctx="${ladder##* }"
      fi
      warn "--no-probe: канона пары ($prof × $eff_sessions) нет — беру последнюю (минимальную) ступень лестницы $ctx, загрузка НЕ проверена (повтори без --no-probe для probe-подбора)"
    elif [ "$ladder" = "-" ] || [ -z "$ladder" ]; then
      ctx=$(profile_field "$prof" 4)
    else
      log "канона пары ($prof × $eff_sessions) нет — probe-подбор по лестнице: $ladder"
      probe_context "$prof" "$eff_sessions"
      ctx="$PROBE_CTX"
      probe_path=1
    fi
  fi
  write_canon "$prof" "$eff_sessions" "$ctx"
  install_units   # лейаут 4.4: юниты при первом use (после канона; идемпотентно)
  if [ "$probe_path" = 1 ]; then
    log "контейнер поднят probe-попыткой (env-оверрайд) — recreate не нужен, health сразу"
    wait_health 180
  else
    log "старт контейнера (recreate = rm+run)"
    container_up "$prof"
    wait_health 180
  fi
  smoke
  echo "канон записан: профиль $prof, sessions $(canon_sessions "$prof"), context $(canon_context "$prof") (в $STACK_DIR/.env)"
}

# Назначение: cmd logs [-f] [N] — логи контейнера как есть: -f → follow,
#   числовой N → --tail N (дефолт 100). Контейнера нет → die.
#
# Побочные эффекты: печать podman logs (вывод как есть, без фильтрации).
#
# Ограничения/допущения: requires container_state (serve.sh); `podman logs
#   -f` не блокируется таймаутом — follow до Ctrl-C (как docker logs -f);
#   порядок флагов фиксированный: logs -f --tail N.
#
# @param 1..N: string[]      # -f и/или число (хвост)
# @stdout string             # вывод podman logs
# @returns integer           # rc podman; die при missing-контейнере
cmd_logs() {
  local follow="" tail_n="" a
  for a in "$@"; do
    case "$a" in
      -f) follow=1 ;;
      *)  isint "$a" || die "logs: аргумент '$a' — жду -f и/или число (хвост строк)" ;;
    esac
  done
  tail_n=""
  for a in "$@"; do case "$a" in -f) ;; *) tail_n="$a" ;; esac; done
  [ "$(container_state)" = missing ] && die "контейнера $CONTAINER нет — подними: gfctl up (или install/use)"
  if [ -n "$follow" ]; then
    podman logs -f --tail "${tail_n:-100}" "$CONTAINER"
  else
    podman logs --tail "${tail_n:-100}" "$CONTAINER"
  fi
}

# Назначение: cmd smoke — health-предикат + 3 запроса + роут из лога:
#   контейнер не running → die; иначе parse_route из лога → smoke (роут +
#   SMOKE: OK; rc 1 при отказе — die внутри smoke).
#
# Побочные эффекты: podman logs; http-запросы smoke; ROUTE_* глобалы.
#
# Ограничения/допущения: требует parse_route/smoke (health.sh) и
#   container_state (serve.sh); standalone-вызов ПОСЛЕ install/use/up —
#   ROUTE_MODEL берётся из лога живого контейнера, не из канона.
#
# @stdout string             # строки smoke (ответы/роут/SMOKE: OK)
# @returns integer           # 0 — SMOKE OK; die (1) при отказах
cmd_smoke() {
  local st; st=$(container_state)
  [ "$st" = running ] || die "контейнер $CONTAINER не запущен (state=$st) — подними: gfctl up"
  parse_route < <(podman logs "$CONTAINER" 2>&1)
  smoke
}

# ── 2.1: bench — фикстура merge_sort ×3 по HTTP (SPEC §3; F12) ───────────────

# Назначение: транспорт bench (изолирован в одной функции, task.md §4) —
#   POST тела $1 (готовая JSON-строка) на
#   http://127.0.0.1:<canon_port>/v1/completions, ответ в файл $2. Fallback
#   (OQ-1, оркестратор): /v1/completions на gufo факт-базой не подтверждён
#   (chat подтверждён, EXP-004) — при отказе completions тело переливается
#   python3 в chat-формат (prompt → messages[0],
#   chat_template_kwargs.enable_thinking=false — ближе к thinking-off
#   байтов фикстуры) и повторяется; числа теряют прямую сравнимость с
#   каноном 76.9 t/s (F12) — WARN печатается, факт — в FACTS после окна.
#
# Побочные эффекты: до 2 http-запросов; запись файла ответа $2 (перезапись);
#   WARN в stderr при fallback. Глобалы и файлы стека не трогает.
#
# Ограничения/допущения: curl -f (HTTP ≥ 400 = отказ → fallback); stderr
#   curl глушится; rc 1 = оба эндпоинта отказали (вызывающий die без
#   ретрая — ретрай = другая нагрузка).
#
# @param 1: string         # JSON-тело запроса (prompt/model/max_tokens/temperature)
# @param 2: string         # путь файла ответа (перезаписывается)
# @returns integer         # 0 — ответ получен; 1 — оба эндпоинта отказали
bench_request() {
  local body="$1" out="$2" url chat
  url="http://127.0.0.1:$(canon_port)/v1/completions"
  if printf '%s' "$body" | curl -fsS -m 300 -H 'Content-Type: application/json' -d @- "$url" > "$out" 2>/dev/null; then
    return 0
  fi
  warn "/v1/completions не ответил — fallback на /v1/chat/completions (числа теряют прямую сравнимость с каноном, F12 — зафиксируй в FACTS)"
  chat=$(printf '%s' "$body" | python3 -c 'import json,sys
d = json.load(sys.stdin)
d["messages"] = [{"role": "user", "content": d.pop("prompt")}]
d["chat_template_kwargs"] = {"enable_thinking": False}
sys.stdout.write(json.dumps(d))') || return 1
  url="http://127.0.0.1:$(canon_port)/v1/chat/completions"
  printf '%s' "$chat" | curl -fsS -m 300 -H 'Content-Type: application/json' -d @- "$url" > "$out" 2>/dev/null
}

# Назначение: cmd bench (SPEC §3; этап 2.1) — замер фикстуры merge_sort
#   (md5 253c7ac5, НЕ редактировать) на ЖИВОМ сервере: 1 прогрев + 3 замера
#   POST /v1/completions (prompt = байты фикстуры как есть, temperature 0,
#   max_tokens 256, одиночный запрос — НЕ параллелить, brief 2.1). Каждый
#   замер: wall (date +%s.%N вокруг curl, GNU-машины) +
#   usage.completion_tokens из ответа → «прогон N: wall X.Xs | M tok |
#   Y.Y tok/s»; сводка — медианы wall и tok/s (средние элементы sort -n).
#   Гейты по порядку: контейнер running → порт слушает → модель в логе
#   (parse_route) → md5-гейт фикстуры (F12: правка байтов теряет
#   сравнимость прогонов). Отказ запроса / битый JSON / пустой usage →
#   die БЕЗ ретрая.
#
# Побочные эффекты: подпроцессы podman logs/curl/python3/md5sum/awk/mktemp;
#   4 http-запроса генерации к модели; временный файл ответа (mktemp под
#   $TMPDIR, cleanup trap'ом EXIT — в диспетчере EXIT-trap больше никто
#   не ставит). Файлы стека не меняет.
#
# Ограничения/допущения: wall с одним знаком, деление на ноль защищено
#   (wall ≤ 0 → 1e-6); живой сервер поднимает gfctl use/on; лишние
#   аргументы → die.
#
# @param 1..N: string[]     # не предусмотрены (die)
# @stdout string            # прогрев-строка, 3 строки «прогон N: …», медиана
# @returns integer          # 0 при возврате — отказы завершают die (exit 1)
cmd_bench() {
  [ -n "${1:-}" ] && die "bench: лишние аргументы '$*' — команда без аргументов (фикстура и 3 прогона захардкожены)"
  [ "$(container_state)" = running ] || die "контейнер $CONTAINER не запущен (state=$(container_state)) — подними: gfctl on/use"
  port_open "$(canon_port)" || die "порт $(canon_port) мёртв — подними сервер: gfctl on/use"
  parse_route < <(podman logs "$CONTAINER" 2>&1)
  [ -n "$ROUTE_MODEL" ] || die "модель не загружена (в логе нет model= из load_completed) — сначала gfctl use"
  local fixture="$TPL_DIR/bench/merge_sort_thinking_off.txt"
  local canon_md5="253c7ac50857fe6d0e10fb0d2c5e35c0" got_md5
  got_md5=$(md5sum "$fixture" 2>/dev/null | awk '{print $1}')
  [ "$got_md5" = "$canon_md5" ] || die "фикстура bench изменена (md5 ${got_md5:-?} ≠ $canon_md5) — сравнимость прогонов потеряна (F12); верни канонный файл из репо"
  local body t0 t1 tok wall tps_v i
  resp=""   # НЕ локальная: EXIT-trap снимает файл ответа после выхода из функции
  body=$(python3 - "$fixture" "$ROUTE_MODEL" <<'PY'
import json, sys
prompt = open(sys.argv[1], "rb").read().decode("utf-8")  # байты фикстуры как есть
sys.stdout.write(json.dumps({"prompt": prompt, "model": sys.argv[2],
                             "max_tokens": 256, "temperature": 0}))
PY
) || die "bench: не собрать тело запроса (python3)"
  resp=$(mktemp "${TMPDIR:-/tmp}/gfctl-bench.XXXXXX")
  trap 'rm -f "$resp"' EXIT
  log "bench: фикстура merge_sort (md5 ok), модель $ROUTE_MODEL — прогрев + 3 замера"
  t0=$(date +%s.%N)
  bench_request "$body" "$resp" || die "bench: прогрев не ответил (оба эндпоинта) — сервер жив? смотри gfctl logs"
  t1=$(date +%s.%N)
  printf 'прогрев: wall %ss\n' "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')"
  local -a walls tps
  for i in 1 2 3; do
    t0=$(date +%s.%N)
    bench_request "$body" "$resp" || die "bench: прогон $i не ответил — без ретрая (ретрай = другая нагрузка, честный замер теряется)"
    t1=$(date +%s.%N)
    tok=$(python3 - "$resp" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
u = d.get("usage") or {}
print(u.get("completion_tokens") or "")
PY
) || tok=""
    [ -n "$tok" ] || die "bench: прогон $i — в ответе нет usage.completion_tokens (битый JSON/пустой usage) — без ретрая"
    read -r wall tps_v <<<"$(awk -v a="$t0" -v b="$t1" -v m="$tok" 'BEGIN{w=b-a; if (w<=0) w=0.000001; printf "%.1f %.1f", w, m/w}')"
    printf 'прогон %s: wall %ss | %s tok | %s tok/s\n' "$i" "$wall" "$tok" "$tps_v"
    walls+=("$wall"); tps+=("$tps_v")
  done
  printf 'медиана: wall %ss | %s tok/s\n' \
    "$(printf '%s\n' "${walls[@]}" | sort -n | sed -n 2p)" \
    "$(printf '%s\n' "${tps[@]}" | sort -n | sed -n 2p)"
}

# ── 3.1: cache (сводка кэша + --verify) и watch (дашборд) ────────────────────

# Назначение: ЧИСТЫЙ фильтр кэш-конфигурации — текст лога на stdin; берёт
#   ПОСЛЕДНЮЮ строку `event=configured` (формат живого лога FX-W1b:
#   «[cache] schema=component-cache-v1 event=configured sessions=1 …
#   capacity_bytes=… automatic_bytes=… disk_capacity_bytes=… ram_cache=on…»)
#   и пишет глобалы CC_SESSIONS/CC_CAPACITY/CC_DISK/CC_RAMCACHE/CC_AUTOMATIC
#   ('' = поля нет). Поля grep -oE с \b-границей (capacity_bytes не ловит
#   disk_capacity_bytes) + cut — паттерн parse_route. stdout пуст.
#
# Побочные эффекты: только чтение stdin и запись пяти глобалов.
#
# Ограничения/допущения: отсутствие строки — НОРМА (кэш не настроен/лог
#   пуст): глобалы '', rc 0 всегда; «последняя строка побеждает» (последний
#   recreate); форматы skipped/evicted НЕ разбираются здесь (в факт-базе
#   их нет — EXP-007 соберёт образцы, cmd_cache считает вхождения).
#
# @stdin string             # текст лога контейнера (podman logs 2>&1)
# @returns integer          # всегда 0
parse_configured() {
  local line
  CC_SESSIONS=""; CC_CAPACITY=""; CC_DISK=""; CC_RAMCACHE=""; CC_AUTOMATIC=""
  line=$(grep 'event=configured' 2>/dev/null | tail -n 1) || true
  [ -n "$line" ] || return 0
  CC_SESSIONS=$(printf '%s\n' "$line" | grep -oE 'sessions=[0-9]+' | tail -n 1 | cut -d= -f2-) || true
  CC_CAPACITY=$(printf '%s\n' "$line" | grep -oE '\bcapacity_bytes=[0-9]+' | tail -n 1 | cut -d= -f2-) || true
  CC_DISK=$(printf '%s\n' "$line" | grep -oE '\bdisk_capacity_bytes=[0-9]+' | tail -n 1 | cut -d= -f2-) || true
  CC_RAMCACHE=$(printf '%s\n' "$line" | grep -oE '\bram_cache=(on|off)' | tail -n 1 | cut -d= -f2-) || true
  CC_AUTOMATIC=$(printf '%s\n' "$line" | grep -oE '\bautomatic_bytes=[0-9]+' | tail -n 1 | cut -d= -f2-) || true
  return 0
}

# Назначение: тип файловой системы каталога (аргумент) — `stat -f -c %T`
#   (tmpfs-детект cache --verify: disk-тир на tmpfs переживает только до
#   ребута). Обёртка ради батареи: faux stat подкладывается через PATH.
#
# Побочные эффекты: подпроцесс stat; печать типа в stdout ('' = сбой stat).
#
# Ограничения/допущения: GNU stat (целевые машины — GNU); сбой/неизвестная
#   ФС → пустая строка, не краш; сравнение с 'tmpfs' — на вызывающем.
#
# @param 1: string          # путь каталога
# @stdout string            # тип ФС (ext4/btrfs/tmpfs/…) или ''
# @returns integer          # всегда 0 (сбой stat заглушен)
fs_type() {
  stat -f -c %T "$1" 2>/dev/null || true
}

# Назначение: контрольная часть `gfctl cache --verify` (вызывается из
#   cmd_cache; порядок фиксированный): (1) контрольный follow-up — python
#   cacheverify1 (doc 5k → q1 → follow-up по тому же разговору), вердикт
#   по reuse из тела ответа: live|disk → PASS, none → die «проверь
#   --cache-ram-bytes» (rc 1); (2) tmpfs-детект — fs_type кэш-каталога,
#   tmpfs → WARN; (3) рестарт-проба — warn до recreate → container_up
#   (канон текущего профиля) → wait_health 180 → python cacheverify2
#   (ход того же разговора; состояние $LOGS_DIR/cache-verify.json):
#   reuse live|disk → PASS «disk-restore работает (X.Xs)», иначе FAIL
#   (rc 1 через return — set -e диспетчера завершает процесс).
#
# Побочные эффекты: до 3 http-запроса генерации; podman logs/rm/run
#   (рестарт УБИВАЕТ активные сессии — warn до recreate); запись/удаление
#   cache-verify.json; ROUTE_* глобалы.
#
# Ограничения/допущения: требует ROUTE_MODEL (parse_route здесь —
#   follow-up/restore ходят с именем из load_completed, F20); rc 1 (FAIL
#   restore) поднимается через return вызывающему (cmd_cache → роутер).
#
# @param 1: profile_id      # канон текущего профиля (рестарт поднимает его)
# @stdout string            # человекочитаемые строки каждого шага
# @returns integer          # 0 — follow-up и restore PASS; 1 — restore FAIL
#   (die при follow-up FAIL/структурных провалах)
cache_verify() {
  local prof="$1" state="$LOGS_DIR/cache-verify.json" out reuse w
  mkdir -p "$LOGS_DIR"
  parse_route < <(podman logs "$CONTAINER" 2>&1)
  [ -n "$ROUTE_MODEL" ] || die "cache --verify: модель не загружена (в логе нет model= из load_completed) — сначала gfctl use"
  echo "-- verify: контрольный follow-up (doc 5k → q1 → follow-up, reuse из тела ответа)"
  out=$(GFCTL_AGENT_STATE="$state" python3 "$TPL_DIR/python/agent_check.py" cacheverify1 "$(canon_port)" "$ROUTE_MODEL") \
    || die "cache --verify: follow-up структурно не прошёл — причина в stderr выше"
  printf '%s\n' "$out"
  reuse=$(grep '^CHECK cacheverify ' <<<"$out" | grep -oE 'reuse=[a-z]+' | head -n1 | cut -d= -f2-) || true
  case "$reuse" in
    live|disk) echo "PASS: follow-up переиспользовал кэш (reuse=$reuse)" ;;
    *) die "cache --verify: follow-up не переиспользовал кэш (reuse=${reuse:-?}) — проверь --cache-ram-bytes (SPEC §3)" ;;
  esac
  if [ "$(fs_type "$STACK_DIR/cache/$prof")" = "tmpfs" ]; then
    warn "кэш-каталог $STACK_DIR/cache/$prof на tmpfs — disk-тир переживает только до ребута"
  fi
  warn "cache --verify: рестарт ПЕРЕЗАПУСКАЕТ контейнер — активные сессии сервера будут потеряны (рестарт поднимает канон профиля $prof)"
  echo "-- verify: рестарт-проба (проверяет disk-тир кэша)"
  container_up "$prof"
  wait_health 180
  out=$(GFCTL_AGENT_STATE="$state" python3 "$TPL_DIR/python/agent_check.py" cacheverify2 "$(canon_port)" "$ROUTE_MODEL") \
    || die "cache --verify: restore-ход структурно не прошёл — причина в stderr выше"
  printf '%s\n' "$out"
  rm -f "$state"
  reuse=$(grep '^CHECK restore ' <<<"$out" | grep -oE 'reuse=[a-z]+' | head -n1 | cut -d= -f2-) || true
  w=$(grep '^CHECK restore ' <<<"$out" | grep -oE 'turn2=[0-9.]+' | head -n1 | cut -d= -f2-) || true
  if [ "$reuse" = "live" ] || [ "$reuse" = "disk" ]; then
    echo "PASS: disk-restore работает (${w:-?}s, reuse=$reuse)"
    return 0
  fi
  echo "FAIL: disk-restore не сработал (reuse=${reuse:-?}) — проверь --cache-disk и файловую систему кэш-каталога"
  return 1
}

# Назначение: cmd cache [--verify] — сводка кэша (rc 0 всегда, как doctor):
#   каталог кэша профиля + du -sb (как status) → parse_configured из лога
#   (configured: sessions/ram-cache/capacity/automatic/disk в GiB; строки
#   нет — «кэш не настроен», норма) → счётчики skipped/evicted — grep -c
#   вхождения БЕЗ разбора формата (EXP-007 соберёт образцы) → /metrics
#   llamacpp:prompt_tokens_cached_total (ключ подтверждён FX-W5; нет
#   ключа/эндпоинта → «?», НЕ фатально). --verify → cache_verify (см.
#   выше; её rc 1 = rc команды). Лишние аргументы → die.
#
# Побочные эффекты: podman logs/curl/du/awk-подпроцессы; при --verify —
#   всё из cache_verify (включая рестарт контейнера). Файлы стека не
#   меняет (кроме state-файла cache-verify.json в --verify).
#
# Ограничения/допущения: мёртвый порт/контейнер → пустые логи и «?» по
#   /metrics — сводка честная, rc 0; порт — canon_port (curl), контейнер —
#   CONTAINER (podman logs).
#
# @param 1: [--verify]      # единственный допустимый аргумент
# @stdout string            # строки сводки (+ шаги verify)
# @returns integer          # 0 — сводка (и PASS verify); 1 — FAIL verify
cmd_cache() {
  local verify=0
  case "${1:-}" in
    "")       ;;
    --verify) verify=1 ;;
    *)        die "cache: неизвестный аргумент '${1:-}' — доступно: --verify" ;;
  esac
  [ -n "${2:-}" ] && die "cache: лишние аргументы после '${1:-}' — доступно: --verify"
  local prof; prof=$(cur_profile)
  local cache_dir="$STACK_DIR/.data/cache/$prof" cache_b="" cache_gib=""
  echo "== gfctl cache — сводка кэша (профиль $prof)"
  if [ -d "$cache_dir" ]; then
    cache_b=$(du -sb "$cache_dir" 2>/dev/null | awk '{print $1}') || true
    [ -n "$cache_b" ] && cache_gib=$(awk -v b="$cache_b" 'BEGIN{printf "%.1f", b/1073741824}')
  fi
  echo "каталог: $cache_dir (${cache_gib:-0.0} GiB)"
  parse_configured < <(podman logs "$CONTAINER" 2>/dev/null)
  if [ -n "$CC_CAPACITY" ]; then
    printf 'configured: sessions %s | ram-cache %s | capacity %s GiB | automatic %s GiB | disk %s GiB\n' \
      "${CC_SESSIONS:-?}" "${CC_RAMCACHE:-?}" \
      "$(awk -v b="$CC_CAPACITY" 'BEGIN{printf "%.1f", b/1073741824}')" \
      "$(awk -v b="${CC_AUTOMATIC:-0}" 'BEGIN{printf "%.1f", b/1073741824}')" \
      "$(awk -v b="${CC_DISK:-0}" 'BEGIN{printf "%.1f", b/1073741824}')"
  else
    echo "configured: строки event=configured в логе нет (кэш не настроен или лог пуст)"
  fi
  local skipped evicted cached="?" mt
  skipped=$(podman logs "$CONTAINER" 2>/dev/null | grep -c 'event=skipped') || true
  evicted=$(podman logs "$CONTAINER" 2>/dev/null | grep -c 'event=evict') || true
  echo "счётчики: skipped ${skipped:-0} | evicted ${evicted:-0} (вхождения в логе, формат не разбирается — EXP-007)"
  mt=$(curl -fsS -m 5 "http://127.0.0.1:$(canon_port)/metrics" 2>/dev/null \
    | awk '$1 == "llamacpp:prompt_tokens_cached_total" {print $2; exit}') || true
  [ -n "$mt" ] && cached="$mt"
  echo "/metrics llamacpp:prompt_tokens_cached_total: $cached (best-effort)"
  [ "$verify" = 1 ] || return 0
  cache_verify "$prof"
}

# Назначение: cmd watch [--interval N] — живой дашборд (SPEC §3/§8): bash
#   ТОЛЬКО разбирает --interval N|--interval=N (дефолт 2; целое ≥1, иначе
#   die — паттерн hfctl cmd_watch 1:1) и exec python3
#   tpl/python/watch_tui.py с env GFCTL_WATCH_PORT/INTERVAL/CONTAINER
#   (argv не используется — python сам решает TUI/plain по isatty);
#   rc = rc python.
#
# Побочные эффекты: exec заменяет процесс диспетчера python-харнесом
#   (далее — всё из watch_tui.py: /metrics, host /proc+/sys, podman logs).
#
# Ограничения/допущения: model в python приходит из лога (load_completed
#   в сиде podman logs), не из .env — из env передаются только
#   порт/интервал/контейнер; GFCTL_WATCH_TICKS (батарейный шов) проходит
#   сквозь exec без правки.
#
# @param 1..N: string[]     # --interval N | --interval=N (дефолт 2 с)
# @stdout string            # весь вывод watch — из python
# @returns integer          # не возвращается — exec; ошибки аргументов: die
cmd_watch() {
  local usage="использование: gfctl watch [--interval N]" interval=2
  while [ $# -gt 0 ]; do
    case "$1" in
      --interval=*) interval="${1#*=}" ;;
      --interval)   [ $# -ge 2 ] || die "$usage"; interval="$2"; shift ;;
      *)            die "watch: неизвестный аргумент '$1' — $usage" ;;
    esac
    shift
  done
  isint "$interval" || die "watch: интервал должен быть целым числом секунд, получено '$interval'"
  [ "$interval" -ge 1 ] || die "watch: интервал должен быть ≥ 1 с"
  GFCTL_WATCH_PORT="$(canon_port)" GFCTL_WATCH_INTERVAL="$interval" \
  GFCTL_WATCH_CONTAINER="$CONTAINER" \
  exec python3 "$TPL_DIR/python/watch_tui.py"
}

# Назначение: cmd uninstall (v2, лейаут 4.4) — снять сервер, данные НЕ
#   трогать (данные — инвариант; дерево стека = git-клон пользователя):
#   ask (не-TTY без GFCTL_YES → rc 1 — снятие только с согласия) → слои ПО
#   ПОРЯДКУ: маркер+container_stop → disable+rm юнитов (serve+watchdog+
#   таймер)+daemon-reload → linger off → limits.d-файл (sudo rm — v2 снимает
#   его; вернётся при следующем install/use из memlock-гейта) → итоговая
#   сводка. Дерево $STACK_DIR (включая .data/ — модели/кэш/логи и канон
#   .env) и podman-образ НЕ трогаются никогда: полный снос — руками
#   (rm -rf клона + podman rmi). «Слоёный» снос дерева ~/gufo и приёмочных
#   ~/gfctl-acc* упразднён (4.4).
#
# Побочные эффекты: маркер остановки; контейнер удалён (podman rm -f);
#   юниты disabled и файлы удалены; linger off; limits.d-файл удалён
#   (sudo). Файлы клона и podman-хранилище не меняются.
#
# Ограничения/допущения: требует container_stop (serve.sh); ask — тот же
#   механизм согласия, что у весов (die при отказе/не-TTY); каждый
#   systemd/sudo-шаг заглушен — uninstall доходит до конца даже на машине
#   без работающего systemd; аргументы НЕ предусмотрены (лишний → die:
#   purge-флаги упразднены вместе со «слоёным» сносом).
#
# @param 1..N: string[]      # не предусмотрены (die)
# @stdout string             # ход слоёв + сводка
# @returns integer           # 0 — снятие выполнено; 1 — согласие не дано
cmd_uninstall() {
  [ -n "${1:-}" ] && die "uninstall: лишние аргументы '$*' — purge-флаги упразднены (лейаут 4.4): данные (.data/) и образ не удаляются — руками: rm -rf клона + podman rmi $IMAGE"
  ask "Снять gfctl-сервер (контейнер + юниты + watchdog + linger + limits.d; данные .data/ и образ НЕ трогаются)? [y/N] " \
    || die "uninstall отменён (снятие — только после согласия; повтори с --yes)"
  echo "слой 1/4: контейнер"
  mkdir -p "$STACK_DIR"; touch "$STOP_MARKER"
  container_stop
  echo "слой 2/4: юниты systemd-user (serve + watchdog + таймер)"
  systemctl --user disable "$UNIT_NAME-serve.service" "$UNIT_NAME-watchdog.timer" 2>/dev/null || true
  rm -f "$UNIT_DIR/$UNIT_NAME-serve.service" \
        "$UNIT_DIR/$UNIT_NAME-watchdog.service" \
        "$UNIT_DIR/$UNIT_NAME-watchdog.timer"
  systemctl --user daemon-reload 2>/dev/null || true
  echo "слой 3/4: linger"
  sudo loginctl disable-linger "${USER:-$(id -un)}" 2>/dev/null || true
  echo "слой 4/4: limits.d-файл"
  sudo rm -f /etc/security/limits.d/99-gfctl-memlock.conf
  echo "uninstall готов. Данные на месте ($STACK_DIR/.data), образ на месте ($IMAGE)."
  echo "Полный снос — руками: rm -rf \"$STACK_DIR\" (клон вместе с .data) + podman rmi $IMAGE. Вернуть: cd \"$STACK_DIR\" && ./gfctl use <профиль>"
}
