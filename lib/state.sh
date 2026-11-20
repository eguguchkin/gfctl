# shellcheck shell=bash
# ── канон профиля: $STACK_DIR/.env (SPEC §4: boot-юнит и вотчдог поднимают
# канон, ничего не пересчитывая) ─────────────────────────────────────────────
# Формат canon: KEY=VALUE построчно (grep-парсинг, как cur_profile 1.1).
# Ключи: GFCTL_PROFILE, GFCTL_SESSIONS, GFCTL_CONTEXT, GFCTL_PORT, GFCTL_BIND,
# GFCTL_MODELS (база весов), GFCTL_IMAGE, а с этапа 2.1 — каноны ПАР
# GFCTL_CTX_<профиль_без_дефисов>_<sessions> (чтение canon_pair_context;
# write_canon пишет пару-ключ поверх активных полей — ОБА представления
# согласованы всегда; переключение 2↔4 сессий не теряет найденные контексты).
# Приоритет чтения:
#   процесс-env (явный оверрайд) > .env > дефолт диспетчера/таблицы —
# тогда `GFCTL_PORT=8198 gfctl status` работает без .env, а
# `install --port 8090` живёт через записанный .env. Единственный писатель
# .env — write_canon (атомарно: .env.tmp + mv; вотчдог/boot не читают полуфайл).
# Модуль читает STACK_DIR/PORT/BIND/MODELS_BASE/IMAGE/TPL_DIR (диспетчер),
# render_tpl (lib/units.sh), profile_field (lib/profiles.sh).

# Назначение: прочитать ключ канона с приоритетом «env > .env > default»:
#   непустой process-env $KEY → он; иначе последняя строка KEY=… в
#   $STACK_DIR/.env; иначе default (аргумент 2, обычно дефолт диспетчера
#   или поле профильной таблицы).
#
# Побочные эффекты: только печать значения в stdout; читает $STACK_DIR/.env
#   (отсутствие файла — норма, дефолт); файлы и env не меняет.
#
# Ограничения/допущения: имя ключа — GFCTL_* (env-переменная читается
#   indirect-раскрытием ${!key}); пустое значение в .env (`KEY=`) трактуется
#   как «нет значения» → default; grep-парсинг — то же семантика, что у
#   cur_profile 1.1 (последнее совпадение побеждает).
#
# @param 1: GFCTL_*        # имя ключа канона (и env-переменной)
# @param 2: string         # значение-дефолт
# @stdout string           # значение канона (env > .env > default)
# @returns integer         # всегда 0 — финальный printf
canon_get() {
  local key="$1" def="$2" v
  v="${!key:-}"
  [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }
  v=$(grep "^$key=" "$STACK_DIR/.env" 2>/dev/null | tail -n 1 | cut -d= -f2-) || true
  printf '%s\n' "${v:-$def}"
}

# Назначение: sessions канона профиля — GFCTL_SESSIONS (env/.env), дефолт —
#   поле 3 профильной таблицы (константа профиля до probe этапа 2).
#
# Побочные эффекты: только печать в stdout (через canon_get).
#
# Ограничения/допущения: prof — канонический id (resolve_profile на
#   вызывающем); overrides --sessions живут в .env после write_canon.
#
# @param 1: profile_id      # канонический id профиля
# @stdout /^[0-9]+$/        # число сессий
# @returns integer          # всегда 0
canon_sessions() { canon_get GFCTL_SESSIONS "$(profile_field "$1" 3)"; }

# Назначение: context канона профиля — GFCTL_CONTEXT (env/.env), дефолт —
#   поле 4 профильной таблицы (проверенная точка до probe этапа 2).
#
# Побочные эффекты: только печать в stdout (через canon_get).
#
# Ограничения/допущения: как canon_sessions.
#
# @param 1: profile_id      # канонический id профиля
# @stdout /^[0-9]+$/        # токенов контекста
# @returns integer          # всегда 0
canon_context() { canon_get GFCTL_CONTEXT "$(profile_field "$1" 4)"; }

