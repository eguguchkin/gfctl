#!/usr/bin/env python3
# Назначение: движковые данные `gfctl watch` v2 (SPEC §3, task.md Round 2):
#   парсер prometheus-текста /metrics gufo, вычисляемые показатели
#   (формулы v2), дельты счётчиков ЗА ТИК («пульс», НЕ скорость),
#   sparkline, TZ-конверсия строк лога (UTC → локальный пояс — в слое
#   watch, контейнер не трогаем), парсеры роута (event=load_completed) и
#   cache-конфигурации (event=configured). Источник семантики счётчиков —
#   gufo/docs/internal/server.md:1557–1583, эмиттер ключей —
#   gufo/src/cli/serve/http_server.cpp:1595–1685 (12 счётчиков + 5 gauge).
#
# Побочные эффекты: нет (чистые функции/классы; чтение часов — time).
#
# Ограничения/допущения: stdlib only; имена метрик — только из факт-базы
#   EXP-007 + код эмиттера (не выдумываются); отсутствующий ключ → None
#   (старый образ движка — деградация '?' в рендере, не краш);
#   gufo_prompt_state_*_bytes — НЕ читаются осознанно (эмитятся только
#   claim-раннерам, на Qwen/Flash-Next их нет — docs:1580–1583).
import calendar
import datetime
import re
import time

# Ключи /metrics (полный список, http_server.cpp:1595–1685). СЧЁТЧИКИ:
K_LOST = 'gufo_device_lost_total'
K_PROMPT = 'llamacpp:prompt_tokens_total'  # HELP: excluding cache hits
K_CACHED = 'llamacpp:prompt_tokens_cached_total'
K_PROMPT_S = 'llamacpp:prompt_seconds_total'
K_PRED = 'llamacpp:tokens_predicted_total'
K_PRED_S = 'llamacpp:tokens_predicted_seconds_total'
K_PEAK = 'llamacpp:n_tokens_max'  # TYPE counter — монотонный максимум
K_ROUNDS = 'llamacpp:spec_decode_num_drafts_total'  # РАУНДЫ верификации — в формулах НЕ участвует
K_DRAFT_TOK = 'llamacpp:spec_decode_num_draft_tokens_total'
K_ACC = 'llamacpp:spec_decode_num_accepted_tokens_total'
K_LOOKUP = 'gufo_spec_lookup_tokens_total'
K_LOOKUP_ACC = 'gufo_spec_lookup_accepted_tokens_total'
# GAUGE:
K_GEN_LAST = 'llamacpp:predicted_tokens_seconds'  # последняя ненулевая скорость
K_PREFILL_LAST = 'llamacpp:prompt_tokens_seconds'
K_Q_PROC = 'llamacpp:requests_processing'
K_Q_DEF = 'llamacpp:requests_deferred'
K_KV = 'llamacpp:kv_cache_usage_ratio'

SPARK_UTF = '▁▂▃▄▅▆▇█'
SPARK_ASCII = ' .:-=+*#'

TS_RE = re.compile(r'(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})')


def parse_metrics(text):
    # @param 1: string  # тело GET /metrics (prometheus-текст)
    # @returns dict     # имя → float; '# …' и *_bucket{…} отброшены,
    #   labels {…} сняты с имени (ключи gufo с ':' идут как есть) — v1 1:1
    out = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        name = parts[0]
        if '{' in name:
            name = name.split('{', 1)[0]
        if name.endswith('_bucket'):
            continue
        try:
            out[name] = float(parts[1])
        except ValueError:
            continue
    return out


def _div(a, b):
    # @returns float|None  # a/b; нет операнда или нулевой знаменатель → None
    if a is None or b is None or b == 0:
        return None
    return a / b


def _pct(a, b):
    # @returns float|None  # a/b×100; защита как у _div
    if a is None or b is None or b == 0:
        return None
    return a / b * 100.0


