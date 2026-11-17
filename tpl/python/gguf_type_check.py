#!/usr/bin/env python3
"""gguf_type_check.py FILE... — потоковый pre-check GGUF-типов тензоров.

Парсит ТОЛЬКО заголовок GGUF (данные весов не читаются — шарды 49 GB остаются
нетронутыми): magic GGUF → version u32 → n_tensors u64 → n_kv u64 → KV-пары
(строковые/скалярные/массив-1-уровень значения пропускаются; вложенный массив
или неизвестный тип значения = ошибка формата) → таблица тензоров (name,
nd u32, dims u64×nd, type u32, offset u64).

RED-контракт — ЧИСЛОВОЙ, validated F3 (unsloth UD-* не грузятся gufo):
    RED = {16, 17, 18, 19, 22, 25, 26} ∪ {t > 29}
Красный вердикт файла — если ЛЮБОЙ тензор с "ffn_" в имени имеет RED-тип.
Risky-типы вне ffn_* — информационная строка WARN, вердикт зелёный.
Имена типов — канонический ggml enum (только отображение; контракт — числа;
NAME-таблица прототипа llm-lab не канонична — не переносилась).

Санити: n_kv, n_tensors ≤ 1 000 000; суммарный объём метаданных > 64 MiB —
ошибка формата (чтение потоковое, бюджет байт).

Вывод: RED:/WARN:-строки деталей + строка вердикта на файл
("<file>: КРАСНЫЙ (v3, tensors=N, kv=M)" / "<file>: зелёный (...)"); не-GGUF,
обрезанные/битые метаданные — строка «ОШИБКА ФОРМАТА: <причина>».

Коды выхода: 0 — все файлы зелёные; 1 — есть красный; 2 — format/IO ошибка
(хотя бы одного файла; ошибка доминирует над красным: незапарсенный файл не
даёт считать вердикт достоверным). stdlib only (struct/sys).
"""

import struct
import sys

MAGIC = b"GGUF"
MAX_KV = 1_000_000
MAX_TENSORS = 1_000_000
MAX_META_BYTES = 64 * 1024 * 1024

# RED-набор низкобитных IQ + BF16/IQ1_M (номера — ggml_type enum; в FFN не выживают)
RED_TYPES = {16, 17, 18, 19, 22, 25, 26}

# Канонический ggml_type enum 0–29 (имена — только отображение)
TYPE_NAMES = {
    0: "F32", 1: "F16", 2: "Q4_0", 3: "Q4_1", 4: "Q4_2*", 5: "Q4_3*",
    6: "Q5_0", 7: "Q5_1", 8: "Q8_0", 9: "Q8_1",
    10: "Q2_K", 11: "Q3_K", 12: "Q4_K", 13: "Q5_K", 14: "Q6_K", 15: "Q8_K",
    16: "IQ2_XXS", 17: "IQ2_XS", 18: "IQ3_XXS", 19: "IQ1_S", 20: "IQ4_NL",
    21: "IQ3_S", 22: "IQ2_S", 23: "IQ4_XS", 24: "IQ3_XS", 25: "IQ1_M",
    26: "BF16", 27: "TQ1_0", 28: "TQ2_0", 29: "MXFP4",
}

# Размеры значений метаданных (enum gguf_metadata_value_type; 8 = string,
# 9 = array — обрабатываются отдельно)
VALUE_SIZES = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8}
VTYPE_STRING = 8
VTYPE_ARRAY = 9


class FormatError(Exception):
    """Битый/не поддерживаемый формат GGUF — rc 2."""


class Reader:
    """Потоковый ридер заголовка с бюджетом байт метаданных (лимит 64 MiB)."""

    __slots__ = ("f", "budget")

    def __init__(self, f):
        self.f = f
        self.budget = MAX_META_BYTES

    def read(self, n):
        if n > self.budget:
            raise FormatError(f"метаданные > {MAX_META_BYTES // (1024 * 1024)} MiB")
        self.budget -= n
        b = self.f.read(n)
        if len(b) != n:
            raise FormatError("обрезанные метаданные")
        return b

    def u32(self):
        return struct.unpack("<I", self.read(4))[0]

    def u64(self):
        return struct.unpack("<Q", self.read(8))[0]

    def string(self):
        n = self.u64()
        if n > self.budget:
            raise FormatError(f"метаданные > {MAX_META_BYTES // (1024 * 1024)} MiB")
        self.budget -= n
        return self.f.read(n).decode("utf-8", "replace")


def skip_value(r, vtype):
    """Пропустить значение KV по типу; вложенный массив/неизвестный тип — ошибка."""
    if vtype == VTYPE_STRING:
        r.string()
    elif vtype == VTYPE_ARRAY:
        etype = r.u32()
        count = r.u64()
        if etype == VTYPE_ARRAY:
            raise FormatError("вложенный массив в KV — не поддерживается")
        if etype == VTYPE_STRING:
            for _ in range(count):
                r.string()
        elif etype in VALUE_SIZES:
            r.read(VALUE_SIZES[etype] * count)
        else:
            raise FormatError(f"неизвестный тип элемента массива KV: {etype}")
    elif vtype in VALUE_SIZES:
        r.read(VALUE_SIZES[vtype])
    else:
        raise FormatError(f"неизвестный тип значения KV: {vtype}")


def check_file(path):
    """Вернуть (version, n_tensors, n_kv, reds, warns); FormatError — наружу."""
    reds, warns = [], []
    with open(path, "rb") as f:
        if f.read(4) != MAGIC:
            raise FormatError("не GGUF (магия)")
        r = Reader(f)
        version = r.u32()
        n_tensors = r.u64()
        n_kv = r.u64()
        if n_kv > MAX_KV:
            raise FormatError(f"n_kv={n_kv} > {MAX_KV} (санити)")
        if n_tensors > MAX_TENSORS:
            raise FormatError(f"n_tensors={n_tensors} > {MAX_TENSORS} (санити)")
        for _ in range(n_kv):
            r.string()
            skip_value(r, r.u32())
        for _ in range(n_tensors):
            name = r.string()
            nd = r.u32()
            if nd > 8:
                raise FormatError(f"nd={nd} > 8 у тензора {name!r}")
            r.read(8 * nd)  # dims
            ttype = r.u32()
            r.read(8)  # offset
            tname = TYPE_NAMES.get(ttype, f"unknown({ttype})")
            if ttype in RED_TYPES or ttype > 29:
                if "ffn_" in name:
                    reds.append((name, tname))
                else:
                    warns.append((name, tname))
    return version, n_tensors, n_kv, reds, warns


def main(argv):
    if len(argv) < 2:
        print("usage: gguf_type_check.py FILE...", file=sys.stderr)
        return 2
    had_red = False
    had_err = False
    for path in argv[1:]:
        try:
            version, n_tensors, n_kv, reds, warns = check_file(path)
        except FormatError as e:
            print(f"{path}: ОШИБКА ФОРМАТА: {e}")
            had_err = True
            continue
        except OSError as e:
            print(f"{path}: ОШИБКА ЧТЕНИЯ: {e}")
            had_err = True
            continue
        for name, tname in reds:
            print(f"RED: {path}: ffn {name} = {tname}")
        for name, tname in warns:
            print(f"WARN: {path}: {name} = {tname} (вне ffn_* — информационно)")
        verdict = "КРАСНЫЙ" if reds else "зелёный"
        print(f"{path}: {verdict} (v{version}, tensors={n_tensors}, kv={n_kv})")
        if reds:
            had_red = True
    if had_err:
        return 2
    if had_red:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
