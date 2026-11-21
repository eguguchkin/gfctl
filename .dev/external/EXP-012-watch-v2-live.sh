#!/usr/bin/env bash
# EXP-012-watch-v2-live — живой прогон watch v2 (DoD 4.5 п.8, BLOCKED-EXTERNAL;
# окно этапа 5 по D6: живые запуски только по явному GO пользователя).
#
# Цель — на живой машине подтвердить:
#   1) отображение: /metrics отвечает HTTP 200; plain-стрим watch завершается
#      rc=0, все 5 блоков на месте ([железо]/[память]/[движок]/[скорость]/[логи]);
#   2) счётчики движутся МЕЖДУ тиками при живой генерации (gfctl bench в фоне):
#      тело строки [движок] меняется между тиками (счётчики/gauge) ИЛИ
#      [скорость] показывает ненулевой пульс хотя бы раз;
#   3) температуры [железо] согласуются с hwmon живой машины (±2 °C;
#      GPU = MAX temp1_input по картам vendor 0x1002, CPU = k10temp);
#      вывод sensors прикладывается как второе свидетельство;
#   4) TZ-метки [логи] согласуются с date хоста: сырая UTC-метка строки
#      движка → локальный HH:MM:SS секунда-в-секунду;
#   5) TUI на SSH-TTY: рамки пяти блоков отрисовались; q — чистый выход
#      rc 0; +/‑ меняют интервал ±1 c; p — пауза/снятие паузы логов
#      (подтверждает оператор — TTY-клавиши автоматом не гоняются).
#
# Предпосылки: машина окна этапа 5 (che-evo / che-FAEX1); `gfctl on`
# выполнен, модель загружена — сервер healthy на :8080 (`gfctl status`);
# запуск из клона gfctl С КОДОМ 4.5 (tpl/python/watch_{tui,engine,sysfs}.py);
# podman доступен юзеру (для [логи]); sensors желателен, но не обязателен
# (истина температур читается из hwmon напрямую). Прод не трогается:
# bench — только генерация по HTTP; юниты/контейнер/канон не меняются.
#
# Запуск (на машине, из корня клона; stdout/stderr → result-файл, stdin
# остаётся TTY — для ручной TUI-секции):
#   bash .dev/external/EXP-012-watch-v2-live.sh > \
#     .dev/external/EXP-012-watch-v2-live.result.txt 2>&1
#
# PASS: все автоматические проверки зелёные И оператор ответил «y» на оба
#   вопроса TUI-секции. Финальная строка файла:
#   RESULT: PASS|FAIL|ERROR — <пояснение>

set -u
cd "$(dirname "$0")/../.." || { echo "RESULT: ERROR — нет корня клона gfctl"; exit 1; }
PORT="${GFCTL_EXP_PORT:-8080}"
CONTAINER="${GFCTL_EXP_CONTAINER:-gufo}"
PASS=0; FAIL=0
ok()  { echo "PASS: $*"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }
section() { echo; echo "== $* =="; }

echo "EXP-012-watch-v2-live · $(date '+%F %T %Z') · host=$(hostname) · порт=$PORT · контейнер=$CONTAINER"

# ── 0. Отображение: сервер жив, /metrics 200 ──────────────────────────────
section "0. Отображение: /metrics 200"
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/metrics" || echo 000)
[ "$code" = 200 ] && ok "/metrics → HTTP 200" \
  || bad "/metrics → $code (нужен 200: gfctl on + модель загружена?)"

# ── 1. Plain-стрим + движение счётчиков (bench в фоне) ────────────────────
section "1. Plain-стрим: 4 тика × 2 c, генерация фоном (bench) — счётчики движутся, rc 0"
BENCH_LOG="$(mktemp /tmp/exp012-bench.XXXXXX)"
WOUT="$(mktemp /tmp/exp012-watch.XXXXXX)"
./gfctl bench > "$BENCH_LOG" 2>&1 &
BENCH_PID=$!
sleep 2
GFCTL_WATCH_TICKS=4 ./gfctl watch --interval 2 > "$WOUT" 2>&1
w_rc=$?
wait "$BENCH_PID" 2>/dev/null || true
echo "LOG: bench хвост: $(tail -2 "$BENCH_LOG" | tr '\n' ' ')"
[ "$w_rc" = 0 ] && ok "watch plain rc=0 (4 тика через диспетчер)" || bad "watch rc=$w_rc"
for blk in железо память движок скорость логи; do
  grep -q " \[$blk\] " "$WOUT" && ok "plain-стрим: блок [$blk] присутствует" \
    || bad "plain-стрим: блока [$blk] нет"
