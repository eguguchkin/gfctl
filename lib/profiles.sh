# shellcheck shell=bash
# ── профили ─────────────────────────────────────────────────────────────────
# Формат записи (9 полей через '|'):
#   set|ram_gate_gib|sessions|context|cache_ram_bytes|cache_disk_bytes|serve_extra|probe_ladder|описание
#   set           — каталог-сет весов в $MODELS_BASE (27b | flash);
#   ram_gate_gib  — порог RAM-гейта в целых GiB (SPEC §5: 56 / 110);
#   sessions      — число сессий serve (константа профиля);
#   context       — ТЕКУЩИЙ канон контекста (single — константа; мульти —
#                   проверенная точка до первого probe; probe 1.2 может
#                   заменить, зафиксировав максимум в каноне профиля);
#   cache_ram_bytes / cache_disk_bytes — тиры кэша в байтах;
#   serve_extra   — serve-флаги движка; @DRAFT@/@MTP@ — токены ролей, 1.2
#                   заменяет контейнерным путём /models/<файл> (маунт models:ro);
#                   --model 1.2 строит из файла с ролью main сета;
#   probe_ladder  — вход probe-подбора контекста 1.2, значения через пробел
#                   ('-' = probe нет, single); первый загрузившийся = канон;
#   описание      — для логов и doctor.
# Числа — SPEC §5 + AGENT-CONFIGS пп.3–4; расхождение без нового окна запрещено.
#
# @typedef profile_id: '27b-single' | '27b-multi' | 'flash-multi'
# @typedef weight_set: '27b' | 'flash'

profile_27b_single="27b|56|1|262144|12884901888|68719476736|--speculative dflash2 --dflash-model @DRAFT@|-|solo DFlash2 (максимум соло-скорости)"
profile_27b_multi="27b|56|2|163840|4294967296|68719476736|--speculative dflash2 --dflash-model @DRAFT@|196608 163840 131072|мульти DFlash2 (probe-лестница, D5)"
profile_flash_multi="flash|110|2|131072|4294967296|68719476736|--speculative mtp --mtp-model @MTP@|262144 229376 196608 163840 131072|мульти MTP (максимальные контексты, floor 131072 проверен FX)"
# @type profile_id PROFILE_DEFAULT=27b-single
PROFILE_LIST="27b-single 27b-multi flash-multi"
PROFILE_DEFAULT=27b-single
# cache-disk 27b-multi 64 GiB — выровнен по остальным профилям (SPEC §1
# «cache-disk по умолчанию»; SPEC §5 поле не задаёт — решение task.md OQ №1).

# ── референсы агентских проверок (SPEC §5/§7; секунды; этап 3.1) ────────────
# Слой скаляров рядом с таблицей (тот же паттерн indirect-раскрытия, что
# profile_field; НЕ 10-е поле: референс многозначный — сессия/follow-up/
# restore/docq). '' = референс не снят → cmp_ref даёт WARN «эталон не снят»,
# сравнение пропускается. Числа — AGENT-CONFIGS п.3 (окно HX-A, 27b-single);
# flash-multi / 27b-multi / docq — после EXP-007 (окно этапа 3).
# Референсы сняты живьём agent-check'ом (EXP-007, evo 2026-11-18, 1×262144,
# тёплая машина, протокол 25 POST — самосогласованный). Прежние 23.8/1.7/0.81
# — смешение окон (flash-next CX): у gufo-27B follow-up/restore другие.
ref_27b_single_session="30.44"   # сессия 15 ходов, total wall (ход 1 = prefill 14.8)
ref_27b_single_followup="3.00"   # follow-up 25k, turn2 wall (k5 3.03 / k100 4.59)
ref_27b_single_docq="3.60"       # [док 25k][q2] turn2 wall
ref_27b_single_restore="2.85"    # рестарт-restore 25k turn2, reuse=disk
# flash-multi — EXP-007 FAEX (2×262144, 2026-11-17→18):
ref_flash_multi_session="17.22"
ref_flash_multi_followup="1.58"
ref_flash_multi_docq="10.44"
ref_flash_multi_restore="1.89"
# ref_<профиль>_docq НЕ снят ни для одного профиля (AGENT-CONFIGS имеет
# только halogen-число — вне gufo); до EXP-007 — всегда WARN.