def engine_stats(m):
    # @param 1: dict|None  # parse_metrics /metrics этого тика
    # @returns dict|None   # m пуст/None → None (dead-тик). Формулы v2
    #   (task.md Round 2; семантика обновления — server.md:1557–1583:
    #   token-счётчики LIVE по чанкам, секундные/раунды/draft-токены/
    #   lookup/n_tokens_max — на done/cancel, speed-gauge — последняя
    #   ненулевая скорость). Значения НЕ округляются (форматирует рендер).
    #   None-значение = нет ключа или деление на 0 (пустые счётчики до
    #   первого done).
    if not m:
        return None
    prompt = m.get(K_PROMPT)
    cached = m.get(K_CACHED)
    return {
        'gen_avg': _div(m.get(K_PRED), m.get(K_PRED_S)),
        'gen_last': m.get(K_GEN_LAST),
        'prefill_avg': _div(prompt, m.get(K_PROMPT_S)),
        'prefill_last': m.get(K_PREFILL_LAST),
        # кэш-эффект: prompt_tokens_total УЖЕ исключает кэш-хиты (HELP
        # http_server.cpp:1601) → знаменатель = prompt + cached, иначе >100%
        'cache_pct': _pct(cached, prompt + cached)
        if prompt is not None and cached is not None else None,
        # acceptance — по ПРЕДЛОЖЕННЫМ ТОКЕНАМ; K_ROUNDS (раунды) — не знаменатель
        'spec_pct': _pct(m.get(K_ACC), m.get(K_DRAFT_TOK)),
        'kv_pct': None if m.get(K_KV) is None else m[K_KV] * 100.0,
        'kv_peak': m.get(K_PEAK),
        'q_proc': m.get(K_Q_PROC),
        'q_def': m.get(K_Q_DEF),
        'tok_prompt': m.get(K_PROMPT),
        'tok_cached': m.get(K_CACHED),
        'tok_pred': m.get(K_PRED),
        'lookup_pct': _pct(m.get(K_LOOKUP_ACC), m.get(K_LOOKUP)),
        'lookup_tok': m.get(K_LOOKUP),
        'lookup_acc': m.get(K_LOOKUP_ACC),
        'device_lost': m.get(K_LOST),
    }


class Deltas:
    """Дельты счётчиков /metrics ЗА ТИК — пульс (НЕ скорость): decode/
    prefill — LIVE token-счётчики (движутся по чанкам — docs:1557–1558),
    drafts — Δspec_decode_num_draft_tokens_total (токены, done-only).
    Отрицательный Δ (recreate/reset счётчиков) → None на тике, база всё
    равно обновляется; update(None) — reset (мёртвый сервер): после
    поднятия ложных дельт нет (перенос hfctl 1:1). Ключа 'gen_last'
    больше НЕТ — «последний запрос» = speed-gauge (engine_stats)."""

    def __init__(self):
        self.prev = None

    def reset(self):
        self.prev = None

    def update(self, m):
        # @param 1: dict|None  # метрики тика (None — сбой чтения)
        # @returns dict   # {'prefill','decode','drafts'} — Δ ТОКЕНОВ за тик
        #   (None — нет базы/сброс), НЕ tok/s
        out = {'prefill': None, 'decode': None, 'drafts': None}
        if m is None:
            self.prev = None
            return out
        if self.prev is not None:
            for key, cnt in (('prefill', K_PROMPT), ('decode', K_PRED),
                             ('drafts', K_DRAFT_TOK)):
                cur = m.get(cnt)
                prev = self.prev.get(cnt)
                if cur is not None and prev is not None:
                    d = int(cur - prev)
                    out[key] = d if d >= 0 else None
        self.prev = m
        return out


def sparkline(values, width, glyphs=SPARK_UTF):
    # @param 1: iterable  # история значений (None — пропуск, тик не
    #   добавляется; перенос hfctl 1:1)
    # @param 2: integer   # ширина в знаках (последние width значений)
    # @param 3: string    # 8 глиф-ступеней (последняя — max)
    # @returns string     # autoscale к максимуму ряда (≥1); пустой ряд → ''
    vals = [v for v in values if v is not None]
    if not vals or width < 1:
        return ''
    mx = max(vals)
    if mx < 1:
        mx = 1.0
    tail = vals[-width:]
    return ''.join(glyphs[min(7, int(v / mx * 7.999))] for v in tail)


