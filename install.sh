#!/usr/bin/env bash
# install.sh — bootstrap-каркас gfctl: раскладка дерева в ~/gufo + симлинк.
# Полное поведение (повтор как обновление поверх живого стека, приёмка
# «чистая машина») — этап 1.2 / PLAN этап 4; SPEC §2.
#
# Назначение: скопировать gfctl + lib/ + tpl/ в $GFCTL_DIR (дефолт ~/gufo),
#   симлинк ~/.local/bin/gfctl; models/ cache/ .env и маркеры НЕ трогаются.
#
# Побочные эффекты: запись в $DEST (gfctl, lib/, tpl/ — lib/tpl заменяются
#   ЦЕЛИКОМ: rm -rf + cp -a, повтор = обновление) и ~/.local/bin (симлинк).
#
# Ограничения/допущения: запуск только из дерева репо (рядом есть gfctl и
#   lib/) — иначе отказ rc 1 («запуск вне дерева», SPEC §2); запуск от своего
#   имени, без sudo; PATH-проверка — WARN с подсказкой, не отказ.
#
# @stdout string   # ход раскладки + финал «готово»
# @stderr string   # WARN о PATH (если ~/.local/bin не в PATH); FATAL вне дерева
# @returns integer # 0 — раскладка готова; 1 — запуск вне дерева
set -euo pipefail

SRC="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
[ -f "$SRC/gfctl" ] && [ -d "$SRC/lib" ] \
  || { echo "FATAL: запуск вне дерева репо — нужны gfctl и lib/ рядом со скриптом (SPEC §2)" >&2; exit 1; }
DEST="${GFCTL_DIR:-$HOME/gufo}"

echo "== gfctl install.sh — bootstrap в $DEST"
mkdir -p "$DEST"
cp -f "$SRC/gfctl" "$DEST/gfctl"
rm -rf "$DEST/lib" "$DEST/tpl"
cp -a "$SRC/lib" "$SRC/tpl" "$DEST/"
mkdir -p "$HOME/.local/bin"
ln -sfn "$DEST/gfctl" "$HOME/.local/bin/gfctl"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "WARN: $HOME/.local/bin не в PATH — добавь: export PATH=\"\$HOME/.local/bin:\$PATH\"" >&2 ;;
esac
echo "готово — проверь: gfctl doctor (каркас 1.1: doctor / models / status)"