# Назначение: значение референса агентской проверки профиля — скаляр
#   ref_<профиль_без_дефисов>_<метрика> (дефисы → подчёркивания, как в
#   profile_field). Метрики: session | followup | restore | docq.
#
# Побочные эффекты: только печать значения в stdout; файлов и глобалов не
#   меняет.
#
# Ограничения/допущения: неснятый/неизвестный референс = ПУСТОЙ stdout при
#   rc 0 (сравнение пропускает вызывающий — cmp_ref печатает WARN «не снят»);
#   метрика не валидируется (опечатка даёт пустоту, как неснятый).
#
# @param 1: profile_id      # канонический id профиля
# @param 2: string          # метрика (session|followup|restore|docq)
# @stdout string            # секунды ('' = референс не снят)
# @returns integer          # всегда 0
ref_get() {
  local name="ref_$(printf '%s' "$1" | tr '-' '_')_$2"
  printf '%s\n' "${!name:-}"
}

# Назначение: N-е поле (1-based, разделитель '|') записи профиля из таблицы
#   шапки файла: 1 — сет весов, 2 — порог RAM-гейта (целые GiB), 3 — sessions,
#   4 — context (канон), 5 — cache_ram_bytes, 6 — cache_disk_bytes,
#   7 — serve_extra, 8 — probe_ladder, 9 — описание.
#
# Побочные эффекты: только печать поля в stdout; подпроцесс tr и cut;
#   таблица profile_* читается indirect-раскрытием ${!name} (имя: profile_
#   с id, дефисы заменены подчёркиваниями), файлов и глобалов не меняет.
#
# Ограничения/допущения: id берётся КАК ЕСТЬ — алиасы не распознаются
#   (нормализация resolve_profile на вызывающем). Номер поля не валидируется:
#   N за числом полей даёт пустую строку при rc 0 (cut), нечисловой N —
#   ошибку cut.
#
# @param 1: profile_id     # канонический id профиля (алиас → rc 1)
# @param 2: /^[1-9]$/      # номер поля таблицы (живые вызовы: 1–9)
# @stdout string           # значение поля (пустая строка при N за числом полей)
# @returns integer         # 0 — поле напечатано; 1 — неизвестный профиль (stdout пуст)
profile_field() {
  local name="profile_$(printf '%s' "$1" | tr '-' '_')" v
  v="${!name:-}"
  [ -n "$v" ] || return 1
  printf '%s\n' "$v" | cut -d'|' -f"$2"
}

# Назначение: нормализовать алиас профиля в канонический id: single →
#   27b-single; multi → 27b-multi; flash → flash-multi; канонические id
#   проходят как есть (распознаны ровно 6 значений case).
#
# Побочные эффекты: только печать id в stdout; файлов, глобалов и env не
#   касается.
#
# Ограничения/допущения: аргумент — строка как есть (живые вызовы передают
#   пользовательский ввод); нераспознанное значение отклоняется rc 1 без
#   вывода, текст отказа — на вызывающем (die со списком PROFILE_LIST).
#
# @param 1: string          # алиас или канонический id (арбитражный ввод пользователя)
# @stdout profile_id        # канонический id (только при rc 0)
# @returns integer          # 0 — канон напечатан; 1 — неизвестное значение (stdout пуст)
resolve_profile() {
  case "$1" in
    27b-single|single)  echo 27b-single ;;
    27b-multi|multi)    echo 27b-multi ;;
    flash-multi|flash)  echo flash-multi ;;
    *) return 1 ;;
  esac
}

