#!/usr/bin/env python3
"""A read-only CISO (`.cso`) image as a seekable file object -- the PSP game images the
.PMF census (tools/pmf_census.py) reads, decompressed one block at a time.

CISO v1 (the format of the `ciso` tool and PPSSPP's / JPCSP's readers): a 24-byte header
`"CISO", u32 header_size, u64 total_bytes, u32 block_size, u8 version, u8 align, u16 0`,
then `n_blocks + 1` little-endian u32 index entries. An entry's low 31 bits, shifted left
by `align`, are the block's file position; bit 31 set = the block is stored raw, clear =
raw deflate (no zlib header). The next entry bounds the block.

    with CsoFile("game.cso") as f: umd_iso.UmdIso(f)
"""
import io
import struct
import zlib


class CsoError(Exception):
    pass


class CsoFile(io.RawIOBase):
    def __init__(self, path, cache_blocks=64):
        self.path = path
        self.f = open(path, "rb")
        h = self.f.read(24)
        if len(h) < 24 or h[:4] != b"CISO":
            self.f.close()
            raise CsoError("%s: no CISO header" % path)
        self.size = struct.unpack("<Q", h[8:16])[0]
        self.block = struct.unpack("<I", h[16:20])[0]
        self.align = h[21]
        if self.block == 0 or self.block & (self.block - 1):
            self.f.close()
            raise CsoError("%s: block size %d" % (path, self.block))
        n = (self.size + self.block - 1) // self.block
        raw = self.f.read(4 * (n + 1))
        if len(raw) < 4 * (n + 1):
            self.f.close()
            raise CsoError("%s: index truncated" % path)
        self.index = struct.unpack("<%dI" % (n + 1), raw)
        self.pos = 0
        self.cache = {}
        self.cache_blocks = cache_blocks

    def _block(self, i):
        d = self.cache.get(i)
        if d is not None:
            return d
        a, b = self.index[i], self.index[i + 1]
        off = (a & 0x7FFFFFFF) << self.align
        end = (b & 0x7FFFFFFF) << self.align
        self.f.seek(off)
        d = self.f.read(end - off)
        if not a & 0x80000000:
            d = zlib.decompressobj(-15).decompress(d)
        d = d[:self.block]
        want = min(self.block, self.size - i * self.block)
        if len(d) < want:
            raise CsoError("%s: block %d decodes to %d of %d bytes" % (self.path, i, len(d), want))
        if len(self.cache) >= self.cache_blocks:
            self.cache.clear()
        self.cache[i] = d
        return d

    def readable(self):
        return True

    def seekable(self):
        return True

    def seek(self, pos, whence=0):
        self.pos = pos if whence == 0 else self.pos + pos if whence == 1 else self.size + pos
        return self.pos

    def tell(self):
        return self.pos

    def read(self, n=-1):
        if n is None or n < 0:
            n = self.size - self.pos
        out = []
        while n > 0 and self.pos < self.size:
            i, o = divmod(self.pos, self.block)
            d = self._block(i)[o:o + n]
            out.append(d)
            self.pos += len(d)
            n -= len(d)
        return b"".join(out)

    def close(self):
        if not self.closed:
            self.f.close()
        super().close()
