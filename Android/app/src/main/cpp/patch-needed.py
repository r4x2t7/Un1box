#!/usr/bin/env python3
"""Rewrite absolute-path DT_NEEDED entries to bare filenames, in place.

The prebuilt engine libraries (libfirmwarekit.so, libqemu-arm.so, ...) carry no
SONAME, so when CMake links them by their absolute path, lld records that path
as the DT_NEEDED string. The device's dynamic linker then dies with
"dlopen failed: library 'C:/...' not found". AGP's C++ model rejects
-Wl,-l:name flags, so we patch the linked binary instead: every DT_NEEDED whose
string resolves to an engine library is overwritten with its bare filename,
NUL-padded to the original length. No offsets move; everything else in .dynstr
stays exactly where it was.
"""
import os
import struct
import sys


def main(so_path, engine_dir):
    with open(so_path, "rb") as f:
        d = bytearray(f.read())

    if d[:4] != b"\x7fELF" or d[4] != 2:
        sys.exit(f"{so_path}: not a 64-bit ELF")

    e_shoff, = struct.unpack_from("<Q", d, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", d, 0x3A)
    sections = []
    for i in range(shnum):
        off = e_shoff + i * shentsize
        name, typ, _fl, _addr, offset, size, link, _info, _align, entsize = \
            struct.unpack_from("<IIQQQQIIQQ", d, off)
        sections.append(dict(name=name, typ=typ, offset=offset, size=size,
                             link=link, entsize=entsize))

    engine_libs = {}
    for fn in os.listdir(engine_dir):
        if fn.endswith(".so"):
            engine_libs[fn] = os.path.join(engine_dir, fn)

    patched = 0
    for s in sections:
        if s["typ"] != 6:  # SHT_DYNAMIC
            continue
        strtab = sections[s["link"]]
        for i in range(s["size"] // s["entsize"]):
            o = s["offset"] + i * s["entsize"]
            tag, val = struct.unpack_from("<QQ", d, o)
            if tag == 0:
                break
            if tag != 1:  # DT_NEEDED
                continue
            start = strtab["offset"] + val
            end = d.index(b"\x00", start)
            text = d[start:end].decode("utf-8", "replace")
            if "/" not in text and "\\" not in text:
                continue
            if os.path.basename(text) not in engine_libs:
                continue
            new = b"lib"  # placeholder, replaced below
            base = os.path.basename(text).encode()
            assert len(base) <= len(text) - len(text) + len(text)
            rewrite = base + b"\x00" * (end - start - len(base))
            assert len(rewrite) == end - start
            d[start:end] = rewrite
            patched += 1
            print(f"  NEEDED {text} -> {base.decode()}")

    if patched:
        with open(so_path, "wb") as f:
            f.write(d)
    print(f"{os.path.basename(so_path)}: {patched} DT_NEEDED rewritten")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
