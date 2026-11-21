#!/usr/bin/env python3
# Назначение: `gfctl watch` — живой дашборд gufo-сервера v2 (SPEC §3,
#   task.md + Round 2): ОДИН коллектор данных и два рендерера — TUI
#   (curses, TTY) и plain-стрим (не-TTY); режим по sys.stdout.isatty().
#   Блоки: «Железо» (GPU из sysfs — перенос hfctl 1:1, CPU Tctl,
#   device-lost из /metrics красным при >0), «Память» (RAM+VRAM/GTT),
#   «Движок» (вычисляемые формулы v2 из кумулятивных /metrics — см.
#   watch_engine; роут из лога load_completed, режим — /ready +
#   configured), «Скорость» (sparkline Δ за тик — «пульс», НЕ скорость;
#   token-счётчики LIVE — docs server.md:1557–1558), «Логи» (podman logs
#   БЕЗ -t — время в строках движка; TZ-конверсия UTC→локальный НА
#   РЕНДЕРЕ). Данные-роль — watch_sysfs (sysfs/proc) + watch_engine
#   (/metrics, формулы, дельты, парсеры лога) — этот файл только харнес.
#   Мёртвый сервер: plain — РОВНО одна строка «недоступен» на тик;
#   TUI — блок «Движок» = «недоступен»; без traceback-спама (v1).
#
# Входы — ТОЛЬКО env (bash cmd_watch передаёт без argv, паттерн hfctl):
#   GFCTL_WATCH_PORT (def 8080, D2), GFCTL_WATCH_INTERVAL (def 2; float;
#   <0.05 — батарея без сна), GFCTL_WATCH_CONTAINER (def gufo); швы
#   батареи GFCTL_WATCH_TICKS (0/нет = бесконечно) и
#   GFCTL_WATCH_SELFCHECK=1 (assert-самопроверка без сервера/TTY,
#   exit 0/1). Клавиши TUI: q/Q — выход rc 0; +/= / -/_ — интервал ±1 с
#   (min 1); p — пауза live-лога.
#
# Побочные эффекты: каждый тик — GET /metrics + GET /ready (curl из
#   PATH, таймаут 5 с); чтение /proc, /sys — каждый тик независимо от
#   сервера; TUI — сид `podman logs --tail 50` (до первой рамки) +
#   daemon-поток `podman logs --tail 1 -f`; рисует в alt-экране, выход
#   снимает (endwin). Файлов и стека не меняет.
#
# Ограничения/допущения: stdlib only, синтаксис 3.8+; HTTP — только в
#   главном потоке; глифы Unicode при UTF-8-окружении, ASCII-фолбэк;
#   initscr-краш (TERM неизвестен) → фолбэк в plain, не краш; uptime v1
#   УБРАН по составу v2 (task.md Round 2: строки «Движок» — роут/режим/
#   формулы; идея вернуть в «Режим» — out-of-scope).
#
# @returns integer  # 0 — обычный выход (q / Ctrl-C / SIGTERM / тики); 1 — selfcheck упал
import curses
import locale
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from collections import deque

import watch_engine
import watch_sysfs

C_RED, C_GREEN, C_YELLOW = 1, 2, 3


def env_float(name, default):
    # @returns float  # env или дефолт; не-число → дефолт (не краш)
    try:
        return float(os.environ.get(name, '') or default)
    except ValueError:
        return default


def choose_utf8(encoding=None, term=None):
    # @returns bool  # True — Unicode-глифы и рамки (не-UTF-8/пустой/dumb TERM → ASCII)
    if encoding is None:
        encoding = locale.getpreferredencoding(False) or ''
    if 'UTF-8' not in encoding.upper().replace('_', '-'):
        return False
    if term is None:
        term = os.environ.get('TERM', '')
    return (term or '').strip() not in ('', 'dumb', 'posix')


class Glyphs:
    # @type bool utf8  # Unicode-набор или ASCII-фолбэк
    def __init__(self, utf8):
        self.utf8 = utf8
        self.tl = '┌' if utf8 else '+'
        self.tr = '┐' if utf8 else '+'
        self.bl = '└' if utf8 else '+'
        self.br = '┘' if utf8 else '+'
        self.h = '─' if utf8 else '-'
        self.v = '│' if utf8 else '|'
        self.dot = '●' if utf8 else 'o'
        self.deg = '°C' if utf8 else 'C'
        self.bar_full = '█' if utf8 else '#'
        self.bar_empty = '░' if utf8 else '.'
        self.spark = watch_engine.SPARK_UTF if utf8 else watch_engine.SPARK_ASCII


