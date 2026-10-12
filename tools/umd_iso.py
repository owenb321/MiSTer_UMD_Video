#!/usr/bin/env python3
"""ISO9660 walk for UMD Video images -- the shared base of every Phase 1 tool.

Lifted from MiSTer_DVD's tools/dvd_report.py IsoWalk (and iso_nav_check.py's walk),
standalone and stdlib-only. A UMD Video image is a plain ISO9660 filesystem
(docs/umd_video_format.md): PVD at LBA 16, then UMD_DATA.BIN and UMD_VIDEO/ with
PARAM.SFO, PLAYLIST.UMD, CLIPINF/NNNNN.CLP and STREAM/NNNNN.MPS.

Unlike the DVD walk this one walks the WHOLE tree (it is small) and records every
sector it reads (`visited`), so umd_fixture.py can cut the exact navigation sectors
the P2 reader will fetch, and the P8 bug bundle can carry them.

Multi-extent files (ECMA-119 §9.1.6: file flag bit 7 = "not the final record") are
joined only when their extents are contiguous; a gapped one raises, and either way the
file is listed in `multi_extent` so a caller can see it. None was seen on the survey
discs; the P2 reader must decide what to do with one (roadmap P2 risk).

    umd_iso.py disc.iso            # the tree with LBAs and sizes
    umd_iso.py disc.iso --json     # the same, machine-readable

UmdIso also takes a seekable file object with a `.size` (tools/cso.py's CsoFile), so the
same walk lists a compressed PSP game image (the .PMF census, tools/pmf_census.py).
"""
import argparse
import json
import os
import struct
import sys

SEC = 2048
VD_START = 16
VD_SCAN_MAX = 32          # volume descriptor set scan bound (real images: 2-3)
FLAG_DIR = 0x02
FLAG_MULTI = 0x80         # "this record is not the final one for the file"


class IsoError(Exception):
    pass


class Extent(object):
    __slots__ = ("lba", "size", "is_dir")

    def __init__(self, lba, size, is_dir):
        self.lba, self.size, self.is_dir = lba, size, is_dir

    @property
    def nsec(self):
        return (self.size + SEC - 1) // SEC

    def __repr__(self):
        return "Extent(lba=%d, size=%d%s)" % (self.lba, self.size,
                                              ", dir" if self.is_dir else "")


def merge(lbas):
    """Sorted unique LBAs -> list of [start, count] runs."""
    out = []
    for l in sorted(set(lbas)):
        if out and l == out[-1][0] + out[-1][1]:
            out[-1][1] += 1
        else:
            out.append([l, 1])
    return out


