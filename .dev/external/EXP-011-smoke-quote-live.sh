#!/usr/bin/env bash
# EXP-011-smoke-quote-live — живой smoke с кавычкой в имени модели (4.3 п.3).
#
# По F20 живые имена gufo кавычек/бэкслешей НЕ содержат (пробелы) —
# естественный сценарий на живой машине сегодня невоспроизводим;
# экранирование тела покрыто батареей end-to-end (§44: faux-curl,
# тело парсится json.load, round-trip Bad"Na\me). Скрипт — хвостовой
# probe: если когдa-либо в живом load-логе появится имя с «"»/«\» —
# прогнать gfctl smoke (сломанное тело = сервер 4xx = smoke die;
# «SMOKE: OK» при кавычке = экранирование живое). Иначе — SKIP.
#
# НЕ DoD 4.3 (pre-existing класс, живых носителей нет — F20).
#
# Предпосылки: живой gufo-стек на машине acc (gfctl up, healthy);
# инсталляция с кодом 4.3 (lib/health.sh содержит json_escape).
# Изменений в стек не вносит (только чтение лога + штатный smoke).
#
# Запуск (на машине, с инсталляцией 4.3):
#   bash .dev/external/EXP-011-smoke-quote-live.sh > \
#     .dev/external/EXP-011-smoke-quote-live.result.txt 2>&1
#
# PASS: имя модели в логе содержит «"» или «\» И `gfctl smoke` печатает
#   «SMOKE: OK» (rc 0) — тело с кавычкой принят сервером.
# SKIP: имя без спецсимволов (ожидаемое сегодня по F20) — живой носитель
#   отсутствует, контракт держит батарея §44.
# Финальная строка файла: RESULT: PASS|FAIL|SKIP — …

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GFCTL="${GFCTL:-$SCRIPT_DIR/../../gfctl}"   # лейаут 4.4: бинарника в PATH нет — клон-относительный путь
LOG="$("$GFCTL" logs 2>/dev/null | grep 'event=load_completed' | tail -1)"
[ -n "$LOG" ] || { echo "RESULT: SKIP — живого load_completed нет (стек не поднят?)"; exit 0; }
MODEL="${LOG##*model=}"; MODEL="${MODEL%% *}"
echo "живое имя модели: '$MODEL'"
case "$MODEL" in
  *'"'*|*'\'*)
    if out="$("${GFCTL:-gfctl}" smoke 2>&1)"; then
      printf '%s\n' "$out"
      echo "RESULT: PASS — smoke OK при имени с кавычкой/бэкслешем (тело принят сервером)"
    else
      printf '%s\n' "$out"
      echo "RESULT: FAIL — smoke провалился на имени со спецсимволом (экранирование?)"
    fi
    ;;
  *)
    echo "RESULT: SKIP — F20: живых имён с кавычками нет ('$MODEL'); экранирование держит батарея §44 (faux-curl, json.load round-trip)"
    ;;
esac