# Назначение: канон текущего профиля — GFCTL_PROFILE из .env стека
#   ($STACK_DIR/.env, SPEC §4); без .env/ключа — PROFILE_DEFAULT.
#
# Побочные эффекты: только печать в stdout; читает $STACK_DIR/.env (в 1.1
#   файл не пишется — только читается; отсутствие — норма).
#
# Ограничения/допущения: требует глобалы STACK_DIR, PROFILE_LIST и
#   PROFILE_DEFAULT диспетчера. Значение вне PROFILE_LIST (мусор в .env)
#   деградирует в PROFILE_DEFAULT — профиль валидируется на вызывающем
#   командой, а не здесь.
#
# @stdout profile_id        # канонический id текущего профиля
# @returns integer          # всегда 0 — финальный printf
cur_profile() {
  local p
  p=$(grep '^GFCTL_PROFILE=' "$STACK_DIR/.env" 2>/dev/null | tail -n 1 | cut -d= -f2-) || true
  case " $PROFILE_LIST " in *" $p "*) printf '%s\n' "$p" ;; *) printf '%s\n' "$PROFILE_DEFAULT" ;; esac
}

# Назначение: весь доступный пул памяти машины в GiB с одним знаком —
#   MemTotal из /proc/meminfo (APU: iGPU делит LPDDR с ОС, поэтому RAM-гейт
#   смотрит MemTotal, а не MemAvailable). Формат отображения для doctor/status.
#
# Побочные эффекты: только печать числа в stdout; читает /proc/meminfo;
#   ничего не меняет.
#
# Ограничения/допущения: без параметров; отсутствие MemTotal в файле даёт
#   ПУСТОЙ stdout (пустоту обязан обработать вызывающий — ram_gate_line и
#   cmd_status печатают «?»).
#
# @stdout string            # GiB пула с одним знаком (например «59.5»; F14)
# @returns integer          # rc awk — 0 и при пустом выводе (совпадения нет)
ram_pool_gib_dec() {
  awk '/MemTotal/{printf "%.1f", $2/1048576}' /proc/meminfo
}

# Назначение: строка вердикта RAM-гейта профиля для doctor — формат DoD:
#   «27b-single: ≥56 GiB — есть 59.5: OK» / «flash-multi: ≥110 GiB — есть
#   59.5: НЕДОСТАТУПЕН». Сравнение ЦЕЛЫМИ GiB (floor от пула), печать have
#   с одним знаком.
#
# Побочные эффекты: только печать строки в stdout; читает /proc/meminfo
#   (через ram_pool_gib_dec) и таблицу профилей; ничего не меняет.
#
# Ограничения/допущения: prof — канонический id (живые вызовы из doctor/
#   status идут по PROFILE_LIST). rc 0 ВСЕГДА — строка не блокировка;
#   блокирующий гейт — обёртка этапа 1.2. Пустой пул (нет /proc/meminfo)
#   деградирует в «есть ?»: НЕИЗВЕСТНО.
#
# @param 1: profile_id      # канонический id профиля (порог — поле 2)
# @stdout string           # строка «<профиль>: ≥<N> GiB — есть <X.X>: OK|НЕДОСТАТУПЕН|НЕИЗВЕСТНО»
# @returns integer         # всегда 0
ram_gate_line() {
  local prof="$1" need have_dec have verdict
  need=$(profile_field "$prof" 2)
  have_dec=$(ram_pool_gib_dec)
  if [ -z "$have_dec" ]; then
    printf '%s: ≥%s GiB — есть ?: НЕИЗВЕСТНО\n' "$prof" "$need"
    return 0
  fi
  have="${have_dec%%.*}"
  if [ "$have" -ge "$need" ]; then verdict="OK"; else verdict="НЕДОСТАТУПЕН"; fi
  printf '%s: ≥%s GiB — есть %s: %s\n' "$prof" "$need" "$have_dec" "$verdict"
}

# Назначение: каталог-сет весов профиля/сета — $MODELS_BASE/<set> (SPEC §2:
#   модели ~/gufo/models/<сет>/).
#
# Побочные эффекты: только печать пути в stdout; каталог НЕ создаёт
#   (создание — free_disk_gib, единственная запись 1.1 вне tests/).
#
# Ограничения/допущения: требует глобал MODELS_BASE диспетчера; аргумент —
#   сет ('27b' | 'flash'), не профиль (сети профилей — поле 1 таблицы).
#
# @param 1: weight_set      # каталог-сет
# @stdout string           # путь каталога сета
# @returns integer         # всегда 0
models_dir_for() {
  printf '%s/%s\n' "$MODELS_BASE" "$1"
}
