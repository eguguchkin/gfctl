# shellcheck shell=bash
# ── agent-check: агентская самопроверка живого сервера (SPEC §7; этап 3.1) ──
# 4 проверки на 25 детерминированных POST /v1/chat/completions: (а) сессия
# 15 ходов (doc ~6.6k + Q→A, greedy, 128 ток, reasoning off) — total wall;
# (б) follow-up-лестница 5k/25k/100k — turn2 wall; (в) [док 25k][q1]→[q2] —
# q2 wall (кэш-эффект); (г) рестарт-restore — ход того же разговора ПОСЛЕ
# recreate (проверяет cache-disk). HTTP/математика — python
# (tpl/python/agent_check.py, transport через curl из PATH — faux-bin-шов
# батареи), оркестрация/референсы/rc — здесь. Тайминги читаются ИЗ ТЕЛА
# ОТВЕТА (timings/component_cache — протокол окон FX/CX), парсинг логов для
# цифр не нужен. Сравнение с референсами — ЧИСТАЯ функция cmp_ref (±25% →
# WARN); неснятый референс — WARN «эталон не снят», НЕ FAIL. rc: 0 при
# all-PASS и при WARN, 1 при FAIL (WARN ≠ FAIL; структурный провал — die
# до сводки). Модуль читает CONTAINER/STACK_DIR/TPL_DIR/LOGS_DIR
# (диспетчер), canon_*/container_state/container_up (serve/state),
# parse_route/wait_health (health), ref_get/cur_profile (profiles);

# Назначение: ЧИСТОЕ сравнение замера с референсом — вердикт-строка в
#   stdout: ref пуст → «WARN: <метка> X.Xs — референс не снят (EXP-007)»;
#   measured ≤ ref×1.25 → «PASS: <метка> X.Xs (референс Y.Ys)»; иначе
#   «WARN: <метка> X.Xs — регрессия >25% к Y.Ys» + « (<hint>)» если hint
#   задан (подсказка причины SPEC §7 п.5 — только follow-up/restore).
#
# Побочные эффекты: только печать в stdout; файлов, глобалов и env не
#   касается (батарея тестирует без HTTP).
#
# Ограничения/допущения: float-сравнение через awk (1 знак при печати);
#   measured пуст/нечисловой — вердикт-строку НЕ ставит вызывающий
#   (структурный провал → die до сводки, здесь печатается как есть);
#   ФЕЙЛ-веток нет: FAIL — только семантика reuse/структуры на вызывающем.
#
# @param 1: string          # метка проверки (в вердикт-строку)
# @param 2: string          # measured, секунды (число от python)
# @param 3: string          # референс, секунды ('' = не снят)
# @param 4: string          # (опц.) подсказка причины в хвост WARN-регрессии
# @stdout string            # «PASS: …» | «WARN: …»
# @returns integer          # всегда 0 — чистая функция
cmp_ref() {
  local label="$1" measured="$2" ref="$3" hint="${4:-}" mf rf
  mf=$(awk -v m="$measured" 'BEGIN{printf "%.1f", m}')
  if [ -z "$ref" ]; then
    printf 'WARN: %s %ss — референс не снят (EXP-007)\n' "$label" "$mf"
    return 0
  fi
  rf=$(awk -v r="$ref" 'BEGIN{printf "%.1f", r}')
  if awk -v m="$measured" -v r="$ref" 'BEGIN{exit !(m <= r * 1.25)}'; then
    printf 'PASS: %s %ss (референс %ss)\n' "$label" "$mf" "$rf"
  else
    printf 'WARN: %s %ss — регрессия >25%% к %ss%s\n' \
      "$label" "$mf" "$rf" "${hint:+ ($hint)}"
  fi
  return 0
}

