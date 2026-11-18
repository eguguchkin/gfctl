# shellcheck shell=bash
# ── веса: таблица сетов + download + check-types ────────────────────────────
# Модуль читает MODELS_BASE, TPL_DIR и GFCTL_MIRROR_BASE (зеркало-first при
# докачке, пусто = пин-URL HF) и пишет через log()/warn() — всё объявлено в
# диспетчере gfctl до source этого файла. Сеты — по profile_field
# (lib/profiles.sh, поле 1).
#
# Формат записи сета: filename|size_bytes|sha256|url|role, role ∈ main|draft|mtp.
# Пины — ПОЛНЫЕ 64-hex sha256 из dl-скриптов окон IX/FX (sha-verify PASS):
# 27B — jpetrina pure-IQ4_XS + z-lab DFlash2 draft (запинован на коммит);
# flash — unsloth UD-Q4_K_XL 4 шарда + MTP shared-Q8_0 (SPEC §5). unsloth
# UD-IQ4_XS (93.6 GB) к профилю НЕ относятся — не грузятся (F3), не пинованы.
# Контроль сумм: flash шарды+MTP = 111 334 654 778 B = 111.3 GB ✓ SPEC §5.
# mmproj не входит — SPEC §5 запрет.
#
# @typedef weight_set: '27b' | 'flash'

set_27b="qwen3.8-27b-IQ4_XS-pure.gguf|14534384640|ea5a3c45d407f9b9e5d2c0d647f0ea600f486f6b86b92b56d0823ba073dae675|https://huggingface.co/jpetrina/Qwen3.8-27B-IQ4_XS-pure-GGUF/resolve/main/qwen3.8-27b-IQ4_XS-pure.gguf|main
Qwen3.8-27B-DFlash2-Q4_K_M.gguf|1143006816|1a25c56858e1ebe93f2718ac1d49d1151f9323325c1bbfd6209370f4db131ebd|https://huggingface.co/z-lab/Qwen3.8-27B-DFlash2-GGUF/resolve/2d9571f8ce46e151f61c6499c99dee6079e1d610/Qwen3.8-27B-DFlash2-Q4_K_M.gguf|draft"
set_flash="Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf|10946618|acc44040f74d0e55fb89c3967056cce5dbda1bcc52e909c3ba6fc72b5e9c0858|https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf|main
Qwen3.8-Flash-Next-UD-Q4_K_XL-00002-of-00004.gguf|49720539552|45792ae869072d8229384c51c7c73dd959e191505252b41dd71852d9746f5ce4|https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00002-of-00004.gguf|main
Qwen3.8-Flash-Next-UD-Q4_K_XL-00003-of-00004.gguf|32803030176|8c76e79d444b16a663d9c8db54e585ed3b1da13eebd2619c37b0c355da803c82|https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00003-of-00004.gguf|main
Qwen3.8-Flash-Next-UD-Q4_K_XL-00004-of-00004.gguf|28800138432|5de8b5dbf89409acc39468decafd4a4a95b13c29d88a14b0356107897829ec36|https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00004-of-00004.gguf|main
mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf|2786568256|5ff54097406a905cf3a724c709124ceb0e3e10235ee862298969e91c96fa96e6|https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf|mtp"

