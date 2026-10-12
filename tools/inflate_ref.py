#!/usr/bin/env python3
"""A DEFLATE / zlib reader after Mark Adler's puff.c (zlib contrib/puff) -- the decode
METHOD umd/png/inflate.sv implements (count / first / index canonical decode, one code
bit at a time), with coverage counters and a symbol trace.

NOT the oracle. zlib is (tools/png_golden.py scores the RTL against zlib.decompress and
PIL). This model exists to:
  * say which DEFLATE features a case actually exercises -- each counter counts an event
    whose mis-handling CHANGES the output (CLAUDE.md "A coverage counter must count what
    the path CHANGES"), e.g. `dist_gt16k_differs` counts matches farther than 16 KB whose
    byte differs from the one a 16 KB window would alias to;
  * localise an RTL mismatch (the symbol trace: literal / match / block events with the
    output position).

Errors follow zlib's verdicts (tools/png_golden.py asserts the agreement case by case);
the messages are zlib's strings where zlib has one.

    inflate_ref.py FILE [--raw] [--trace]    # zlib stream (default) or raw DEFLATE
"""
import sys
from collections import Counter

MAXBITS = 15
MAXLCODES = 286
MAXDCODES = 30
FIXLCODES = 288

LBASE = (3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
         35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258)
LEXT = (0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0)
DBASE = (1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
         257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
         8193, 12289, 16385, 24577)
DEXT = (0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13)
CLORDER = (16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15)


class InflateError(Exception):
    pass


class Huffman(object):
    """count[len] codes of each length, symbol[] in canonical order (puff's struct)."""

    def __init__(self, lengths):
        self.count = [0] * (MAXBITS + 1)
        for ln in lengths:
            self.count[ln] += 1
        self.symbol = [0] * len(lengths)
        self.used = [ln for ln in lengths if ln]
        left = 1
        self.left = 0
        if self.count[0] == len(lengths):       # no codes: complete, but decoding fails
            return
        for ln in range(1, MAXBITS + 1):
            left <<= 1
            left -= self.count[ln]
            if left < 0:
                self.left = -1                  # over-subscribed
                return
        self.left = left                        # > 0: incomplete
        offs = [0] * (MAXBITS + 1)
        for ln in range(1, MAXBITS):
            offs[ln + 1] = offs[ln] + self.count[ln]
        for sym, ln in enumerate(lengths):
            if ln:
                self.symbol[offs[ln]] = sym
                offs[ln] += 1


