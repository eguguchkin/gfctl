#!/usr/bin/env bash
# EXP-010-curl416-live — живое подтверждение 4.3 п.2 (review 1.1 №5):
# на машине с РЕАЛЬНЫМ curl oversized .part → WARN «удали .part руками»
# ДО первой сетевой попытки; попытки curl -C - отклоняются (по review 1.1
# №5 — HTTP 416: Range: bytes=<psz>- при psz>size не satisfiable),
# .part сохраняется, rc=1 (прежняя семантика не менялась).
#
# НЕ DoD 4.3 (behavior unchanged) — хвост review 4.2 №5; эксп. для
# ближайшего машинного окна, гонять отдельно машины ради него не нужно.
#
# Предпосылки: машина acc (che-evo/che-FAEX1), юзер ai; checkout/инсталляция
# gfctl с кодом 4.3 (lib/models.sh содержит «БОЛЬШЕ пин-размера»);
# сеть до huggingface.co — желательна (иначе видны сетевые отказы вместо
# 416, WARN-часть PASS-критерию не мешает). sudo НЕ нужен; реальные
# модели и прод НЕ трогаются — всё в mktemp-каталоге.
#
# Запуск (на машине, из каталога gfctl с кодом 4.3):
#   bash .dev/external/EXP-010-curl416-live.sh > \
#     .dev/external/EXP-010-curl416-live.result.txt 2>&1
#
# PASS (обе ветки легальны — контракт 4.3 = WARN-порядок + семантика не
#   менялась, а НЕ конкретный код ответа CDN):
#   ветка A (416, review 1.1 №5): ровно 3 попытки, rc=1, .part цел;
#   ветка B (CDN отдал полный ответ, observed 2026-11-18 из ocbox):
#     curl завершился ok → SHA-MISMATCH → dest/.part удалены (само-
#     восстановление 4.2 работает), rc=1;
#   в ОБЕИХ ветках строка 1 трейса = WARN «…БОЛЬШЕ пин-размера … удали
#   .part руками …» РАНЬШЕ любых строк попыток/curl.
# Финальная строка файла: RESULT: PASS|FAIL|ERROR — …

set -u
GFCTL_SRC="${GFCTL_SRC:-$(pwd)}"
TRACE="$(mktemp /tmp/exp010-trace.XXXXXX)"
WORK="$(mktemp -d /tmp/exp010-part.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

log()  { echo "LOG: $*"  >> "$TRACE"; }
warn() { echo "WARN: $*" >> "$TRACE"; }
die()  { echo "DIE: $*"  >> "$TRACE"; exit 1; }

# shellcheck disable=SC1091
source "$GFCTL_SRC/lib/models.sh" || { echo "RESULT: ERROR — models.sh не source'нулся"; exit 1; }

# реальный пин из таблицы (первый файл сета flash, ~10 MiB — гейт места
# проходит всюду); формат записи filename|size|sha256|url|role
IFS='|' read -r fname psize psha purl _role <<< "$(weights_for flash | head -1)"
[ -n "${purl:-}" ] || { echo "RESULT: ERROR — weights_for flash пуст"; exit 1; }

head -c $((psize + 1000)) /dev/urandom > "$WORK/$fname.part"   # oversized .part
PARTSZ=$(stat -c %s "$WORK/$fname.part")

download_file "$purl" "$WORK/$fname" "$psize" "$psha"; RC=$?
echo "RC=$RC" >> "$TRACE"

echo "=== трейс (порядок строк — суть проверки) ==="
cat "$TRACE"
echo "=== .part: было $PARTSZ B, стало $(stat -c %s "$WORK/$fname.part" 2>/dev/null || echo НЕТ) B ==="

# арбитраж по трейсу
FIRST=$(head -1 "$TRACE")
ATTEMPTS=$(grep -c 'качаю (попытка' "$TRACE")
WARNOK=$([[ "$FIRST" == WARN:*"БОЛЬШЕ пин-размера"*"удали .part руками"* ]] && echo yes || echo no)
PARTNOW=$(stat -c %s "$WORK/$fname.part" 2>/dev/null || echo -1)
if [ "$WARNOK" = no ]; then
  echo "RESULT: FAIL — WARN не первой строкой трейса: '$FIRST'"
elif [ "$ATTEMPTS" = 3 ] && [ "$RC" = 1 ] && [ "$PARTNOW" = "$PARTSZ" ]; then
  echo "RESULT: PASS — ветка A (416): WARN до 3 попыток, .part сохранён, rc=1"
elif grep -q 'SHA-MISMATCH' "$TRACE" && [ "$RC" = 1 ] && [ "$PARTNOW" = -1 ]; then
  echo "RESULT: PASS — ветка B (CDN без 416): WARN до попытки, SHA-MISMATCH само-восстановление (dest/.part удалены), rc=1"
else
  echo "RESULT: FAIL — rc=$RC attempts=$ATTEMPTS part=$PARTNOW (было $PARTSZ) trace: $(grep -c . "$TRACE") строк"
fi
