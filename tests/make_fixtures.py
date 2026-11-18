#!/usr/bin/env python3
"""make_fixtures.py OUTDIR — синтетические мини-GGUF для check-types.

Генерирует фиксированный набор мини-заголовков GGUF (только header + KV +
tensor-infos, данных нет): детерминированные байты (struct.pack), без
случайности. Файлы — тестовые ассеты репо: tests/fixtures/ хранит эталонные
копии (run_checks.sh сверяет регенерацию с ними — байт-в-байт), чтобы
фикстуры оставались в дереве и не дрейфовали.

Случаи (имя → ожидание парсера):
  gguf_ffn_iq2_s.gguf      ffn-тензор type 22 (IQ2_S)      → RED, rc 1
  gguf_ffn_iq4_xs.gguf     ffn-тензор type 23 (IQ4_XS)     → зелёный, rc 0
  gguf_ffn_q4_k.gguf       ffn-тензор type 12 (Q4_K)       → зелёный, rc 0
  gguf_ffn_unknown31.gguf  ffn-тензор type 31 (unknown>29) → RED, rc 1
  gguf_attn_iq2_xs.gguf    risky type 17 (IQ2_XS) вне ffn  → зелёный + WARN, rc 0
  gguf_ffn_iq1_m.gguf      ffn-тензор type 29 (IQ1_M)      → RED, rc 1 (4.2:
                           прежний контракт {25,26} ловил I16/I32, а IQ1_M
                           пропускал — канон 29=IQ1_M, review 1.1 Q1)
  gguf_ffn_i16.gguf        ffn-тензор type 25 (I16)        → зелёный, rc 0
                           (I-типы — целые/служебные, не весовые форматы)
  gguf_indexer_bf16.gguf   type 30 (BF16) вне ffn (indexer — F20)
                                                          → зелёный + WARN, rc 0
  gguf_not_gguf.gguf       магия ≠ GGUF                    → rc 2
  gguf_truncated.gguf      n_kv=5, данные оборваны         → rc 2 (обрезанные)
  gguf_kv_nested.gguf      KV-массив массивов              → rc 2 (не поддерж.)
  gguf_meta_budget.gguf    массив 9e6×u64 (> 64 MiB)       → rc 2 (бюджет)
  gguf_meta_overflow.gguf  n_kv=2e6 (> 1e6 санити)         → rc 2 (санити)

stdlib only (struct/os/sys).
"""

import os
import struct
import sys

U32 = struct.Struct("<I")
U64 = struct.Struct("<Q")


def gstr(b):
    """GGUF string: u64 len + bytes."""
    return U64.pack(len(b)) + b


def kv_string(name, value):
    return gstr(name) + U32.pack(8) + gstr(value)


def kv_u32(name, value):
    return gstr(name) + U32.pack(4) + U32.pack(value)


def kv_nested_array(name):
    # vtype 9 (array) с etype 9 (array) — вложенный массив: парсер обязан отказать
    return gstr(name) + U32.pack(9) + U32.pack(9) + U64.pack(1)


def kv_big_scalar_array(name, etype, count):
    return gstr(name) + U32.pack(9) + U32.pack(etype) + U64.pack(count)


def tinfo(name, dims, ttype, offset):
    return (
        gstr(name)
        + U32.pack(len(dims))
        + b"".join(U64.pack(d) for d in dims)
        + U32.pack(ttype)
        + U64.pack(offset)
    )


def header(n_kv, n_tensors):
    return b"GGUF" + U32.pack(3) + U64.pack(n_tensors) + U64.pack(n_kv)


def gguf(kvs, tensors):
    return header(len(kvs), len(tensors)) + b"".join(kvs) + b"".join(tensors)


FIXTURES = {
    "gguf_ffn_iq2_s.gguf": gguf(
        [kv_string(b"general.architecture", b"qwen38")],
        [tinfo(b"blk.0.attn_q.weight", (2048, 2048), 0, 0),
         tinfo(b"blk.0.ffn_gate.weight", (2048, 8192), 22, 4096)],
    ),
    "gguf_ffn_iq4_xs.gguf": gguf(
        [kv_string(b"general.architecture", b"qwen38")],
        [tinfo(b"blk.0.attn_q.weight", (2048, 2048), 0, 0),
         tinfo(b"blk.0.ffn_down.weight", (8192, 2048), 23, 4096)],
    ),
    "gguf_ffn_q4_k.gguf": gguf(
        [],
        [tinfo(b"blk.1.ffn_up.weight", (8192, 8192), 12, 0)],
    ),
    "gguf_ffn_unknown31.gguf": gguf(
        [],
        [tinfo(b"blk.0.ffn_gate_exps.weight", (8192, 2048, 8), 31, 0)],
    ),
    "gguf_attn_iq2_xs.gguf": gguf(
        [kv_u32(b"qwen3.block_count", 28)],
        [tinfo(b"blk.0.attn_v.weight", (2048, 2048), 17, 0),
         tinfo(b"blk.0.attn_k.weight", (2048, 2048), 0, 4096)],
    ),
    "gguf_ffn_iq1_m.gguf": gguf(
        [],
        [tinfo(b"blk.0.ffn_up.weight", (8192, 8192), 29, 0)],
    ),
    "gguf_ffn_i16.gguf": gguf(
        [],
        [tinfo(b"blk.0.ffn_gate.weight", (2048, 8192), 25, 0)],
    ),
    "gguf_indexer_bf16.gguf": gguf(
        [],
        [tinfo(b"blk.0.indexer.weight", (2048, 64), 30, 0)],
    ),
    "gguf_not_gguf.gguf": b"RIFX" + b"\x00" * 64,
    "gguf_truncated.gguf": (header(5, 1) + gstr(b"general.architecture"))[:32],
    "gguf_kv_nested.gguf": header(1, 0) + kv_nested_array(b"test.nested"),
    "gguf_meta_budget.gguf": header(1, 0) + kv_big_scalar_array(b"test.big", 10, 9_000_000),
    "gguf_meta_overflow.gguf": header(2_000_000, 0),
}


def main(argv):
    if len(argv) != 2:
        print("usage: make_fixtures.py OUTDIR", file=sys.stderr)
        return 2
    outdir = argv[1]
    os.makedirs(outdir, exist_ok=True)
    for name, data in FIXTURES.items():
        with open(os.path.join(outdir, name), "wb") as f:
            f.write(data)
    for name in FIXTURES:
        print(os.path.join(outdir, name))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
