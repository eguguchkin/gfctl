#!/usr/bin/env bash
# run_checks.sh — вся internal-check батарея сабстэджа 1.1 одним вызовом.
# Пункты: AGENTS.md «Internal checks» + Test strategy task.md (диспетчер,
# профильная таблица vs литералы task.md, таблицы весов vs литералы task.md,
# models inventory/download_file (file://, без сети HF), check-types на
# синтетических мини-GGUF, doctor, status --json). Всё локально; сеть —
# только localhost (file:// и никакой podman/ssh — hygiene).
#
# @stdout string   # PASS/FAIL по каждому пункту + ИТОГО
# @returns integer # 0 — все зелёные; 1 — есть FAIL
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
PASS=0 FAIL=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/gfctl-checks.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

ok()  { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL + 1)); }
# rc_out <cmd...> → печатает «rc <код>|<вывод>»; никогда не роняет set -e
rc_out() {
  local rc=0 out
  out=$("$@" 2>&1) || rc=$?
  printf '%s\n%s' "$rc" "$out"
}

# ── faux-bin: PATH-заглушки внешних бинарей (Test strategy task.md 1.2) ────
# Каждая пишет в $GFCTL_FAUX_LOG построчно «<cmd> <args…>» и сценарится
# env-флагами GFCTL_FAUX_*; ролей не делают (никаких реальных podman/
# systemd/loginctl/sudo-вызовов — hygiene). Сценарии:
#   podman  — run (GFCTL_FAUX_RUNFAIL=N: первые N run падают; счётчик
#             GFCTL_FAUX_CNT; --context запоминается в файл
#             $GFCTL_FAUX_CNT.ctx — механика probe: logs маппятся по ctx),
#             logs (GFCTL_FAUX_CTX_LOGS="ctx:файл ctx:файл" → файл по
#             текущему ctx из .ctx-файла; нет маппинга/ctx → старый
#             GFCTL_FAUX_PODMAN_LOGS — старые тесты не меняются),
#             inspect (GFCTL_FAUX_INSPECT=state|missing), rm/rmi/ps — rc 0;
#   systemctl — лог + is-enabled (GFCTL_FAUX_SYS_ENABLED=yes|no);
#   loginctl/sudo — лог + rc 0 (sudo passthrough-НЕТ: внутренняя команда
#             не исполняется — реальная система не трогается);
#   curl    — лог URL; /ready rc 0 (GFCTL_FAUX_CURL_READYFAIL=1 → rc 7),
#             /v1/completions — JSON с usage (FAILFIRST/FAILALL; счётчик
#             GFCTL_FAUX_CNT.curl), chat-completions — скриптовый JSON
#             (FAILFIRST: 1-й вызов падает, FAILALL: все падают);
#   sleep   — мгновенный (батарея быстрая).
FAUX="$TMP/faux"; mkdir -p "$FAUX"
FAUXLOG="$TMP/faux.log"; FAUXCNT="$TMP/faux.cnt"
: > "$FAUXLOG"; rm -f "$FAUXCNT" "$FAUXCNT.curl" "$FAUXCNT.ctx"
cat > "$FAUX/podman" <<'EOF'
#!/usr/bin/env bash
{ printf 'podman'; printf ' %s' "$@"; printf '\n'; } >> "${GFCTL_FAUX_LOG:?}"
case "${1:-}" in
  run)
    prev=""; ctx=""
    for a in "$@"; do
      [ "$prev" = "--context" ] && ctx="$a"
      prev="$a"
    done
    [ -n "$ctx" ] && printf '%s\n' "$ctx" > "${GFCTL_FAUX_CNT}.ctx"
    if [ -n "${GFCTL_FAUX_RUNFAIL:-}" ]; then
      n=$(cat "$GFCTL_FAUX_CNT" 2>/dev/null || echo 0)
      n=$((n + 1)); echo "$n" > "$GFCTL_FAUX_CNT"
      [ "$n" -le "$GFCTL_FAUX_RUNFAIL" ] && exit 1
    fi
    exit 0 ;;
  logs)
    if [ -n "${GFCTL_FAUX_CTX_LOGS:-}" ]; then
      cur=$(cat "${GFCTL_FAUX_CNT}.ctx" 2>/dev/null || true)
      for pair in $GFCTL_FAUX_CTX_LOGS; do
        case "$pair" in "$cur:"*) cat "${pair#*:}"; exit 0 ;; esac
      done
    fi
    [ -n "${GFCTL_FAUX_PODMAN_LOGS:-}" ] && cat "$GFCTL_FAUX_PODMAN_LOGS"; exit 0 ;;
  inspect)
    case "${GFCTL_FAUX_INSPECT:-missing}" in
      missing) exit 1 ;;
      *) printf '%s\n' "$GFCTL_FAUX_INSPECT"; exit 0 ;;
    esac ;;
esac
exit 0
EOF
cat > "$FAUX/systemctl" <<'EOF'
#!/usr/bin/env bash
{ printf 'systemctl'; printf ' %s' "$@"; printf '\n'; } >> "${GFCTL_FAUX_LOG:?}"
case "${1:-} ${2:-}" in
  "--user is-enabled")
    if [ "${GFCTL_FAUX_SYS_ENABLED:-yes}" = yes ]; then echo enabled; exit 0; fi
    echo disabled; exit 1 ;;
esac
exit 0
EOF
cat > "$FAUX/loginctl" <<'EOF'
#!/usr/bin/env bash
{ printf 'loginctl'; printf ' %s' "$@"; printf '\n'; } >> "${GFCTL_FAUX_LOG:?}"
[ "${1:-}" = show-user ] && echo "Linger=yes"
exit 0
EOF
cat > "$FAUX/sudo" <<'EOF'
#!/usr/bin/env bash
{ printf 'sudo'; printf ' %s' "$@"; printf '\n'; } >> "${GFCTL_FAUX_LOG:?}"
exit 0
EOF
cat > "$FAUX/curl" <<'EOF'
#!/usr/bin/env bash
{ printf 'curl'; printf ' %s' "$@"; printf '\n'; } >> "${GFCTL_FAUX_LOG:?}"
case "$*" in
  *"/ready"*)
    [ "${GFCTL_FAUX_CURL_READYFAIL:-0}" = 1 ] && exit 7
    exit 0 ;;
  *"/v1/completions"*)
    n=$(cat "$GFCTL_FAUX_CNT.curl" 2>/dev/null || echo 0)
    n=$((n + 1)); echo "$n" > "$GFCTL_FAUX_CNT.curl"
    [ "${GFCTL_FAUX_CURL_FAILALL:-0}" = 1 ] && exit 7
    if [ "${GFCTL_FAUX_CURL_FAILFIRST:-0}" = 1 ] && [ "$n" = 1 ]; then exit 7; fi
    printf '{"choices":[{"text":"def merge_sort(a): return sorted(a)"}],"usage":{"prompt_tokens":20,"completion_tokens":256,"total_tokens":276}}'
    exit 0 ;;
  *"/v1/chat/completions"*)
    n=$(cat "$GFCTL_FAUX_CNT.curl" 2>/dev/null || echo 0)
    n=$((n + 1)); echo "$n" > "$GFCTL_FAUX_CNT.curl"
    [ "${GFCTL_FAUX_CURL_FAILALL:-0}" = 1 ] && exit 7
    if [ "${GFCTL_FAUX_CURL_FAILFIRST:-0}" = 1 ] && [ "$n" = 1 ]; then exit 7; fi
    printf '{"choices":[{"message":{"content":"ок"}}]}'
    exit 0 ;;
esac
exit 0
EOF
cat > "$FAUX/sleep" <<'EOF'
#!/usr/bin/env bash
{ printf 'sleep'; printf ' %s' "$@"; printf '\n'; } >> "${GFCTL_FAUX_LOG:?}"
exit 0
EOF
chmod +x "$FAUX"/*
if [ "$(ls "$FAUX" | wc -l)" = 6 ]; then ok "faux-bin: 6 заглушек (podman/systemctl/loginctl/sudo/curl/sleep)"; else bad "faux-bin создание"; fi

# frun — процессный запуск ./gfctl с faux-PATH: лог/счётчики/паузы — швы
# теста; HOME/GFCTL_DIR — в $TMP (никаких следов в реальном home).
frun() {  # frun <cmd...> — rc наружу; env-сценарии GFCTL_FAUX_* задаёт caller
  PATH="$FAUX:$PATH" GFCTL_DIR="$TMP/stack" HOME="$TMP/home" \
  GFCTL_FAUX_LOG="$FAUXLOG" GFCTL_FAUX_CNT="$FAUXCNT" \
  GFCTL_RECREATE_PAUSE_S=0 GFCTL_HEALTH_POLL=1 GFCTL_SMOKE_RETRY_S=0 \
  GFCTL_RUN_ATTEMPTS="${GFCTL_RUN_ATTEMPTS:-3}" \
  ./gfctl "$@"
}

# gf — harness: мини-диспетчер в субшелле (глобалы как в gfctl + все lib +
# faux-PATH); код-аргумент исполняется ПОСЛЕ source lib — там живут
# оверрайды гейт-функций (gpu_nodes_present/ram_gate_line/ulimit — единственный
# способ подменить их в отдельном процессе) и прямые вызовы cmd_*/функций.
gf() {  # gf <bash-код> — stdout+stderr и rc наружу
  (
    set -euo pipefail
    export PATH="$FAUX:$PATH"
    export GFCTL_FAUX_LOG="$FAUXLOG" GFCTL_FAUX_CNT="$FAUXCNT"
    export GFCTL_RECREATE_PAUSE_S=0 GFCTL_HEALTH_POLL=1 GFCTL_SMOKE_RETRY_S=0
    HOME="$TMP/home" USER="tester"
    IMAGE="ghcr.io/gufo-org/toolboxes/gufo-runtime:latest"
    STACK_DIR="$TMP/stack" MODELS_BASE="$TMP/stack/models"
    PORT=8080 BIND="0.0.0.0"
    STOP_MARKER="$STACK_DIR/.gfctl-stopped"
    CONTAINER="gufo" UNIT_NAME="gfctl"
    LOGS_DIR="$STACK_DIR/logs" UNIT_DIR="$HOME/.config/systemd/user"
    ASSUME_YES=1 SELF="$ROOT/gfctl" LIB_DIR="$ROOT/lib" TPL_DIR="$ROOT/tpl"
    log()  { printf '\n== %s\n' "$*"; }
    warn() { printf 'WARN: %s\n' "$*" >&2; }
    die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
    ask()  { [ "${ASSUME_YES:-}" = 1 ] && return 0; echo "(неинтерактивный режим: авто-нет)"; return 1; }
    isint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
    source "$LIB_DIR/profiles.sh";  source "$LIB_DIR/models.sh"
    source "$LIB_DIR/state.sh";     source "$LIB_DIR/serve.sh"
    source "$LIB_DIR/units.sh";     source "$LIB_DIR/health.sh"
    source "$LIB_DIR/autostart.sh"; source "$LIB_DIR/commands.sh"
    eval "$1"
  )
}