class Inflater(object):
    def __init__(self, data, trace=False):
        self.data = data
        self.pos = 0          # next input byte
        self.bitbuf = 0
        self.bitcnt = 0
        self.out = bytearray()
        self.cov = Counter()
        self.trace = [] if trace else None
        self.block_start = 0

    # -- bits ------------------------------------------------------------------------
    def bits(self, need):
        val = self.bitbuf
        while self.bitcnt < need:
            if self.pos >= len(self.data):
                raise InflateError("unexpected end of data")
            val |= self.data[self.pos] << self.bitcnt
            self.pos += 1
            self.bitcnt += 8
        self.bitbuf = val >> need
        self.bitcnt -= need
        return val & ((1 << need) - 1)

    def decode(self, h):
        code = first = index = 0
        for ln in range(1, MAXBITS + 1):
            code |= self.bits(1)
            count = h.count[ln]
            if code - count < first:
                if ln == MAXBITS:
                    self.cov["code_len15_decoded"] += 1
                return h.symbol[index + (code - first)]
            index += count
            first += count
            first <<= 1
            code <<= 1
        raise InflateError("invalid code")      # ran out of codes (incomplete code)

    # -- blocks ----------------------------------------------------------------------
    def stored(self):
        self.bitbuf = 0
        self.bitcnt = 0
        if self.pos + 4 > len(self.data):
            raise InflateError("unexpected end of data")
        ln = self.data[self.pos] | self.data[self.pos + 1] << 8
        nln = self.data[self.pos + 2] | self.data[self.pos + 3] << 8
        self.pos += 4
        if ln != (~nln & 0xFFFF):
            raise InflateError("invalid stored block lengths")
        if self.pos + ln > len(self.data):
            raise InflateError("unexpected end of data")
        self.out += self.data[self.pos:self.pos + ln]
        self.pos += ln
        self.cov["stored"] += 1
        if ln == 0:
            self.cov["stored_len0"] += 1
        if ln == 65535:
            self.cov["stored_len65535"] += 1
        if self.trace is not None:
            self.trace.append(("stored", len(self.out) - ln, ln))

    def codes(self, lencode, distcode):
        while True:
            sym = self.decode(lencode)
            if sym < 256:
                if self.trace is not None:
                    self.trace.append(("lit", len(self.out), sym))
                self.out.append(sym)
                self.cov["literal"] += 1
            elif sym == 256:
                if self.trace is not None:
                    self.trace.append(("eob", len(self.out)))
                return
            else:
                sym -= 257
                if sym >= 29:
                    raise InflateError("invalid literal/length code")
                ext = self.bits(LEXT[sym])
                ln = LBASE[sym] + ext
                if LEXT[sym] and ext:
                    self.cov["len_extra_nonzero"] += 1
                if sym == 28:
                    self.cov["len258_code285"] += 1
                if sym == 27 and ext == 31:
                    self.cov["len258_code284"] += 1
                if not distcode.used:
                    raise InflateError("invalid distance code")
                dsym = self.decode(distcode)
                if dsym >= 30:
                    raise InflateError("invalid distance code")
                dext = self.bits(DEXT[dsym])
                dist = DBASE[dsym] + dext
                if DEXT[dsym] and dext:
                    self.cov["dist_extra_nonzero"] += 1
                if dist > len(self.out):
                    raise InflateError("invalid distance too far back")
                p = len(self.out)
                if self.trace is not None:
                    self.trace.append(("match", p, ln, dist))
                self.cov["match"] += 1
                self.cov["max_dist"] = max(self.cov["max_dist"], dist)
                if dist == 32768:
                    self.cov["dist32768"] += 1
                if dist < ln:
                    self.cov["overlap_dist1" if dist == 1 else "overlap_dist_gt1"] += 1
                if p - dist < self.block_start:
                    self.cov["match_into_earlier_block"] += 1
                for i in range(ln):
                    b = self.out[p + i - dist]
                    # a 16 KB window would read slot (p+i-dist) mod 16K, holding the byte
                    # written 16K later -- count only where that byte differs
                    if dist > 16384 and self.out[p + i - dist + 16384] != b:
                        self.cov["dist_gt16k_differs"] += 1
                    self.out.append(b)

    def fixed(self):
        lengths = [8] * 144 + [9] * 112 + [7] * 24 + [8] * 8
        lc = Huffman(lengths)
        dc = Huffman([5] * 30)
        dc.used = [5] * 30
        self.cov["fixed"] += 1
        # fixed codes 286/287 and distances 30/31 are decodable symbols, refused when
        # decoded (zlib: "invalid literal/length code" / "invalid distance code")
        dc30 = Huffman([5] * 32)
        self.codes(lc, dc30)

    def dynamic(self):
        nlen = self.bits(5) + 257
        ndist = self.bits(5) + 1
        ncode = self.bits(4) + 4
        if nlen > MAXLCODES or ndist > MAXDCODES:
            raise InflateError("too many length or distance symbols")
        if nlen == MAXLCODES:
            self.cov["hlit286"] += 1
        if ndist == MAXDCODES:
            self.cov["hdist30"] += 1
        if ncode == 19:
            self.cov["hclen19"] += 1
        lengths = [0] * 19
        for i in range(ncode):
            lengths[CLORDER[i]] = self.bits(3)
        lencode = Huffman(lengths)
        if lencode.left != 0:
            # zlib: an incomplete code-length code is refused too
            raise InflateError("invalid code lengths set")
        lengths = []
        while len(lengths) < nlen + ndist:
            sym = self.decode(lencode)
            if sym < 16:
                lengths.append(sym)
                continue
            if sym == 16:
                if not lengths:
                    raise InflateError("invalid bit length repeat")
                ln = lengths[-1]
                rep = 3 + self.bits(2)
                self.cov["rep16"] += 1
                if len(lengths) < nlen < len(lengths) + rep:
                    self.cov["rep16_across_lit_dist"] += 1
            elif sym == 17:
                ln, rep = 0, 3 + self.bits(3)
                self.cov["rep17"] += 1
            else:
                ln, rep = 0, 11 + self.bits(7)
                self.cov["rep18"] += 1
            if len(lengths) + rep > nlen + ndist:
                raise InflateError("invalid bit length repeat")
            lengths += [ln] * rep
        if lengths[256] == 0:
            raise InflateError("invalid code -- missing end-of-block")
        lc = Huffman(lengths[:nlen])
        if lc.left < 0 or (lc.left > 0 and not (len(lc.used) == 1 and lc.used[0] == 1)):
            raise InflateError("invalid literal/lengths set")
        dc = Huffman(lengths[nlen:])
        if dc.left < 0 or (dc.left > 0 and not (len(dc.used) == 1 and dc.used[0] == 1)):
            raise InflateError("invalid distances set")
        if len(dc.used) == 1 and dc.used[0] == 1:
            self.cov["dist_single_code"] += 1
        if not dc.used:
            self.cov["dist_empty"] += 1
        if max(lengths) == 15:
            self.cov["code_len15_table"] += 1
        self.cov["dynamic"] += 1
        self.codes(lc, dc)

    def run(self):
        """Raw DEFLATE -> bytes."""
        last = 0
        nblk = 0
        while not last:
            last = self.bits(1)
            typ = self.bits(2)
            self.block_start = len(self.out)
            nblk += 1
            if typ == 0:
                self.stored()
            elif typ == 1:
                self.fixed()
            elif typ == 2:
                self.dynamic()
            else:
                raise InflateError("invalid block type")
        if nblk > 1:
            self.cov["multi_block"] += 1
        return bytes(self.out)


