#!/usr/bin/env python3
# Назначение: `gfctl watch` — живой дашборд gufo-сервера (SPEC §3/§8):
#   ОДИН коллектор данных и два рендерера: TUI (curses, TTY) и plain-стрим
#   строк (не-TTY: пайп/файл). Режим выбирается sys.stdout.isatty().
#   РАЗНИЦА движков против hfctl-каркаса (тот же рендер/клавиши/поток
#   логов, слой данных перестроен): gufo НЕ имеет /stats — /metrics
#   ЕДИНСТВЕННЫЙ движковый источник; печатаются СЫРЫЕ ключи `llamacpp:*`
#   (факт-база подтверждает только llamacpp:prompt_tokens_cached_total —
#   имена НЕ выдумываются, полный список снимает EXP-007); model/uptime —
#   из сида логов (model= последней load_completed — подстрока до
#   «sessions=», как parse_route; uptime — от первого timestamp лога);
#   «Память» — MemTotal/MemAvailable /proc/meminfo + первая temp*_input
#   /sys/class/hwmon. Блоки (SPEC §3): «Движок», «Скорость», «Память»,
#   «Логи» (podman logs -f, deque 500, stderr→stdout — podman печатает
#   логи в stderr). Мёртвый сервер: plain — РОВНО одна строка
#   «недоступен» на тик; TUI — блок «Движок» = «недоступен»; urllib/curl
#   -ошибка → значение None, без traceback-спама.
#
# Входы — ТОЛЬКО env (bash передаёт без argv, паттерн hfctl):
#   GFCTL_WATCH_PORT (def 8080), GFCTL_WATCH_INTERVAL (def 2; float;
#   <0.05 — батарейный режим без сна), GFCTL_WATCH_CONTAINER (def gufo);
#   батарейный шов GFCTL_WATCH_TICKS (0/нет = бесконечно; N>0 — N тиков
#   и выход); GFCTL_WATCH_SELFCHECK=1 — assert-самопроверка без сервера
#   и TTY (exit 0/1). Клавиши TUI: q/Q — выход rc 0; +/- (=/_) — интервал
#   ±1 с (min 1); p — пауза live-лога.
#
# Побочные эффекты: каждый тик — GET /metrics (curl из PATH, таймаут 5 с);
#   чтение /proc, /sys — каждый тик независимо от сервера; TUI — сид
#   `podman logs -t --tail 50` (до первой рамки) + daemon-поток
#   `podman logs -t --tail 1 -f`; TUI рисует в alt-экране, выход снимает
#   экран (endwin). Файлов и стека не меняет.
#
# Ограничения/допущения: stdlib only, синтаксис 3.8+; HTTP — только в
#   главном потоке; глифы Unicode при UTF-8-окружении, ASCII-фолбэк;
#   initscr-краш (TERM неизвестен) → фолбэк в plain, не краш; uptime по
#   сиду --tail 50 — best-effort (у долгоживущего лога начала может не
#   быть → «?»).
#
# @returns integer  # 0 — обычный выход (q / Ctrl-C / SIGTERM / тики); 1 — selfcheck упал
import curses
import glob
import json
import locale
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from collections import deque

C_RED, C_GREEN = 1, 2

CONFIRMED_CACHED = 'llamacpp:prompt_tokens_cached_total'  # единственный подтверждённый ключ (FX-W5)
TS_RE = re.compile(r'^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})')

METRICS_FIXTURE = (
    '# HELP llamacpp:prompt_tokens_cached_total Total prompt tokens reused from cache\n'
    'llamacpp:prompt_tokens_cached_total 539\n'
    'llamacpp:foo_bucket{le="10"} 3\n'
    'llamacpp:bar{machine="x"} 7\n'
)


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


def _read(path):
    # @returns string|None  # содержимое (strip); нет файла → None
    try:
        with open(path, 'r') as f:
            return f.read().strip()
    except OSError:
        return None


def _num(s):
    # @returns float|None
    if s is None:
        return None
    try:
        return float(s)
    except ValueError:
        return None


