#!/usr/bin/env python3
"""rco_census.py -- P9's M0 census (docs/menus.md S7): every disc's menu containers
(UMD_VIDEO/RESOURCE/*.RCO) and their compiled scripts (VSMX), measured read-only.

The RCO layout is RCOMage's (github.com/kakaroto/RCOMage, LGPL 2.1: src/rcofile.h,
src/rcoreader.c, data/*attribdef-psp.ini), cross-checked against JPCSP's
jpcsp.format.rco. Written from those descriptions, not copied:

  RCO     "\\0PRF", version (0x70 / 0x71 on UMDs), 0, compression (upper nibble: 0 none,
          1 zlib, 2 RLZ), then 37 words: the table pointers (main, VSMX, text, sound,
          model, image, unknown, font, object, anim), the text / label / event data, the
          pointer tables and the attached image / sound / model data (offset, length).
  entry   0x28 bytes: u16 typeId (low byte the type within its table, high byte the
          table id: 1 main, 2 VSMX, 3 text, 4 image, 5 model, 6 sound, 7 font, 8 object,
          9 anim), u16 0, label offset, header size (0x28), entry size, number of
          subentries, offset of the next sibling, previous, parent, 2 x 0; then its
          extra data, then its subentries.
  VSMX    "VSMX", version 0x10000, then code / text / property / names (offset, length,
          entries): the code is 8-byte groups {u32 id, u32 value}; text and property
          strings are UTF-16LE, names ASCII, NUL-terminated.

Outputs, per disc, a JSON record under --out, and a summary (the maxima that become
docs/spec_hardening.md rows, the object / animation / opcode histograms, every API
identifier with the number of discs that use it).

    rco_census.py [--iso-dir DIR] [--out DIR] [--jobs N] [images...]
"""
import argparse
import collections
import json
import multiprocessing
import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

TABLES = {1: "main", 2: "vsmx", 3: "text", 4: "image", 5: "model", 6: "sound", 7: "font", 8: "object", 9: "anim"}
# object / anim type names in order (RCOMage data/objattribdef-psp.ini, animattribdef-psp.ini)
OBJ_TYPES = ["ObjectTree", "Page", "Plane", "Button", "XMenu", "XMList", "XList", "Progress", "Scroll",
             "MList", "MItem", "Obj0B", "XItem", "Text", "ModelObject", "Spin", "Action", "ItemSpin",
             "Group", "LList", "LItem", "Edit", "Clock", "IList", "IItem", "Icon", "UButton"]
ANIM_TYPES = ["AnimTree", "Animation", "MoveTo", "Recolour", "Rotate", "Resize", "Fade", "Delay",
              "FireEvent", "Lock", "Unlock", "SlideOut"]
OPS = {0x0: "NOTHING", 0x1: "ASSIGN", 0x2: "ADD", 0x3: "SUB", 0x4: "MUL", 0x5: "DIV", 0x6: "MOD",
       0x7: "POS", 0x8: "NEG", 0x9: "NOT", 0xa: "P_INC", 0xb: "P_DEC", 0xc: "INC", 0xd: "DEC",
       0xe: "EQ", 0xf: "NE", 0x10: "SEQ", 0x11: "SNE", 0x12: "LT", 0x13: "LE", 0x14: "GE", 0x15: "GT",
       0x16: "INSTANCEOF", 0x17: "IN", 0x18: "TYPEOF", 0x19: "BAND", 0x1a: "BXOR", 0x1b: "BOR",
       0x1c: "BNOT", 0x1d: "SHL", 0x1e: "SHR", 0x1f: "USHR", 0x20: "PUSH", 0x21: "POP",
       0x22: "END_STMT", 0x23: "NULL", 0x24: "EMPTYARRAY", 0x25: "BOOL", 0x26: "INT", 0x27: "FLOAT",
       0x28: "STRING", 0x29: "OBJECT", 0x2a: "FUNCTION", 0x2b: "ARRAY", 0x2c: "THIS",
       0x2d: "UNNAMED_VAR", 0x2e: "VARIABLE", 0x2f: "PROPERTY", 0x30: "METHOD", 0x31: "SET_ATTR",
       0x32: "UNSET", 0x33: "OBJ_ADD_ATTR", 0x34: "ARRAY_INDEX", 0x35: "ARRAY_INDEX_KEEP",
       0x36: "ARRAY_INDEX_ASSIGN", 0x37: "ARRAY_INDEX_ASSIGN2", 0x38: "ARRAY_ELEM", 0x39: "SECT_START",
       0x3a: "JUMP_TRUE", 0x3b: "JUMP_FALSE", 0x3c: "CALL_FUNC", 0x3d: "CALL_METHOD", 0x3e: "CALL_NEW",
       0x3f: "RETURN", 0x40: "OP_40", 0x41: "OP_41", 0x42: "OP_42", 0x43: "OP_43", 0x44: "OP_44",
       0x45: "END", 0x46: "DEBUG_FILE", 0x47: "DEBUG_LINE", 0x48: "OP_48", 0x49: "MAKE_FLOAT_ARRAY"}
