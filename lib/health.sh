# shellcheck shell=bash
# ── health: роут из лога (load_completed), http-проба /ready, смоук ─────────
# gufo не имеет hipfire-формата /health: роут читается из лога контейнера —
# ПОСЛЕДНЯЯ строка `event=load_completed` (формат подтверждён окнами IX/FX:
# «… speculative=dflash2 … sessions=1 context_tokens=262144 … model=…»);
# имена моделей gufo бывают С ПРОБЕЛАМИ (EXP-005 FAEX: «Qwen3.8 Flash Next»);
# http-проба — GET /ready. Смоук — 3 запроса чата, ретрай ЛЮБОГО пустого
# ответа РОВНО ОДИН раз через GFCTL_SMOKE_RETRY_S (дефолт 15 с, F15: прогрев
# ядер после recreate; EXP-006/2.1-F4: пустой бывает не только первым).
# Парсинг движковых строк изолирован в parse_route/http_ready — смена
# ревизии gufo правится в одном месте. Модуль читает CONTAINER (диспетчер),
# canon_port (state.sh), TPL_DIR; пишет глобалы ROUTE_SPEC/ROUTE_SESSIONS/
# ROUTE_CTX/ROUTE_MODEL; печатает через log/warn/die.

# Назначение: ЧИСТЫЙ фильтр роута — текст лога на stdin; берёт ПОСЛЕДНЮЮ
#   строку с `event=load_completed` и извлекает поля speculative=, sessions=,
#   context_tokens=, model= (grep -o + cut -d=; model= — подстрока между
#   «model=» и « sessions=», т.к. имена gufo содержат ПРОБЕЛЫ — EXP-005 FAEX;
#   sessions= присутствует в load_completed всегда). ПИШЕТ глобалы ROUTE_SPEC/
#   ROUTE_SESSIONS/ROUTE_CTX/ROUTE_MODEL ('' = совпадения нет). В stdout не
#   печатает.
#
# Побочные эффекты: только чтение stdin и запись четырёх глобалов.
#
# Ограничения/допущения: отсутствие load_completed — НОРМА (загрузка ещё
#   идёт): глобалы обнуляются, rc 0 всегда; все grep под set -e + pipefail
#   заглушены `|| true` (отсутствие совпадения — не ошибка); «последняя
#   строка побеждает» — роут из последнего recreate.
#
# @stdin string             # текст лога контейнера (podman logs 2>&1)
# @returns integer          # всегда 0
parse_route() {
  local line
  ROUTE_SPEC=""; ROUTE_SESSIONS=""; ROUTE_CTX=""; ROUTE_MODEL=""
  line=$(grep 'event=load_completed' 2>/dev/null | tail -n 1) || true
  [ -n "$line" ] || return 0
  ROUTE_SPEC=$(printf '%s\n' "$line" | grep -oE 'speculative=[^ ]+' | tail -n 1 | cut -d= -f2-) || true
  ROUTE_SESSIONS=$(printf '%s\n' "$line" | grep -oE 'sessions=[0-9]+' | tail -n 1 | cut -d= -f2-) || true
  ROUTE_CTX=$(printf '%s\n' "$line" | grep -oE 'context_tokens=[0-9]+' | tail -n 1 | cut -d= -f2-) || true
  # 2.1-F3: имя = подстрока между «model=» и « sessions=» — старый grep
  # 'model=[^ ]+' обрезал по пробелу («Qwen3.8» → 404 model_not_found;
  # EXP-005 FAEX: имена gufo содержат пробелы, sessions= есть всегда).
  # s///p печатает ТОЛЬКО при совпадении model= → нет совпадения ⇒ ''.
  ROUTE_MODEL=$(printf '%s\n' "$line" | sed -n 's/.*model=//p' | sed 's/sessions=.*//; s/[[:space:]]*$//')
  return 0
}

