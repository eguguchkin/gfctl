#!/usr/bin/env python3
# Назначение: системные источники блока «Железо»/«Память» `gfctl watch` v2
#   (SPEC §3, task.md): GPU-карта AMD из /sys/class/drm (перенос hfctl 1:1,
#   масштабы: freq1_input = Гц, power1_input = мкВт, vram/gtt = байты),
#   CPU Tctl из k10temp, RAM из /proc/meminfo. Только чтение файлов —
#   никаких сети/подпроцессов; отсутствующий датчик → None в СВОЁМ поле
#   (рендер печатает '?', деградация без краша). Ловушка v1 устранена:
#   температура GPU — ТОЛЬКО из hwmon-каталогов ЭТОЙ карты (MAX
#   temp1_input), не первая попавшаяся temp*_input (на машинах-целях
#   evo/FAEX та была CPU k10temp).
#
# Побочные эффекты: нет (чистые чтения sysfs/proc).
#
# Ограничения/допущения: stdlib only; sysfs-лейаут amdgpu (gfx1151:
#   card*/device/hwmon/hwmon*/); первая карта с vendor 0x1002 — на
#   машинах-целях одна; значения, кроме оговорённых, НЕ округляются —
#   форматирование делает рендер.
import glob

_KIB_IN_GIB = 1048576.0  # /proc/meminfo в KiB


def _read(path):
    # @returns string|None  # содержимое (strip); нет файла/прав → None
    try:
        with open(path, 'r') as f:
            return f.read().strip()
    except OSError:
        return None


def _num(s):
    # @returns float|None  # число из строки; не-число → None
    if s is None:
        return None
    try:
        return float(s)
    except ValueError:
        return None


# (поле, файл в card*/device/hwmon/hwmon*/, делитель) — масштабы сверены
# вживую (hfctl, машина gfx1151 128 GiB). gpu_busy_percent НЕ в hwmon-
# каталоге — card*/device/, читается отдельно в read_gpu.
GPU_SPEC = (
    ('sclk_mhz', 'freq1_input', 1e6),
    ('power_w', 'power1_input', 1e6),
    ('vram_used', 'mem_info_vram_used', 1.0),
    ('gtt_used', 'mem_info_gtt_used', 1.0))


def read_gpu(base='/sys/class/drm'):
    # @param 1: string  # каталог с card* (дефолт /sys/class/drm; selfcheck
    #   подкладывает фейковое дерево)
    # @returns dict|None  # первая карта vendor 0x1002 (card[0-9]* sorted):
    #   temp_c — MAX temp1_input/1000 (миллиградусы) по ВСЕМ
    #   card*/device/hwmon/hwmon*/ ЭТОЙ карты; sclk_mhz — freq1_input/1e6
    #   (Гц→MHz); power_w — power1_input/1e6 (мкВт→W); busy_pct —
    #   card*/device/gpu_busy_percent; vram_used/gtt_used — БАЙТЫ (в GiB
    #   переводит рендер). Отсутствующее поле — None в своём ключе;
    #   AMD-карты нет → None (вся карта)
    for card in sorted(glob.glob(base + '/card[0-9]*')):
        if _read(card + '/device/vendor') != '0x1002':
            continue
        gpu = {'temp_c': None, 'sclk_mhz': None, 'power_w': None,
               'busy_pct': None, 'vram_used': None, 'gtt_used': None}
        busy = _num(_read(card + '/device/gpu_busy_percent'))
        if busy is not None:
            gpu['busy_pct'] = busy
        temps = []
        for hw in sorted(glob.glob(card + '/device/hwmon/hwmon*/')):
            t = _num(_read(hw + 'temp1_input'))
            if t is not None:
                temps.append(t)
            for key, fname, scale in GPU_SPEC:
                if gpu[key] is None:
                    v = _num(_read(hw + fname))
                    if v is not None:
                        gpu[key] = v / scale
        if temps:
            gpu['temp_c'] = max(temps) / 1000.0
        return gpu
    return None


def read_cpu_temp(base='/sys/class/hwmon'):
    # @param 1: string  # каталог с hwmon* (дефолт /sys/class/hwmon)
    # @returns float|None  # Tctl °C: первый hwmon с name=='k10temp',
    #   temp1_input/1000 (миллиградусы), 1 знак; нет датчика/чтения → None
    for hw in sorted(glob.glob(base + '/hwmon*')):
        if _read(hw + '/name') == 'k10temp':
            v = _num(_read(hw + '/temp1_input'))
            if v is not None:
                return round(v / 1000.0, 1)
    return None


def read_mem(path='/proc/meminfo'):
    # @param 1: string  # путь к meminfo (selfcheck может подложить файл)
    # @returns dict  # {'available_gib','total_gib'} — GiB (round 1, v1
    #   watch 1:1); поля нет/файл нечитаем → None в своём ключе
    kib = {}
    try:
        with open(path, 'r') as f:
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

    def g(key):
        v = kib.get(key)
        return None if v is None else round(v / _KIB_IN_GIB, 1)

    return {'available_gib': g('MemAvailable'), 'total_gib': g('MemTotal')}