# Назначение: построчные записи сета из таблицы шапки (разделитель '|':
#   filename|size|sha256|url|role) — единственный ридер таблицы.
#
# Побочные эффекты: только печать записей в stdout; indirect-раскрытие
#   ${!name}, файлов и глобалов не меняет.
#
# Ограничения/допущения: аргумент — сет ('27b' | 'flash'), не профиль.
#
# @param 1: weight_set      # каталог-сет
# @stdout string[]          # записи сета, по одной на файл
# @returns integer          # 0 — записи напечатаны; 1 — неизвестный сет
weights_for() {
  local name="set_$1" v
  v="${!name:-}"
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

# Назначение: имя файла сета с данной ролью (для подстановки @DRAFT@/@MTP@ в
#   serve-флагах этапа 1.2; main — для --model).
#
# Побочные эффекты: только печать имени файла в stdout.
#
# Ограничения/допущения: роль с несколькими файлами (main у flash — 4 шарда)
#   возвращает ПЕРВОЕ совпадение — 1.2 для main строит список отдельно.
#
# @param 1: weight_set      # каталог-сет
# @param 2: main|draft|mtp  # роль из таблицы
# @stdout string            # имя файла (только при rc 0)
# @returns integer          # 0 — найдено; 1 — не найдено / неизвестный сет
set_file_role() {
  local set="$1" role="$2" f size sha url r
  while IFS='|' read -r f size sha url r; do
    if [ "$r" = "$role" ]; then printf '%s\n' "$f"; return 0; fi
  done < <(weights_for "$set") || return 1
  return 1
}

# Назначение: свободное место в GiB (один знак) на ФС каталога dir; при
#   отсутствии каталог создаёт (mkdir -p — ЕДИНСТВЕННАЯ запись 1.1 вне tests/,
#   санкционирована task.md).
#
# Побочные эффекты: mkdir -p dir (если нет); чтение stat -f; печать в stdout.
#
# Ограничения/допущения: GNU stat (доки целевой машины — GNU, не BusyBox);
#   сбой stat (экзотическая ФС) деградирует в «?» — сравнения на вызывающем
#   трактовают «?» как 0 (консервативно: НЕДОСТАТУЧНО).
#
# @param 1: string          # каталог (проверка его ФС)
# @stdout string           # GiB с одним знаком или «?»
# @returns integer         # всегда 0 (печать «?» при сбое stat)
free_disk_gib() {
  local dir="$1" out
  mkdir -p "$dir"
  out=$(stat -f -c '%a %S' "$dir" 2>/dev/null) || { echo "?"; return 0; }
  awk -v line="$out" 'BEGIN{n=split(line,a," "); printf "%.1f", (n==2 ? a[1]*a[2] : 0)/1073741824}'
}

# Назначение: единица работы download — скачать один файл с pre-flight
#   «нужно X GiB (остаток), свободно Y Gi» ДО трафика, докачкой curl
#   (-C - resume существующего .part) и sha256-верификацией после.
#   ЗЕРКАЛО-FIRST (4.1-F1): если GFCTL_MIRROR_BASE непуст — ПЕРВАЯ попытка
#   качает "$GFCTL_MIRROR_BASE/<basename dest>" (страховка от смерти/рейт-
#   лимитов HF: зеркалом может быть NAS/LAN-сервер, на котором разложены те
#   же имена файлов, что в пинах таблицы). Отказ зеркала = curl rc≠0 ИЛИ
#   итоговый http-код ≥400 (rc 0 c ошибочным кодом тоже фоллбэк) → WARN и
#   пин-URL в той же попытке; попытки 2–3 — сразу пин-URL. Зеркальная
#   попытка без --retry (fail-fast: живой фоллбэк сам ретраит 4×); битый/
#   частичный хвост зеркала НЕ должен ломать resume пин-URL → .part
#   восстанавливается до размера до попытки (truncate/rm). Финальный
#   арбитр в любом случае sha256 — зеркальный файл, прошедший http-гейт,
#   но битый по содержимому, словит SHA-MISMATCH и будет удалён.
#
# Побочные эффекты: файлы dest.part/dest в каталоге сета; сеть (curl);
#   mkdir -p каталога сета (через free_disk_gib). Размер dest совпал → SKIP
#   без сети; .part полного пин-размера → mv + sha-арбитраж без сети
#   (part>pin, review 1.1 — локальное скачанное приоритетнее пин-сверки).
#   SHA-MISMATCH → dest И dest.part удаляются (битый файл не должен
#   выглядеть скачанным). Сетевой отказ 3 попыток → rc 1, .part остаётся
#   (докачка следующим запуском).
#
# Ограничения/допущения: size/sha — пины из таблицы сета (не произвольные);
#   dest-симлинк разыменовывается в SKIP-проверке (stat -L — GNU stat без -L
#   вернул бы размер ссылки ~91 B и ложную докачку, EXP-005-faex: веса живут
#   симлинками); несовместимый .part от прошлой сессии проявит себя как
#   SHA-MISMATCH → удаление (само-восстановление); pre-flight сравнивает GiB
#   с одним знаком через awk; curl без прогресс-метра (-sSL, флаги task.md);
#   http-код «000» (file:// — батарея/LAN-схема без http) трактуется как
#   годный ответ — содержимое всё равно судит sha256.
#
# @param 1: string   # url (https://… из таблицы или file:// для тестов)
# @param 2: string   # dest — полный путь итогового файла
# @param 3: integer  # size — пин размера в байтах
# @param 4: /^[0-9a-f]{64}$/ # sha — пин sha256
# @stdout string     # «нужно/свободно», «SKIP:», «PASS:», ход попыток с URL (log)
# @stderr string     # WARN при нехватке места / SHA-MISMATCH / сетевом отказе /
#                    # отказе зеркала (фоллбэк)
# @returns integer   # 0 — файл на месте и sha OK; 1 — отказ (место/сеть/sha)
download_file() {
  local url="$1" dest="$2" size="$3" sha="$4"
  local part="$dest.part" attempt remaining psz need_gib have_gib ok got
  local mirror="${GFCTL_MIRROR_BASE:-}" try_url mrc http_code pre_size
  if [ -f "$dest" ] && [ "$(stat -L -c %s "$dest")" = "$size" ]; then
    echo "SKIP: $(basename "$dest") (размер совпал — честный sha-статус даёт: gfctl models)"
    return 0
  fi
  remaining="$size"
  ok=""
  if [ -f "$part" ]; then
    psz=$(stat -c %s "$part" 2>/dev/null || echo 0)
    if [ "$psz" -gt 0 ] && [ "$psz" -le "$size" ]; then remaining=$((size - psz)); fi
    # part>pin (review 1.1): локальный .part уже ПОЛНОГО пин-размера (обрыв
    # между концом скачивания и mv) — докачка его НЕ перекрывает и сеть не
    # дёргает: mv + sha-арбитраж в общем хвосте ниже. Битый «полный» .part
    # словит SHA-MISMATCH и будет удалён — финальный арбитр sha256, как и
    # для сетевых попыток.
    if [ "$psz" = "$size" ]; then
      log "локальный $(basename "$part") уже полного размера ($size B) — сеть не нужна"
      ok=1
    fi
  fi
  need_gib=$(awk -v b="$remaining" 'BEGIN{printf "%.1f", b/1073741824}')
  have_gib=$(free_disk_gib "$(dirname "$dest")")
  echo "нужно ${need_gib} GiB (остаток), свободно ${have_gib} GiB"
  if awk -v a="$need_gib" -v b="$have_gib" 'BEGIN{exit !(a>b)}'; then
    warn "мало места: нужно ${need_gib} GiB, свободно ${have_gib} GiB — отказ ДО трафика"
    return 1
  fi
  if [ -z "$ok" ]; then
    for attempt in 1 2 3; do
      if [ -n "$mirror" ] && [ "$attempt" = 1 ]; then
        try_url="$mirror/$(basename "$dest")"
        log "качаю (попытка 1/3, зеркало): $(basename "$dest") ← $try_url"
        pre_size=$(stat -c %s "$part" 2>/dev/null || echo 0)
        mrc=0; http_code=$(curl -sSL -C - --connect-timeout 10 -o "$part" -w '%{http_code}' "$try_url") || mrc=$?
        if [ "$mrc" = 0 ]; then
          case "$http_code" in
            2*|000) log "зеркало ответило годным файлом (http ${http_code:-?})"; ok=1; break ;;
            *)      mrc=1 ;;   # rc 0, но http ≥400 (или пустой) — фоллбэк
          esac
        fi
        # битый/частичный хвост зеркала не должен ломать resume пин-URL
        if [ "$pre_size" -gt 0 ]; then truncate -s "$pre_size" "$part" 2>/dev/null || true; else rm -f "$part"; fi
        warn "зеркало не ответило годным файлом (rc=$mrc, http=${http_code:-?}) — фоллбэк на пин-URL"
      fi
      log "качаю (попытка $attempt/3): $(basename "$dest") ← $url"
      if curl -sSL -C - --retry 4 --retry-delay 5 --connect-timeout 20 -o "$part" "$url"; then ok=1; break; fi
      [ "$attempt" -lt 3 ] && sleep 15
    done
  fi
  if [ -z "$ok" ]; then
    warn "скачивание не удалось за 3 попытки — $part сохранён для докачки"
    return 1
  fi
  mv -f "$part" "$dest"
  got=$(sha256sum "$dest" 2>/dev/null | awk '{print $1}' || true)
  if [ "$got" = "$sha" ]; then
    echo "PASS: $(basename "$dest") (sha OK)"
    return 0
  fi
  rm -f "$dest" "$part"
  warn "SHA-MISMATCH: $(basename "$dest") удалён (источник изменился или файл битый) — перекачай: gfctl models download <сет>"
  return 1
}