# Назначение: канон контекста ПАРЫ (профиль × sessions) — этап 2.1: плоский
#   ключ GFCTL_CTX_<профиль_без_дефисов>_<sessions> (дефисы → подчёркивания:
#   27b-multi × 2 → GFCTL_CTX_27b_multi_2). Приоритет чтения однозначный:
#   1) canon_get пары-ключа (env-оверрайд > .env — механика canon_get);
#   2) 1.2-совместимость («миграция чтением»): активные поля канона
#      GFCTL_PROFILE==prof И GFCTL_SESSIONS==sessions → GFCTL_CONTEXT —
#      .env формата 1.2 (EXP-004) продолжает работать как канон пары;
#   3) иначе пусто (канона пары нет → вызывающий запускает probe-подбор).
#
# Побочные эффекты: только печать значения в stdout; читает $STACK_DIR/.env
#   (через canon_get) и профильную таблицу; файлы и env не меняет.
#
# Ограничения/допущения: prof — канонический id (resolve_profile на
#   вызывающем); sessions — число (isint на вызывающем). Env-оверрайд пары —
#   носитель probe-попыток: probe_context поднимает попытки через
#   GFCTL_CONTEXT=<ступень>, НЕ записывая .env между попытками.
#
# @param 1: profile_id      # канонический id профиля
# @param 2: /^[0-9]+$/      # sessions пары
# @stdout /^[0-9]*$/        # context пары (пустая строка = канона пары нет)
# @returns integer          # всегда 0 — финальный printf
canon_pair_context() {
  local prof="$1" sessions="$2" norm key ctx
  norm=$(printf '%s' "$prof" | tr '-' '_')
  key="GFCTL_CTX_${norm}_${sessions}"
  ctx=$(canon_get "$key" "")
  [ -n "$ctx" ] && { printf '%s\n' "$ctx"; return 0; }
  if [ "$(canon_get GFCTL_PROFILE "")" = "$prof" ] \
     && [ "$(canon_get GFCTL_SESSIONS "$(profile_field "$prof" 3)")" = "$sessions" ]; then
    ctx=$(canon_get GFCTL_CONTEXT "")
  fi
  printf '%s\n' "$ctx"
}

# Назначение: порт канона — GFCTL_PORT (env/.env), дефолт — глобал PORT
#   диспетчера (D2: 8080). ВСЕ runtime-потребители порта (serve/http/smoke/
#   logs/status) идут через canon_port, не через сырой глобал.
#
# Побочные эффекты: только печать в stdout.
#
# Ограничения/допущения: без параметров; значение — цифры (пишет write_canon).
#
# @stdout /^[0-9]+$/        # порт
# @returns integer          # всегда 0
canon_port() { canon_get GFCTL_PORT "$PORT"; }

# Назначение: адрес bind канона — GFCTL_BIND (env/.env), дефолт — глобал
#   BIND (0.0.0.0, LAN без ключа).
#
# Побочные эффекты: только печать в stdout.
#
# Ограничения/допущения: без параметров.
#
# @stdout string            # адрес (по умолчанию 0.0.0.0)
# @returns integer          # всегда 0
canon_bind() { canon_get GFCTL_BIND "$BIND"; }

# Назначение: записать канон профиля в $STACK_DIR/.env — render
#   tpl/env/env.tpl во $STACK_DIR/.env.tmp + mv (атомарная замена: параллельный
#   читатель — вотчдог/boot — не видит полуфайл). port/bind/models/image —
#   из актуальных глобалов диспетчера (install/use ставят их из аргументов
#   ДО вызова). Полная перезапись: единственный писатель .env.
#   Этап 2.1: КРОМЕ активных полей шаблона пишется канон ПАРЫ — к .env.tmp
#   дописываются все строки ^GFCTL_CTX_ из прежнего .env КРОМЕ ключа этой
#   пары + актуальная GFCTL_CTX_<профиль>_<sessions>=<context> (upsert:
#   чужие пары сохраняются, дублей ключа не бывает; каждое успешное use
#   пишет ОБА представления — читатели 1.2 и canon_pair_context согласованы).
#
# Побочные эффекты: mkdir -p $STACK_DIR; ПЕРЕЗАПИСЬ $STACK_DIR/.env
#   (через временный .env.tmp + mv -f, inode меняется). В stdout не печатает.
#
# Ограничения/допущения: требует render_tpl (units.sh; die на нераскрытых
#   плейсхолдерах) и глобалы STACK_DIR/TPL_DIR/PORT/BIND/MODELS_BASE/IMAGE.
#   sessions/context — аргументами (вызывающий решает: таблица или
#   пользовательский оверрайд); ручные правки .env теряются (шапка шаблона
#   напоминает про install/use); пары из старого .env переносятся (grep по
#   ^GFCTL_CTX_; отсутствие .env — норма).
#
# @param 1: profile_id      # канонический id профиля
# @param 2: /^[0-9]+$/      # sessions канона
# @param 3: /^[0-9]+$/      # context канона (токенов)
# @returns integer          # 0 при возврате — die render_tpl и сбой mv
#   завершают процесс по set -e
write_canon() {
  local prof="$1" sessions="$2" context="$3" norm key
  norm=$(printf '%s' "$prof" | tr '-' '_')
  key="GFCTL_CTX_${norm}_${sessions}"
  mkdir -p "$STACK_DIR"
  render_tpl "$TPL_DIR/env/env.tpl" "$STACK_DIR/.env.tmp" \
    MODELS_DIR="$MODELS_BASE" SESSIONS="$sessions" PROFILE="$prof" \
    CONTEXT="$context" IMAGE="$IMAGE" PORT="$PORT" BIND="$BIND"
  { grep '^GFCTL_CTX_' "$STACK_DIR/.env" 2>/dev/null | grep -v "^$key=" || true; } >> "$STACK_DIR/.env.tmp"
  printf '%s=%s\n' "$key" "$context" >> "$STACK_DIR/.env.tmp"
  mv -f "$STACK_DIR/.env.tmp" "$STACK_DIR/.env"
}