def http_get(url, timeout=5.0):
    # @returns string   # тело ответа; сбой — исключение (зовущий ловит).
    #   curl из PATH (не urllib): faux-bin-шов батареи — счётчик вызовов и
    #   URL-лог видны в FAUXLOG/GFCTL_FAUX_CNT.curl (§37)
    p = subprocess.run(['curl', '-fsS', '-m', '%.0f' % max(1, timeout), url],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if p.returncode != 0:
        raise OSError('curl rc=%d' % p.returncode)
    return p.stdout.decode('utf-8', 'replace')


def fmt1(x):
    # @returns string  # 1 знак; None → '-' (нет данных/деление на 0)
    return '-' if x is None else '%.1f' % x


def fmti(x, q='?'):
    # @returns string  # целое; None → q (нет ключа/датчика)
    return q if x is None else str(int(x))


def fmt_pct(x):
    # @returns string  # проценты 1 знак с '%'; None → '?'
    return '?' if x is None else '%.1f%%' % x


def fmt_gib(b):
    # @returns string  # байты → GiB 1 знак; None → '?' (датчик/поле нет)
    return '?' if b is None else fmt1(b / (1024.0 ** 3))


def fmt_tok(v):
    # @returns string  # счётчик компактно: <1000 — целое, → «99.1k», ≥1M → «1.2M»
    if v is None:
        return '?'
    if v >= 1_000_000:
        return '%.1fM' % (v / 1e6)
    if v >= 1000:
        return '%.1fk' % (v / 1000.0)
    return str(int(v))


def fmt_c(x):
    # @returns string  # °C 1 знак; None → '?'
    return '?' if x is None else '%.1f' % x


def temp_color(deg, fmt=None):
    # @param 2: callable  # печататель (fmt_c/fmti) — порог сравнивается по
    #   НАПЕЧАТАННОМУ значению (79.95 печатается «80.0» → жёлтый; hfctl 1:1);
    #   без fmt — по сырому числу
    # @returns integer  # None→0; ≥90 → C_RED; 80…89.9 → C_YELLOW; иначе 0
    #   (пороги DoD: жёлтый 80–89 °C, красный ≥90)
    if deg is None:
        return 0
    if fmt is not None:
        deg = float(fmt(deg))
    if deg >= 90:
        return C_RED
    if deg >= 80:
        return C_YELLOW
    return 0


def mem_fill_color(avail, total):
    # @returns integer  # цвет RAM по заполнению (task.md Round 2: пороги
    #   зеркалят температурные 90/80): доля avail/total ≤0.1 → C_RED,
    #   ≤0.2 → C_YELLOW, иначе 0; нет данных → 0
    if avail is None or total is None or total <= 0:
        return 0
    frac = avail / total
    if frac <= 0.1:
        return C_RED
    if frac <= 0.2:
        return C_YELLOW
    return 0


def fmt_uptime(s):
    # @returns string  # d/h/m; None → '?' (v1 1:1 — статус-бар/журналы)
    if s is None:
        return '?'
    s = int(s)
    d, rem = divmod(s, 86400)
    h, rem = divmod(rem, 3600)
    m, sec = divmod(rem, 60)
    if d:
        return '%dd %dh %dm' % (d, h, m)
    if h:
        return '%dh %dm' % (h, m)
    return '%dm %ds' % (m, sec)


def dead_line(ts, port):
    # @returns string  # ровно ОДНА строка мёртвого сервера (plain, на тик)
    return '%s сервер недоступен (нет /metrics на :%d); жду…' % (ts, port)


def fmt_plain(snap, route, conf, deltas, ts, glyphs=None):
    # @returns list  # срез 4 блоков plain-стрима (порядок фиксирован:
    #   железо/память/движок/скорость); «Логи» печатает вызывающий —
    #   хвост буфера c TZ-конверсией. Чего нет → '?', нет данных → '-'
    g = glyphs or Glyphs(choose_utf8())
    st = snap['stats'] or {}
    gpu = snap['gpu']
    if gpu is None:
        gpu_part = 'GPU: карта AMD (0x1002) не найдена'
    else:
        gpu_part = ('GPU %s%s %sMHz %sW %s%% VRAM %s GiB GTT %s GiB'
                    % (fmt_c(gpu['temp_c']), g.deg, fmti(gpu['sclk_mhz']),
                       fmti(gpu['power_w']), fmti(gpu['busy_pct']),
                       fmt_gib(gpu['vram_used']), fmt_gib(gpu['gtt_used'])))
    cpu = snap['cpu_t']
    cpu_part = ('CPU %s%s' % (fmt_c(cpu), g.deg)) if cpu is not None else 'CPU ?'
    line_hw = '%s [железо] %s | %s | lost %s' % (
        ts, gpu_part, cpu_part, fmti(st.get('device_lost')))

    mem = snap['mem']
    gp = gpu or {}
    line_mem = ('%s [память] RAM %s/%s GiB | VRAM %s GiB | GTT %s GiB'
                % (ts, fmt1(mem.get('available_gib')), fmt1(mem.get('total_gib')),
                   fmt_gib(gp.get('vram_used')), fmt_gib(gp.get('gtt_used'))))

    conf_part = ''
    if any(conf.values()):
        disk = conf.get('disk')
        disk_s = (fmt1(float(disk) / (1024.0 ** 3)) + ' GiB') if disk else '?'
        conf_part = ' | cache: ram %s · disk %s' % (
            conf.get('ram_cache') or '?', disk_s)
    lookup = ''
    lt = st.get('lookup_tok') or 0
    la = st.get('lookup_acc') or 0
    if lt > 0 or la > 0:
        lookup = ' | lookup %s/%s (%s)' % (fmt_tok(la), fmt_tok(lt),
                                           fmt_pct(st.get('lookup_pct')))
    line_en = ('%s [движок] gen %s/%s tok/s | prefill %s/%s | кэш %s | спек %s'
               ' | KV %s пик %s | оч %s/%s | префил %s+%s | сген %s'
               ' | %s · s%s · ctx %s | %s%s%s'
               % (ts, fmt1(st.get('gen_avg')), fmt1(st.get('gen_last')),
                  fmt1(st.get('prefill_avg')), fmt1(st.get('prefill_last')),
                  fmt_pct(st.get('cache_pct')), fmt_pct(st.get('spec_pct')),
                  fmt_pct(st.get('kv_pct')), fmt_tok(st.get('kv_peak')),
                  fmti(st.get('q_proc')), fmti(st.get('q_def')),
                  fmt_tok(st.get('tok_prompt')), fmt_tok(st.get('tok_cached')),
                  fmt_tok(st.get('tok_pred')),
                  route['spec'] or '?', route['sessions'] or '?',
                  route['ctx'] or '?', 'готов' if snap['ready'] else 'нет',
                  conf_part, lookup))

    d = deltas or {}
    line_sp = ('%s [скорость] пульс: decode +%s prefill +%s drafts +%s (ток/тик)'
               % (ts, d.get('decode') or 0, d.get('prefill') or 0,
                  d.get('drafts') or 0))
    return [line_hw, line_mem, line_en, line_sp]


def put(win, y, x, s, attr=0):
    # addstr в точку окна; обрезка по краю, за пределом — молча (деградация,
    # не трейс — каркас hfctl)
    h, w = win.getmaxyx()
    if y < 0 or y >= h or x >= w or not s:
        return
    if x < 0:
        s = s[-x:]
        x = 0
    if x + len(s) > w:
        s = s[:w - x]
    if not s:
        return
    try:
        win.addstr(y, x, s, attr)
    except (curses.error, UnicodeEncodeError, ValueError):
        pass


def status_bar_layout(W, interval, model, paused):
    # (left, mid, right, x_mid, x_right, draw_mid, draw_right) — каркас
    # hfctl; модель усечена так, чтобы разрыв left→mid был ≥1 колонки
    prefix = 'gfctl watch │ модель '
    mid = 'интервал %g c' % interval
    right = ('логи: live, пауза: p │ q — выход' if not paused
             else 'логи: пауза, live: p │ q — выход')
    right_x = max(0, W - len(right) - 1)
    mid_x = max(0, min(W // 2 - len(mid) // 2, right_x - len(mid) - 1))
    model_w = mid_x - len(prefix) - 3
    left = prefix + model[:max(0, model_w)]
    draw_mid = mid_x > 2 + len(left)
    draw_right = right_x > 2 + len(left)
    return left, mid, right, mid_x, right_x, draw_mid, draw_right


class LogStreamer(threading.Thread):
    """Логи движка: сид `podman logs --tail 50` (seed(), синхронно в
    главном потоке ДО первой рамки), далее live `podman logs --tail 1 -f`
    (дедуп первой live-строки против хвоста сида). БЕЗ `-t` в обоих
    вызовах (task.md Round 2, DoD 4): время берём из строк движка и
    конвертируем TZ сами. stdout построчно → deque(500). podman logs
    печатает логи в STDERR (проверено вживую) — ОБА вызова объединяют
    stderr в stdout-PIPE. Поток НЕ дёргает curses и HTTP. podman/
    контейнера нет → сид и стрим молча падают (буфер пуст), повторные
    попытки раз в ~1 с. stop() завершает подпроцесс."""

    def __init__(self, container):
        super().__init__(daemon=True)
        self.container = container
        self.buf = deque(maxlen=500)
        self._proc = None
        self._stopped = False
        self._last_try = 0.0
        self._seed_tail = None

    def seed(self):
        # @returns None  # нет podman/таймаут/rc≠0 — молча (буфер пуст)
        try:
            proc = subprocess.run(
                ['podman', 'logs', '--tail', '50', self.container],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, errors='replace', timeout=10)
        except (FileNotFoundError, OSError, subprocess.TimeoutExpired):
            return
        if proc.returncode == 0:
            lines = proc.stdout.splitlines()
            self.buf.extend(lines)
            self._seed_tail = lines[-1] if lines else None

    def _spawn_once(self):
        now = time.monotonic()
        if now - self._last_try < 1.0:
            return
        self._last_try = now
        try:
            proc = subprocess.Popen(
                ['podman', 'logs', '--tail', '1', '-f', self.container],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, errors='replace')
        except (FileNotFoundError, OSError):
            return
        self._proc = proc
        for line in proc.stdout:
            line = line.rstrip('\n')
            if self._seed_tail is not None and line == self._seed_tail:
                self._seed_tail = None
                continue  # дедуп: live ре-эммитит хвост сида один раз
            self._seed_tail = None
            self.buf.append(line)
        self._proc = None

    def stop(self):
        self._stopped = True
        p = self._proc
        if p is not None and p.poll() is None:
            try:
                p.terminate()
            except OSError:
                pass

    def run(self):
        try:
            while not self._stopped:
                self._spawn_once()
                if not self._stopped:
                    time.sleep(1)
        finally:
            self.stop()


def selfcheck():
    # @returns integer  # 0 — всё прошло; 1 — есть провалы (имена в stderr)
    fails = []
    total = 0

    def ck(name, cond):
        nonlocal total
        total += 1
        if not cond:
            fails.append(name)

    # ── парсер /metrics (v1 1:1 + нейтральность к prompt_state/histogram) ──
    m = watch_engine.parse_metrics(
        '# HELP llamacpp:prompt_tokens_cached_total x\n'
        'llamacpp:prompt_tokens_cached_total 539\n'
        'llamacpp:foo_bucket{le="10"} 3\n'
        'llamacpp:bar{machine="x"} 7\n'
        'gufo_prompt_state_budget_bytes 123\n')
    ck('metrics cached_total', m.get('llamacpp:prompt_tokens_cached_total') == 539.0)
    ck('metrics labels stripped', m.get('llamacpp:bar') == 7.0)
    ck('metrics _bucket excluded', 'llamacpp:foo_bucket' not in m)
    ck('metrics # lines excluded', len(m) == 3)
    ck('metrics prompt_state parse-neutral', m.get('gufo_prompt_state_budget_bytes') == 123.0)

    # ── engine_stats: EXP-007-снапшот (кросс-чек формул v2) ────────────────
    m7 = watch_engine.parse_metrics(
        'llamacpp:prompt_tokens_total 93\n'
        'llamacpp:prompt_tokens_cached_total 27044\n'
        'llamacpp:prompt_seconds_total 0.63273363599999999\n'
        'llamacpp:tokens_predicted_total 18\n'
        'llamacpp:tokens_predicted_seconds_total 0.89354949399999994\n'
        'llamacpp:n_tokens_max 27155\n'
        'llamacpp:spec_decode_num_drafts_total 7\n'
        'llamacpp:spec_decode_num_draft_tokens_total 30\n'
        'llamacpp:spec_decode_num_accepted_tokens_total 11\n'
        'llamacpp:prompt_tokens_seconds 146.98128044515718\n'
        'llamacpp:predicted_tokens_seconds 20.144379377825491\n'
        'llamacpp:requests_processing 0\n'
        'llamacpp:requests_deferred 0\n'
        'llamacpp:kv_cache_usage_ratio 0\n'
        'gufo_device_lost_total 0\n')
    st7 = watch_engine.engine_stats(m7)
    ck('stats EXP-007 gen_avg≈20.14 (18/0.8935)', abs(st7['gen_avg'] - 20.1444) < 0.01)
    ck('stats EXP-007 prefill_avg≈146.98 (93/0.6327)', abs(st7['prefill_avg'] - 146.9813) < 0.01)
    ck('stats EXP-007 gauge passthrough (последний)', st7['gen_last'] == 20.144379377825491
       and st7['prefill_last'] == 146.98128044515718)
    ck('stats EXP-007 cache_pct≈99.66 ≤100 (новый знаменатель)',
       abs(st7['cache_pct'] - 99.658) < 0.01 and st7['cache_pct'] <= 100.0)
    ck('stats EXP-007 spec_pct≈36.67 ПО ТОКЕНАМ (11/30, не раунды 11/7)',
       abs(st7['spec_pct'] - 36.6667) < 0.01)
    ck('stats EXP-007 KV/пик/очередь/lost',
       st7['kv_pct'] == 0.0 and st7['kv_peak'] == 27155.0
       and st7['q_proc'] == 0.0 and st7['q_def'] == 0.0 and st7['device_lost'] == 0.0)
    ck('stats lookup нули → pct None',
       watch_engine.engine_stats(watch_engine.parse_metrics(
           'gufo_spec_lookup_tokens_total 0\ngufo_spec_lookup_accepted_tokens_total 0\n'
       ))['lookup_pct'] is None)

    # ── engine_stats: фикстура snap1 (точные значения) + края ─────────────
    M1_TEXT = (
        'llamacpp:prompt_tokens_total 10000\n'
        'llamacpp:prompt_tokens_cached_total 990000\n'
        'llamacpp:prompt_seconds_total 100\n'
        'llamacpp:tokens_predicted_total 50000\n'
        'llamacpp:tokens_predicted_seconds_total 2500\n'
        'llamacpp:n_tokens_max 262144\n'
        'llamacpp:spec_decode_num_drafts_total 5000\n'
        'llamacpp:spec_decode_num_draft_tokens_total 100000\n'
        'llamacpp:spec_decode_num_accepted_tokens_total 60000\n'
        'llamacpp:prompt_tokens_seconds 98.7\n'
        'llamacpp:predicted_tokens_seconds 21.4\n'
        'llamacpp:requests_processing 0\n'
        'llamacpp:requests_deferred 0\n'
        'llamacpp:kv_cache_usage_ratio 0.12\n'
        'gufo_device_lost_total 0\n')
    m1 = watch_engine.parse_metrics(M1_TEXT)
    st1 = watch_engine.engine_stats(m1)
    ck('stats snap1 gen_avg ровно 20.0', st1['gen_avg'] == 20.0)
    ck('stats snap1 prefill_avg ровно 100.0', st1['prefill_avg'] == 100.0)
    ck('stats snap1 cache_pct ровно 99.0 (≤100)', abs(st1['cache_pct'] - 99.0) < 1e-6)
    ck('stats snap1 spec_pct ровно 60.0 (accepted/draft_tokens)',
       abs(st1['spec_pct'] - 60.0) < 1e-6 and st1['spec_pct'] != 60000.0 / 5000.0 * 100)
    ck('stats деление на 0 → None (счётчики пусты до первого done)',
       watch_engine.engine_stats(watch_engine.parse_metrics(
           'llamacpp:tokens_predicted_total 5\nllamacpp:tokens_predicted_seconds_total 0\n'
       ))['gen_avg'] is None)
    ck('stats spec_pct None при draft_tokens=0',
       watch_engine.engine_stats(watch_engine.parse_metrics(
           'llamacpp:spec_decode_num_accepted_tokens_total 5\n'
           'llamacpp:spec_decode_num_draft_tokens_total 0\n'))['spec_pct'] is None)
    ck('stats None/пусто', watch_engine.engine_stats(None) is None
       and watch_engine.engine_stats({}) is None)

    # ── Deltas (пульс v2: draft по draft_tokens, без gen_last) ────────────
    d = watch_engine.Deltas()
    ck('deltas тик1: базы нет → все None', d.update(m1) ==
       {'prefill': None, 'decode': None, 'drafts': None})
    d2 = d.update(watch_engine.parse_metrics(
        'llamacpp:prompt_tokens_total 10512\n'
        'llamacpp:prompt_tokens_cached_total 990512\n'
        'llamacpp:tokens_predicted_total 50300\n'
        'llamacpp:spec_decode_num_draft_tokens_total 100000\n'))
    ck('deltas тик2 live-пульс без done: decode +300 prefill +512 drafts +0',
       d2 == {'prefill': 512, 'decode': 300, 'drafts': 0})
    ck('deltas без ключа gen_last (Round 2)', 'gen_last' not in d2)
    d3 = d.update(watch_engine.parse_metrics(
        'llamacpp:prompt_tokens_total 10512\n'
        'llamacpp:prompt_tokens_cached_total 990512\n'
        'llamacpp:tokens_predicted_total 50300\n'
        'llamacpp:spec_decode_num_draft_tokens_total 101000\n'))
    ck('deltas тик3 done-пульс: drafts +1000 (токены), decode/prefill 0',
       d3 == {'prefill': 0, 'decode': 0, 'drafts': 1000})
    dn = d.update(watch_engine.parse_metrics(
        'llamacpp:tokens_predicted_total 10\n'))  # recreate → отрицательный Δ
    ck('deltas отрицательный Δ → None (сброс счётчиков)',
       dn == {'prefill': None, 'decode': None, 'drafts': None})
    d.update(None)
    ck('deltas update(None) reset: ложных дельт после поднятия нет',
       d.update(watch_engine.parse_metrics('llamacpp:tokens_predicted_total 10\n')) ==
       {'prefill': None, 'decode': None, 'drafts': None})

    # ── sparkline (hfctl 1:1) ──────────────────────────────────────────────
    ck('sparkline UTF autoscale', watch_engine.sparkline([1, 2, 4, 8], 4) == '▁▂▄█')
    tail_vals = list(range(20))
    sp = watch_engine.sparkline(tail_vals, 8, watch_engine.SPARK_ASCII)
    ck('sparkline tail kept + ascii', len(sp) == 8 and sp[-1] == watch_engine.SPARK_ASCII[7])
    ck('sparkline empty → ""', watch_engine.sparkline([], 8) == '')
    ck('sparkline нули → первые глифы (mx clamp 1)',
       watch_engine.sparkline([0, 0], 2) == watch_engine.SPARK_UTF[0] * 2)

    # ── TZ-конверсия (детерминизм: TZ=UTC через tzset) ─────────────────────
    old_tz = os.environ.get('TZ')
    os.environ['TZ'] = 'UTC'
    time.tzset()
    try:
        ep = watch_engine.log_ts_utc_epoch('2026-11-17 23:28:03 [INFO] [gpu] event=x')
        ck('ts epoch UTC == timegm', ep == watch_engine.log_ts_utc_epoch('2026-11-17T23:28:03 [INFO]')
           and time.strftime('%H:%M:%S', time.gmtime(ep)) == '23:28:03')
        ck('log_line_local UTC: метка → HH:MM:SS + хвост',
           watch_engine.log_line_local('2026-11-17 23:28:03 [INFO] [gpu] event=x')
           == '23:28:03 [INFO] [gpu] event=x')
        ck('log_line_local T-разделитель', watch_engine.log_line_local(
            '2026-11-17T08:47:19 boot') == '08:47:19 boot')
    finally:
        if old_tz is None:
            os.environ.pop('TZ', None)
        else:
            os.environ['TZ'] = old_tz
        time.tzset()
    ck('log_line_local без метки — строка как есть',
       watch_engine.log_line_local('event=listening address=http://x') ==
       'event=listening address=http://x')
    ck('log_ts невозможная дата → None', watch_engine.log_ts_utc_epoch('2026-13-40 99:99:99 x') is None)
    ck('log_ts нет метки → None', watch_engine.log_ts_utc_epoch('event=listening') is None)

    # ── парсеры лога (семантика parse_route/parse_configured 1:1) ─────────
    seed = ['2026-11-17 08:47:19 [INFO] boot',
            'event=load_completed speculative=mtp elapsed_ms=1 '
            'model=Qwen3.8 Flash Next sessions=2 context_tokens=262144 draft_limit=7']
    r = watch_engine.parse_route_lines(seed)
    ck('route: модель с пробелами целиком + поля',
       r == {'spec': 'mtp', 'sessions': '2', 'ctx': '262144',
             'model': 'Qwen3.8 Flash Next'})
    r2 = watch_engine.parse_route_lines(seed + [
        'event=load_completed speculative=dflash2 sessions=1 context_tokens=163840 model=B'])
    ck('route: последняя load_completed побеждает', r2['spec'] == 'dflash2' and r2['model'] == 'B')
    ck('route: пусто → все ""', watch_engine.parse_route_lines(['boot']) ==
       {'spec': '', 'sessions': '', 'ctx': '', 'model': ''})
    c = watch_engine.parse_configured_lines([
        '2026-11-18 07:27:02 [INFO] [cache] schema=component-cache-v1 event=configured '
        'sessions=1 ram_cache=on capacity_bytes=12884901888 automatic_bytes=4294967296 '
        'disk_capacity_bytes=68719476736'])
    ck('configured: поля + \\b-граница (capacity≠disk_capacity)',
       c == {'sessions': '1', 'ram_cache': 'on', 'capacity': '12884901888',
             'automatic': '4294967296', 'disk': '68719476736'})
    ck('configured: пусто → все ""', watch_engine.parse_configured_lines(['x']) ==
       {'sessions': '', 'ram_cache': '', 'capacity': '', 'automatic': '', 'disk': ''})

    # ── sysfs (фейковые деревья tempfile) ──────────────────────────────────
    fake = tempfile.mkdtemp(prefix='watch_v2_sys_')
    try:
        os.makedirs(fake + '/drm/card0/device/hwmon/hwmon0')
        os.makedirs(fake + '/drm/card0/device/hwmon/hwmon1')
        os.makedirs(fake + '/drm/card1/device/hwmon/hwmon0')
        os.makedirs(fake + '/drm/card1/device/hwmon/hwmon1')
        os.makedirs(fake + '/drm/card2/device')
        with open(fake + '/drm/card0/device/vendor', 'w') as f:
            f.write('0x10de\n')  # не-AMD первой картой — skip-ветка
        with open(fake + '/drm/card1/device/vendor', 'w') as f:
            f.write('0x1002\n')
        with open(fake + '/drm/card1/device/gpu_busy_percent', 'w') as f:
            f.write('3\n')
        with open(fake + '/drm/card1/device/hwmon/hwmon0/temp1_input', 'w') as f:
            f.write('35875\n')
        with open(fake + '/drm/card1/device/hwmon/hwmon1/temp1_input', 'w') as f:
            f.write('41000\n')  # MAX по ЭТОЙ карте → 41.0
        with open(fake + '/drm/card1/device/hwmon/hwmon1/freq1_input', 'w') as f:
            f.write('600000000\n')
        with open(fake + '/drm/card1/device/hwmon/hwmon1/power1_input', 'w') as f:
            f.write('5453000\n')
        with open(fake + '/drm/card1/device/hwmon/hwmon1/mem_info_vram_used', 'w') as f:
            f.write('3435973837\n')
        gpu = watch_sysfs.read_gpu(fake + '/drm')
        ck('read_gpu: skip не-AMD, MAX temp по карте (не CPU!), поля',
           gpu is not None and gpu['temp_c'] == 41.0 and gpu['sclk_mhz'] == 600.0
           and abs(gpu['power_w'] - 5.453) < 1e-9 and gpu['busy_pct'] == 3.0
           and gpu['vram_used'] == 3435973837.0)
        with open(fake + '/drm/card2/device/vendor', 'w') as f:
            f.write('0x1002\n')
        ck('read_gpu: per-field None',
           watch_sysfs.read_gpu(fake + '/drm') is not None
           and watch_sysfs.read_gpu(fake + '/drm')['gtt_used'] is None)
        ck('read_gpu: нет AMD → None', watch_sysfs.read_gpu(fake) is None)
        os.makedirs(fake + '/hwmon2')
        with open(fake + '/hwmon2/name', 'w') as f:
            f.write('k10temp\n')
        with open(fake + '/hwmon2/temp1_input', 'w') as f:
            f.write('45500\n')
        ck('read_cpu_temp: Tctl k10temp 45.5', watch_sysfs.read_cpu_temp(fake) == 45.5)
        ck('read_cpu_temp: нет k10temp → None', watch_sysfs.read_cpu_temp(fake + '/drm') is None)
    finally:
        shutil.rmtree(fake)
    mem = watch_sysfs.read_mem()
    ck('read_mem хост: GiB > 0', mem['total_gib'] is not None and mem['total_gib'] > 0)

    # ── цвета (пороги DoD; по НАПЕЧАТАННОМУ значению) ──────────────────────
    ck('temp_color границы 79.9/80/89.9/90/None',
       temp_color(79.9) == 0 and temp_color(80) == C_YELLOW
       and temp_color(89.9) == C_YELLOW and temp_color(90) == C_RED
       and temp_color(None) == 0)
    ck('temp_color как печатается: 79.95→"80.0"→жёлтый, 89.96→"90.0"→красный',
       fmt_c(79.95) == '80.0' and temp_color(79.95, fmt_c) == C_YELLOW
       and fmt_c(89.96) == '90.0' and temp_color(89.96, fmt_c) == C_RED)
    ck('temp_color fmti: 79.96→"79"→0, 89.96→"89"→жёлтый, 90.0→красный',
       temp_color(79.96, fmti) == 0 and temp_color(89.96, fmti) == C_YELLOW
       and temp_color(90.0, fmti) == C_RED)
    ck('mem_fill_color: ≤0.1 красный, ≤0.2 жёлтый, выше 0, нет данных 0',
       mem_fill_color(5, 100) == C_RED and mem_fill_color(10, 100) == C_RED
       and mem_fill_color(15, 100) == C_YELLOW and mem_fill_color(20, 100) == C_YELLOW
       and mem_fill_color(50, 100) == 0 and mem_fill_color(None, 100) == 0
       and mem_fill_color(5, 0) == 0)

    # ── форматтеры ─────────────────────────────────────────────────────────
    ck('fmt_tok границы', fmt_tok(999) == '999' and fmt_tok(1000) == '1.0k'
       and fmt_tok(1234567) == '1.2M' and fmt_tok(None) == '?')
    ck('fmt_gib', fmt_gib(None) == '?' and fmt_gib(1073741824) == '1.0'
       and fmt_gib(10737418240) == '10.0')
    ck('fmt_pct', fmt_pct(None) == '?' and fmt_pct(99.0) == '99.0%'
       and fmt_pct(60.0396) == '60.0%')

    # ── plain-срез (полный пин формата, UTF-глифы) ─────────────────────────
    snap = {'engine_ok': True, 'metrics': m1, 'stats': st1, 'ready': True,
            'gpu': {'temp_c': 54.0, 'sclk_mhz': 600.0, 'power_w': 5.45,
                    'busy_pct': 3.0, 'vram_used': 3435973836.8,
                    'gtt_used': 1181116006.4},
            'cpu_t': 45.0,
            'mem': {'available_gib': 45.2, 'total_gib': 60.4}}
    route = {'spec': 'dflash2', 'sessions': '1', 'ctx': '262144',
             'model': 'qwen3.8-27b-IQ4_XS-pure'}
    conf = {'sessions': '1', 'ram_cache': 'on', 'capacity': '12884901888',
            'automatic': '4294967296', 'disk': '68719476736'}
    deltas = {'decode': 12, 'prefill': 93, 'drafts': 7}
    plain = fmt_plain(snap, route, conf, deltas, '12:00:00', Glyphs(True))
    ck('plain железо', plain[0] == '12:00:00 [железо] GPU 54.0°C 600MHz 5W 3% VRAM 3.2 GiB'
       ' GTT 1.1 GiB | CPU 45.0°C | lost 0')
    ck('plain память', plain[1] == '12:00:00 [память] RAM 45.2/60.4 GiB'
       ' | VRAM 3.2 GiB | GTT 1.1 GiB')
    ck('plain движок (формулы v2, роут/режим/configured)', plain[2] ==
       '12:00:00 [движок] gen 20.0/21.4 tok/s | prefill 100.0/98.7'
       ' | кэш 99.0% | спек 60.0% | KV 12.0% пик 262.1k | оч 0/0'
       ' | префил 10.0k+990.0k | сген 50.0k | dflash2 · s1 · ctx 262144'
       ' | готов | cache: ram on · disk 64.0 GiB')
    ck('plain скорость (пульс, НЕ скорость)', plain[3] ==
       '12:00:00 [скорость] пульс: decode +12 prefill +93 drafts +7 (ток/тик)')
    joined = '\n'.join(plain)
    ck('plain: prompt_state_* не читаются, lookup скрыт при нулях',
       'budget' not in joined and 'lookup' not in joined
       and 'budget' not in '\n'.join(fmt_plain(
           dict(snap, stats=dict(st1, prompt_state_budget_bytes=123.0)),
           route, conf, deltas, '12:00:00', Glyphs(True))))
    st_l = watch_engine.engine_stats(watch_engine.parse_metrics(
        M1_TEXT + 'gufo_spec_lookup_tokens_total 250\n'
        'gufo_spec_lookup_accepted_tokens_total 200\n'))
    ck('plain: lookup при ненулевых суммарных виден',
       'lookup 200/250 (80.0%)' in fmt_plain(
           dict(snap, stats=st_l), route, conf, deltas, '12:00:00', Glyphs(True))[2])

    # ── dead-line (v1 1:1) ─────────────────────────────────────────────────
    ck('plain dead line', 'недоступен' in dead_line('12:00:00', 8080)
       and dead_line('x', 1).count('недоступен') == 1)

    # ── rows_* (TUI-строки, стиль — код цвета или A_BOLD) ──────────────────
    w = Watch()
    ck('rows engine dead',
       w.rows_engine({'engine_ok': False}, route, conf) == [('недоступен', '')])
    w.last_deltas = deltas
    rows_e = w.rows_engine(snap, route, conf)
    ck('rows engine labels (состав v2)',
       [x[0] for x in rows_e] == ['Роут', 'Режим', 'Генерация', 'Prefill',
                                  'Кэш-эффект', 'Спекуляция принято',
                                  'Draft-пульс', 'KV', 'Очередь', 'Префил',
                                  'Сгенерировано'])
    ck('rows engine: спекуляция выделена A_BOLD, draft-пульс число',
       rows_e[5][2] == curses.A_BOLD and rows_e[6][1] == '+7 ток/тик')
    ck('rows engine: lookup скрыт при нулях',
       'Prompt-lookup' not in [x[0] for x in rows_e])
    rows_l = w.rows_engine(dict(snap, stats=st_l), route, conf)
    ck('rows engine: lookup при ненулевых последней строкой',
       rows_l[-1][0] == 'Prompt-lookup')
    rows_hw = w.rows_hardware(snap)
    ck('rows hardware labels',
       [x[0] for x in rows_hw] == ['GPU temp', 'GPU freq', 'GPU load',
                                   'GPU power', 'VRAM', 'GTT', 'CPU temp',
                                   'Device lost'])
    ck('rows hardware: GPU-температура жёлтая 80+ (печатаемое значение)',
       w.rows_hardware(dict(snap, gpu=dict(snap['gpu'], temp_c=85.0)))[0][2] == C_YELLOW)
    ck('rows hardware: lost >0 → красный', w.rows_hardware(
        dict(snap, stats=dict(st1, device_lost=2.0)))[-1][2] == C_RED)
    ck('rows hardware: нет AMD-карты → заглушка + CPU + lost',
       [x[0] for x in w.rows_hardware(dict(snap, gpu=None))] ==
       ['GPU', 'CPU temp', 'Device lost'])
    rows_m = w.rows_memory(snap)
    ck('rows memory labels', [x[0] for x in rows_m] == ['RAM', 'VRAM', 'GTT'])
    ck('rows memory: RAM без цвета при 45/60',
       rows_m[0][2] == 0 and 'GiB' in rows_m[0][1])
    ck('rows memory: RAM красная при avail ≤10%',
       w.rows_memory(dict(snap, mem={'available_gib': 3.0, 'total_gib': 60.4}))[0][2] == C_RED)
    w.hist['decode'].extend([0, 1, 2])
    ck('rows speed labels', [x[0] for x in w.rows_speed(80)] == ['decode', 'prefill', 'drafts'])

    # ── сид логов: без podman не падает; stderr→stdout; БЕЗ -t ─────────────
    ls = LogStreamer('no-such-container')
    try:
        ls.seed()
        seeded_ok = True
    except Exception:
        seeded_ok = False
    ck('seed without podman no crash', seeded_ok)
    fake_bin = tempfile.mkdtemp(prefix='watch_v2_podman_')
    args_file = os.path.join(fake_bin, 'args')
    try:
        shim = fake_bin + '/podman'
        with open(shim, 'w') as f:
            f.write('#!/bin/sh\n')
            f.write('printf \'%%s\\n\' "$@" >> "%s"\n' % args_file)
            f.write('echo fake-log-line >&2\n')
        os.chmod(shim, 0o755)
        old_path = os.environ['PATH']
        os.environ['PATH'] = fake_bin + os.pathsep + old_path
        try:
            ls_s = LogStreamer('no-such-container')
            ls_s.seed()
            args = open(args_file).read().split()
            ck('seed: stderr→stdout (podman logs → stderr)',
               list(ls_s.buf) == ['fake-log-line'])
            ck('seed args: --tail 50 и БЕЗ -t (DoD 4)',
               '-t' not in args and args.index('--tail') >= 0
               and args[args.index('--tail') + 1] == '50')
        finally:
            os.environ['PATH'] = old_path
    finally:
        shutil.rmtree(fake_bin)

    # ── каркас (v1 1:1) ────────────────────────────────────────────────────
    ck('glyphs utf8', choose_utf8('UTF-8') is True)
    ck('glyphs ascii encoding', choose_utf8('ANSI_X3.4-1968') is False)
    ck('glyphs term dumb', choose_utf8('UTF-8', term='dumb') is False)
    left, mid, right, mid_x, right_x, draw_mid, draw_right = status_bar_layout(
        80, 2, 'qwen3.8-27b-IQ4_XS-pure', False)
    ck('status bar 80 cols gap≥1',
       draw_mid and draw_right and mid_x - 2 - len(left) >= 1
       and right_x + len(right) <= 80)

    for name in fails:
        print('selfcheck FAIL: %s' % name, file=sys.stderr)
    print('selfcheck: %d/%d ok' % (total - len(fails), total))
    return 1 if fails else 0


class Watch:
    """Состояние + цикл. TUI и plain используют один коллектор (collect)
    и одну обработку тика (apply_tick: дельты+история); различаются рендер
    и период печати. Роут/cache-conf пересчитываются из буфера логов на
    каждый тик (после recreate сид/live приносит новый load_completed —
    обновляется само)."""

    def __init__(self):
        self.port = int(env_float('GFCTL_WATCH_PORT', 8080))
        self.interval = env_float('GFCTL_WATCH_INTERVAL', 2.0)
        self.container = os.environ.get('GFCTL_WATCH_CONTAINER') or 'gufo'
        self.max_ticks = int(env_float('GFCTL_WATCH_TICKS', 0))  # батарейный шов
        self.ticks = 0
        self.utf8 = choose_utf8()
        self.glyphs = Glyphs(self.utf8)
        self.colors = False
        self.streamer = LogStreamer(self.container)
        self.deltas = watch_engine.Deltas()
        self.hist = {'decode': deque(maxlen=120), 'prefill': deque(maxlen=120),
                     'drafts': deque(maxlen=120)}
        self.last_deltas = {'decode': None, 'prefill': None, 'drafts': None}
        self.log_view = []
        self.paused = False
        self.stop = False
        self.signum = None

    def collect(self):
        # @returns dict  # снапшот тика: engine_ok — по /metrics; stats —
        #   engine_stats (None при сбое); ready — GET /ready (режим «готов»);
        #   gpu/cpu_t/mem — хост, читаются каждый тик независимо от сервера
        snap = {'engine_ok': False, 'metrics': None, 'stats': None,
                'ready': False, 'gpu': watch_sysfs.read_gpu(),
                'cpu_t': watch_sysfs.read_cpu_temp(),
                'mem': watch_sysfs.read_mem()}
        try:
            snap['metrics'] = watch_engine.parse_metrics(
                http_get('http://127.0.0.1:%d/metrics' % self.port))
            snap['stats'] = watch_engine.engine_stats(snap['metrics'])
            snap['engine_ok'] = True
        except Exception:
            pass  # мёртвый сервер — None, не краш (v1)
        try:
            http_get('http://127.0.0.1:%d/ready' % self.port)
            snap['ready'] = True
        except Exception:
            pass
        return snap

    def apply_tick(self, snap):
        # Дельты + история пульса: успешный тик — update по /metrics,
        # сбой — reset (без ложных дельт после recreate); None-дельта в
        # истории → 0 (плоская линия sparkline)
        if snap['engine_ok']:
            d = self.deltas.update(snap['metrics'])
        else:
            d = self.deltas.update(None)
        self.last_deltas = d
        for key in ('decode', 'prefill', 'drafts'):
            self.hist[key].append(d[key] or 0)

    def route_conf(self):
        # @returns (dict, dict)  # роут (load_completed) + cache-configured
        #   из буфера логов (последняя строка побеждает)
        buf = list(self.streamer.buf)
        return (watch_engine.parse_route_lines(buf),
                watch_engine.parse_configured_lines(buf))

    def refresh_log_view(self):
        # TZ-конверсия НА РЕНДЕРЕ: буфер хранит сырые строки (детерминизм
        # паузы/перерисовки; task.md Round 1 «Логи»)
        self.log_view = [watch_engine.log_line_local(l)
                         for l in self.streamer.buf]

    def tick_done(self):
        self.ticks += 1
        if self.max_ticks and self.ticks >= self.max_ticks:
            self.stop = True

    def sleep_quanta(self, secs, checker=None):
        # Сон квантами 0.1 с с проверкой stop/клавиш; интервал <0.05
        # (батарейный, только env напрямую) — сна нет
        if secs < 0.05:
            return
        end = time.monotonic() + secs
        while not self.stop and time.monotonic() < end:
            if checker is not None:
                checker()
                if self.stop:
                    return
            time.sleep(min(0.1, max(0.0, end - time.monotonic())))

    def set_interval(self, v):
        self.interval = max(1.0, float(v))  # клавишами min 1

    def run_plain(self):
        # v1 семантика: строки БЕЗУСЛОВНО раз в interval (первая сразу).
        # Мёртвый сервер: РОВНО одна строка «недоступен» на тик, без спама;
        # полный срез при недоступности не печатается. «Логи» — хвост (1
        # строка, TZ-конвертированная) тем же блоком.
        self.streamer.seed()
        while not self.stop:
            snap = self.collect()
            self.apply_tick(snap)
            self.refresh_log_view()
            ts = time.strftime('%H:%M:%S')
            if snap['engine_ok']:
                route, conf = self.route_conf()
                for line in fmt_plain(snap, route, conf, self.last_deltas,
                                      ts, self.glyphs):
                    print(line, flush=True)
                if self.log_view:
                    print('%s [логи] %s' % (ts, self.log_view[-1]), flush=True)
            else:
                print(dead_line(ts, self.port), flush=True)
            self.tick_done()
            self.sleep_quanta(self.interval)

    # ── TUI ─────────────────────────────────────────────────────────────────
    def run_tui(self, win):
        win.nodelay(True)
        win.keypad(True)
        try:
            curses.noecho()
            curses.cbreak()
            win.clear()
            curses.curs_set(0)
        except curses.error:
            pass
        if curses.has_colors():
            try:
                curses.start_color()
                curses.use_default_colors()
                curses.init_pair(C_RED, curses.COLOR_RED, -1)
                curses.init_pair(C_GREEN, curses.COLOR_GREEN, -1)
                curses.init_pair(C_YELLOW, curses.COLOR_YELLOW, -1)
                self.colors = True
            except curses.error:
                pass
        self.streamer.seed()  # до первой рамки — стартовые строки видны сразу
        self.streamer.start()
        try:
            while not self.stop:
                cur = self.interval
                self.drain_keys(win)
                if self.stop:
                    break
                snap = self.collect()
                self.apply_tick(snap)
                if not self.paused:
                    self.refresh_log_view()
                H, W = win.getmaxyx()
                self.draw(win, W, H, snap)
                win.refresh()
                self.sleep_quanta(cur, checker=lambda: self.drain_keys(win))
        finally:
            self.streamer.stop()
            curses.endwin()

    def handle_key(self, ch):
        if ch in (ord('q'), ord('Q')):
            self.stop = True
        elif ch in (ord('+'), ord('=')):
            self.set_interval(self.interval + 1)
        elif ch in (ord('-'), ord('_')):
            self.set_interval(self.interval - 1)
        elif ch == ord('p'):
            self.paused = not self.paused

    def drain_keys(self, win):
        while True:
            ch = win.getch()
            if ch == -1:
                return
            self.handle_key(ch)
            if self.stop:
                return

    def attr(self, style):
        # @returns integer  # код цвета (C_RED/C_GREEN/C_YELLOW — инт 1..3)
        #   → curses.color_pair (при self.colors); флаги curses (A_BOLD ≥
        #   2**16, с кодами цветов не коллидировали) → как есть; 0 → 0
        if style in (C_RED, C_GREEN, C_YELLOW):
            return curses.color_pair(style) if self.colors else 0
        return style

    def box(self, win, x, y, w, h):
        g = self.glyphs
        if w < 3 or h < 2:
            return
        put(win, y, x, g.tl + g.h * (w - 2) + g.tr)
        put(win, y + h - 1, x, g.bl + g.h * (w - 2) + g.br)
        for i in range(1, h - 1):
            put(win, y + i, x, g.v)
            put(win, y + i, x + w - 1, g.v)

    def block(self, win, x, y, w, h, title, rows):
        # Рамка с заголовком В верхней границе (экономия вертикали против
        # v1 — строки с y+1); строки (label, value[, style]) — не
        # поместившиеся отбрасываются ХВОСТОМ (деградация узкого экрана)
        self.box(win, x, y, w, h)
        if w >= len(title) + 6:
            put(win, y, x + 2, self.glyphs.h + ' %s ' % title, curses.A_BOLD)
        lw = max((len(label) + 1 for label, *_ in rows), default=0)
        for i, row in enumerate(rows):
            yy = y + 1 + i
            if yy >= y + h - 1:
                break
            label, value = row[0], row[1]
            style = row[2] if len(row) > 2 else 0
            put(win, yy, x + 2,
                (label + ':').ljust(lw) + ' ' + value[:max(0, w - lw - 4)],
                self.attr(style))

    def rows_hardware(self, snap):
        # Блок «Железо» (task.md Round 2): GPU sysfs (перенос hfctl 1:1),
        # CPU Tctl, Device lost из /metrics (красный при >0 — потери
        # GPU-контекста; '?' при отсутствии ключа — старый образ)
        g = self.glyphs
        gpu = snap['gpu']
        if gpu is None:
            rows = [('GPU', 'карта AMD (0x1002) не найдена')]
        else:
            rows = [('GPU temp', fmt_c(gpu['temp_c']) + g.deg,
                     temp_color(gpu['temp_c'], fmt_c)),
                    ('GPU freq', fmti(gpu['sclk_mhz']) + ' MHz'),
                    ('GPU load', fmti(gpu['busy_pct']) + '%'),
                    ('GPU power', fmti(gpu['power_w']) + ' W'),
                    ('VRAM', fmt_gib(gpu['vram_used']) + ' GiB'),
                    ('GTT', fmt_gib(gpu['gtt_used']) + ' GiB')]
        cpu = snap['cpu_t']
        rows.append(('CPU temp',
                     (fmt_c(cpu) + g.deg) if cpu is not None else '?',
                     temp_color(cpu, fmt_c)))
        lost = (snap['stats'] or {}).get('device_lost')
        rows.append(('Device lost', fmti(lost), C_RED if (lost or 0) > 0 else 0))
        return rows

    def rows_memory(self, snap):
        # Блок «Память» (SPEC §3): RAM avail/total + bar (hfctl 1:1, ширина
        # 10), цвет по заполнению (≤0.1 красный, ≤0.2 жёлтый); VRAM/GTT used
        g = self.glyphs
        mem = snap['mem']
        gpu = snap['gpu'] or {}
        avail, total = mem.get('available_gib'), mem.get('total_gib')
        width = 10
        if avail is None or total is None:
            val = '?'
            mem_attr = 0
        else:
            n = max(0, min(width, int(round(avail / total * width))))
            val = ('%s%s %s/%s GiB' % (g.bar_full * n, g.bar_empty * (width - n),
                                       fmt1(avail), fmt1(total)))
            mem_attr = mem_fill_color(avail, total)
        return [('RAM', val, mem_attr),
                ('VRAM', fmt_gib(gpu.get('vram_used')) + ' GiB'),
                ('GTT', fmt_gib(gpu.get('gtt_used')) + ' GiB')]

    def rows_engine(self, snap, route, conf):
        # Блок «Движок» (task.md Round 2, формулы v2): мёртвый сервер —
        # ровно строка «недоступен» (v1); спекуляция — выделенная строка
        # (A_BOLD); prompt-lookup — только при ненулевых суммарных
        if not snap['engine_ok']:
            return [('недоступен', '')]
        st = snap['stats'] or {}
        d = self.last_deltas or {}
        rows = [('Роут', '%s · s%s · ctx %s' % (route['spec'] or '?',
                                                route['sessions'] or '?',
                                                route['ctx'] or '?'))]
        if any(conf.values()):
            disk = conf.get('disk')
            disk_s = (fmt1(float(disk) / (1024.0 ** 3)) + ' GiB') if disk else '?'
            conf_part = 'ram %s · disk %s' % (conf.get('ram_cache') or '?', disk_s)
        else:
            conf_part = 'нет данных'
        rows.append(('Режим', ('готов' if snap['ready'] else 'нет')
                     + ' | cache: ' + conf_part))
        rows.append(('Генерация', '%s (средн) · %s (посл) tok/s'
                     % (fmt1(st.get('gen_avg')), fmt1(st.get('gen_last')))))
        rows.append(('Prefill', '%s (средн) · %s (посл) tok/s'
                     % (fmt1(st.get('prefill_avg')), fmt1(st.get('prefill_last')))))
        rows.append(('Кэш-эффект', fmt_pct(st.get('cache_pct'))))
        rows.append(('Спекуляция принято', fmt_pct(st.get('spec_pct')),
                     curses.A_BOLD))
        rows.append(('Draft-пульс', '+%s ток/тик' % (d.get('drafts') or 0)))
        rows.append(('KV', '%s · пик %s' % (fmt_pct(st.get('kv_pct')),
                                            fmt_tok(st.get('kv_peak')))))
        rows.append(('Очередь', '%s/%s' % (fmti(st.get('q_proc')),
                                           fmti(st.get('q_def')))))
        rows.append(('Префил', '%s обработано · %s из кэша'
                     % (fmt_tok(st.get('tok_prompt')),
                        fmt_tok(st.get('tok_cached')))))
        rows.append(('Сгенерировано', fmt_tok(st.get('tok_pred'))))
        lt = st.get('lookup_tok') or 0
        la = st.get('lookup_acc') or 0
        if lt > 0 or la > 0:
            rows.append(('Prompt-lookup', '%s/%s (%s)' % (fmt_tok(la), fmt_tok(lt),
                                                          fmt_pct(st.get('lookup_pct')))))
        return rows

    def rows_speed(self, W):
        # Блок «Скорость» (task.md Round 2): sparkline пульса — decode/
        # prefill LIVE (token-счётчики движутся по чанкам), drafts — пульс
        # завершений (Δdraft_tokens); дельта — НЕ скорость (ток/тик)
        width = max(4, W // 2 - 18)
        return [('decode', watch_engine.sparkline(self.hist['decode'], width,
                                                  self.glyphs.spark)),
                ('prefill', watch_engine.sparkline(self.hist['prefill'], width,
                                                   self.glyphs.spark)),
                ('drafts', watch_engine.sparkline(self.hist['drafts'], width,
                                                  self.glyphs.spark))]

    def draw(self, win, W, H, snap):
        win.erase()
        g = self.glyphs
        route, conf = self.route_conf()
        put(win, 0, 0, g.dot, self.attr(C_GREEN if snap['engine_ok'] else C_RED))
        left, mid, right, mid_x, right_x, draw_mid, draw_right = \
            status_bar_layout(W, self.interval, route['model'] or '-', self.paused)
        put(win, 0, 2, left)
        if draw_mid:
            put(win, 0, mid_x, mid)
        if draw_right:
            put(win, 0, right_x, right)
        if H < 4 or W < 8:
            return
        rows_hw = self.rows_hardware(snap)
        rows_mem = self.rows_memory(snap)
        rows_e = self.rows_engine(snap, route, conf)
        rows_s = self.rows_speed(W)
        col_w = max(10, W // 2)
        x2 = W - col_w
        h1 = max(len(rows_hw), len(rows_mem)) + 2
        h_e = len(rows_e) + 2
        h_s = len(rows_s) + 2
        LOG_MIN = 3
        budget = H - 1
        rem = budget - h1 - h_e - h_s
        if rem < LOG_MIN:  # режем «Движок» (самый длинный), логи держим
            h_e = max(3, budget - h1 - h_s - LOG_MIN)
            rem = budget - h1 - h_e - h_s
        if rem < LOG_MIN:
            h_s = max(3, budget - h1 - h_e - LOG_MIN)
            rem = budget - h1 - h_e - h_s
        if rem < LOG_MIN:
            h1 = max(3, budget - h_e - h_s - LOG_MIN)
            rem = budget - h1 - h_e - h_s
        self.block(win, 0, 1, col_w, h1, 'Железо', rows_hw)
        if W >= 2 * col_w:
            self.block(win, x2, 1, col_w, h1, 'Память', rows_mem)
        self.block(win, 0, 1 + h1, W, h_e, 'Движок', rows_e)
        self.block(win, 0, 1 + h1 + h_e, W, h_s,
                   'Скорость · пульс завершений', rows_s)
        log_top = 1 + h1 + h_e + h_s
        self.box(win, 0, log_top, W, rem)
        put(win, log_top + 1, 2, 'Логи', curses.A_BOLD)
        if self.log_view and rem >= 4:
            for i, ln in enumerate(self.log_view[-(rem - 2):]):
                put(win, log_top + 2 + i, 2, ln)
        elif rem >= 4:
            put(win, log_top + 2, 2, '(ждём логи…)')


def main(argv):
    if os.environ.get('GFCTL_WATCH_SELFCHECK') == '1':
        return selfcheck()
    w = Watch()

    def on_signal(signum, frame):
        w.stop = True
        w.signum = signum

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)
    term = os.environ.get('TERM', '')
    if sys.stdout.isatty() and term:
        try:
            win = curses.initscr()
        except (curses.error, OSError):
            win = None  # TERM неизвестен/кривой → фолбэк в plain, не краш
        if win is not None:
            w.run_tui(win)
            return 0
    w.run_plain()
    if w.signum is not None:
        print('Выход Ctrl-C', flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