done
mapfile -t EN < <(grep ' \[движок\] ' "$WOUT" | sed 's/^.* \[движок\] //')
n=${#EN[@]}
[ "$n" = 4 ] && ok "[движок]-строк = тикам (4)" || bad "[движок]-строк: $n (ожидалось 4)"
if [ "$n" -ge 2 ]; then
  gen_first=$(sed -E 's/.*сген ([^ ]+).*/\1/' <<<"${EN[0]}")
  gen_last=$(sed -E 's/.*сген ([^ ]+).*/\1/' <<<"${EN[$((n-1))]}")
  echo "LOG: сген тик1=$gen_first тик$n=$gen_last; тело тик1: ${EN[0]}"
  if [ "${EN[0]}" != "${EN[$((n-1))]}" ]; then
    ok "счётчики движутся между тиками: тело [движок] изменилось (сген $gen_first → $gen_last)"
  elif grep -Eq 'пульс: (decode|prefill|drafts) \+[1-9]' "$WOUT"; then
    ok "счётчики движутся: ненулевой пульс в [скорость] (сген печатается грубо: $gen_first → $gen_last)"
  else
    bad "счётчики стоят: сген $gen_first → $gen_last, пульса нет (генерация шла во время тиков?)"
  fi
  grep -q '| готов' <<<"${EN[$((n-1))]}" && ok "режим: «готов» (/ready 200)" \
    || bad "режим не «готов»: ${EN[$((n-1))]}"
fi

# ── 2. Температуры: [железо] vs hwmon (±2 °C) ─────────────────────────────
section "2. Температуры [железо] vs hwmon/sensors"
HW_LINE=$(grep ' \[железо\] ' "$WOUT" | tail -1)
echo "LOG: $HW_LINE"
sensors 2>/dev/null | grep -Ei 'edge|junction|Tctl|k10temp' || echo "LOG: sensors недоступен — истина из hwmon"
gpu_watch=$(sed -En 's/.*GPU ([0-9.]+)°C.*/\1/p' <<<"$HW_LINE")
cpu_watch=$(sed -En 's/.*CPU ([0-9.]+)°C.*/\1/p' <<<"$HW_LINE")
gpu_hw=$(
  for c in /sys/class/drm/card[0-9]*; do
    [ "$(cat "$c/device/vendor" 2>/dev/null)" = "0x1002" ] || continue
    for h in "$c"/device/hwmon/hwmon*; do
      t=$(cat "$h/temp1_input" 2>/dev/null) && echo "$t"
    done
  done | sort -n | tail -1)
cpu_hw=$(for h in /sys/class/hwmon/hwmon*; do
    [ "$(cat "$h/name" 2>/dev/null)" = "k10temp" ] && { cat "$h/temp1_input" 2>/dev/null; break; }
  done)
gpu_hw_c=$(awk -v m="${gpu_hw:-}" 'BEGIN{ if (m=="") print "?"; else printf "%.1f", m/1000 }')
cpu_hw_c=$(awk -v m="${cpu_hw:-}" 'BEGIN{ if (m=="") print "?"; else printf "%.1f", m/1000 }')
if [ -n "$gpu_watch" ] && [ "$gpu_hw_c" != "?" ]; then
  awk -v a="$gpu_watch" -v b="$gpu_hw_c" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<=2.0)}' \
    && ok "GPU temp: watch=$gpu_watch°C vs hwmon=$gpu_hw_c°C (Δ≤2)" \
    || bad "GPU temp: watch=$gpu_watch°C vs hwmon=$gpu_hw_c°C (Δ>2)"
else
  bad "GPU temp несравнима: watch='$gpu_watch' hwmon='$gpu_hw_c' (карта 0x1002 найдена?)"