def log_ts_utc_epoch(line):
    # @param 1: string  # строка лога движка (метки — UTC, контейнер не
    #   трогаем; формат подтверждён EXP-005/006: 'YYYY-MM-DD HH:MM:SS [LVL]')
    # @returns int|None  # epoch UTC первого re-матча TS_RE; метки нет /
    #   календарно невозможна → None (время НЕ выдумывается)
    m = TS_RE.search(line)
    if not m:
        return None
    y, mo, d, h, mi, s = (int(m.group(i)) for i in range(1, 7))
    try:
        datetime.datetime(y, mo, d, h, mi, s)
    except ValueError:
        return None
    return calendar.timegm((y, mo, d, h, mi, s, 0, 0, 0))


def log_line_local(line):
    # @returns string  # TZ-конверсия для рендера: метка найдена →
    #   'HH:MM:SS' + хвост строки после метки (time.localtime от UTC-epoch);
    #   метки нет → строка как есть. Буфер хранит СЫРЫЕ строки — конверсия
    #   на рендере (детерминизм паузы/перерисовки)
    epoch = log_ts_utc_epoch(line)
    if epoch is None:
        return line
    m = TS_RE.search(line)
    return time.strftime('%H:%M:%S', time.localtime(epoch)) + line[m.end():]


def parse_route_lines(lines):
    # @param 1: iterable  # строки буфера логов
    # @returns dict  # {'spec','sessions','ctx','model'} из ПОСЛЕДНЕЙ строки
    #   event=load_completed (последняя побеждает — последний recreate);
    #   семантика parse_route lib/health.sh 1:1: model — подстрока между
    #   'model=' и 'sessions=' (имена gufo содержат пробелы); строки нет →
    #   все ''
    spec = sessions = ctx = model = ''
    for line in lines:
        if 'event=load_completed' not in line:
            continue
        m = re.search(r'speculative=([^ ]+)', line)
        spec = m.group(1) if m else ''
        m = re.search(r'sessions=([0-9]+)', line)
        sessions = m.group(1) if m else ''
        m = re.search(r'context_tokens=([0-9]+)', line)
        ctx = m.group(1) if m else ''
        if 'model=' in line:
            model = line.split('model=', 1)[1].split('sessions=', 1)[0].strip()
    return {'spec': spec, 'sessions': sessions, 'ctx': ctx, 'model': model}


def parse_configured_lines(lines):
    # @param 1: iterable  # строки буфера логов
    # @returns dict  # {'sessions','ram_cache','capacity','automatic','disk'}
    #   из ПОСЛЕДНЕЙ строки event=configured (формат живого лога FX-W1b);
    #   семантика parse_configured lib/commands.sh 1:1 (\b-границы:
    #   capacity_bytes не ловит disk_capacity_bytes); байты — перевод в
    #   GiB делает рендер; строки нет → все ''
    sessions = ram_cache = capacity = automatic = disk = ''
    for line in lines:
        if 'event=configured' not in line:
            continue
        m = re.search(r'sessions=([0-9]+)', line)
        sessions = m.group(1) if m else ''
        m = re.search(r'\bram_cache=(on|off)', line)
        ram_cache = m.group(1) if m else ''
        m = re.search(r'\bcapacity_bytes=([0-9]+)', line)
        capacity = m.group(1) if m else ''
        m = re.search(r'\bautomatic_bytes=([0-9]+)', line)
        automatic = m.group(1) if m else ''
        m = re.search(r'\bdisk_capacity_bytes=([0-9]+)', line)
        disk = m.group(1) if m else ''
    return {'sessions': sessions, 'ram_cache': ram_cache,
            'capacity': capacity, 'automatic': automatic, 'disk': disk}
