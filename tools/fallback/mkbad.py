#!/usr/bin/env python3
"""mkbad.py <in.mkv> <out.mkv>: the same file with its HEVC track's hvcC
(Matroska CodecPrivate) broken: the first NAL unit's length says 65535, more
than the record holds, so libavcodec's HEVC decoders refuse to open
("Invalid NAL unit size in extradata."). Nothing else changes."""
import sys

data = bytearray(open(sys.argv[1], "rb").read())
i = data.find(b"\x63\xa2")  # CodecPrivate; the first one is the video track's here
if i < 0:
    sys.exit("no CodecPrivate")
b, n = data[i + 2], 1
while not b & (0x80 >> (n - 1)):
    n += 1
size = b & (0xFF >> n)
for k in range(1, n):
    size = size << 8 | data[i + 2 + k]
start = i + 2 + n
hvcc = data[start:start + size]
# hvcC: 22 bytes, numOfArrays, then per array: type, numNalus (2), and per
# NAL unit: its length (2) and the unit
if size < 28 or hvcc[0] != 1:
    sys.exit("not an hvcC record")
data[start + 26:start + 28] = b"\xff\xff"
open(sys.argv[2], "wb").write(data)
print("hvcC at %d, %d bytes: first NAL unit length %d -> 65535"
      % (start, size, int.from_bytes(hvcc[26:28], "big")))
