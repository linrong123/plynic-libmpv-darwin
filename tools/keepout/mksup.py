#!/usr/bin/env python3
"""mksup.py <out.sup>: write a small PGS (Blu-ray bitmap subtitle) stream.

A 1920x1080 presentation: from 1 s to 50 s a 640x96 block of two "lines"
(white bars with a dark outline, a gap between them) whose bottom edge sits
54 px above the bottom of the picture, like a subtitle authored at the usual
place. Written from the segment layout in the Blu-ray spec as FFmpeg's
pgssubdec reads it (PCS, WDS, PDS, ODS, END), so the bitmap subtitle path
(sd_lavc) can be tested without a sample file.

The same display set is repeated every 2 s (an epoch start each time, as a
disc does at acquisition points), so a seek finds one nearby.
"""
import struct
import sys

W, H = 1920, 1080
OBJ_W, OBJ_H = 640, 96
OBJ_X, OBJ_Y = (W - OBJ_W) // 2, H - 54 - OBJ_H


def segment(kind, pts, payload):
    return b"PG" + struct.pack(">IIBH", int(pts * 90000), 0, kind, len(payload)) + payload


def pcs(number, state, objects):
    p = struct.pack(">HHBHBBBB", W, H, 0x10, number, state, 0, 0, len(objects))
    for oid, x, y in objects:
        p += struct.pack(">HBBHH", oid, 0, 0, x, y)
    return p


def wds():
    return struct.pack(">BBHHHH", 1, 0, OBJ_X, OBJ_Y, OBJ_W, OBJ_H)


def pds():
    # id, Y, Cr, Cb, alpha (BT.709 limited range): 1 white, 2 near black
    return bytes([0, 0]) + bytes([1, 235, 128, 128, 255, 2, 20, 128, 128, 255])


def rle_line(pixels):
    out = bytearray()
    i = 0
    while i < len(pixels):
        c = pixels[i]
        n = 1
        while i + n < len(pixels) and pixels[i + n] == c and n < 16383:
            n += 1
        if c == 0:
            out += bytes([0, n]) if n < 64 else bytes([0, 0x40 | (n >> 8), n & 0xFF])
        elif n < 3:
            out += bytes([c]) * n
        elif n < 64:
            out += bytes([0, 0x80 | n, c])
        else:
            out += bytes([0, 0xC0 | (n >> 8), n & 0xFF, c])
        i += n
    return bytes(out) + b"\x00\x00"


def bitmap():
    rows = []
    for y in range(OBJ_H):
        row = []
        for x in range(OBJ_W):
            # two bars 40 px high with a 4 px outline, 8 px apart; the upper
            # one shorter, as a first line usually is
            c = 0
            for top, left, right in ((0, 80, OBJ_W - 80), (48, 0, OBJ_W)):
                if top <= y < top + 44 and left <= x < right:
                    inner = top + 4 <= y < top + 40 and left + 4 <= x < right - 4
                    c = 1 if inner else 2
            row.append(c)
        rows.append(row)
    return b"".join(rle_line(r) for r in rows)


def ods():
    data = bitmap()
    length = len(data) + 4
    return (struct.pack(">HBB", 0, 0, 0xC0) + length.to_bytes(3, "big") +
            struct.pack(">HH", OBJ_W, OBJ_H) + data)


def main():
    hide = 50.0
    out = b""
    n = 0
    for show in range(1, int(hide), 2):
        out += segment(0x16, show, pcs(n, 0x80, [(0, OBJ_X, OBJ_Y)]))
        out += segment(0x17, show, wds())
        out += segment(0x14, show, pds())
        out += segment(0x15, show, ods())
        out += segment(0x80, show, b"")
        n += 1
    out += segment(0x16, hide, pcs(n, 0x00, []))
    out += segment(0x17, hide, wds())
    out += segment(0x80, hide, b"")
    with open(sys.argv[1], "wb") as f:
        f.write(out)


if __name__ == "__main__":
    main()