# Назначение: цикл докачки сета с ЕДИНОЙ семантикой согласия (cmd_models
#   download, cmd_install, cmd_use): если есть недостающие/битые-по-размеру
#   файлы — ask «скачать?» (не-TTY без GFCTL_YES → авто-нет die, SPEC: веса
#   качаются только после согласия), затем download_file по КАЖДОМУ файлу
#   сета (уже скачанные — SKIP без вопросов и без сети).
#
# Побочные эффекты: при наличии недостающих — вопрос ask + download_file
#   (сеть, файлы весов, mkdir каталога сета через free_disk_gib); полные
#   сеты — только чтение stat (SKIP-строки). rc 1, если хоть один файл не
#   докачан.
#
# Ограничения/допущения: аргумент — сет ('27b' | 'flash'); размер читается
#   stat -L (симлинк-веса FAEX — EXP-005-faex, без -L размер ссылки ≠ пин →
#   ложный ask); «битый по размеру» ловится здесь и перекачивается через
#   download_file; sha-битые
#   размер-корректные файлы НЕ ловятся здесь (честный статус — inventory,
#   перекачка — `gfctl models download`). Требует ask/download_file этого
#   модуля и глобалы ASSUME_YES/MODELS_BASE. Сообщение ask печатает объём
#   НЕДОСТАЮЩИХ байтов (ленивый добор use честен: полная скачанная пара —
#   SKIP без вопросов).
#
# @param 1: weight_set      # каталог-сет
# @stdout string            # SKIP/PASS-строки download_file (+ ask-prompt)
# @returns integer          # 0 — все файлы на месте с пин-размером;
#   1 — отказ скачивания/согласия (die внутри ask-ветки)
ensure_weights() {
  local set="$1" dir f size _sha _url _role need=0 missing_b=0 rc=0 actual
  dir=$(models_dir_for "$set")
  while IFS='|' read -r f size _sha _url _role; do
    [ -n "$f" ] || continue
    actual=$(stat -L -c %s "$dir/$f" 2>/dev/null || echo 0)
    if [ "$actual" != "$size" ]; then need=1; missing_b=$((missing_b + size)); fi
  done < <(weights_for "$set") || return 1
  if [ "$need" = 1 ]; then
    ask "Скачать недостающие веса сета $set ($(awk -v b="$missing_b" 'BEGIN{printf "%.1f", b/1073741824}') GiB) в $dir? [y/N] " \
      || die "скачивание отменено (веса качаются только после согласия; повтори с --yes)"
  fi
  while IFS='|' read -r f size sha url role; do
    [ -n "$f" ] || continue
    download_file "$url" "$dir/$f" "$size" "$sha" || rc=1
  done < <(weights_for "$set")
  return "$rc"
}