NAME_OPS = {0x2e}                         # the value indexes the names table
PROP_OPS = {0x2f, 0x30, 0x31, 0x32, 0x33}  # ... the property table
TEXT_OPS = {0x28}                         # ... the text table


def ini_extra_words(path):
    """{type index: extra words} from an RCOMage attribdef ini (refs are 2 words, values 1)"""
    out, cur, idx = {}, None, -1
    for ln in open(path, encoding="latin-1"):
        ln = ln.split(";")[0].strip()
        if not ln:
            continue
        if ln.startswith("["):
            idx += 1
            cur = idx
            out[cur] = 0
        elif "=" in ln and cur is not None:
            t = ln.split("=", 1)[1].strip()
            out[cur] += 1 if t in ("int", "float") else 2
    return out


REFS = os.environ.get("UMD_REFS_DIR", os.path.join(HERE, "..", "..", "..", "umd_repos"))
_DATA = os.path.join(REFS, "RCOMage", "data")
OBJ_WORDS = ini_extra_words(os.path.join(_DATA, "objattribdef-psp.ini")) if os.path.isdir(_DATA) else {}
ANIM_WORDS = ini_extra_words(os.path.join(_DATA, "animattribdef-psp.ini")) if os.path.isdir(_DATA) else {}


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def cstr16(b, o, end):
    s = bytearray()
    while o + 1 < end:
        c = b[o:o + 2]
        if c == b"\0\0":
            break
        s += c
        o += 2
    return s.decode("utf-16-le", "replace")