fi
if [ -n "$cpu_watch" ] && [ "$cpu_hw_c" != "?" ]; then
  awk -v a="$cpu_watch" -v b="$cpu_hw_c" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<=2.0)}' \
    && ok "CPU Tctl: watch=$cpu_watch°C vs hwmon=$cpu_hw_c°C (Δ≤2)" \
    || bad "CPU Tctl: watch=$cpu_watch°C vs hwmon=$cpu_hw_c°C (Δ>2)"
else
  bad "CPU Tctl несравнима: watch='$cpu_watch' hwmon='$cpu_hw_c' (k10temp есть?)"
fi

# ── 3. TZ: [логи] vs date хоста ───────────────────────────────────────────
section "3. TZ-конверсия: [логи] vs date хоста (UTC → локальный)"
REN=$(grep ' \[логи\] ' "$WOUT" | tail -1)
echo "LOG: $REN"
ren_tail=${REN#*\[логи\] }          # «HH:MM:SS <хвост строки>»
ren_ts=${ren_tail:0:8}
tail_txt=${ren_tail:9}
if [[ "$ren_ts" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] && [ -n "$tail_txt" ]; then
  RAW=$(podman logs --tail 200 "$CONTAINER" 2>&1 | grep -F -- "$tail_txt" | while IFS= read -r l; do t=${l:0:19}; [ "$(date -d "$t UTC" +%H:%M:%S 2>/dev/null)" = "$ren_ts" ] && { printf '%s\n' "$l"; break; }; done)
  raw_ts=$(sed -En 's/^([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}).*/\1/p' <<<"$RAW")
  echo "LOG: сырая строка движка: $RAW"
  if [ -n "$raw_ts" ]; then
    exp_ts=$(date -d "$raw_ts UTC" '+%H:%M:%S')
    echo "LOG: date хоста ($raw_ts UTC → локально): $exp_ts; локальное сейчас: $(date '+%T %Z')"
    [ "$ren_ts" = "$exp_ts" ] \
      && ok "TZ: raw=$raw_ts UTC → рендер=$ren_ts, date хоста=$exp_ts (сходится)" \
      || bad "TZ: raw=$raw_ts UTC → рендер=$ren_ts, date хоста ждёт $exp_ts"
  else
    bad "в хвосте podman logs нет UTC-метки для «$tail_txt» (формат EXP-005/006 нарушен?)"
  fi
else
  bad "[логи] без HH:MM:SS-префикса: $REN"
fi

# ── 4. TUI на SSH-TTY (ручная секция оператора) ───────────────────────────
section "4. TUI на SSH-TTY: q/+/-/p (подтверждение оператора)"
if [ -t 0 ]; then
  cat <<'EOF'
В ДРУГОМ ОКНЕ SSH-TTY выполни и вернись сюда:
  ./gfctl watch
  • рамки пяти блоков (Железо|Память|Движок|Скорость|Логи) отрисовались,
    статус-бар с моделью; температуры/значения не «прыгают» по строкам;
  • '+', затем '-' — «интервал» в статус-баре изменился на ±1 c;
  • 'p' — статус сменился на «логи: пауза», ещё раз 'p' — обратно;
  • 'q' — чистый выход без мусора в терминале; сразу после: echo $? → 0.
EOF
  read -rp "q вышел с rc 0, +/- меняют интервал, p паузит логи? [y/n] " a1
  read -rp "рамки/блоки отрисовались корректно? [y/n] " a2
  if [ "$a1" = y ] && [ "$a2" = y ]; then
    ok "TUI: клавиши q/+/-/p + рамки (подтверждено оператором)"
  else
    bad "TUI: ответы оператора: клавиши='$a1' рамки='$a2'"
  fi
else
  bad "stdin не TTY — TUI-секция требует оператора; перезапусти с терминала (stdout можно оставить перенаправлённым)"
fi

# ── итог ──────────────────────────────────────────────────────────────────
rm -f "$WOUT" "$BENCH_LOG"
echo
echo "ИТОГО: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" = 0 ]; then
  echo "RESULT: PASS — watch v2 живой: отображение 200, счётчики движутся, rc 0; температуры и TZ сходятся; TUI подтверждён"
else
  echo "RESULT: FAIL — зелёных $PASS, красных $FAIL (см. FAIL-строки выше)"
fi