# Назначение: ждать загрузки модели — цикл с шагом GFCTL_HEALTH_POLL
#   (дефолт 5 с): `podman logs | parse_route`; ROUTE_SPEC непуст → печать
#   «загрузка завершена после Ns» + rc 0. Ранний выход: после
#   GFCTL_LOADFAIL_AFTER секунд (дефолт 20 — не ловить ложный load_failed
#   при старте podman) `grep load_failed` в логе → warn + хвост 30 строк +
#   rc 1 (без ожидания всего таймаута). Прогресс-печатка «жду загрузки… Ns»
#   каждую итерацию. Таймаут → warn + хвост логов + rc 1.
#
# Побочные эффекты: подпроцессы podman logs; sleep по шагу опроса; печать
#   прогресса в stdout, warn — в stderr; ПИШЕТ ROUTE_* глобалы (последний
#   parse_route — вызывающий smoke их читает).
#
# Ограничения/допущения: требует глобалы CONTAINER и хелперы log/warn
#   (диспетчер); таймаут — аргумент (живые вызовы: 180 install/use, 300 up);
#   батарея снижает шаг/порог переменными GFCTL_HEALTH_POLL/
#   GFCTL_LOADFAIL_AFTER. grep -q load_failed в if — отказ grep (нет
#   совпадения) не роняет set -e.
#
# @param 1: integer         # таймаут в секундах (дефолт 180)
# @returns integer          # 0 — load_completed найден; 1 — load_failed или
#   таймаут (подробности в stdout/stderr)
wait_load() {
  local t="${1:-180}" i=0 lf="${GFCTL_LOADFAIL_AFTER:-20}" poll="${GFCTL_HEALTH_POLL:-5}"
  log "жду загрузки модели (до ${t}с)"
  while [ "$i" -lt "$t" ]; do
    # process substitution, не пайп: parse_route пишет ROUTE_* в ТЕКУЩИЙ шелл
    # (правая часть пайпа — субшелл, глобалы бы потерялись)
    parse_route < <(podman logs "$CONTAINER" 2>&1)
    if [ -n "$ROUTE_SPEC" ]; then
      echo "загрузка завершена после ${i}с"
      return 0
    fi
    if [ "$i" -ge "$lf" ] && podman logs "$CONTAINER" 2>&1 | grep -q 'load_failed'; then
      warn "load_failed в логе контейнера (после ${i}с) — ранний выход, хвост логов:"
      podman logs --tail 30 "$CONTAINER" 2>&1 | tail -30 || true
      return 1
    fi
    echo "жду загрузки… ${i}с"
    sleep "$poll"; i=$((i + poll))
  done
  warn "модель не загрузилась за ${t}с — хвост логов:"
  podman logs --tail 30 "$CONTAINER" 2>&1 | tail -30 || true
  return 1
}

# Назначение: http-проба готовности — curl GET http://127.0.0.1:<canon_port>/
#   ready (эндпоинт подтверждён окнами IX), rc 0/1. Порт — canon_port
#   (env > .env > дефолт), НЕ сырой глобал.
#
# Побочные эффекты: подпроцесс curl (5 с таймаут); ничего не печатает.
#
# Ограничения/допущения: после load_completed сокету нужно время — вызывающий
#   wait_health поллит с ретраями; curl-отказ (tcp refused/timeout) = rc 1.
#
# @returns integer          # 0 — /ready ответил; 1 — отказ
http_ready() {
  curl -fsS -m 5 "http://127.0.0.1:$(canon_port)/ready" >/dev/null 2>&1
}

# Назначение: полный health = wait_load (загрузка движка) → поллинг
#   http_ready (шаг 2 с, до 30 с) → печать роута строкой
#   «роут: <spec>, sessions <n>, ctx <c>»; rc 1 при любом отказе (вызывающий
#   install/use завершается по set -e).
#
# Побочные эффекты: всё из wait_load/http_ready; печать роута в stdout.
#
# Ограничения/допущения: таймаут — аргумент (дефолт 180); ROUTE_* после
#   успеха заполнены (smoke читает ROUTE_MODEL); 30-секундный http-хвост
#   покрывает задержку сокета после load_completed.
#
# @param 1: integer         # таймаут wait_load в секундах (дефолт 180)
# @returns integer          # 0 — загрузка + http OK (роут напечатан);
#   1 — отказ любого этапа
wait_health() {
  local t="${1:-180}" i=0
  wait_load "$t" || return 1
  while [ "$i" -lt 30 ]; do
    if http_ready; then
      printf 'роут: %s, sessions %s, ctx %s\n' "$ROUTE_SPEC" "$ROUTE_SESSIONS" "$ROUTE_CTX"
      return 0
    fi
    sleep 2; i=$((i + 2))
  done
  warn "/ready не отвечает после load_completed (+30с) — смотри gfctl logs"
  return 1
}