# Назначение: cmd agent-check — гейты → warn рестарта → python stage1
#   (24 запроса: сессия 15 + лестница 6 + docq 2 + restore-turn1) →
#   cmp_ref по CHECK-строкам → container_up (ЕДИНСТВЕННЫЙ путь подъёма:
#   рестарт восстанавливает канон текущего профиля) → wait_health 180 →
#   python stage2 (restore-ход, 1 запрос) → cmp_ref + reuse-вердикт →
#   сводка «AGENT-CHECK: PASS=N WARN=M FAIL=K». rc: 0 при FAIL=0 (WARN
#   не считается отказом), 1 при FAIL; структурный провал (python rc≠0 /
#   нет CHECK-строки) → die до сводки. Состояние restore — временный файл
#   $LOGS_DIR/agent-check-restore.json (полн messages+ответ), удаляется
#   после использования.
#
# Побочные эффекты: 25 http-запросов генерации; mkdir $LOGS_DIR; запись и
#   удаление agent-check-restore.json; podman logs/rm/run (рестарт УБИВАЕТ
#   активные сессии — предупреждение warn до recreate); ROUTE_* глобалы.
#
# Ограничения/допущения: требует globals ROUTE_* (parse_route здесь),
#   ref_get (profiles.sh), cmp_ref (выше); тайминги не ассертятся
#   (машино-зависимы) — только вердикт-строки; follow-up 5k/100k печатаются
#   без сравнения (референс только у 25k); docq до EXP-007 всегда WARN
#   «не снят»; лишние аргументы → die.
#
# @param 1..N: string[]     # не предусмотрены (die)
# @stdout string            # ход проверок, CHECK-строки python, вердикты, сводка
# @returns integer          # не всегда — exit 1 при FAIL; die при структуре
cmd_agentcheck() {
  [ -n "${1:-}" ] && die "agent-check: лишние аргументы '$*' — команда без аргументов (сценарий фиксированный: SPEC §7)"
  [ "$(container_state)" = running ] || die "контейнер $CONTAINER не запущен (state=$(container_state)) — подними: gfctl up"
  port_open "$(canon_port)" || die "порт $(canon_port) мёртв — подними сервер: gfctl on/use"
  parse_route < <(podman logs "$CONTAINER" 2>&1)
  [ -n "$ROUTE_MODEL" ] || die "модель не загружена (в логе нет model= из load_completed) — сначала gfctl use"
  local prof; prof=$(cur_profile)
  warn "agent-check: рестарт-restore ПЕРЕЗАПУСКАЕТ контейнер — активные сессии сервера будут потеряны (рестарт поднимает канон профиля $prof)"
  mkdir -p "$LOGS_DIR"
  local port out p=0 w=0 f=0 v session_w k5 k25 k100 docq_w restore_w reuse state
  state="$LOGS_DIR/agent-check-restore.json"
  port=$(canon_port)
  echo "== gfctl agent-check — профиль $prof, модель $ROUTE_MODEL (25 запросов, SPEC §7)"
  out=$(GFCTL_AGENT_STATE="$state" python3 "$TPL_DIR/python/agent_check.py" stage1 "$port" "$ROUTE_MODEL") \
    || die "agent-check: stage1 структурно не прошёл (транспорт/timings/JSON — причина в stderr выше)"
  printf '%s\n' "$out"
  session_w=$(grep '^CHECK session ' <<<"$out" | grep -oE 'total=[0-9.]+' | head -n1 | cut -d= -f2-) || true
  k5=$(grep '^CHECK followup ' <<<"$out" | grep -oE 'k5=[0-9.]+' | cut -d= -f2-) || true
  k25=$(grep '^CHECK followup ' <<<"$out" | grep -oE 'k25=[0-9.]+' | cut -d= -f2-) || true
  k100=$(grep '^CHECK followup ' <<<"$out" | grep -oE 'k100=[0-9.]+' | cut -d= -f2-) || true
  docq_w=$(grep '^CHECK docq ' <<<"$out" | grep -oE 'q2=[0-9.]+' | head -n1 | cut -d= -f2-) || true
  [ -n "$session_w" ] && [ -n "$k25" ] && [ -n "$k100" ] && [ -n "$docq_w" ] \
    || die "agent-check: в выводе stage1 нет ожидаемых CHECK-строк (session/followup/docq) — контракт python нарушен"
  v=$(cmp_ref "сессия 15 ходов" "$session_w" "$(ref_get "$prof" session)"); printf '%s\n' "$v"
  case "$v" in PASS*) p=$((p + 1)) ;; *) w=$((w + 1)) ;; esac
  echo "follow-up 5k: ${k5}s | follow-up 100k: ${k100}s (без сравнения — референс только у 25k)"
  v=$(cmp_ref "follow-up 25k" "$k25" "$(ref_get "$prof" followup)" "проверь --cache-ram-bytes/--cache-disk"); printf '%s\n' "$v"
  case "$v" in PASS*) p=$((p + 1)) ;; *) w=$((w + 1)) ;; esac
  v=$(cmp_ref "[док 25k] q2" "$docq_w" "$(ref_get "$prof" docq)"); printf '%s\n' "$v"
  case "$v" in PASS*) p=$((p + 1)) ;; *) w=$((w + 1)) ;; esac
  echo "рестарт контейнера (restore проверяет disk-тир; канон профиля $prof)…"
  container_up "$prof"
  wait_health 180
  out=$(GFCTL_AGENT_STATE="$state" python3 "$TPL_DIR/python/agent_check.py" stage2 "$port" "$ROUTE_MODEL") \
    || die "agent-check: stage2 (restore-ход) структурно не прошёл — причина в stderr выше"
  printf '%s\n' "$out"
  rm -f "$state"
  restore_w=$(grep '^CHECK restore ' <<<"$out" | grep -oE 'turn2=[0-9.]+' | head -n1 | cut -d= -f2-) || true
  reuse=$(grep '^CHECK restore ' <<<"$out" | grep -oE 'reuse=[a-z]+' | head -n1 | cut -d= -f2-) || true
  [ -n "$restore_w" ] || die "agent-check: в выводе stage2 нет CHECK restore — контракт python нарушен"
  v=$(cmp_ref "рестарт-restore" "$restore_w" "$(ref_get "$prof" restore)" "проверь --cache-disk"); printf '%s\n' "$v"
  case "$v" in PASS*) p=$((p + 1)) ;; *) w=$((w + 1)) ;; esac
  case "$reuse" in
    live|disk) echo "restore: reuse=$reuse — disk-restore работает" ;;
    none) printf 'FAIL: disk-restore не сработал (reuse=none) — проверь --cache-disk и файловую систему кэш-каталога (gfctl cache)\n'; f=$((f + 1)) ;;
    *) printf 'FAIL: restore: reuse не распознан (%s)\n' "${reuse:-?}"; f=$((f + 1)) ;;
  esac
  printf 'AGENT-CHECK: PASS=%s WARN=%s FAIL=%s\n' "$p" "$w" "$f"
  if [ "$f" -gt 0 ]; then exit 1; fi
}