def adler32(b):
    a, s = 1, 0
    for x in b:
        a = (a + x) % 65521
        s = (s + a) % 65521
    return s << 16 | a


def inflate_zlib(data, trace=False):
    """zlib stream -> (bytes, Inflater). Raises InflateError with zlib's wording.
    Trailing bytes after the Adler are the caller's business (inf.pos says where the
    stream ended)."""
    if len(data) < 2:
        raise InflateError("unexpected end of data")
    cmf, flg = data[0], data[1]
    if (cmf * 256 + flg) % 31:
        raise InflateError("incorrect header check")
    if cmf & 15 != 8:
        raise InflateError("unknown compression method")
    if cmf >> 4 > 7:
        raise InflateError("invalid window size")
    if flg & 0x20:
        raise InflateError("need dictionary")
    inf = Inflater(data[2:], trace)
    out = inf.run()
    p = inf.pos
    if p + 4 > len(inf.data):
        raise InflateError("unexpected end of data")
    want = int.from_bytes(inf.data[p:p + 4], "big")
    if adler32(out) != want:
        raise InflateError("incorrect data check")
    inf.pos = p + 4 + 2                    # in `data` coordinates, after the Adler
    return out, inf


def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("file")
    ap.add_argument("--raw", action="store_true")
    ap.add_argument("--trace", action="store_true")
    a = ap.parse_args(argv)
    data = open(a.file, "rb").read()
    try:
        if a.raw:
            inf = Inflater(data, a.trace)
            out = inf.run()
        else:
            out, inf = inflate_zlib(data, a.trace)
    except InflateError as e:
        print("error: %s" % e)
        return 1
    print("%d bytes; coverage: %s" % (len(out), dict(sorted(inf.cov.items()))))
    if a.trace:
        for t in inf.trace:
            print(" ".join(str(x) for x in t))
    return 0


if __name__ == "__main__":
    sys.exit(main())
