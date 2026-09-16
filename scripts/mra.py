#!/usr/bin/env python3
"""Build the SDRAM image an `.mra` describes, the way mra-tools-c would.

scripts/build_mra.py uses it to check that each `.mra` reproduces the image
built directly from the driver's ROM_START, and to pick each region's map by
testing which one does (LESSONS_LEARNED: derived interleaves were wrong on
Psikyo).

Semantics implemented:

  <part name= .../>            the whole file, verbatim
  <part repeat="N">FF</part>   N bytes of the given filler
  <part>0A 0B</part>           literal bytes (used for the mod byte and for
                               hiscore configuration blocks)
  <interleave output="N">      N is BITS (16 or 32), so the output word is
                               N/8 bytes. Each child part carries a `map`
                               with one digit per output byte. A digit d != 0
                               means that output byte comes from byte (d-1)
                               of the part's chunk; 0 means the part does not
                               contribute there. A part's chunk size is its
                               number of non-zero digits.
"""
import zipfile
import xml.etree.ElementTree as ET


def _zip_read(z, name):
    names = {n.split('/')[-1]: n for n in z.namelist()}
    if name not in names:
        raise KeyError(f"{name} not in zip")
    return z.read(names[name])


def _literal_bytes(text):
    return bytes(int(tok, 16) for tok in (text or "").split())


def pattern_from_map(m):
    """Decode a `map` attribute the way mra-tools-c does.

    Transcribed, not derived, from mra-tools-c `src/mra.c`,
    `get_pattern_from_map()`:

        for (i = n - 1, j = 0; i >= 0; i--) {
            if (map[i] != '0') {
                if (!first_found) { first_found = -1; *map_index = n - i - 1; }
                (*pattern)[j++] = map[i] - 1;
            }
        }

    The string is scanned right to left. `map_index` is the output-byte offset
    where this part starts, and `pattern[j]` is the source byte that lands at
    output byte `map_index + j`:

        map="12"  ->  pattern [1,0]  ->  out[0]=src[1], out[1]=src[0]  SWAP
        map="21"  ->  pattern [0,1]  ->  out[0]=src[0], out[1]=src[1]  verbatim

    as docs/LESSONS_LEARNED.md records. Returns (map_index, pattern).
    """
    pattern = []
    map_index = None
    n = len(m)
    for i in range(n - 1, -1, -1):
        if m[i] != '0':
            if map_index is None:
                map_index = n - i - 1
            pattern.append(int(m[i]) - 1)
    return (map_index or 0), pattern


def interleave(parts, output_bits):
    """parts: list of (data, map_string). Returns the interleaved bytes."""
    owidth = output_bits // 8
    for _, m in parts:
        if len(m) != owidth:
            raise ValueError(f"map {m!r} is not {owidth} digits for output={output_bits}")

    decoded = [pattern_from_map(m) for _, m in parts]
    chunk = {i: len(pat) for i, (_, pat) in enumerate(decoded)}
    n_words = min(len(d) // chunk[i] for i, (d, _) in enumerate(parts) if chunk[i])

    out = bytearray(n_words * owidth)
    for i, (data, _) in enumerate(parts):
        map_index, pat = decoded[i]
        cs = len(pat)
        if not cs:
            continue
        for w in range(n_words):
            base = w * cs
            for j, src in enumerate(pat):
                out[w * owidth + map_index + j] = data[base + src]
    return bytes(out)


def build_image(mra_path, zip_path, size=None):
    """Assemble the index-0 ROM image an .mra describes."""
    root = ET.parse(mra_path).getroot()
    rom0 = None
    for rom in root.findall("rom"):
        if rom.get("index") == "0":
            rom0 = rom
            break
    if rom0 is None:
        raise ValueError("no <rom index=\"0\"> in the .mra")

    out = bytearray()
    with zipfile.ZipFile(zip_path) as z:
        for el in rom0:
            if el.tag == "part":
                if el.get("name"):
                    out += _zip_read(z, el.get("name"))
                elif el.get("repeat"):
                    out += _literal_bytes(el.text) * int(el.get("repeat"), 0)
                else:
                    out += _literal_bytes(el.text)
            elif el.tag == "interleave":
                bits = int(el.get("output"))
                parts = [(_zip_read(z, p.get("name")), p.get("map")) for p in el]
                out += interleave(parts, bits)
            else:
                raise ValueError(f"unexpected element <{el.tag}> in <rom index=0>")
    if size is not None and len(out) != size:
        raise ValueError(f"image is {len(out)} bytes, expected {size}")
    return bytes(out)


def mod_byte(mra_path):
    """The index-1 mod byte, which selects the board variant at runtime."""
    root = ET.parse(mra_path).getroot()
    for rom in root.findall("rom"):
        if rom.get("index") == "1":
            return _literal_bytes(rom.find("part").text)[0]
    return None


def _selftest():
    """Pin the map convention to mra-tools-c. A self-consistency check built
    on this module cannot catch a wrong convention here."""
    src = bytes([0xAA, 0xBB, 0xCC, 0xDD])

    got = interleave([(src, "12")], 16)
    assert got == bytes([0xBB, 0xAA, 0xDD, 0xCC]), f'map="12" must SWAP, got {got.hex()}'

    got = interleave([(src, "21")], 16)
    assert got == bytes([0xAA, 0xBB, 0xCC, 0xDD]), f'map="21" must be verbatim, got {got.hex()}'

    # ROM_LOAD16_BYTE pairing. The digit's position counted from the right is
    # the output byte it feeds:
    #
    #     map="01"  ->  map_index 0  ->  the part lands at output byte 0
    #     map="10"  ->  map_index 1  ->  the part lands at output byte 1
    a = bytes([0x11, 0x22])
    b = bytes([0x33, 0x44])
    got = interleave([(a, "01"), (b, "10")], 16)
    assert got == bytes([0x11, 0x33, 0x22, 0x44]), f"byte pairing wrong: {got.hex()}"

    # A 32-bit interleave with a part contributing a non-zero-offset pair.
    c = bytes([0x01, 0x02, 0x03, 0x04])
    got = interleave([(c, "0012")], 32)
    assert got[0:2] == bytes([0x02, 0x01]), f"map_index/pattern wrong: {got.hex()}"

    print("mra.py selftest: map convention matches mra-tools-c")


if __name__ == "__main__":
    _selftest()