# Назначение: честный инвентарь сета — построчно «файл | size-пин B | статус»,
#   статус ∈ «есть, размер OK, sha OK» / «есть, размер OK, sha ✗ (перекачай)» /
#   «есть, РАЗМЕР ≠ (факт N B)» / «НЕТ»; плюс строки «незавершённый .part:
#   N GiB» при наличии хвостов. sha пересчитывается ВСЕГДА при совпавшем
#   размере (решение task.md OQ №4 — stateless-честность; ~10 c на 27b,
#   ~40 c на flash на NVMe).
#
# Побочные эффекты: только чтение файлов сета и печать в stdout; ничего не
#   меняет (mkdir НЕ делает).
#
# Ограничения/допущения: аргумент — сет; размер — stat -L (симлинк-веса,
#   EXP-005-faex); отсутствие каталога сета — норма
#   (все строки «НЕТ»); «есть, sha ✗» — случай размера за пределами перечня
#   task.md, добавлен как честное завершение «sha-статуса» (см. dev-report).
#
# @param 1: weight_set      # каталог-сет
# @stdout string[]          # строки инвентаря
# @returns integer          # всегда 0 (отчёт, не проверка)
inventory() {
  local set="$1" dir f size sha got actual status part psz
  dir=$(models_dir_for "$set")
  while IFS='|' read -r f size sha _url _role; do
    [ -n "$f" ] || continue
    if [ -f "$dir/$f" ]; then
      actual=$(stat -L -c %s "$dir/$f" 2>/dev/null || echo 0)
      if [ "$actual" = "$size" ]; then
        got=$(sha256sum "$dir/$f" 2>/dev/null | awk '{print $1}' || true)
        if [ "$got" = "$sha" ]; then
          status="есть, размер OK, sha OK"
        else
          status="есть, размер OK, sha ✗ (перекачай: gfctl models download $set)"
        fi
      else
        status="есть, РАЗМЕР ≠ (факт ${actual} B)"
      fi
    else
      status="НЕТ"
    fi
    printf '%s | %s B | %s\n' "$f" "$size" "$status"
  done < <(weights_for "$set")
  for part in "$dir"/*.part; do
    [ -e "$part" ] || continue
    psz=$(stat -c %s "$part" 2>/dev/null || echo 0)
    awk -v p="$(basename "$part")" -v b="$psz" 'BEGIN{printf "%s | — | незавершённый .part: %.1f GiB\n", p, b/1073741824}'
  done
  return 0
}

# Назначение: сумма пин-размеров сета в байтах (для doctor «нужно X GiB» и
#   сводок).
#
# Побочные эффекты: только печать числа в stdout.
#
# Ограничения/допущения: аргумент — сет; неизвестный сет → rc 1 (сквозь
#   pipefail — программная ошибка вызывающего).
#
# @param 1: weight_set      # каталог-сет
# @stdout integer           # суммарный размер в байтах
# @returns integer          # 0; 1 — неизвестный сет
set_total_bytes() {
  weights_for "$1" | awk -F'|' '{s+=$2} END{printf "%.0f\n", s+0}'
}

# Назначение: дешёвая статистика сета без sha — строка «present total
#   missing_bytes»: present — файлов на месте С ПИН-РАЗМЕРОМ; total — всего
#   в таблице; missing_bytes — сумма пин-размеров отсутствующих/битых по
#   размеру. Потребители: cmd_status --json и сводка cmd_models (sha-честность
#   даёт inventory — здесь цена важнее).
#
# Побочные эффекты: только чтение stat файлов сета и печать в stdout.
#
# Ограничения/допущения: аргумент — сет; process substitution сохраняет
#   счётчики (не субшелл); размер — stat -L (симлинк-веса, EXP-005-faex);
#   stat сбойного файла трактуется как отсутствие.
#
# @param 1: weight_set      # каталог-сет
# @stdout string            # «present total missing_bytes»
# @returns integer          # 0; 1 — неизвестный сет
set_stats() {
  local set="$1" dir f size present=0 total=0 missing=0 actual
  dir=$(models_dir_for "$set")
  while IFS='|' read -r f size _sha _url _role; do
    [ -n "$f" ] || continue
    total=$((total + 1))
    if [ -f "$dir/$f" ]; then
      actual=$(stat -L -c %s "$dir/$f" 2>/dev/null || echo 0)
      if [ "$actual" = "$size" ]; then
        present=$((present + 1))
      else
        missing=$((missing + size))
      fi
    else
      missing=$((missing + size))
    fi
  done < <(weights_for "$set") || return 1
  printf '%s %s %s\n' "$present" "$total" "$missing"
}

# Назначение: pre-check GGUF-типов тензоров сета — для каждого *.gguf из
#   таблицы сета зовёт tpl/python/gguf_type_check.py (потоковый парсер
#   заголовка, без GPU); вердикт СЕТА = красный, если ≥1 файл красный ИЛИ
#   с ошибкой формата (непроверяемый файл не может считаться зелёным).
#
# Побочные эффекты: только чтение файлов и печать в stdout (выдача парсера
#   построчно + финальный вердикт); ничего не меняет.
#
# Ограничения/допустимости: аргумент — сет; ни одного скачанного файла →
#   die «нечего проверять» rc 1; контракт красных типов — числовой
#   (RED = {16,17,18,19,22,29} ∪ {t>29} ТОЛЬКО на ffn_*-тензорах; канон
#   ggml enum: IQ1_M=29, BF16=30 — display-имена в парсере), validated
#   F3 + живьём EXP-005 (F20); rc: 0 — зелёный, 1 — красный/ошибка формата.
#
# @param 1: weight_set      # каталог-сет
# @stdout string[]          # вердикты файлов + финальная строка сета
# @returns integer          # 0 — зелёный; 1 — красный / ошибка формата / нечего проверять
check_types() {
  local set="$1" dir f rc_file out any=0 red=0 err=0
  dir=$(models_dir_for "$set")
  while IFS='|' read -r f _size _sha _url _role; do
    [ -n "$f" ] || continue
    [ -f "$dir/$f" ] || continue
    any=1
    rc_file=0
    out=$(python3 "$TPL_DIR/python/gguf_type_check.py" "$dir/$f") || rc_file=$?
    printf '%s\n' "$out"
    if [ "$rc_file" = 1 ]; then
      red=1
    elif [ "$rc_file" != 0 ]; then
      err=1
    fi
  done < <(weights_for "$set")
  if [ "$any" = 0 ]; then
    die "нечего проверять — веса сета $set не скачаны ($dir)"
  fi
  if [ "$red" = 1 ] || [ "$err" = 1 ]; then
    echo "КРАСНЫЙ — не загрузится (FFN низкобитные IQ/BF16/MXFP4/неизвестные; SPEC §5)"
    return 1
  fi
  echo "зелёный — сет $set можно грузить"
  return 0
}