# Назначение: экранирование строки для вставки в JSON-тело smoke-запроса
#   (4.3 п.3 / review 4.2 №4: имя модели из лога с «"»/«\» ломало JSON тела
#   запроса). Локальная копия json_str (commands.sh, 4.2 п.6): health.sh
#   source'ится РАНЬШЕ commands.sh и не должен от него зависеть; имя другое,
#   чтобы канон-функция не переопределялась при полной сборке диспетчера.
#
# Побочные эффекты: только печать в stdout; ничего не меняет.
#
# Ограничения/допущения: чистая функция; прочие управляющие символы (< 0x20)
#   не экранируются (как в json_str — живой источник спецсимволов — имена
#   gufo: пробелы/кавычки, F20).
#
# @param 1: string    # исходная строка
# @stdout string     # содержимое JSON-строки (БЕЗ обрамляющих кавычек)
# @returns integer   # всегда 0
json_escape() {
  local s="$1"
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}
  printf '%s' "$s"
}

# Назначение: смоук-проверка живого сервера — 3 запроса POST
#   /v1/chat/completions (curl -m 300; код / проза / математика) с
#   "model" = ROUTE_MODEL (имя движка из load_completed; пуст → die
#   «health не выполнен»). РЕТРАЙ ЛЮБОГО запроса РОВНО ОДИН раз (2.1-F4,
#   EXP-006: пустой ВТОРОЙ ответ валил смоук намертво): пустой ответ →
#   warn + пауза GFCTL_SMOKE_RETRY_S (дефолт 15 с, F15) + повтор ТОГО ЖЕ
#   запроса; второй пустой подряд — провал. Ответ валиден, если
#   tpl/python/smoke_resp.py извлёк непустой content. Успех → печать
#   роута + «SMOKE: OK»; провал → die (rc 1).
#
# Побочные эффекты: до 6 http-запросов генерации к модели на
#   127.0.0.1:<canon_port>; подпроцессы curl/python3; sleep ретрая; строки
#   «ответ: …» от smoke_resp.py в stdout, warn — в stderr. Файлы не меняет.
#
# Ограничения/допущения: требует globals ROUTE_* (заполняет wait_load/
#   parse_route вызывающего) и TPL_DIR; ROUTE_MODEL экранируется json_escape
#   в JSON тела (4.3 п.3); промпты независимы — провал одного
#   не мешает остальным; провал — die(): процесс завершается с кодом 1.
#   Худший бюджет — 3×2×(300+15) с — интерактивные вызывающие
#   (install/use/smoke).
#
# @returns integer          # всегда 0 при возврате — провал завершает
#   процесс через die() (exit 1)
smoke() {
  [ -n "${ROUTE_MODEL:-}" ] || die "смоук: health не выполнен (в логе нет model= из load_completed) — сначала gfctl install/use/up"
  log "смоук: 3 запроса"
  local ok=1 n=0 prompt try out
  for prompt in \
    "Напиши одну строку python: print('hello world')" \
    "Ответь ровно: ок" \
    "Сколько будет 2+2? Ответь одним числом."
  do
    n=$((n + 1))
    try=0
    while :; do
      try=$((try + 1))
      if out=$(curl -fsS -m 300 "http://127.0.0.1:$(canon_port)/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"$(json_escape "$ROUTE_MODEL")\",\"messages\":[{\"role\":\"user\",\"content\":\"$prompt\"}],\"max_tokens\":200}" 2>/dev/null) && \
         printf '%s' "$out" | python3 "$TPL_DIR/python/smoke_resp.py"; then
        break
      fi
      # ретрай ЛЮБОГО запроса ровно 1 раз (2.1-F4, EXP-006: пустой ВТОРОЙ
      # ответ валил смоук намертво; прогрев F15 бывает на любом запросе)
      if [ "$try" -ge 2 ]; then ok=0; break; fi
      warn "смоук-запрос $n не ответил содержимым — повторяю через ${GFCTL_SMOKE_RETRY_S:-15}с"
      sleep "${GFCTL_SMOKE_RETRY_S:-15}"
    done
  done
  printf 'роут: %s, sessions %s, ctx %s\n' "$ROUTE_SPEC" "$ROUTE_SESSIONS" "$ROUTE_CTX"
  [ "$ok" = 1 ] || die "смоук не прошёл — смотри 'gfctl logs'"
  echo "SMOKE: OK"
}