class UmdIso(object):
    """An ISO9660 image, walked in full.

    files: {'/UMD_VIDEO/PLAYLIST.UMD': Extent, ...} -- upper-case, ';1' stripped,
           directories included (is_dir True) with a trailing-slash-free path.
    """

    def __init__(self, path_or_bytes):
        if isinstance(path_or_bytes, (bytes, bytearray)):
            self.path = "<bytes>"
            self._buf = bytes(path_or_bytes)
            self.f = None
            self.image_bytes = len(self._buf)
        elif hasattr(path_or_bytes, "read"):
            # a seekable file object with a .size (cso.CsoFile: a compressed game image)
            self.path = getattr(path_or_bytes, "path", "<file>")
            self._buf = None
            self.f = path_or_bytes
            self.image_bytes = path_or_bytes.size
        else:
            self.path = path_or_bytes
            self._buf = None
            self.f = open(path_or_bytes, "rb")
            self.image_bytes = os.path.getsize(path_or_bytes)
        self.visited = []          # every LBA read, in order (the reader's LBA sequence)
        self.vd_lbas = []
        self.files = {}
        self.multi_extent = []     # paths of multi-extent files
        self._walk()

    # -- sector access -----------------------------------------------------------
    def sec(self, n, record=True):
        if record:
            self.visited.append(n)
        if self._buf is not None:
            d = self._buf[n * SEC:(n + 1) * SEC]
        else:
            self.f.seek(n * SEC)
            d = self.f.read(SEC)
        if len(d) < SEC:
            raise IsoError("sector %d is past the end of the image" % n)
        return d

    def read_sectors(self, lba, n, record=False):
        return b"".join(self.sec(lba + i, record) for i in range(n))

    def close(self):
        if self.f:
            self.f.close()

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()

    # -- the walk ----------------------------------------------------------------
    def _dir_records(self, dlba, dlen):
        """Raw records of one directory: [(name_bytes, lba, size, flags)]."""
        out = []
        for s in range((dlen + SEC - 1) // SEC):
            buf = self.sec(dlba + s)
            p = 0
            while p < SEC:
                rl = buf[p]
                if rl == 0:
                    break           # records never straddle a sector: rest is padding
                if rl < 34 or p + rl > SEC:
                    raise IsoError("bad directory record at LBA %d+%d" % (dlba + s, p))
                lba = struct.unpack("<I", buf[p + 2:p + 6])[0]
                size = struct.unpack("<I", buf[p + 10:p + 14])[0]
                fl = buf[p + 25]
                nl = buf[p + 32]
                nm = buf[p + 33:p + 33 + nl]
                out.append((nm, lba, size, fl))
                p += rl
        return out

    def _walk(self):
        pvd = None
        lba = VD_START
        while True:
            if lba >= VD_START + VD_SCAN_MAX:
                raise IsoError("no volume descriptor set terminator within %d sectors"
                               % VD_SCAN_MAX)
            d = self.sec(lba)
            if d[1:6] != b"CD001":
                raise IsoError("not ISO9660: no CD001 at sector %d" % lba)
            self.vd_lbas.append(lba)
            if d[0] == 1 and pvd is None:
                pvd = d
            if d[0] == 255:
                break
            lba += 1
        if pvd is None:
            raise IsoError("no Primary Volume Descriptor")
        # "UMD VIDEO" is the SYSTEM identifier (PVD 8-39); the volume id is blank on
        # every surveyed disc.
        self.system_id = pvd[8:40].decode("latin-1").strip()
        self.volume_id = pvd[40:72].decode("latin-1").strip()
        self.volume_sectors = struct.unpack("<I", pvd[80:84])[0]
        self.logical_block_size = struct.unpack("<H", pvd[128:130])[0]
        if self.logical_block_size != SEC:
            raise IsoError("logical block size %d, not 2048" % self.logical_block_size)
        root_lba = struct.unpack("<I", pvd[158:162])[0]
        root_len = struct.unpack("<I", pvd[166:170])[0]
        self.files[""] = Extent(root_lba, root_len, True)
        self._walk_dir("", root_lba, root_len, depth=0)

    def _walk_dir(self, prefix, dlba, dlen, depth):
        if depth > 8:                       # ECMA-119 §6.8.2.1 limits depth to 8
            raise IsoError("directory depth > 8 at %s" % prefix)
        pending = None                      # (name, lba, size, [(lba,size)...]) multi-extent
        subdirs = []
        for nm, lba, size, fl in self._dir_records(dlba, dlen):
            if nm in (b"\x00", b"\x01"):
                continue                    # '.' and '..'
            name = nm.decode("latin-1").upper().split(";")[0]
            if name.endswith("."):
                name = name[:-1]            # "NAME." for extension-less files
            path = prefix + "/" + name
            if fl & FLAG_DIR:
                self.files[path] = Extent(lba, size, True)
                subdirs.append((path, lba, size))
                continue
            if pending is not None and pending[0] != path:
                raise IsoError("multi-extent file %s has no final record" % pending[0])
            if fl & FLAG_MULTI or pending is not None:
                if pending is None:
                    pending = (path, [])
                pending[1].append((lba, size))
                if fl & FLAG_MULTI:
                    continue
                path, parts = pending
                pending = None
                self.multi_extent.append(path)
                pos = parts[0][0]
                for i, (plba, psize) in enumerate(parts):
                    if plba != pos:
                        raise IsoError("multi-extent file %s is not contiguous" % path)
                    if i < len(parts) - 1 and psize % SEC:
                        raise IsoError("multi-extent file %s: a non-final extent is "
                                       "not a whole number of sectors" % path)
                    pos = plba + psize // SEC
                self.files[path] = Extent(parts[0][0], sum(p[1] for p in parts), False)
                continue
            self.files[path] = Extent(lba, size, False)
        if pending is not None:
            raise IsoError("multi-extent file %s has no final record" % pending[0])
        for path, lba, size in subdirs:
            self._walk_dir(path, lba, size, depth + 1)

    # -- file access -------------------------------------------------------------
    def extent(self, path):
        p = path.upper()
        if not p.startswith("/"):
            p = "/" + p
        if p not in self.files:
            raise IsoError("%s not in image" % path)
        return self.files[p]

    def exists(self, path):
        try:
            self.extent(path)
            return True
        except IsoError:
            return False

    def read(self, path, record=True):
        """Whole file contents (sectors recorded in `visited` by default)."""
        e = self.extent(path)
        return self.read_sectors(e.lba, e.nsec, record)[:e.size]

    def iter_sectors(self, path):
        """(lba, 2048 bytes) for each sector of a file; the tail sector is whole."""
        e = self.extent(path)
        for i in range(e.nsec):
            yield e.lba + i, self.sec(e.lba + i, record=False)

    def listdir(self, path):
        p = "/" + path.strip("/").upper() if path.strip("/") else ""
        return sorted(k[len(p) + 1:] for k in self.files
                      if k.startswith(p + "/") and "/" not in k[len(p) + 1:])

    def clips(self):
        """Clip numbers present as STREAM/NNNNN.MPS, sorted."""
        out = []
        for n in self.listdir("/UMD_VIDEO/STREAM"):
            if n.endswith(".MPS") and n[:5].isdigit():
                out.append(int(n[:5]))
        return sorted(out)

    def clip_infos(self):
        """Clip numbers present as CLIPINF/NNNNN.CLP, sorted. Not always == clips():
        The Simpsons Movie carries a 16 KB STREAM/00006.MPS with no CLP."""
        return sorted(int(n[:5]) for n in self.listdir("/UMD_VIDEO/CLIPINF")
                      if n.endswith(".CLP") and n[:5].isdigit())

    def lba_runs(self):
        return merge(self.visited)

    def umd_data(self):
        """UMD_DATA.BIN: 'TITLE|DISCID|VERSION|FLAGS...' -> dict (None if absent)."""
        if not self.exists("/UMD_DATA.BIN"):
            return None
        return parse_umd_data(self.read("/UMD_DATA.BIN"))


def parse_umd_data(raw):
    """UMD_DATA.BIN (48 bytes on every surveyed disc): '|'-separated ASCII fields,
    zero-padded. Field 0 is the product code (e.g. 'ULUS-12345' on some, a title stub
    on others), then the disc id (hex), a version, and a type/flags field."""
    text = raw.split(b"\x00")[0].decode("latin-1")
    fields = text.split("|")
    return {"raw": text, "fields": fields,
            "product": fields[0].strip() if fields else "",
            "disc_id": fields[1] if len(fields) > 1 else "",
            "version": fields[2] if len(fields) > 2 else "",
            "flags": fields[3] if len(fields) > 3 else ""}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("iso")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    with UmdIso(a.iso) as iso:
        if a.json:
            json.dump({"system_id": iso.system_id, "volume_id": iso.volume_id,
                       "volume_sectors": iso.volume_sectors,
                       "umd_data": iso.umd_data(),
                       "multi_extent": iso.multi_extent,
                       "files": {k or "/": {"lba": e.lba, "size": e.size, "dir": e.is_dir}
                                 for k, e in sorted(iso.files.items())}},
                      sys.stdout, indent=1)
            print()
            return 0
        print("system %r  volume %r  %d sectors  VDs at %s"
              % (iso.system_id, iso.volume_id, iso.volume_sectors, iso.vd_lbas))
        ud = iso.umd_data()
        if ud:
            print("UMD_DATA.BIN  %r" % ud["raw"])
        for k, e in sorted(iso.files.items(), key=lambda kv: kv[1].lba):
            print("%8d %11d  %s%s" % (e.lba, e.size, k or "/", "/" if e.is_dir and k else ""))
        if iso.multi_extent:
            print("MULTI-EXTENT: %s" % ", ".join(iso.multi_extent))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except IsoError as e:
        sys.exit("umd_iso: %s" % e)