# ── фикстуры лога движка (формат окон IX/FX: event=load_completed …) ────────
LOGOK="$TMP/logload"
printf 'event=listening address=http://0.0.0.0:8080\nspeculative=dflash2 draft ready\n' > "$LOGOK"
printf 'event=load_completed speculative=dflash2 sessions=1 context_tokens=262144 model=qwen3.8-27b-IQ4_XS-pure\n' >> "$LOGOK"
LOGTWO="$TMP/logtwo"   # две load_completed — побеждает ПОСЛЕДНЯЯ (последний recreate)
printf 'event=load_completed speculative=dflash2 sessions=1 context_tokens=262144 model=A\n' > "$LOGTWO"
printf 'noise\n' >> "$LOGTWO"
printf 'event=load_completed speculative=mtp sessions=2 context_tokens=131072 model=B\n' >> "$LOGTWO"
LOGNONE="$TMP/lognone"; printf 'event=listening address=http://0.0.0.0:8080\n' > "$LOGNONE"
LOGFAIL="$TMP/logfail"; printf 'event=listening\nmodel load error: OOM\n event=load_failed reason=oom\n' > "$LOGFAIL"

echo "== 1. AGENTS internal checks: bash -n / py_compile"
if bash -n gfctl lib/*.sh 2>&1; then ok "bash -n gfctl lib/*.sh"; else bad "bash -n gfctl lib/*.sh"; fi
if python3 -m py_compile tpl/python/*.py 2>&1; then ok "py_compile tpl/python/*.py"; else bad "py_compile tpl/python/*.py"; fi

echo "== 2. диспетчер: bare/garbage/--help; заглушки остались РОВНО у этапа 3 (п.0 Test strategy 2.1: bench — живая)"
rc=$(rc_out ./gfctl | head -n 1); usage_out=$(rc_out ./gfctl | tail -n +2)
[ "$rc" = 1 ] && grep -q 'Команды:' <<<"$usage_out" && grep -q 'gfctl — деплой' <<<"$usage_out" \
  && ok "bare → rc=1 + usage" || bad "bare → rc=1 + usage (rc=$rc)"
! grep -q 'bench.*этап' <<<"$usage_out" \
  && ok "usage: bench без пометки [этап 2] (2.1 — живая команда)" || bad "usage bench: пометка этапа осталась"
rc=$(rc_out ./gfctl garbage | head -n 1); gar_out=$(rc_out ./gfctl garbage | tail -n +2)
[ "$rc" = 1 ] && grep -q 'неизвестная команда' <<<"$gar_out" && grep -q 'Профили: 27b-single 27b-multi flash-multi' <<<"$gar_out" \
  && ok "garbage → rc=1 + список + Профили" || bad "garbage → rc=1 + список + Профили (rc=$rc)"
rc=$(rc_out ./gfctl --help | head -n 1)
[ "$rc" = 0 ] && ok "--help → rc=0" || bad "--help → rc=0 (rc=$rc)"
rc=$(rc_out ./gfctl install --profile bogus | head -n 1); o=$(rc_out ./gfctl install --profile bogus | tail -n +2)
[ "$rc" = 1 ] && ! grep -q 'появится в сабстэдже' <<<"$o" \
  && ok "install — живая команда (die по грамматике, не заглушка)" || bad "install не-заглушка (rc=$rc)"
for c in watch cache agent-check; do
  out=$(rc_out ./gfctl "$c"); rc=${out%%$'\n'*}
  if [ "$rc" = 1 ] && grep -q 'этап' <<<"$out"; then ok "заглушка этапа 3: $c → rc=1 «этап»"; else bad "заглушка $c (rc=$rc)"; fi
done
for c in use logs on off up down uninstall smoke bench; do
  set +e; out=$(PATH="$FAUX:$PATH" GFCTL_DIR="$TMP/noact" HOME="$TMP/noact-home" \
    GFCTL_RECREATE_PAUSE_S=0 GFCTL_RUN_ATTEMPTS=1 GFCTL_HEALTH_POLL=300 timeout 30 ./gfctl "$c" </dev/null 2>&1); prc=$?; set -e
  if [ "$prc" -lt 124 ] && ! grep -q 'появится в сабстэдже' <<<"$out"; then ok "не-заглушка: $c"; else bad "$c остался заглушкой (rc=$prc)"; fi
done

echo "== 3. фикстуры: регенерация байт-в-байт с ассетами tests/fixtures"
python3 tests/make_fixtures.py "$TMP/fix" >/dev/null
fix_ok=1
for f in "$TMP"/fix/*.gguf; do
  if ! cmp -s "$f" "tests/fixtures/$(basename "$f")"; then bad "фикстура $(basename "$f") ≠ коммиченной"; fix_ok=0; fi
done
[ "$fix_ok" = 1 ] && ok "фикстуры детерминированы и равны ассетам ($(ls "$TMP"/fix/*.gguf | wc -l) шт)"

echo "== 4. check-types: парсер на мини-GGUF (числовой RED-контракт)"
PYCHK="python3 tpl/python/gguf_type_check.py"
expect_rc() { # expect_rc <want> <desc> <file>
  local want="$1" desc="$2" file="$3" rc
  set +e; python3 tpl/python/gguf_type_check.py "$file" >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" = "$want" ] && ok "$desc (rc=$rc)" || bad "$desc — ждём rc=$want, факт rc=$rc"
}
expect_rc 1 "ffn IQ2_S (22) → КРАСНЫЙ"    "$TMP/fix/gguf_ffn_iq2_s.gguf"
expect_rc 0 "ffn IQ4_XS (23) → зелёный"   "$TMP/fix/gguf_ffn_iq4_xs.gguf"
expect_rc 0 "ffn Q4_K (12) → зелёный"     "$TMP/fix/gguf_ffn_q4_k.gguf"
expect_rc 1 "ffn unknown(31) → КРАСНЫЙ"   "$TMP/fix/gguf_ffn_unknown31.gguf"
expect_rc 0 "attn IQ2_XS (17) вне ffn → зелёный + WARN" "$TMP/fix/gguf_attn_iq2_xs.gguf"
expect_rc 2 "не-GGUF → rc 2"              "$TMP/fix/gguf_not_gguf.gguf"
expect_rc 2 "обрезанные метаданные → rc 2" "$TMP/fix/gguf_truncated.gguf"
expect_rc 2 "вложенный KV-массив → rc 2"  "$TMP/fix/gguf_kv_nested.gguf"
expect_rc 2 "метаданные > 64 MiB → rc 2"  "$TMP/fix/gguf_meta_budget.gguf"
expect_rc 2 "n_kv > 1e6 (санити) → rc 2"  "$TMP/fix/gguf_meta_overflow.gguf"
warn_out=$(python3 tpl/python/gguf_type_check.py "$TMP/fix/gguf_attn_iq2_xs.gguf")
grep -q '^WARN:' <<<"$warn_out" && ok "WARN-строка для risky вне ffn" || bad "нет WARN-строки для risky вне ffn"

echo "== 5. check-types уровень gfctl (красный сет → rc 1 + КРАСНЫЙ)"
mkdir -p "$TMP/m/27b"
cp "$TMP/fix/gguf_ffn_iq2_s.gguf" "$TMP/m/27b/qwen3.8-27b-IQ4_XS-pure.gguf"
set +e; GFCTL_MODELS="$TMP/m" ./gfctl models --check-types >"$TMP/ct.out" 2>&1; ct_rc=$?; set -e
[ "$ct_rc" = 1 ] && grep -q 'КРАСНЫЙ' "$TMP/ct.out" \
  && ok "gfctl check-types: IQ2_S в ffn → rc=1 + КРАСНЫЙ" || bad "gfctl check-types красный (rc=$ct_rc)"
cp "$TMP/fix/gguf_ffn_iq4_xs.gguf" "$TMP/m/27b/qwen3.8-27b-IQ4_XS-pure.gguf"
set +e; GFCTL_MODELS="$TMP/m" ./gfctl models --check-types >"$TMP/ct.out" 2>&1; ct_rc=$?; set -e
[ "$ct_rc" = 0 ] && grep -q 'зелёный' "$TMP/ct.out" \
  && ok "gfctl check-types: IQ4_XS в ffn → rc=0 + зелёный" || bad "gfctl check-types зелёный (rc=$ct_rc)"
mkdir -p "$TMP/mempty/27b"
set +e; GFCTL_MODELS="$TMP/mempty" ./gfctl models --check-types >"$TMP/ct.out" 2>&1; ct_rc=$?; set -e
[ "$ct_rc" = 1 ] && grep -q 'нечего проверять' "$TMP/ct.out" \
  && ok "check-types пустой сет → rc=1 «нечего проверять»" || bad "check-types пустой сет (rc=$ct_rc)"
set +e; GFCTL_MODELS="$TMP/m" ./gfctl models --check-types flash >"$TMP/ct.out" 2>&1; ct_rc=$?; set -e
[ "$ct_rc" = 1 ] && grep -q 'нечего проверять' "$TMP/ct.out" \
  && ok "check-types flash (не скачан) → rc=1" || bad "check-types flash не скачан (rc=$ct_rc)"

echo "== 6. профильная таблица: 9 полей × 3 профиля = литералам task.md"
pp() { ( MODELS_BASE="$TMP/m"; source lib/profiles.sh; "$@" ); }
assert_field() { # assert_field <prof> <n> <want>
  local got; got=$(pp profile_field "$1" "$2")
  if [ "$got" = "$3" ]; then ok "profile_field $1[$2]"; else bad "profile_field $1[$2]: ждём '$3', факт '$got'"; fi
}
assert_field 27b-single 1 27b
assert_field 27b-single 2 56
assert_field 27b-single 3 1
assert_field 27b-single 4 262144
assert_field 27b-single 5 12884901888
assert_field 27b-single 6 68719476736
assert_field 27b-single 7 '--speculative dflash2 --dflash-model @DRAFT@'
assert_field 27b-single 8 '-'
assert_field 27b-single 9 'solo DFlash2 (максимум соло-скорости)'
assert_field 27b-multi 1 27b
assert_field 27b-multi 2 56
assert_field 27b-multi 3 2
assert_field 27b-multi 4 163840
assert_field 27b-multi 5 4294967296
assert_field 27b-multi 6 68719476736
assert_field 27b-multi 7 '--speculative dflash2 --dflash-model @DRAFT@'
assert_field 27b-multi 8 '196608 163840 131072'
assert_field 27b-multi 9 'мульти DFlash2 (probe-лестница, D5)'
assert_field flash-multi 1 flash
assert_field flash-multi 2 110
assert_field flash-multi 3 2
assert_field flash-multi 4 131072
assert_field flash-multi 5 4294967296
assert_field flash-multi 6 68719476736
assert_field flash-multi 7 '--speculative mtp --mtp-model @MTP@'
assert_field flash-multi 8 '262144 229376 196608 163840 131072'
assert_field flash-multi 9 'мульти MTP (максимальные контексты, floor 131072 проверен FX)'
[ "$(pp resolve_profile single)" = 27b-single ] && [ "$(pp resolve_profile multi)" = 27b-multi ] \
  && [ "$(pp resolve_profile flash)" = flash-multi ] && [ "$(pp resolve_profile 27b-single)" = 27b-single ] \
  && ok "resolve_profile: single/multi/flash/канон" || bad "resolve_profile алиасы"
if pp profile_field no-such-profile 1 2>/dev/null; then bad "profile_field неизвестный → rc 1"; else ok "profile_field неизвестный → rc 1"; fi
gate_out=$(pp ram_gate_line 27b-single)
grep -Eq '^27b-single: ≥56 GiB — есть [0-9]+\.[0-9]: (OK|НЕДОСТАТУПЕН)$' <<<"$gate_out" \
  && ok "ram_gate_line формат «≥56 GiB — есть X.X: …»" || bad "ram_gate_line формат: '$gate_out'"
[ "$(pp models_dir_for 27b)" = "$TMP/m/27b" ] && ok "models_dir_for" || bad "models_dir_for"

echo "== 7. таблицы весов: строки сетов = литералам task.md §models"
sm() { ( MODELS_BASE="$TMP/m"; source lib/models.sh; "$@" ); }
cat > "$TMP/want_27b" <<'EOF'
qwen3.8-27b-IQ4_XS-pure.gguf|14534384640|ea5a3c45d407f9b9e5d2c0d647f0ea600f486f6b86b92b56d0823ba073dae675|https://huggingface.co/jpetrina/Qwen3.8-27B-IQ4_XS-pure-GGUF/resolve/main/qwen3.8-27b-IQ4_XS-pure.gguf|main
Qwen3.8-27B-DFlash2-Q4_K_M.gguf|1143006816|1a25c56858e1ebe93f2718ac1d49d1151f9323325c1bbfd6209370f4db131ebd|https://huggingface.co/z-lab/Qwen3.8-27B-DFlash2-GGUF/resolve/2d9571f8ce46e151f61c6499c99dee6079e1d610/Qwen3.8-27B-DFlash2-Q4_K_M.gguf|draft
EOF
cat > "$TMP/want_flash" <<'EOF'
Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf|10946618|acc44040f74d0e55fb89c3967056cce5dbda1bcc52e909c3ba6fc72b5e9c0858|https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf|main
Qwen3.8-Flash-Next-UD-Q4_K_XL-00002-of-00004.gguf|49720539552|45792ae869072d8229384c51c7c73dd959e191505252b41dd71852d9746f5ce4|https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00002-of-00004.gguf|main
Qwen3.8-Flash-Next-UD-Q4_K_XL-00003-of-00004.gguf|32803030176|8c76e79d444b16a663d9c8db54e585ed3b1da13eebd2619c37b0c355da803c82|https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00003-of-00004.gguf|main
Qwen3.8-Flash-Next-UD-Q4_K_XL-00004-of-00004.gguf|28800138432|5de8b5dbf89409acc39468decafd4a4a95b13c29d88a14b0356107897829ec36|https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00004-of-00004.gguf|main
mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf|2786568256|5ff54097406a905cf3a724c709124ceb0e3e10235ee862298969e91c96fa96e6|https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf|mtp
EOF
sm weights_for 27b > "$TMP/got_27b"; sm weights_for flash > "$TMP/got_flash"
cmp -s "$TMP/got_27b" "$TMP/want_27b" \
  && ok "set_27b: 2 записи байт-в-байт (size/sha/url/role)" \
  || bad "set_27b расходится с task.md"
cmp -s "$TMP/got_flash" "$TMP/want_flash" \
  && ok "set_flash: 5 записей байт-в-байт (size/sha/url/role)" \
  || bad "set_flash расходится с task.md"
[ "$(sm set_total_bytes flash)" = 114121223034 ] \
  && ok "контроль сумм flash-сета (шарды 111 334 654 778 + MTP 2 786 568 256)" \
  || bad "контроль сумм flash ≠ 114121223034 ($(sm set_total_bytes flash))"
[ "$(sm set_total_bytes 27b)" = 15677391456 ] \
  && ok "контроль сумм 27b = сумма пин-размеров (15 677 391 456 B)" \
  || bad "контроль сумм 27b ≠ 15677391456 ($(sm set_total_bytes 27b))"
[ "$(sm set_file_role 27b draft)" = "Qwen3.8-27B-DFlash2-Q4_K_M.gguf" ] \
  && ok "set_file_role 27b draft" || bad "set_file_role 27b draft"

echo "== 8. models: инвентарь пустого/битого/недокачанного"
mkdir -p "$TMP/empty27b" "$TMP/broken/27b" "$TMP/broken/flash"
inv=$(GFCTL_MODELS="$TMP/empty" ./gfctl models)
[ "$(grep -c '| НЕТ$' <<<"$inv")" = 7 ] && ok "пустой MODELS_BASE: 7×«НЕТ» + rc 0" || bad "пустой инвентарь (НЕТ=$(grep -c '| НЕТ$' <<<"$inv"))"
grep -q 'сводка по профилям' <<<"$inv" && [ "$(grep -c 'сет .* файлов' <<<"$inv")" = 3 ] \
  && ok "сводка по 3 профилям" || bad "сводка по профилям"
head -c 10946618 /dev/urandom > "$TMP/broken/flash/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf"
head -c 12345 /dev/urandom > "$TMP/broken/flash/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf"
head -c 5000 /dev/urandom > "$TMP/broken/flash/Qwen3.8-Flash-Next-UD-Q4_K_XL-00002-of-00004.gguf.part"
inv=$(GFCTL_MODELS="$TMP/broken" ./gfctl models)
grep -q '00001-of-00004.gguf | 10946618 B | есть, размер OK, sha ✗' <<<"$inv" \
  && ok "размер OK + sha ✗ → «перекачай»" || bad "sha ✗ статус"
grep -q 'mtp-.*\.gguf | 2786568256 B | есть, РАЗМЕР ≠ (факт 12345 B)' <<<"$inv" \
  && ok "РАЗМЕР ≠ с фактом" || bad "РАЗМЕР ≠ статус"
grep -q 'незавершённый .part: 0.0 GiB' <<<"$inv" \
  && ok ".part-хвост отражён" || bad ".part строка"
echo "== 9. download_file: pre-flight / file:// PASS / resume / SKIP / SHA-MISMATCH"
mkdir -p "$TMP/dl/flash" "$TMP/srv"
dlf() { ( MODELS_BASE="$TMP/dl"
          log()  { echo "LOG: $*"; }; warn() { echo "WARN: $*" >&2; }; die() { echo "DIE: $*" >&2; exit 1; }
          source lib/models.sh; download_file "$@" ); }
head -c 200000 /dev/urandom > "$TMP/srv/blob1"; sha1=$(sha256sum "$TMP/srv/blob1" | awk '{print $1}')
head -c 100000 /dev/urandom > "$TMP/srv/blob2"
set +e; dlf_out=$(dlf "file://$TMP/srv/blob1" "$TMP/dl/flash/x.gguf" 10995116277760 deadbeef); pf_rc=$?; set -e
[ "$pf_rc" = 1 ] && grep -q 'нужно 10240.0 GiB (остаток), свободно' <<<"$dlf_out" && [ ! -e "$TMP/dl/flash/x.gguf.part" ] \
  && ok "pre-flight: не хватает места → rc 1 ДО трафика (без .part)" || bad "pre-flight отказ (rc=$pf_rc)"
set +e; dlf_out=$(dlf "file://$TMP/srv/blob1" "$TMP/dl/flash/a.gguf" 200000 "$sha1"); d_rc=$?; set -e
[ "$d_rc" = 0 ] && grep -q 'PASS: a.gguf (sha OK)' <<<"$dlf_out" && cmp -s "$TMP/dl/flash/a.gguf" "$TMP/srv/blob1" \
  && ok "download PASS + sha OK + байты совпали" || bad "download PASS (rc=$d_rc)"
head -c 150000 "$TMP/srv/blob1" > "$TMP/dl/flash/b.gguf.part"
set +e; dlf_out=$(dlf "file://$TMP/srv/blob1" "$TMP/dl/flash/b.gguf" 200000 "$sha1"); r_rc=$?; set -e
[ "$r_rc" = 0 ] && cmp -s "$TMP/dl/flash/b.gguf" "$TMP/srv/blob1" && [ ! -e "$TMP/dl/flash/b.gguf.part" ] \
  && ok "resume с .part → PASS, файл цельный, .part поглощён" || bad "resume (rc=$r_rc)"
set +e; dlf_out=$(dlf "file://$TMP/srv/blob1" "$TMP/dl/flash/a.gguf" 200000 "$sha1"); s_rc=$?; set -e
[ "$s_rc" = 0 ] && grep -q 'SKIP: a.gguf' <<<"$dlf_out" \
  && ok "SKIP при совпавшем размере" || bad "SKIP (rc=$s_rc)"
# 2.1-F1: dest-симлинк — SKIP по размеру ЦЕЛЕВОГО файла, симлинк не заменяется
ln -s "$TMP/srv/blob1" "$TMP/dl/flash/link_ok.gguf"
set +e; dlf_out=$(dlf "file://$TMP/srv/blob2" "$TMP/dl/flash/link_ok.gguf" 200000 "$sha1"); ls_rc=$?; set -e
[ "$ls_rc" = 0 ] && grep -q 'SKIP: link_ok.gguf' <<<"$dlf_out" && [ -L "$TMP/dl/flash/link_ok.gguf" ] \
  && ok "SKIP по симлинку (stat -L): симлинк не заменён файлом" || bad "SKIP симлинк (rc=$ls_rc)"
ln -s "$TMP/srv/blob2" "$TMP/dl/flash/link_bad.gguf"   # целевой 100000 B ≠ пин 200000
set +e; dlf_out=$(dlf "file://$TMP/srv/blob1" "$TMP/dl/flash/link_bad.gguf" 200000 "$sha1"); lb_rc=$?; set -e
! grep -q 'SKIP: link_bad.gguf' <<<"$dlf_out" && [ "$lb_rc" = 0 ] \
  && grep -q 'PASS: link_bad.gguf (sha OK)' <<<"$dlf_out" && [ ! -L "$TMP/dl/flash/link_bad.gguf" ] \
  && cmp -s "$TMP/dl/flash/link_bad.gguf" "$TMP/srv/blob1" \
  && ok "негатив: симлинк не-того размера → НЕ SKIP, скачал, PASS" || bad "негатив симлинк (rc=$lb_rc)"
sha2=$(sha256sum "$TMP/srv/blob1" | awk '{print $1}')   # заведомо чужой sha для blob2
set +e; dlf_out=$(dlf "file://$TMP/srv/blob2" "$TMP/dl/flash/c.gguf" 100000 "$sha2" 2>&1); mm_rc=$?; set -e
[ "$mm_rc" = 1 ] && [ ! -e "$TMP/dl/flash/c.gguf" ] && [ ! -e "$TMP/dl/flash/c.gguf.part" ] \
  && grep -q 'SHA-MISMATCH' <<<"$dlf_out" \
  && ok "SHA-MISMATCH → rc 1, dest+.part удалены" || bad "SHA-MISMATCH (rc=$mm_rc)"
echo "== 10. models download: не-TTY без --yes → авто-нет rc 1"
set +e; GFCTL_MODELS="$TMP/empty" ./gfctl models download 27b </dev/null >"$TMP/dl.out" 2>&1; dl_rc=$?; set -e
[ "$dl_rc" = 1 ] && grep -q 'авто-нет' "$TMP/dl.out" \
  && ok "download без согласия → rc=1 «авто-нет»" || bad "download авто-нет (rc=$dl_rc)"
# 2.1-F2: симлинк-веса (stat -L) — inventory не врёт «РАЗМЕР ≠», ensure_weights
#   считает симлинк-сет полным (FAEX, EXP-005-faex: веса живут симлинками)
mkdir -p "$TMP/linkset/27b" "$TMP/linktgt"
truncate -s 1143006816 "$TMP/linktgt/draft.gguf"
ln -s "$TMP/linktgt/draft.gguf" "$TMP/linkset/27b/Qwen3.8-27B-DFlash2-Q4_K_M.gguf"
inv=$(GFCTL_MODELS="$TMP/linkset" ./gfctl models)
grep -q 'DFlash2-Q4_K_M.gguf | 1143006816 B | есть, размер OK' <<<"$inv" \
  && ok "inventory на симлинке: «размер OK» (stat -L), не «РАЗМЕР ≠»" || bad "inventory симлинк ($(grep 'DFlash2-Q4' <<<"$inv"))"
truncate -s 14534384640 "$TMP/linktgt/main.gguf"
ln -s "$TMP/linktgt/main.gguf" "$TMP/linkset/27b/qwen3.8-27b-IQ4_XS-pure.gguf"
set +e; GFCTL_MODELS="$TMP/linkset" ./gfctl models download 27b </dev/null >"$TMP/ew.out" 2>&1; ew_rc=$?; set -e
[ "$ew_rc" = 0 ] && ! grep -q 'Скачать недостающие' "$TMP/ew.out" && [ "$(grep -c 'SKIP:' "$TMP/ew.out")" = 2 ] \
  && ok "ensure_weights на симлинк-сете: сет полный — без ask, 2×SKIP, rc 0" || bad "ensure_weights симлинк (rc=$ew_rc)"

echo "== 11. doctor: деградация без GPU/podman, rc 0"
set +e; ./gfctl doctor >"$TMP/doctor.out" 2>&1; doc_rc=$?; set -e
[ "$doc_rc" = 0 ] && ok "doctor rc=0" || bad "doctor rc=$doc_rc"
grep -q '^ОС:' "$TMP/doctor.out" && ok "doctor: ОС-строка" || bad "doctor: ОС-строка"
[ "$(grep -c '≥56 GiB — есть' "$TMP/doctor.out")" = 2 ] \
  && ok "doctor: RAM-гейты 27b-single+multi в формате DoD" || bad "doctor: гейты 27b ×2"
grep -q 'flash-multi: ≥110 GiB — есть' "$TMP/doctor.out" \
  && ok "doctor: RAM-гейт flash-multi с цифрами" || bad "doctor: гейт flash-multi"
grep -q '^диск \[27b\]: нужно' "$TMP/doctor.out" && grep -q '^диск \[flash\]: нужно' "$TMP/doctor.out" \
  && ok "doctor: диск под оба сета" || bad "doctor: диск-строки"
grep -q '^порт 8080:' "$TMP/doctor.out" && grep -q '^gpu-lock:' "$TMP/doctor.out" \
  && ok "doctor: порт + gpu-lock" || bad "doctor: порт/gpu-lock"
! grep -qi 'traceback\|FATAL' "$TMP/doctor.out" \
  && ok "doctor: без traceback/FATAL" || bad "doctor: traceback/FATAL в выводе"

echo "== 12. status: --json валиден при мёртвом порте; человекочитаемая строка"
set +e; GFCTL_PORT=8198 ./gfctl status --json >"$TMP/status.json" 2>&1; st_rc=$?; set -e
if [ "$st_rc" = 0 ] && python3 -m json.tool "$TMP/status.json" >/dev/null 2>&1; then
  ok "status --json → rc=0, json.tool парсит"
else
  bad "status --json (rc=$st_rc или JSON невалиден)"
fi
python3 - "$TMP/status.json" <<'EOF' && ok "status --json: схема (health/route/gates/models + cache null)" || bad "status --json схема"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["health"] == "не запущен", d
assert d["route"] is None and d["autostart"] is None and d["version"] is None, d
assert d["cache"] is None, d
assert set(d["gates"]) == {"27b-single", "27b-multi", "flash-multi"}, d
assert d["models"]["27b"]["total"] == 2 and d["models"]["flash"]["total"] == 5, d
assert isinstance(d["models"]["27b"]["complete"], bool), d
EOF
st_out=$(GFCTL_PORT=8198 ./gfctl status)
grep -q '^профиль: 27b-single | health: не запущен | автозапуск: — | роут: — | кэш: — | веса 27b: 0/2$' <<<"$st_out" \
  && ok "status: одна строка, мёртвый порт (null'ы схемы 1.1)" || bad "status строка: '$st_out'"

echo "== 13. установка каркаса: install.sh в $TMP/gufo"
set +e; GFCTL_DIR="$TMP/gufo" ./install.sh >"$TMP/inst.out" 2>&1; in_rc=$?; set -e
[ "$in_rc" = 0 ] && [ -x "$TMP/gufo/gfctl" ] && [ -d "$TMP/gufo/lib" ] && [ -d "$TMP/gufo/tpl" ] \
  && ok "install.sh: дерево раскладано" || bad "install.sh раскладка (rc=$in_rc)"
cmp -s /workspace/hfctl/tpl/bench/merge_sort_thinking_off.txt "$TMP/gufo/tpl/bench/merge_sort_thinking_off.txt" \
  && ok "фикстура bench доложена в дерево" || bad "bench-фикстура в дереве"
set +e; (cd / && GFCTL_DIR="$TMP/gufo2" bash "$ROOT/install.sh" >/dev/null 2>&1); inst_rc=$?; set -e
if [ "$inst_rc" = 0 ]; then ok "install.sh: идемпотентный повтор = обновление (rc 0)"; else bad "install.sh повтор (rc=$inst_rc)"; fi
mkdir -p "$TMP/lonely"; cp install.sh "$TMP/lonely/"
set +e; bash "$TMP/lonely/install.sh" >/dev/null 2>&1; away_rc=$?; set -e
[ "$away_rc" = 1 ] && ok "install.sh вне дерева (без gfctl/lib рядом) → rc 1" || bad "install.sh вне дерева (rc=$away_rc)"

echo "== 14. state: write_canon = env.tpl + пар-блок (2.1); canon_get env > .env > default; canon_pair_context"
: > "$FAUXLOG"
gf 'write_canon 27b-single 1 262144' >/dev/null 2>&1
sed -e 's/__PROFILE__/27b-single/' -e 's/__SESSIONS__/1/' -e 's/__CONTEXT__/262144/' \
    -e 's/__PORT__/8080/' -e 's/__BIND__/0.0.0.0/' \
    -e "s|__MODELS_DIR__|$TMP/stack/models|" \
    -e "s|__IMAGE__|ghcr.io/gufo-org/toolboxes/gufo-runtime:latest|" \
    tpl/env/env.tpl > "$TMP/env.want"
printf 'GFCTL_CTX_27b_single_1=262144\n' >> "$TMP/env.want"
cmp -s "$TMP/stack/.env" "$TMP/env.want" \
  && ok "write_canon: .env = env.tpl с подстановкой + пара-ключ этой пары" || bad "write_canon ≠ шаблон+пара"
[ "$(grep -c '^GFCTL_CTX_' "$TMP/stack/.env")" = 1 ] \
  && ok "свежий write_canon: ровно один пар-ключ (env.tpl не менялся)" || bad "число пар-ключей"
[ "$(gf 'canon_get GFCTL_PORT 9999')" = 8080 ] && ok "canon_get: .env побеждает дефолт" || bad "canon_get .env"
[ "$(gf 'GFCTL_PORT=8198; canon_get GFCTL_PORT 9999')" = 8198 ] && ok "canon_get: env-оверрайд > .env" || bad "canon_get env"
[ "$(gf 'canon_get GFCTL_NOPE abc')" = abc ] && ok "canon_get: ключа нет нигде → default" || bad "canon_get default"
[ "$(gf 'canon_sessions 27b-single')" = 1 ] && [ "$(gf 'canon_context 27b-single')" = 262144 ] \
  && ok "canon_sessions/context читают канон" || bad "canon_sessions/context"
rm -f "$TMP/stack/.env"
[ "$(gf 'canon_sessions 27b-multi')" = 2 ] && [ "$(gf 'canon_context 27b-multi')" = 163840 ] \
  && ok "без .env canon_* падают в профильную таблицу (поля 3/4)" || bad "canon_* дефолты таблицы"
printf 'GFCTL_PROFILE=bogus\n' > "$TMP/stack/.env"
[ "$(gf 'cur_profile')" = 27b-single ] && ok "кривой GFCTL_PROFILE в .env → дефолт (cur_profile 1.1)" || bad "cur_profile мусор"
gf 'write_canon 27b-multi 4 131072' >/dev/null 2>&1
[ "$(gf 'canon_sessions 27b-multi')" = 4 ] && [ "$(gf 'canon_context 27b-multi')" = 131072 ] \
  && ok "overrides sessions/context живут в каноне" || bad "canon overrides"
# 2.1: upsert пар-ключей — чужая пара сохранена, своя обновлена без дублей
gf 'write_canon 27b-single 1 262144' >/dev/null 2>&1
[ "$(grep -c '^GFCTL_CTX_27b_single_1=262144$' "$TMP/stack/.env")" = 1 ] \
  && [ "$(grep -c '^GFCTL_CTX_27b_multi_4=131072$' "$TMP/stack/.env")" = 1 ] \
  && [ "$(grep -c '^GFCTL_CTX_' "$TMP/stack/.env")" = 2 ] \
  && ok "upsert пар: GFCTL_CTX_27b_multi_4 сохранён + GFCTL_CTX_27b_single_1 добавлен, без дублей" \
  || bad "pair upsert: $(grep '^GFCTL_CTX_' "$TMP/stack/.env")"
[ "$(gf 'canon_pair_context 27b-multi 4')" = 131072 ] \
  && ok "canon_pair_context: чужая пара читается после её write_canon" || bad "pair чужая"
[ "$(gf 'canon_pair_context 27b-single 1')" = 262144 ] \
  && ok "canon_pair_context: пара читается по ключу" || bad "pair своя"
[ "$(gf 'GFCTL_CTX_27b_multi_4=999; canon_pair_context 27b-multi 4')" = 999 ] \
  && ok "canon_pair_context: env-оверрайд пары > .env (носитель probe-попыток)" || bad "pair env"
# 1.2-совместимость: .env без пар-ключей (EXP-004-формат) читается fallback'ом
printf 'GFCTL_PROFILE=27b-multi\nGFCTL_SESSIONS=2\nGFCTL_CONTEXT=163840\nGFCTL_PORT=8080\nGFCTL_BIND=0.0.0.0\nGFCTL_MODELS=%s\nGFCTL_IMAGE=ghcr.io/gufo-org/toolboxes/gufo-runtime:latest\n' "$TMP/stack/models" > "$TMP/stack/.env"
[ "$(gf 'canon_pair_context 27b-multi 2')" = 163840 ] \
  && ok "1.2-формат: активные поля канона = канон пары (миграция чтением)" || bad "pair fallback 1.2"
[ -z "$(gf 'canon_pair_context 27b-multi 3')" ] \
  && ok "та же пара с чужой sessions → канона нет (пусто → probe)" || bad "pair чужая sessions"
[ -z "$(gf 'canon_pair_context flash-multi 2')" ] \
  && ok "чужой профиль → канона пары нет (пусто → probe)" || bad "pair чужой профиль"

echo "== 15. serve_args: канон 27b-single байт-в-байт; multi/flash; чистота; чужой токен"
: > "$FAUXLOG"
CANON_ARGS="gufo serve llm --host 0.0.0.0 --model /models/qwen3.8-27b-IQ4_XS-pure.gguf --speculative dflash2 --dflash-model /models/Qwen3.8-27B-DFlash2-Q4_K_M.gguf --sessions 1 --context 262144 --cache-ram-bytes 12884901888 --cache-disk /cache --cache-disk-bytes 68719476736"
[ "$(gf 'serve_args 27b-single 1 262144')" = "$CANON_ARGS" ] \
  && ok "serve_args 27b-single = канону Design (байт-в-байт)" || bad "serve_args канон: '$(gf 'serve_args 27b-single 1 262144')'"
a1=$(gf 'serve_args 27b-single 1 262144'); a2=$(gf 'serve_args 27b-single 1 262144')
[ "$a1" = "$a2" ] && ok "serve_args чистая (два вызова — идентичный вывод)" || bad "serve_args нечистая"
sa_multi=$(gf 'serve_args 27b-multi 2 163840')
grep -q '/models/Qwen3.8-27B-DFlash2-Q4_K_M.gguf' <<<"$sa_multi" && grep -q -- '--sessions 2 --context 163840' <<<"$sa_multi" \
  && ok "serve_args 27b-multi: draft-путь + sessions/context оверрайд" || bad "serve_args multi"
sa_flash=$(gf 'serve_args flash-multi 2 131072')
grep -q -- '--model /models/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf' <<<"$sa_flash" \
  && grep -q -- '--mtp-model /models/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf' <<<"$sa_flash" \
  && ok "serve_args flash: --model = ПЕРВЫЙ шард 00001 + --mtp-model" || bad "serve_args flash"
set +e; gf 'set_s="m.gguf|1|0|u|main"
profile_bad="s|56|1|1024|1|1|--speculative x --foo @BOGUS@|-|тест"
serve_args bad 1 1024' >/dev/null 2>&1; tk_rc=$?; set -e
[ "$tk_rc" = 1 ] && ok "serve_args: неизвестный токен @BOGUS@ → die rc 1" || bad "serve_args токен (rc=$tk_rc)"

echo "== 16. render_tpl: подстановка + die на чужом __X__"
printf 'host __STACK_DIR__ podman __PODMAN_BIN__ c __CONTAINER__\n' > "$TMP/u1.tpl"
gf 'render_tpl "$TMP/u1.tpl" "$TMP/u1.out" PODMAN_BIN="/usr/bin/podman" STACK_DIR="/home/x/gufo" CONTAINER="gufo"' >/dev/null 2>&1
[ "$(cat "$TMP/u1.out")" = "host /home/x/gufo podman /usr/bin/podman c gufo" ] \
  && ok "render_tpl: __X__ → значения" || bad "render_tpl подстановка"
set +e; printf 'oops __BOGUS__\n' > "$TMP/u2.tpl"
gf 'render_tpl "$TMP/u2.tpl" "$TMP/u2.out" FOO=1' >/dev/null 2>&1; rr_rc=$?; set -e
[ "$rr_rc" = 1 ] && ok "render_tpl: чужой __BOGUS__ → die rc 1" || bad "render_tpl die (rc=$rr_rc)"

echo "== 17. install happy-path (faux-bin): канон-строка podman run байт-в-байт + юниты + порядок"
mkdir -p "$TMP/stack/models/27b"
truncate -s 14534384640 "$TMP/stack/models/27b/qwen3.8-27b-IQ4_XS-pure.gguf"   # sparse — stat честен, диск не тратится
truncate -s 1143006816 "$TMP/stack/models/27b/Qwen3.8-27B-DFlash2-Q4_K_M.gguf"
gf 'write_canon 27b-single 1 262144' >/dev/null 2>&1   # канон после §14-фикстур
: > "$FAUXLOG"; rm -f "$FAUXCNT" "$FAUXCNT.curl"
set +e; out=$(GFCTL_FAUX_PODMAN_LOGS="$LOGOK" gf 'gpu_nodes_present(){ return 0; }
ram_gate_line(){ printf "%s: ≥N GiB — есть 999.0: OK\n" "$1"; }
ulimit(){ echo unlimited; }
cmd_install --profile 27b-single' 2>&1); in_rc=$?; set -e
[ "$in_rc" = 0 ] && grep -q 'SMOKE: OK' <<<"$out" && grep -q 'автозапуск ВКЛ' <<<"$out" \
  && ok "install happy-path → rc 0 (health + smoke + автозапуск)" || { bad "install happy-path (rc=$in_rc)"; tail -5 <<<"$out"; }
CANON_RUN="podman run -d --name gufo --device /dev/kfd --device /dev/dri --group-add keep-groups --ipc=host --ulimit memlock=-1:-1 --userns=keep-id:uid=1000,gid=1000 -p 0.0.0.0:8080:8080 -v $TMP/stack/models/27b:/models:ro -v $TMP/stack/cache/27b-single:/cache ghcr.io/gufo-org/toolboxes/gufo-runtime:latest $CANON_ARGS"
grep -Fxq "$CANON_RUN" "$FAUXLOG" \
  && ok "podman run в faux-логе = канонической строке Design (байт-в-байт)" || bad "podman run ≠ канону"
ud="$TMP/home/.config/systemd/user"
[ -f "$ud/gfctl-serve.service" ] && [ -f "$ud/gfctl-watchdog.service" ] && [ -f "$ud/gfctl-watchdog.timer" ] \
  && ok "install_units: 3 юнита в systemd-user (идемпотентные имена)" || bad "юниты не сгенерированы"
grep -q '^ExecStart=/usr/bin/env bash .*gfctl _boot$' "$ud/gfctl-serve.service" \
  && grep -q '^KillMode=process$' "$ud/gfctl-serve.service" \
  && grep -q '^TimeoutStartSec=900$' "$ud/gfctl-serve.service" \
  && ok "serve-юнит: ExecStart=_boot + KillMode=process + TimeoutStartSec=900" || bad "serve-юнит контент"
grep -q '^ExecStop=.*podman rm -f gufo$' "$ud/gfctl-serve.service" \
  && ok "serve-юнит: ExecStop = podman rm -f (страховка)" || bad "serve-юнит ExecStop"
grep -q '_watchdog' "$ud/gfctl-watchdog.service" \
  && ok "watchdog-юнит: ExecStart=_watchdog" || bad "watchdog-юнит"
grep -q '^OnUnitActiveSec=1min$' "$ud/gfctl-watchdog.timer" \
  && ok "таймер: OnUnitActiveSec=1min" || bad "таймер 1 мин"
grep -q 'sudo loginctl enable-linger' "$FAUXLOG" \
  && ok "autostart_on: enable-linger вызван" || bad "enable-linger"
[ ! -e "$TMP/stack/.gfctl-stopped" ] && ok "install: маркер остановки снят" || bad "маркер не снят"
i_rm=$(grep -n '^podman rm' "$FAUXLOG" | head -n1 | cut -d: -f1)
i_run=$(grep -n '^podman run' "$FAUXLOG" | head -n1 | cut -d: -f1)
i_logs=$(grep -n '^podman logs' "$FAUXLOG" | head -n1 | cut -d: -f1)
i_ready=$(grep -n '/ready' "$FAUXLOG" | head -n1 | cut -d: -f1)
i_chat=$(grep -n '/v1/chat/completions' "$FAUXLOG" | head -n1 | cut -d: -f1)
if [ -n "$i_rm" ] && [ "$i_rm" -lt "$i_run" ] && [ "$i_run" -lt "$i_logs" ] && [ "$i_logs" -lt "$i_ready" ] && [ "$i_ready" -lt "$i_chat" ]; then
  ok "порядок recreate→health→smoke: rm < run < logs < /ready < chat (по логу)"
else
  bad "порядок вызовов: rm=$i_rm run=$i_run logs=$i_logs ready=$i_ready chat=$i_chat"
fi
grep -q 'SKIP: qwen3.8-27b-IQ4_XS-pure.gguf' <<<"$out" \
  && ok "install идемпотентен по весам: полные файлы — SKIP без вопросов" || bad "weights SKIP"
n_run1=$(grep -c '^podman run -d' "$FAUXLOG")
set +e; out2=$(GFCTL_FAUX_PODMAN_LOGS="$LOGOK" gf 'gpu_nodes_present(){ return 0; }
ram_gate_line(){ printf "%s: ≥N GiB — есть 999.0: OK\n" "$1"; }
ulimit(){ echo unlimited; }
cmd_install --profile 27b-single' 2>&1); in2_rc=$?; set -e
[ "$in2_rc" = 0 ] && ok "install повтор поверх работающего → rc 0 (идемпотентен)" || bad "install повтор (rc=$in2_rc)"
n_run2=$(grep -c '^podman run -d' "$FAUXLOG")
[ "$((n_run2 - n_run1))" = 1 ] && ok "повтор install: ровно один recreate (run +1, дублей нет)" || bad "повтор install run Δ=$((n_run2 - n_run1))"
[ "$(ls "$ud" | wc -l)" = 3 ] && ok "повтор install: юнит-файлов по-прежнему 3" || bad "дубли юнитов"

echo "== 18. use: гейты → ленивая докачка → канон → recreate → health → smoke"
set +e; ./gfctl use bogus >/dev/null 2>&1; u1_rc=$?
./gfctl use 27b-single --sessions abc >/dev/null 2>&1; u2_rc=$?; set -e
[ "$u1_rc" = 1 ] && ok "use неизвестный профиль → die rc 1" || bad "use bogus (rc=$u1_rc)"
[ "$u2_rc" = 1 ] && ok "use --sessions abc → die rc 1" || bad "use --sessions abc (rc=$u2_rc)"
: > "$FAUXLOG"; rm -f "$FAUXCNT" "$FAUXCNT.curl"
set +e; out=$(GFCTL_FAUX_PODMAN_LOGS="$LOGOK" gf 'ram_gate_line(){ printf "%s: ≥N GiB — есть 999.0: OK\n" "$1"; }
cmd_use 27b-multi --sessions 2 --context 163840' 2>&1); us_rc=$?; set -e
[ "$us_rc" = 0 ] && grep -q 'SMOKE: OK' <<<"$out" && ok "use happy-path → rc 0 (health+smoke)" || bad "use happy-path (rc=$us_rc)"
grep -q '^GFCTL_PROFILE=27b-multi$' "$TMP/stack/.env" \
  && grep -q '^GFCTL_SESSIONS=2$' "$TMP/stack/.env" && grep -q '^GFCTL_CONTEXT=163840$' "$TMP/stack/.env" \
  && ok "use: канон перезаписан (профиль+sessions+context)" || bad "use канон"
n_run_u1=$(grep -c '^podman run -d' "$FAUXLOG")
grep -q -- '--sessions 2 --context 163840' "$FAUXLOG" \
  && ok "use: recreate c sessions/context оверрайда" || bad "use run args"
grep -q '/models/Qwen3.8-27B-DFlash2-Q4_K_M.gguf' <<<"$(grep '^podman run' "$FAUXLOG" | tail -n1)" \
  && ok "use 27b-multi: @DRAFT@ → контейнерный путь /models/<draft>" || bad "use draft путь"
! grep -q '^systemctl' "$FAUXLOG" \
  && ok "use: автозапуск не трогает (нет systemctl-вызовов)" || bad "use трогает автозапуск"
set +e; out=$(GFCTL_FAUX_PODMAN_LOGS="$LOGOK" gf 'ram_gate_line(){ printf "%s: ≥N GiB — есть 999.0: OK\n" "$1"; }
cmd_use 27b-single --no-probe' 2>&1); up_rc=$?; set -e
[ "$up_rc" = 0 ] && grep -q 'WARN' <<<"$out" \
  && ok "use --no-probe → WARN no-op, rc 0 (OQ orchestrator)" || bad "use --no-probe (rc=$up_rc)"

echo "== 19. health: parse_route / wait_load / wait_health / load_failed / http"
pr=$(gf 'parse_route < <(printf "%s\n" "boot" "event=load_completed speculative=dflash2 sessions=1 context_tokens=262144 model=A" "noise" "event=load_completed speculative=mtp sessions=2 context_tokens=131072 model=B")
printf "[%s|%s|%s|%s]" "$ROUTE_SPEC" "$ROUTE_SESSIONS" "$ROUTE_CTX" "$ROUTE_MODEL"')
[ "$pr" = "[mtp|2|131072|B]" ] && ok "parse_route: ПОСЛЕДНЯЯ load_completed побеждает (все 4 поля)" || bad "parse_route: '$pr'"
pr0=$(gf 'parse_route < <(printf "nothing here\n"); printf "[%s|%s|%s|%s]" "${ROUTE_SPEC:-}" "${ROUTE_SESSIONS:-}" "${ROUTE_CTX:-}" "${ROUTE_MODEL:-}"')
[ "$pr0" = "[|||]" ] && ok "parse_route: нет load_completed → пустые ROUTE_*, rc 0" || bad "parse_route пусто"
set +e; out=$(GFCTL_FAUX_PODMAN_LOGS="$LOGOK" gf 'wait_load 4' 2>&1); wl_rc=$?; set -e
[ "$wl_rc" = 0 ] && grep -q 'загрузка завершена после 0с' <<<"$out" \
  && ok "wait_load: fixture-лог с load_completed → rc 0" || bad "wait_load ok (rc=$wl_rc)"
set +e; out=$(GFCTL_FAUX_PODMAN_LOGS="$LOGOK" gf 'wait_health 180' 2>&1); wh_rc=$?; set -e
[ "$wh_rc" = 0 ] && grep -q 'роут: dflash2, sessions 1, ctx 262144' <<<"$out" \
  && ok "wait_health: rc 0 + строка роута «роут: dflash2, sessions 1, ctx 262144»" || bad "wait_health (rc=$wh_rc)"
set +e; out=$(GFCTL_FAUX_PODMAN_LOGS="$LOGNONE" gf 'wait_load 3' 2>&1); wt_rc=$?; set -e
[ "$wt_rc" = 1 ] && grep -q 'listening' <<<"$out" \
  && ok "wait_load: нет load_completed → таймаут rc 1 + хвост логов" || bad "wait_load таймаут (rc=$wt_rc)"
set +e; out=$(GFCTL_FAUX_PODMAN_LOGS="$LOGFAIL" GFCTL_LOADFAIL_AFTER=0 gf 'wait_load 30' 2>&1); wf_rc=$?; set -e
[ "$wf_rc" = 1 ] && grep -q 'WARN.*load_failed' <<<"$out" \
  && ok "wait_load: load_failed → ранний выход rc 1 (seam GFCTL_LOADFAIL_AFTER)" || bad "load_failed early (rc=$wf_rc)"
set +e; out=$(GFCTL_FAUX_PODMAN_LOGS="$LOGOK" GFCTL_FAUX_CURL_READYFAIL=1 gf 'wait_health 10' 2>&1); hc_rc=$?; set -e
[ "$hc_rc" = 1 ] && ! grep -q '^роут:' <<<"$out" \
  && ok "wait_health: /ready не отвечает → rc 1 (роут не печатается)" || bad "wait_health http-отказ (rc=$hc_rc)"

echo "== 20. boot/watchdog/off/on/up: маркер РАНЬШЕ подъёма; on возвращает всё"
: > "$FAUXLOG"
set +e; out=$(gf 'gpu_nodes_present(){ return 1; }; cmd_boot 2 1' 2>&1); b1_rc=$?; set -e
[ "$b1_rc" = 1 ] && grep -q 'boot:' <<<"$out" \
  && ok "cmd_boot: GPU-ноды не появились в бюджет (2с/1с) → rc 1 + сообщение" || bad "boot отказ (rc=$b1_rc)"
rm -f "$TMP/gpucnt"
set +e; out=$(GFCTL_FAUX_INSPECT=running gf "gpucnt=\"$TMP/gpucnt\"
gpu_nodes_present(){ n=\$(cat \"\$gpucnt\" 2>/dev/null || echo 0); n=\$((n+1)); echo \$n > \"\$gpucnt\"; [ \"\$n\" -ge 2 ]; }
cmd_boot 30 1" 2>&1); b2_rc=$?; set -e
[ "$b2_rc" = 0 ] && [ "$(grep -c '^podman run -d' "$FAUXLOG")" = 1 ] \
  && ok "cmd_boot: нода появилась со 2-й проверки → ровно один run, rc 0" || bad "boot gpu-late (rc=$b2_rc, run=$(grep -c '^podman run -d' "$FAUXLOG"))"
: > "$FAUXLOG"; touch "$TMP/stack/.gfctl-stopped"
set +e; out=$(frun _watchdog 2>&1); wd1_rc=$?; set -e
[ "$wd1_rc" = 0 ] && [ "$(grep -c '^podman' "$FAUXLOG")" = 0 ] \
  && ok "_watchdog: маркер на месте → ПЕРВАЯ проверка, ноль podman-вызовов, rc 0" || bad "watchdog маркер"
mv "$TMP/stack/.gfctl-stopped" "$TMP/stack/.env.hidden"; mv "$TMP/stack/.env" "$TMP/stack/.env.keep" 2>/dev/null || true
: > "$FAUXLOG"
set +e; out=$(frun _watchdog 2>&1); wd2_rc=$?; set -e
[ "$wd2_rc" = 0 ] && [ "$(grep -c '^podman' "$FAUXLOG")" = 0 ] \
  && ok "_watchdog: canon .env отсутствует → return 0 (поднимать нечего)" || bad "watchdog no-env"
mv "$TMP/stack/.env.hidden" "$TMP/stack/.env"; mv "$TMP/stack/.env.keep" "$TMP/stack/.env" 2>/dev/null || true
: > "$FAUXLOG"
set +e; out=$(GFCTL_FAUX_INSPECT=exited frun _watchdog 2>&1); wd3_rc=$?; set -e
[ "$wd3_rc" = 0 ] && [ "$(grep -c '^podman run -d' "$FAUXLOG")" = 1 ] \
  && ok "_watchdog: без маркера + exited → ровно один run, rc 0" || bad "watchdog up (rc=$wd3_rc)"
grep -q 'state=exited -> up' "$TMP/stack/logs/watchdog.log" \
  && ok "_watchdog: событие дописано в logs/watchdog.log" || bad "watchdog.log"
: > "$FAUXLOG"
set +e; out=$(gf 'touch() { printf "touch %s\n" "$*" >> "$GFCTL_FAUX_LOG"; command touch "$@"; }
cmd_off' 2>&1); off_rc=$?; set -e
[ "$off_rc" = 0 ] && ok "cmd_off → rc 0 (2 итоговые строки)" || bad "off rc=$off_rc"
first_touch=$(grep -n '^touch ' "$FAUXLOG" | head -n1 | cut -d: -f1)
first_rm=$(grep -n '^podman rm' "$FAUXLOG" | head -n1 | cut -d: -f1)
first_dis=$(grep -n '^systemctl --user disable' "$FAUXLOG" | head -n1 | cut -d: -f1)
if [ -n "$first_touch" ] && [ "$first_touch" -lt "$first_rm" ] && [ "$first_rm" -lt "$first_dis" ]; then
  ok "off: touch-маркер РАНЬШЕ podman rm и systemctl disable (порядок фиксированный)"
else
  bad "off порядок: touch=$first_touch rm=$first_rm disable=$first_dis"
fi
[ -f "$TMP/stack/.gfctl-stopped" ] && ok "off: маркер .gfctl-stopped существует" || bad "off маркер"
[ ! -e "$ud/gfctl-serve.service" ] && [ ! -e "$ud/gfctl-watchdog.timer" ] \
  && ok "off: юнит-файлы удалены" || bad "off юниты остались"
grep -q 'sudo loginctl disable-linger' "$FAUXLOG" && ok "off: linger off (F11)" || bad "off linger"
: > "$FAUXLOG"
set +e; out=$(GFCTL_FAUX_PODMAN_LOGS="$LOGOK" frun on 2>&1); on_rc=$?; set -e
[ "$on_rc" = 0 ] && ok "gfctl on → rc 0 (юниты+timer+linger+подъём)" || bad "on rc=$on_rc"
[ ! -e "$TMP/stack/.gfctl-stopped" ] && ok "on: маркер снят" || bad "on маркер не снят"
grep -q '^systemctl --user enable gfctl-serve.service gfctl-watchdog.timer$' "$FAUXLOG" \
  && ok "on: enable serve+timer" || bad "on enable"
[ "$(grep -c '/v1/chat/completions' "$FAUXLOG")" = 0 ] \
  && ok "on быстрый: smoke НЕ зовётся (0 chat-вызовов)" || bad "on зовёт smoke"
[ -f "$ud/gfctl-serve.service" ] && ok "on: юниты восстановлены" || bad "on юниты"
: > "$FAUXLOG"
set +e; out=$(GFCTL_FAUX_PODMAN_LOGS="$LOGOK" frun up 2>&1); upup_rc=$?; set -e
[ "$upup_rc" = 0 ] && [ "$(grep -c '^podman run -d' "$FAUXLOG")" = 1 ] \
  && ok "up (алиас): маркер снят + ровно один run + health, rc 0" || bad "up (rc=$upup_rc)"
! grep -q '^systemctl' "$FAUXLOG" && ok "up: автозапуск не трогает" || bad "up трогает автозапуск"

echo "== 21. recreate-ретрай (F10): run падает 1 раз → 2 вызова; все попытки → die"
: > "$FAUXLOG"; rm -f "$FAUXCNT"
set +e; out=$(GFCTL_FAUX_RUNFAIL=1 gf 'container_up 27b-single' 2>&1); r1_rc=$?; set -e
[ "$r1_rc" = 0 ] && [ "$(grep -c '^podman run -d' "$FAUXLOG")" = 2 ] \
  && ok "ретрай: 1-й run упал → ровно 2 вызова run, rc 0" || bad "ретрай 1 (rc=$r1_rc, run=$(grep -c '^podman run -d' "$FAUXLOG"))"
: > "$FAUXLOG"; rm -f "$FAUXCNT"
set +e; out=$(GFCTL_FAUX_RUNFAIL=99 GFCTL_RUN_ATTEMPTS=3 gf 'container_up 27b-single' 2>&1); r2_rc=$?; set -e
[ "$r2_rc" = 1 ] && [ "$(grep -c '^podman run -d' "$FAUXLOG")" = 3 ] \
  && ok "ретрай: все GFCTL_RUN_ATTEMPTS неудачны → die rc 1, вызовов run = attempts" || bad "ретрай 2 (rc=$r2_rc)"

echo "== 22. logs: -f/--tail порядок; missing → die"
: > "$FAUXLOG"
set +e; out=$(GFCTL_FAUX_INSPECT=running frun logs 50 -f 2>&1); lg_rc=$?; set -e
grep -q '^podman logs -f --tail 50 gufo$' "$FAUXLOG" \
  && ok "logs 50 -f → podman logs -f --tail 50" || bad "logs args"
[ "$lg_rc" = 0 ] && ok "logs rc 0" || bad "logs rc=$lg_rc"
set +e; out=$(frun logs 2>&1); lg2_rc=$?; set -e
[ "$lg2_rc" = 1 ] && grep -q 'контейнера' <<<"$out" \
  && ok "logs: missing-контейнер → die rc 1" || bad "logs missing (rc=$lg2_rc)"

echo "== 23. smoke: 3 запроса; ретрай РОВНО первого (F15); провал → rc 1"
: > "$FAUXLOG"; rm -f "$FAUXCNT.curl"
set +e; out=$(GFCTL_FAUX_INSPECT=running GFCTL_FAUX_PODMAN_LOGS="$LOGOK" frun smoke 2>&1); sm_rc=$?; set -e
[ "$sm_rc" = 0 ] && grep -q 'SMOKE: OK' <<<"$out" \
  && ok "smoke happy-path → SMOKE: OK rc 0" || bad "smoke happy (rc=$sm_rc)"
[ "$(cat "$FAUXCNT.curl")" = 3 ] && ok "smoke: ровно 3 chat-вызова (без ретрая)" || bad "smoke вызовы=$(cat "$FAUXCNT.curl")"
grep -q 'роут: dflash2, sessions 1, ctx 262144' <<<"$out" && ok "smoke печатает роут" || bad "smoke роут"
: > "$FAUXLOG"; rm -f "$FAUXCNT.curl"
set +e; out=$(GFCTL_FAUX_INSPECT=running GFCTL_FAUX_PODMAN_LOGS="$LOGOK" GFCTL_FAUX_CURL_FAILFIRST=1 frun smoke 2>&1); sm2_rc=$?; set -e
[ "$sm2_rc" = 0 ] && [ "$(cat "$FAUXCNT.curl")" = 4 ] && grep -q 'повторяю' <<<"$out" \
  && ok "ретрай первого: 2+1+1 = 4 curl-вызова, WARN, rc 0" || bad "smoke ретрай (rc=$sm2_rc, n=$(cat "$FAUXCNT.curl"))"
: > "$FAUXLOG"; rm -f "$FAUXCNT.curl"
set +e; out=$(GFCTL_FAUX_INSPECT=running GFCTL_FAUX_PODMAN_LOGS="$LOGOK" GFCTL_FAUX_CURL_FAILALL=1 frun smoke 2>&1); sm3_rc=$?; set -e
[ "$sm3_rc" = 1 ] && ok "все запросы неудачны → rc 1" || bad "smoke провал (rc=$sm3_rc)"

echo "== 24. uninstall: слои; модели и образ по умолчанию живы"
gf 'install_units' >/dev/null 2>&1   # юниты для слоя 2 (off в §20 их снёс)
: > "$FAUXLOG"
set +e; out=$(GFCTL_YES=1 frun uninstall </dev/null 2>&1); un_rc=$?; set -e
[ "$un_rc" = 0 ] && ok "uninstall (GFCTL_YES) → rc 0" || bad "uninstall rc=$un_rc"
[ -f "$TMP/stack/models/27b/qwen3.8-27b-IQ4_XS-pure.gguf" ] \
  && ok "uninstall без флагов: веса на месте" || bad "весs удалены!"
! grep -q '^podman rmi' "$FAUXLOG" && ok "uninstall без флагов: podman rmi ОТСУТСТВУЕТ" || bad "rmi был"
[ ! -e "$TMP/stack/.env" ] && [ ! -e "$TMP/stack/cache" ] \
  && ok "uninstall: дерево стека снесено (кроме models)" || bad "стек не снесён"
grep -q 'sudo rm -f /etc/security/limits.d/99-gfctl-memlock.conf' "$FAUXLOG" \
  && ok "uninstall: слой limits.d (sudo rm)" || bad "limits.d слой"
grep -q 'sudo loginctl disable-linger' "$FAUXLOG" && ok "uninstall: linger off" || bad "linger"
[ ! -e "$ud/gfctl-serve.service" ] && ok "uninstall: юниты удалены" || bad "юниты"
set +e; out=$(GFCTL_YES=1 frun uninstall --purge-models --purge-image </dev/null 2>&1); un2_rc=$?; set -e
[ "$un2_rc" = 0 ] && [ ! -e "$TMP/stack/models" ] \
  && ok "uninstall --purge-models: база весов удалена" || bad "purge-models"
grep -q '^podman rmi ghcr.io/gufo-org/toolboxes/gufo-runtime:latest' "$FAUXLOG" \
  && ok "uninstall --purge-image: podman rmi в логе" || bad "purge-image"
mkdir -p "$TMP/stack/models/27b"; truncate -s 1143006816 "$TMP/stack/models/27b/d.gguf"; printf 'GFCTL_PROFILE=27b-single\n' > "$TMP/stack/.env"
set +e; out=$(frun uninstall </dev/null 2>&1); un3_rc=$?; set -e
[ "$un3_rc" = 1 ] && [ -f "$TMP/stack/.env" ] \
  && ok "uninstall без согласия (не-TTY, без GFCTL_YES) → rc 1, НИЧЕГО не удалено" || bad "uninstall отказ (rc=$un3_rc)"

echo "== 25. status живой: роут из лога + автозапуск + версия + кэш (процесс + faux)"
gf 'write_canon 27b-single 1 262144' >/dev/null 2>&1
mkdir -p "$TMP/stack/models/27b"   # §24 purge-models снёс веса — восстанавливаем sparse-фикстуры
truncate -s 14534384640 "$TMP/stack/models/27b/qwen3.8-27b-IQ4_XS-pure.gguf"
truncate -s 1143006816 "$TMP/stack/models/27b/Qwen3.8-27B-DFlash2-Q4_K_M.gguf"
mkdir -p "$TMP/stack/cache/27b-single"; head -c 512 /dev/urandom > "$TMP/stack/cache/27b-single/blob"
python3 - <<'PYEOF' &
import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 8080)); s.listen(5)
time.sleep(45)
PYEOF
LISPID=$!
sleep 0.4
set +e; out=$(GFCTL_FAUX_INSPECT="ghcr.io/gufo-org/toolboxes/gufo-runtime:latest" GFCTL_FAUX_PODMAN_LOGS="$LOGOK" frun status 2>&1); st1_rc=$?; set -e
grep -q '^профиль: 27b-single | health: ok | автозапуск: вкл | роут: dflash2, sessions 1, ctx 262144 | кэш: .*cache/27b-single ([0-9.]* GiB) | веса 27b: 2/2$' <<<"$out" \
  && ok "status живой: человекострока (роут+автозапуск+кэш+веса)" || bad "status живая строка: $out"
GFCTL_FAUX_INSPECT="ghcr.io/gufo-org/toolboxes/gufo-runtime:latest" GFCTL_FAUX_PODMAN_LOGS="$LOGOK" \
  frun status --json > "$TMP/status_live.json" 2>&1
python3 - "$TMP/status_live.json" <<'EOF' && ok "status --json живой: route/autostart/version/cache + старые ключи на месте" || bad "status live JSON"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["health"] == "ok", d
assert d["route"] == {"speculative": "dflash2", "sessions": 1, "context": 262144,
                      "model": "qwen3.8-27b-IQ4_XS-pure"}, d
assert d["autostart"] is True, d
assert d["version"] == "ghcr.io/gufo-org/toolboxes/gufo-runtime:latest", d
assert d["cache"]["dir"].endswith("cache/27b-single"), d
assert isinstance(d["cache"]["bytes"], int), d
# схема 1.1: старые ключи и типы на месте
assert d["port"] == 8080 and d["bind"] == "0.0.0.0", d
assert set(d["gates"]) == {"27b-single", "27b-multi", "flash-multi"}, d
assert d["models"]["27b"]["present"] == 2 and isinstance(d["models"]["27b"]["complete"], bool), d
EOF
kill "$LISPID" 2>/dev/null || true
wait "$LISPID" 2>/dev/null || true

# ══ 2.1: probe-подбор контекста + bench ══════════════════════════════════════
GATE_OK='ram_gate_line(){ printf "%s: ≥N GiB — есть 999.0: OK\n" "$1"; }'
NO_W='ensure_weights(){ return 0; }'

echo "== 26. probe 27b-multi: 196608 fail → 163840 ok; попытки по порядку; канон пары; успех БЕЗ второго run"
rm -f "$TMP/stack/.env" "$FAUXCNT.ctx"; : > "$FAUXLOG"; rm -f "$FAUXCNT.curl"
set +e
out=$(GFCTL_LOADFAIL_AFTER=0 GFCTL_FAUX_CTX_LOGS="196608:$LOGFAIL 163840:$LOGOK 131072:$LOGOK" \
  gf "$GATE_OK
cmd_use 27b-multi" 2>&1); pb_rc=$?; set -e
[ "$pb_rc" = 0 ] && grep -q 'SMOKE: OK' <<<"$out" \
  && ok "probe fail→ok: rc 0 + SMOKE" || { bad "probe fail→ok (rc=$pb_rc)"; tail -8 <<<"$out"; }
grep -q 'канона пары (27b-multi × 2) нет — probe-подбор по лестнице' <<<"$out" \
  && ok "use без канона пары → probe-подбор объявлен" || bad "probe не объявлен"
grep -q '^GFCTL_PROFILE=27b-multi$' "$TMP/stack/.env" && grep -q '^GFCTL_SESSIONS=2$' "$TMP/stack/.env" \
  && grep -q '^GFCTL_CONTEXT=163840$' "$TMP/stack/.env" && grep -q '^GFCTL_CTX_27b_multi_2=163840$' "$TMP/stack/.env" \
  && ok "успех: канон пары записан (активные поля + GFCTL_CTX_27b_multi_2=163840)" || bad "канон пары после probe"
mapfile -t pruns < <(grep '^podman run' "$FAUXLOG")
[ "${#pruns[@]}" = 2 ] && [[ ${pruns[0]} == *'--context 196608'* ]] && [[ ${pruns[1]} == *'--context 163840'* ]] \
  && ok "лестница по порядку: --context 196608 затем 163840; РОВНО 2 run (успех без второго recreate)" \
  || bad "run-линии probe: $(grep -c '^podman run' "$FAUXLOG") шт"
J26="$TMP/stack/logs/probe-27b-multi-2.log"
grep -q 'ступень 196608: попытка загрузки (sessions 2)' "$J26" && grep -q 'ступень 196608: ОТКАЗ — load_failed' "$J26" \
  && grep -q 'ступень 163840: OK — канон' "$J26" && ! grep -q 'ступень 131072' "$J26" \
  && ok "журнал попыток: обе ступени с вердиктами; 131072 не достигнута (успех раньше)" || bad "журнал probe (26)"

echo "== 27. probe flash-multi: 262144 fail → 229376 fail → 196608 ok"
rm -f "$TMP/stack/.env" "$FAUXCNT.ctx"; : > "$FAUXLOG"
set +e
out=$(GFCTL_LOADFAIL_AFTER=0 \
  GFCTL_FAUX_CTX_LOGS="262144:$LOGFAIL 229376:$LOGFAIL 196608:$LOGOK 163840:$LOGOK 131072:$LOGOK" \
  gf "$GATE_OK
$NO_W
cmd_use flash-multi" 2>&1); pf_rc=$?; set -e
[ "$pf_rc" = 0 ] && grep -q '^GFCTL_CTX_flash_multi_2=196608$' "$TMP/stack/.env" \
  && ok "flash-лестница: rc 0, канон пары 196608 (GFCTL_CTX_flash_multi_2)" || { bad "flash probe (rc=$pf_rc)"; tail -8 <<<"$out"; }
mapfile -t fruns < <(grep '^podman run' "$FAUXLOG")
[ "${#fruns[@]}" = 3 ] && [[ ${fruns[0]} == *'--context 262144'* ]] && [[ ${fruns[1]} == *'--context 229376'* ]] \
  && [[ ${fruns[2]} == *'--context 196608'* ]] \
  && ok "flash-лестница по порядку: 262144 → 229376 → 196608; ровно 3 run" || bad "flash run-линии"
[ "$(grep -c 'ОТКАЗ' "$TMP/stack/logs/probe-flash-multi-2.log")" = 2 ] \
  && ok "журнал flash: 2 отказа + OK (первая загрузившаяся = канон)" || bad "журнал flash (27)"

echo "== 28. probe полный отказ → die с таблицей попыток; .env НЕ испорчен; sessions=4 → подсказка 65536"
printf 'GFCTL_PROFILE=27b-single\nGFCTL_SESSIONS=1\nGFCTL_CONTEXT=262144\nGFCTL_PORT=8080\nGFCTL_BIND=0.0.0.0\nGFCTL_MODELS=%s\nGFCTL_IMAGE=x\n' "$TMP/stack/models" > "$TMP/stack/.env"
cp "$TMP/stack/.env" "$TMP/env.before"
rm -f "$FAUXCNT.ctx"; : > "$FAUXLOG"
set +e
out=$(GFCTL_LOADFAIL_AFTER=0 GFCTL_FAUX_CTX_LOGS="196608:$LOGFAIL 163840:$LOGFAIL 131072:$LOGFAIL" \
  gf "$GATE_OK
$NO_W
cmd_use 27b-multi" 2>&1); pa_rc=$?; set -e
[ "$pa_rc" = 1 ] \
  && grep -q 'ступень 196608: ОТКАЗ' <<<"$out" && grep -q 'ступень 163840: ОТКАЗ' <<<"$out" \
  && grep -q 'ступень 131072: ОТКАЗ' <<<"$out" && grep -q 'это тоже результат' <<<"$out" \
  && grep -q -- '--context N' <<<"$out" \
  && ok "все ступени отказали: die rc 1 + таблица (ступень → причина) + подсказка --context N" \
  || { bad "полный отказ (rc=$pa_rc)"; tail -6 <<<"$out"; }
cmp -s "$TMP/stack/.env" "$TMP/env.before" \
  && ok "отказ probe НЕ портит .env (ни пар-ключа, ни полей — свойство отката)" || bad ".env испорчен отказом"
[ "$(grep -c '^podman run' "$FAUXLOG")" = 3 ] \
  && ok "полный отказ: ровно 3 попытки (лестница целиком)" || bad "число попыток (28)"
set +e
out=$(GFCTL_LOADFAIL_AFTER=0 \
  GFCTL_FAUX_CTX_LOGS="262144:$LOGFAIL 229376:$LOGFAIL 196608:$LOGFAIL 163840:$LOGFAIL 131072:$LOGFAIL" \
  gf "$GATE_OK
$NO_W
cmd_use flash-multi --sessions 4" 2>&1); pa4_rc=$?; set -e
[ "$pa4_rc" = 1 ] && grep -q -- '--context 65536' <<<"$out" \
  && ok "sessions=4 полный отказ: die + подсказка --context 65536 (OQ-2a)" || bad "sessions4 отказ (rc=$pa4_rc)"
[ "$(grep -c 'ОТКАЗ' "$TMP/stack/logs/probe-flash-multi-4.log")" = 5 ] \
  && ok "журнал sessions=4: все 5 ступеней лестницы с отказами" || bad "журнал sessions4 (28)"

echo "== 29. повторный use с каноном пары = ровно ОДНА загрузка, пере-перебора нет"
gf 'write_canon 27b-multi 2 163840' >/dev/null 2>&1
rm -f "$FAUXCNT.ctx"; : > "$FAUXLOG"
set +e
out=$(GFCTL_FAUX_PODMAN_LOGS="$LOGOK" gf "$GATE_OK
cmd_use 27b-multi" 2>&1); pu_rc=$?; set -e
[ "$pu_rc" = 0 ] && grep -q 'канон пары (27b-multi × 2): context 163840 — probe пропущен' <<<"$out" \
  && ok "повторный use: «канон пары … — probe пропущен», rc 0" || { bad "повторный use (rc=$pu_rc)"; tail -6 <<<"$out"; }
[ "$(grep -c '^podman run' "$FAUXLOG")" = 1 ] \
  && ok "повторный use: ровно ОДИН podman run (DoD)" || bad "повторный use: run=$(grep -c '^podman run' "$FAUXLOG")"

echo "== 30. --no-probe: без канона → минимальная ступень; с каноном → канон; WARN всегда"
rm -f "$TMP/stack/.env" "$FAUXCNT.ctx"; : > "$FAUXLOG"
set +e
out=$(GFCTL_FAUX_PODMAN_LOGS="$LOGOK" gf "$GATE_OK
cmd_use 27b-multi --no-probe" 2>&1); np_rc=$?; set -e
[ "$np_rc" = 0 ] && grep -q 'WARN: --no-probe: канона пары (27b-multi × 2) нет — беру последнюю (минимальную) ступень лестницы 131072' <<<"$out" \
  && ok "--no-probe без канона: WARN + последняя (минимальная) ступень 131072" || bad "--no-probe без канона (rc=$np_rc)"
grep '^podman run' "$FAUXLOG" | grep -q -- '--context 131072' && [ "$(grep -c '^podman run' "$FAUXLOG")" = 1 ] \
  && ok "--no-probe без канона: ровно одна загрузка с --context 131072" || bad "--no-probe run-args (30)"
grep -q '^GFCTL_CTX_27b_multi_2=131072$' "$TMP/stack/.env" \
  && ok "--no-probe: результат зафиксирован в каноне пары (повтор не переберёт)" || bad "--no-probe канон (30)"
rm -f "$FAUXCNT.ctx"; : > "$FAUXLOG"
set +e
out=$(GFCTL_FAUX_PODMAN_LOGS="$LOGOK" gf "$GATE_OK
cmd_use 27b-multi --no-probe" 2>&1); np2_rc=$?; set -e
[ "$np2_rc" = 0 ] && grep -q 'WARN: --no-probe: беру канон пары (27b-multi × 2): context 131072' <<<"$out" \
  && [ "$(grep -c '^podman run' "$FAUXLOG")" = 1 ] \
  && ok "--no-probe с каноном: WARN + канон, ровно одна загрузка" || bad "--no-probe с каноном (rc=$np2_rc)"

echo "== 31. sessions=4 изоляция канона: (flash-multi,2) не затирается, (flash-multi,4) добавлен"
gf 'write_canon flash-multi 2 196608' >/dev/null 2>&1
rm -f "$FAUXCNT.ctx"; : > "$FAUXLOG"
set +e
out=$(GFCTL_LOADFAIL_AFTER=0 GFCTL_FAUX_CTX_LOGS="262144:$LOGOK" \
  gf "$GATE_OK
$NO_W
cmd_use flash-multi --sessions 4" 2>&1); s4_rc=$?; set -e
[ "$s4_rc" = 0 ] \
  && grep -q '^GFCTL_CTX_flash_multi_2=196608$' "$TMP/stack/.env" \
  && grep -q '^GFCTL_CTX_flash_multi_4=262144$' "$TMP/stack/.env" \
  && ok "канон (flash-multi,4) добавлен, (flash-multi,2) сохранён — пары изолированы" || { bad "sessions4 изоляция (rc=$s4_rc)"; tail -6 <<<"$out"; }
grep '^podman run' "$FAUXLOG" | grep -q -- '--sessions 4 --context 262144' \
  && ok "sessions=4: та же лестница, оверрайд меняет только admission (SPEC §5)" || bad "sessions4 run-args (31)"

echo "== 32. bench: живой (прогрев+3+медиана), мёртвый порт, нет контейнера, md5-гейт, битый ответ"
[ "$(md5sum tpl/bench/merge_sort_thinking_off.txt | awk '{print $1}')" = "253c7ac50857fe6d0e10fb0d2c5e35c0" ] \
  && ok "md5-гейт репо: фикстура bench не изменена (253c7ac5)" || bad "фикстура bench в репо ИЗМЕНЕНА"
set +e; out=$(frun bench 2>&1); b0_rc=$?; set -e
[ "$b0_rc" = 1 ] && grep -q 'не запущен' <<<"$out" \
  && ok "bench без контейнера → die «подними» rc 1" || bad "bench без контейнера (rc=$b0_rc)"
set +e; out=$(GFCTL_FAUX_INSPECT=running GFCTL_PORT=8099 frun bench 2>&1); b1_rc=$?; set -e
[ "$b1_rc" = 1 ] && grep -q 'мёртв' <<<"$out" \
  && ok "bench мёртвый порт → die «мёртв» rc 1 (DoD)" || bad "bench мёртвый порт (rc=$b1_rc)"
cp -r tpl "$TMP/tplbad"; printf 'x' >> "$TMP/tplbad/bench/merge_sort_thinking_off.txt"
python3 - <<'PYEOF' &
import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 8099)); s.listen(5)
time.sleep(60)
PYEOF
BLID=$!
sleep 0.4
set +e; out=$(GFCTL_FAUX_INSPECT=running GFCTL_PORT=8099 GFCTL_FAUX_PODMAN_LOGS="$LOGOK" \
  gf 'TPL_DIR="$TMP/tplbad"; cmd_bench' 2>&1); b2_rc=$?; set -e
[ "$b2_rc" = 1 ] && grep -q 'фикстура bench изменена' <<<"$out" \
  && ok "md5-гейт: подправленная КОПИЯ фикстуры → die (канон в репо не мутируется)" || bad "md5-гейт bench (rc=$b2_rc)"
rm -f "$FAUXCNT.curl"; : > "$FAUXLOG"
set +e; out=$(GFCTL_FAUX_INSPECT=running GFCTL_PORT=8099 GFCTL_FAUX_PODMAN_LOGS="$LOGOK" frun bench 2>&1); b3_rc=$?; set -e
[ "$b3_rc" = 0 ] && grep -q '^прогрев: wall ' <<<"$out" \
  && [ "$(grep -c '^прогон [123]: wall [0-9.]*s | 256 tok | [0-9.]* tok/s$' <<<"$out")" = 3 ] \
  && grep -q '^медиана: wall ' <<<"$out" \
  && ok "bench живой: прогрев + 3 прогона (wall|256 tok|tok/s) + медиана, rc 0" || { bad "bench живой (rc=$b3_rc)"; tail -8 <<<"$out"; }
[ "$(cat "$FAUXCNT.curl")" = 4 ] \
  && ok "bench: ровно 4 вызова curl (1 прогрев + 3 замера)" || bad "bench вызовы=$(cat "$FAUXCNT.curl")"
[ "$(grep -c '/v1/completions' "$FAUXLOG")" = 4 ] && [ "$(grep -c '/v1/chat/completions' "$FAUXLOG")" = 0 ] \
  && ok "bench: POST /v1/completions, fallback не срабатывал" || bad "bench эндпоинт"
rm -f "$FAUXCNT.curl"
set +e; out=$(GFCTL_FAUX_INSPECT=running GFCTL_PORT=8099 GFCTL_FAUX_PODMAN_LOGS="$LOGOK" \
  GFCTL_FAUX_CURL_FAILALL=1 frun bench 2>&1); b4_rc=$?; set -e
[ "$b4_rc" = 1 ] && [ "$(cat "$FAUXCNT.curl")" = 2 ] \
  && ! grep -q '^прогон 1:' <<<"$out" && ! grep -q '^медиана' <<<"$out" \
  && ok "bench битый ответ: die rc 1 на прогреве (completions+fallback = 2 вызова, без ретрая)" \
  || bad "bench FAILALL (rc=$b4_rc, curl=$(cat "$FAUXCNT.curl"))"
kill "$BLID" 2>/dev/null || true
wait "$BLID" 2>/dev/null || true

printf 'ИТОГО: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