def parse_vsmx(b, base):
    """-> a dict of one VSMX script at b[base:]"""
    sig, ver, co, cl, to, tl, tn, po, pl, pn, no, nl, nn = struct.unpack_from("<13I", b, base)
    out = {"version": ver, "code_bytes": cl, "instructions": cl // 8, "text_entries": tn, "text_bytes": tl,
           "prop_entries": pn, "prop_bytes": pl, "name_entries": nn, "name_bytes": nl}

    def table16(off, ln):
        o, e, res = base + off, base + off + ln, []
        while o < e:
            s = cstr16(b, o, e)
            res.append(s)
            o += (len(s.encode("utf-16-le")) + 2)
        return res

    def table8(off, ln):
        raw = bytes(b[base + off:base + off + ln])
        return [x.decode("latin-1") for x in raw.split(b"\0")[:-1]] if raw else []

    text, prop, names = table16(to, tl), table16(po, pl), table8(no, nl)
    ops = collections.Counter()
    unknown = collections.Counter()
    used_names, used_props = collections.Counter(), collections.Counter()
    floats = ints = 0
    max_func_args = 0
    for i in range(cl // 8):
        gid, val = struct.unpack_from("<II", b, base + co + 8 * i)
        op = gid & 0xFF
        if op not in OPS:
            unknown[op] += 1
        ops[OPS.get(op, "0x%02x" % op)] += 1
        if op in NAME_OPS and val < len(names):
            used_names[names[val]] += 1
        elif op in PROP_OPS and val < len(prop):
            used_props[prop[val]] += 1
        if op == 0x27:
            floats += 1
        if op == 0x26:
            ints += 1
        if op == 0x2a:
            max_func_args = max(max_func_args, (gid >> 8) & 0xFF)
    out.update(ops=dict(ops), unknown_ops={"0x%02x" % k: v for k, v in unknown.items()},
               names=dict(used_names), props=dict(used_props), strings=len(text),
               max_string=max((len(t) for t in text), default=0), float_consts=floats, int_consts=ints,
               max_func_args=max_func_args, sample_text=text[:40])
    return out


def disasm(b, base):
    """-> text: one line per instruction, operands resolved (the census's reading aid for M0;
    RCOMage's own vsmxdec mis-reads the UTF-16 tables on Linux, where wchar_t is 4 bytes)"""
    sig, ver, co, cl, to, tl, tn, po, pl, pn, no, nl, nn = struct.unpack_from("<13I", b, base)

    def table16(off, ln):
        o, e, res = base + off, base + off + ln, []
        while o < e:
            t = cstr16(b, o, e)
            res.append(t)
            o += len(t.encode("utf-16-le")) + 2
        return res
    text, prop = table16(to, tl), table16(po, pl)
    raw = bytes(b[base + no:base + no + nl])
    names = [x.decode("latin-1") for x in raw.split(b"\0")[:-1]] if raw else []
    out = []
    for i in range(cl // 8):
        gid, val = struct.unpack_from("<II", b, base + co + 8 * i)
        op = gid & 0xFF
        nm = OPS.get(op, "0x%02x" % op)
        arg = ""
        if op in NAME_OPS:
            arg = names[val] if val < len(names) else "?%d" % val
        elif op in PROP_OPS:
            arg = "." + (prop[val] if val < len(prop) else "?%d" % val)
        elif op in TEXT_OPS or op == 0x46:
            arg = repr(text[val] if val < len(text) else "?%d" % val)
        elif op == 0x27:
            arg = repr(struct.unpack("<f", struct.pack("<I", val))[0])
        elif op in (0x26, 0x25, 0x47, 0x2d):
            arg = str(val)
        elif op == 0x2a:
            arg = "args=%d locals=%d start=%d" % ((gid >> 8) & 0xFF, (gid >> 24) & 0xFF, val)
        elif op in (0x39, 0x3a, 0x3b):
            arg = "-> %d" % val
        elif op in (0x3c, 0x3d, 0x3e):
            arg = "argc=%d" % val
        out.append("%6d  %-18s %s" % (i, nm, arg))
    return "\n".join(out) + "\n"


def walk(b, off, end, counts, depth=0, warn=None):
    """the entry at b[off]: record it, return the offset past it (its subentries included)"""
    tid, _z, lab, hsize, esize, nsub, nxt, _p, _par = struct.unpack_from("<HHIIIIIII", b, off)
    typ, table = tid & 0xFF, tid >> 8
    tname = TABLES.get(table, "t%d" % table)
    extra = 0
    rec = {"table": tname, "type": typ}
    if table == 2 and typ == 1:
        extra = 8
    elif table == 3 and typ == 1:
        lang, fmt, nidx = struct.unpack_from("<HHI", b, off + 0x28)
        extra = 8 + 12 * nidx
        counts["text_langs"][lang] += 1
        counts["text_strings_max"] = max(counts["text_strings_max"], nidx)
    elif table in (4, 5) and typ == 1:
        fmt, comp = struct.unpack_from("<HH", b, off + 0x28)
        extra = (nxt - 0x28) if nxt else (12 + (4 if comp else 0))
        counts["img_fmt" if table == 4 else "model_fmt"][(fmt, comp)] += 1
    elif table == 6 and typ == 1:
        fmt, ch = struct.unpack_from("<HH", b, off + 0x28)
        extra = 12 + 8 * ch
        counts["sound_fmt"][(fmt, ch)] += 1
    elif table == 8 and typ > 0:
        extra = (esize - 0x28) if esize else 4 * OBJ_WORDS.get(typ, 0)
        counts["obj"][OBJ_TYPES[typ] if typ < len(OBJ_TYPES) else "obj%d" % typ] += 1
    elif table == 9 and typ > 0:
        extra = (nxt - 0x28) if (nxt and not nsub) else 4 * ANIM_WORDS.get(typ, 0)
        counts["anim"][ANIM_TYPES[typ] if typ < len(ANIM_TYPES) else "anim%d" % typ] += 1
    counts["entries"] += 1
    counts["max_depth"] = max(counts["max_depth"], depth)
    counts["max_children"] = max(counts["max_children"], nsub)
    o = off + 0x28 + extra
    for _ in range(nsub):
        if o + 0x28 > end:
            warn.append("subentry past the tree at 0x%x" % o)
            break
        o = walk(b, o, end, counts, depth + 1, warn)
    return off + nxt if nxt else o


def parse_rco(b):
    if b[:4] != b"\x00PRF":
        return {"error": "not an RCO"}
    ver, _n, comp = struct.unpack_from("<III", b, 4)
    f = struct.unpack_from("<37I", b, 16)
    r = {"version": "0x%x" % ver, "compression": comp >> 4, "umd_flag": comp & 0xF, "bytes": len(b)}
    tree = b
    if comp >> 4:
        # the tables from 0xA4 are packed: HeaderComprInfo {packed, unpacked, longest text}
        lp, lu, _lt = struct.unpack_from("<III", b, 0xA4)
        try:
            body = zlib.decompress(bytes(b[0xB0:0xB0 + lp]))
            tree = bytes(b[:0xA4]) + body
            r["unpacked"] = lu
        except Exception as e:  # RLZ, or unknown
            r["error"] = "tables packed (%s): %s" % (comp >> 4, e)
            return r
    counts = {"entries": 0, "max_depth": 0, "max_children": 0, "obj": collections.Counter(),
              "anim": collections.Counter(), "text_langs": collections.Counter(), "text_strings_max": 0,
              "img_fmt": collections.Counter(), "model_fmt": collections.Counter(),
              "sound_fmt": collections.Counter()}
    warn = []
    try:
        walk(tree, f[0], len(tree), counts, 0, warn)
    except struct.error as e:
        warn.append("tree walk: %s" % e)
    r["tree"] = {k: (dict((str(kk), vv) for kk, vv in v.items()) if isinstance(v, collections.Counter) else v)
                 for k, v in counts.items()}
    r["warnings"] = warn[:8]
    k = tree.find(b"VSMX")
    scripts = []
    while k >= 0:
        try:
            scripts.append(parse_vsmx(tree, k))
        except struct.error as e:
            r.setdefault("vsmx_errors", []).append(str(e))
        k = tree.find(b"VSMX", k + 4)
    r["vsmx"] = scripts
    return r


def census_one(img):
    import umd_iso
    out = {"disc": os.path.basename(img), "rco": {}}
    try:
        iso = umd_iso.UmdIso(img)
        try:
            names = [n for n in iso.listdir("/UMD_VIDEO/RESOURCE") if n.upper().endswith(".RCO")]
        except Exception:
            names = []
        out["resource_files"] = sorted(names)
        for n in sorted(names):
            b = iso.read("/UMD_VIDEO/RESOURCE/" + n, record=False)
            out["rco"][n] = parse_rco(b)
    except Exception as e:
        out["error"] = repr(e)
    return out


def summary(recs):
    s = {"discs": len(recs), "discs_with_menus": 0, "rco_files": 0, "compression": collections.Counter(),
         "version": collections.Counter(), "obj": collections.Counter(), "anim": collections.Counter(),
         "ops": collections.Counter(), "unknown_ops": collections.Counter(), "langs": collections.Counter(),
         "sound": collections.Counter(), "max": collections.defaultdict(lambda: (0, "")),
         "ident_discs": collections.Counter(), "prefixes": collections.Counter(), "first_files": collections.Counter()}

    def mx(k, v, where):
        if v > s["max"][k][0]:
            s["max"][k] = (v, where)
    for r in recs:
        if r.get("rco"):
            s["discs_with_menus"] += 1
        idents = set()
        files = r.get("resource_files", [])
        if files:
            s["first_files"][files[0]] += 1
        for n, rc in r.get("rco", {}).items():
            s["rco_files"] += 1
            s["prefixes"][n[:2].upper()] += 1
            s["compression"][rc.get("compression")] += 1
            s["version"][rc.get("version")] += 1
            where = "%s/%s" % (r["disc"], n)
            mx("rco_bytes", rc.get("bytes", 0), where)
            t = rc.get("tree", {})
            for k, v in t.get("obj", {}).items():
                s["obj"][k] += v
            for k, v in t.get("anim", {}).items():
                s["anim"][k] += v
            for k, v in t.get("text_langs", {}).items():
                s["langs"][k] += v
            for k, v in t.get("sound_fmt", {}).items():
                s["sound"][k] += v
            mx("tree_entries", t.get("entries", 0), where)
            mx("tree_depth", t.get("max_depth", 0), where)
            mx("children", t.get("max_children", 0), where)
            mx("text_strings", t.get("text_strings_max", 0), where)
            for v in rc.get("vsmx", []):
                for k, c in v["ops"].items():
                    s["ops"][k] += c
                for k, c in v["unknown_ops"].items():
                    s["unknown_ops"][k] += c
                mx("instructions", v["instructions"], where)
                mx("strings", v["strings"], where)
                mx("string_len", v["max_string"], where)
                mx("prop_entries", v["prop_entries"], where)
                mx("name_entries", v["name_entries"], where)
                mx("func_args", v["max_func_args"], where)
                idents.update(v["names"].keys())
                idents.update(v["props"].keys())
        for i in idents:
            s["ident_discs"][i] += 1
    return s


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("images", nargs="*")
    ap.add_argument("--iso-dir", default=os.environ.get("UMD_ISO_DIR", os.path.expanduser("~/umd-isos")))
    ap.add_argument("--out", default=os.path.join(HERE, "..", ".sim", "rco_census"))
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--disasm", metavar="DIR", help="write every script's disassembly to DIR/<disc>/<rco>.vsmx.txt")
    a = ap.parse_args(argv)
    if a.disasm:
        import umd_iso
        for img in (a.images or []):
            iso = umd_iso.UmdIso(img)
            d = os.path.join(a.disasm, os.path.basename(img))
            os.makedirs(d, exist_ok=True)
            for n in iso.listdir("/UMD_VIDEO/RESOURCE"):
                if n.upper().endswith(".RCO"):
                    b = iso.read("/UMD_VIDEO/RESOURCE/" + n, record=False)
                    k = b.find(b"VSMX")
                    if k >= 0:
                        with open(os.path.join(d, n + ".vsmx.txt"), "w") as f:
                            f.write(disasm(b, k))
            print("disassembled", d)
        return 0
    imgs = a.images or sorted(os.path.join(a.iso_dir, n) for n in os.listdir(a.iso_dir)
                              if n.lower().endswith(".iso"))
    os.makedirs(a.out, exist_ok=True)
    with multiprocessing.Pool(a.jobs) as pool:
        recs = list(pool.imap(census_one, imgs))
    for r in recs:
        with open(os.path.join(a.out, r["disc"] + ".json"), "w") as f:
            json.dump(r, f, indent=1, default=str)
    s = summary(recs)
    print("discs %d (with RESOURCE/*.RCO: %d), RCO files %d" % (s["discs"], s["discs_with_menus"], s["rco_files"]))
    print("versions %s; table compression %s; file prefixes %s" % (dict(s["version"]), dict(s["compression"]), dict(s["prefixes"])))
    print("first file (sorted) per disc: %s" % s["first_files"].most_common(8))
    print("text languages (RCO lang id: count) %s" % dict(s["langs"]))
    print("objects %s" % s["obj"].most_common())
    print("animations %s" % s["anim"].most_common())
    print("sounds (format, channels) %s" % dict(s["sound"]))
    print("opcodes %s" % s["ops"].most_common())
    print("UNKNOWN opcodes %s" % dict(s["unknown_ops"]))
    print("maxima:")
    for k, (v, w) in sorted(s["max"].items()):
        print("  %-14s %8d  (%s)" % (k, v, w))
    ids = s["ident_discs"].most_common()
    print("identifiers: %d distinct; on >= half the discs with menus:" % len(ids))
    half = max(1, s["discs_with_menus"] // 2)
    print("  " + ", ".join("%s(%d)" % kv for kv in ids if kv[1] >= half))
    with open(os.path.join(a.out, "_identifiers.tsv"), "w") as f:
        for k, v in ids:
            f.write("%s\t%d\n" % (k, v))
    return 0


if __name__ == "__main__":
    sys.exit(main())