def http_get(url, timeout=5.0):
    # @returns string   # тело ответа; сбой — исключение (зовущий ловит).
    #   curl из PATH (не urllib): faux-bin-шов батареи — счётчик /metrics-
    #   вызовов виден в FAUXLOG/счётчике (§D теста watch)
    p = subprocess.run(['curl', '-fsS', '-m', '%.0f' % max(1, timeout), url],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if p.returncode != 0:
        raise OSError('curl rc=%d' % p.returncode)
    return p.stdout.decode('utf-8', 'replace')


def parse_metrics(text):
    # @returns dict     # name → float; '# …' и *_bucket{…} отброшены,
    #   labels {…} сняты с имени (ключи gufo с ':' идут как есть)
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


def parse_seed(lines):
    # @param 1: iterable  # строки лога (сид deque стримера)
    # @returns (string|None, float|None)  # (model, uptime_s): model — из
    #   ПОСЛЕДНЕЙ load_completed, подстрока между «model=» и « sessions=»
    #   (имена с пробелами — то же правило, что parse_route); uptime —
    #   now − первый timestamp «YYYY-MM-DD HH:MM:SS» лога; нет данных → None
    model = None
    first_ts = None
    for line in lines:
        m = TS_RE.match(line)
        if m and first_ts is None:
            try:
                first_ts = time.mktime(time.strptime(
                    m.group(1) + ' ' + m.group(2), '%Y-%m-%d %H:%M:%S'))
            except ValueError:
                pass
        if 'load_completed' in line and 'model=' in line:
            name = line.split('model=', 1)[1].split('sessions=', 1)[0].strip()
            if name:
                model = name
    return model, ((time.time() - first_ts) if first_ts else None)


def read_first_temp(base='/sys/class/hwmon'):
    # @returns float|None  # первая temp*_input /1000 (°C, 1 знак); нет → None
    for hw in sorted(glob.glob(base + '/hwmon*')):
        for tf in sorted(glob.glob(hw + '/temp*_input')):
            v = _num(_read(tf))
            if v is not None:
                return round(v / 1000.0, 1)
    return None


def read_mem():
    # @returns dict     # /proc/meminfo в GiB (1 знак): available_gib, total_gib
    kib = {}
    try:
        with open('/proc/meminfo', 'r') as f:
            for line in f:
                key, _, rest = line.partition(':')
                parts = rest.split()
                if parts:
                    try:
                        kib[key.strip()] = int(parts[0])
                    except ValueError:
                        pass
    except OSError:
        pass
    gib = 1048576.0

    def g(key):
        v = kib.get(key)
        return None if v is None else round(v / gib, 1)

    return {'available_gib': g('MemAvailable'), 'total_gib': g('MemTotal')}


class LogStreamer(threading.Thread):
    """Логи движка: сид `podman logs -t --tail 50` (seed(), синхронно в
    главном потоке ДО первой рамки — стартовые строки видны сразу), далее
    live `podman logs -t --tail 1 -f` (дедуп первой live-строки против
    хвоста сида). stdout построчно → deque(500). podman logs печатает логи
    в STDERR (проверено вживую, hfctl-каркас) — ОБА вызова объединяют
    stderr в stdout-PIPE. Поток НЕ дёргает curses и HTTP. podman/контейнер
    нет → сид и стрим молча падают (буфер пуст), повторные попытки раз в
    ~1 с. stop() завершает подпроцесс."""

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
                ['podman', 'logs', '-t', '--tail', '50', self.container],
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
                ['podman', 'logs', '-t', '--tail', '1', '-f', self.container],
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


def fmt1(x):
    # @returns string  # 1 знак; None → '-'
    return '-' if x is None else '%.1f' % x


def fmti(x, q='?'):
    # @returns string  # целое; None → q (нет ключа/датчика)
    return q if x is None else str(int(x))


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


def fmt_uptime(s):
    # @returns string  # d/h/m; None → '?'
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


def fmt_plain(snap, model, uptime, ts):
    # @returns list  # срез блоков для plain-стрима (3 строки, порядок
    #   фиксирован: движок/скорость/память); скорость — СЫРЫЕ числовые
    #   llamacpp:* (sorted — детерминизм), чего нет — '?'
    m = snap['metrics'] or {}
    mem = snap['mem']
    raw = sorted(k for k, v in m.items() if isinstance(v, float))
    speed = ' '.join('%s=%s' % (k, fmti(m[k])) for k in raw) if raw else '?'
    temp = fmt_c(snap['temp_c']) + Glyphs(choose_utf8()).deg if snap['temp_c'] is not None else '?'
    return ['%s [движок] model: %s | uptime: %s | cached_total: %s'
            % (ts, model or '?', fmt_uptime(uptime), fmt_tok(m.get(CONFIRMED_CACHED))),
            '%s [скорость] %s' % (ts, speed),
            '%s [память] RAM: %s/%s GiB | temp: %s'
            % (ts, fmt1(mem.get('available_gib')), fmt1(mem.get('total_gib')), temp)]


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


PLAIN_SNAP = {
    'engine_ok': True,
    'metrics': {CONFIRMED_CACHED: 539.0, 'llamacpp:zz_other': 12.0},
    'mem': {'available_gib': 45.2, 'total_gib': 60.4},
    'temp_c': 54.0,
}
PLAIN_MODEL = 'qwen3.8-27b-IQ4_XS-pure'
PLAIN_UP = 312.0
PLAIN_FULL = [
    '12:00:00 [движок] model: qwen3.8-27b-IQ4_XS-pure | uptime: 5m 12s | cached_total: 539',
    '12:00:00 [скорость] llamacpp:prompt_tokens_cached_total=539 llamacpp:zz_other=12',
    '12:00:00 [память] RAM: 45.2/60.4 GiB | temp: 54.0°C',
]


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


def selfcheck():
    # @returns integer  # 0 — всё прошло; 1 — есть провалы (имена в stderr)
    fails = []
    total = 0

    def ck(name, cond):
        nonlocal total
        total += 1
        if not cond:
            fails.append(name)

    m = parse_metrics(METRICS_FIXTURE)
    ck('metrics cached_total', m.get(CONFIRMED_CACHED) == 539.0)
    ck('metrics labels stripped', m.get('llamacpp:bar') == 7.0)
    ck('metrics _bucket excluded', 'llamacpp:foo_bucket' not in m)
    ck('metrics # lines excluded', len(m) == 2)

    ck('plain full slice', fmt_plain(PLAIN_SNAP, PLAIN_MODEL, PLAIN_UP, '12:00:00') == PLAIN_FULL)
    ck('plain dead line', 'недоступен' in dead_line('12:00:00', 8080)
       and dead_line('x', 1).count('недоступен') == 1)
    ck('fmt_tok границы', fmt_tok(999) == '999' and fmt_tok(1000) == '1.0k'
       and fmt_tok(1234567) == '1.2M' and fmt_tok(None) == '?')
    ck('fmt_uptime', fmt_uptime(312) == '5m 12s' and fmt_uptime(None) == '?')

    seed = ['2026-11-17 08:47:19 [INFO] boot',
            'event=load_completed speculative=mtp elapsed_ms=1 '
            'model=Qwen3.8 Flash Next sessions=2 context_tokens=262144 draft_limit=7']
    model, up = parse_seed(seed)
    ck('seed model с пробелами целиком', model == 'Qwen3.8 Flash Next')
    ck('seed uptime > 0', up is not None and up > 0)
    ck('seed без timestamp → uptime None', parse_seed(['no ts here'])[1] is None)
    ck('seed последняя load_completed побеждает',
       parse_seed(['model=A sessions=1 load_completed', 'model=B sessions=1 load_completed'])[0] == 'B')

    fake_hw = tempfile.mkdtemp(prefix='watch_tui_hw_')
    try:
        os.makedirs(fake_hw + '/hwmon3')
        with open(fake_hw + '/hwmon3/temp1_input', 'w') as f:
            f.write('35875\n')  # миллиградусы → 35.9 °C
        ck('hwmon первая temp*_input', read_first_temp(fake_hw) == 35.9)
        ck('temp fmt', fmt_c(35.9) == '35.9' and fmt_c(None) == '?')
    finally:
        shutil.rmtree(fake_hw)

    w = Watch()
    fix = dict(PLAIN_SNAP)
    ck('rows engine labels',
       [r[0] for r in w.rows_engine(fix, PLAIN_MODEL, 1.0)] == ['Модель', 'Uptime', 'Cached tok'])
    ck('rows engine dead',
       w.rows_engine(dict(fix, engine_ok=False), None, None) == [('недоступен', '')])
    ck('rows memory labels',
       [r[0] for r in w.rows_memory(fix)] == ['RAM', 'Temp'])
    ck('rows speed raw keys',
       w.rows_speed(fix)[0][0] == CONFIRMED_CACHED)

    # Сид логов: без podman не падает, buf пуст (pty-окружение контейнера)
    ls = LogStreamer('no-such-container')
    try:
        ls.seed()
        seeded_ok = True
    except Exception:
        seeded_ok = False
    ck('seed without podman no crash', seeded_ok)

    # podman logs печатает в STDERR — вызовы обязаны объединять stderr в stdout
    fake_bin = tempfile.mkdtemp(prefix='watch_tui_podman_')
    try:
        shim = fake_bin + '/podman'
        with open(shim, 'w') as f:
            f.write('#!/bin/sh\necho fake-log-line >&2\n')
        os.chmod(shim, 0o755)
        old_path = os.environ['PATH']
        os.environ['PATH'] = fake_bin + os.pathsep + old_path
        try:
            ls_s = LogStreamer('no-such-container')
            ls_s.seed()
            ck('seed: stderr→stdout (podman logs → stderr)',
               list(ls_s.buf) == ['fake-log-line'])
        finally:
            os.environ['PATH'] = old_path
    finally:
        shutil.rmtree(fake_bin)

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
    """Состояние + цикл. TUI и plain используют один коллектор (collect);
    различаются рендер и период печати. model/uptime пересчитываются из
    буфера логов на каждый тик (после recreate сид/live приносит новый
    load_completed — модель обновляется сама)."""

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
        self.log_view = []
        self.paused = False
        self.stop = False
        self.signum = None

    def collect(self):
        # @returns dict  # engine_ok — только по /metrics (единственный
        #   движковый источник gufo); mem/temp — каждый тик независимо
        snap = {'engine_ok': False, 'metrics': None,
                'mem': read_mem(), 'temp_c': read_first_temp()}
        try:
            snap['metrics'] = parse_metrics(
                http_get('http://127.0.0.1:%d/metrics' % self.port))
            snap['engine_ok'] = True
        except Exception:
            pass  # мёртвый сервер — значение None, не краш
        return snap

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

    def engine_state(self):
        # @returns (model, uptime_s)  # из буфера логов; пусто → (None, None)
        return parse_seed(list(self.streamer.buf))

    def run_plain(self):
        # Строки БЕСУСЛОВНО раз в interval (первая сразу). Мёртвый сервер:
        # РОВНО одна строка «недоступен» на тик, без спама; полный срез
        # при недоступности не печатается.
        self.streamer.seed()
        while not self.stop:
            snap = self.collect()
            ts = time.strftime('%H:%M:%S')
            if snap['engine_ok']:
                model, up = self.engine_state()
                for line in fmt_plain(snap, model, up, ts):
                    print(line, flush=True)
                if self.streamer.buf:  # «Логи» — тем же блоком (хвост, 1 строка)
                    print('%s [логи] %s' % (ts, self.streamer.buf[-1]), flush=True)
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
                if not self.paused:
                    self.log_view = list(self.streamer.buf)
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

    def attr(self, c):
        if c and self.colors:
            return curses.color_pair(c)
        return 0

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
        # Заголовок внутри вверху; строки (label, value[, attr]) — не
        # поместившиеся отбрасываются ХВОСТОМ (деградация узкого экрана)
        self.box(win, x, y, w, h)
        put(win, y + 1, x + 2, title, curses.A_BOLD)
        lw = max((len(label) + 1 for label, *_ in rows), default=0)
        for i, row in enumerate(rows):
            yy = y + 2 + i
            if yy >= y + h - 1:
                break
            label, value = row[0], row[1]
            attr = row[2] if len(row) > 2 else 0
            put(win, yy, x + 2,
                (label + ':').ljust(lw) + ' ' + value[:max(0, w - lw - 4)], attr)

    def rows_engine(self, snap, model, uptime):
        # Мёртвый сервер — ровно строка «недоступен» (плоский ряд)
        if not snap['engine_ok']:
            return [('недоступен', '')]
        return [('Модель', model or '?'),
                ('Uptime', fmt_uptime(uptime)),
                ('Cached tok', fmt_tok((snap['metrics'] or {}).get(CONFIRMED_CACHED)))]

    def rows_speed(self, snap):
        # Сырые числовые llamacpp:* (факт-база тонкая — печатаем как есть,
        # имена НЕ выдумываем; EXP-007 снимет полный список → тогда подписи)
        m = snap['metrics'] or {}
        raw = sorted(k for k, v in m.items() if isinstance(v, float))
        return [(k, fmti(m[k])) for k in raw] or [('ключи', '?')]

    def rows_memory(self, snap):
        g = self.glyphs
        mem = snap['mem']
        temp = fmt_c(snap['temp_c']) + g.deg if snap['temp_c'] is not None else '?'
        return [('RAM', '%s/%s GiB' % (fmt1(mem.get('available_gib')),
                                       fmt1(mem.get('total_gib')))),
                ('Temp', temp)]

    def draw(self, win, W, H, snap):
        win.erase()
        g = self.glyphs
        put(win, 0, 0, g.dot, self.attr(C_GREEN if snap['engine_ok'] else C_RED))
        model, up = self.engine_state()
        left, mid, right, mid_x, right_x, draw_mid, draw_right = \
            status_bar_layout(W, self.interval, model or '-', self.paused)
        put(win, 0, 2, left)
        if draw_mid:
            put(win, 0, mid_x, mid)
        if draw_right:
            put(win, 0, right_x, right)
        if H < 4 or W < 8:
            return
        rows_e = self.rows_engine(snap, model, up)
        rows_m = self.rows_memory(snap)
        rows_s = self.rows_speed(snap)
        col_w = max(10, W // 2)
        x2 = W - col_w
        h1 = max(len(rows_e), len(rows_m)) + 3
        LOG_MIN = 3
        h2 = len(rows_s) + 3
        rem = H - 1 - h1 - h2
        if rem < LOG_MIN:
            # не хватает вертикали: режем «Скорость» (сырые ключи — самый
            # длинный список), логи держим в LOG_MIN
            h2 = max(3, H - 1 - h1 - LOG_MIN)
            rem = H - 1 - h1 - h2
        log_top = 1 + h1 + h2
        self.block(win, 0, 1, col_w, h1, 'Движок', rows_e)
        if W >= 2 * col_w:
            self.block(win, x2, 1, col_w, h1, 'Память', rows_m)
        self.block(win, 0, 1 + h1, W, h2, 'Скорость', rows_s)
        self.box(win, 0, log_top, W, rem)
        put(win, log_top + 1, 2, 'Логи')
        # Контент — только при rem ≥ 4 (при минимуме 3 зона = рамка +
        # «Логи» + рамка: каркас hfctl, иначе строка легла бы на нижнюю рамку)
        if self.log_view and rem >= 4:
            for i, ln in enumerate(self.log_view[-(rem - 3):]):
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
    sys.exit(main(sys.argv[1:]))
