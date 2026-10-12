#!/usr/bin/env python3
"""The stream features a cosim window exercises, for run_cosim.sh --sample.

The census that --sample chooses from: for each disc window, which coding tools and
structures the decoder meets, read from the front end's record stream
(tools/h264_fe_ref.py decode_stream: the same syntax elements the RTL is fed, by name).
The RTL paths that a feature drives are exercised only on discs whose windows hold it,
so a sample that keeps every feature of the library keeps every such path.

    cosim_features.py STEM.es            print a window's features, one "name count" a line

What a feature list is NOT: content. Two discs with the same features differ in motion,
residuals and picture-edge references; that and throughput are why the sample also keeps
the slowest windows and why a full sweep stays the gate for a change that alters cycles
(bench/umd/run_cosim.sh, docs/h264_recon.md S5 "The sample").
"""

import collections
import sys

# mb_type as coded (Tables 7-11, 7-13, 7-14): the inter types by name; the intra types
# in a P or B slice are the I slice's, offset by 5 / 23
P_MB = {0: "16x16", 1: "16x8", 2: "8x16", 3: "8x8", 4: "8x8ref0"}
B_MB = {0: "direct16x16", 1: "L0_16x16", 2: "L1_16x16", 3: "Bi_16x16",
        4: "L0_L0_16x8", 5: "L0_L0_8x16", 6: "L1_L1_16x8", 7: "L1_L1_8x16",
        8: "L0_L1_16x8", 9: "L0_L1_8x16", 10: "L1_L0_16x8", 11: "L1_L0_8x16",
        12: "L0_Bi_16x8", 13: "L0_Bi_8x16", 14: "L1_Bi_16x8", 15: "L1_Bi_8x16",
        16: "Bi_L0_16x8", 17: "Bi_L0_8x16", 18: "Bi_L1_16x8", 19: "Bi_L1_8x16",
        20: "Bi_Bi_16x8", 21: "Bi_Bi_8x16", 22: "8x8"}
P_SUB = {0: "8x8", 1: "8x4", 2: "4x8", 3: "4x4"}
B_SUB = {0: "direct8x8", 1: "L0_8x8", 2: "L1_8x8", 3: "Bi_8x8", 4: "L0_8x4", 5: "L0_4x8",
         6: "L1_8x4", 7: "L1_4x8", 8: "Bi_8x4", 9: "Bi_4x8", 10: "L0_4x4", 11: "L1_4x4", 12: "Bi_4x4"}
ST = {0: "P", 1: "B", 2: "I", 3: "SP", 4: "SI"}


def intra_name(v):
    """an I-slice mb_type (0..25) as a feature name"""
    if v == 0:
        return "I4x4"
    if v == 25:
        return "PCM"
    return "I16x16"


def refs_bucket(n):
    return "1" if n <= 1 else "2" if n == 2 else "3-4" if n <= 4 else "5-8" if n <= 8 else "9+"


def features(rec):
    """a Counter of feature -> occurrences over one window's records"""
    f = collections.Counter()
    nal_t, nal_ref = None, 0
    pps = {}                       # pps id -> its fields
    cur_pps = None                 # the PPS being parsed (N 8)
    sh = {}                        # the slice header being parsed
    cur_type = "?"                 # the slice type in force (mb_type's meaning depends on it)
    ps_since_vcl = False           # a parameter set since the last slice
    qp = 26
    widths = set()
    structs = set()

    def slice_begin():
        nonlocal qp
        p = pps.get(sh.get("pic_parameter_set_id"), {})
        s = ST.get(sh["slice_type"] % 5, "?")
        f["slice:" + s] += 1
        field = sh.get("field_pic_flag", 0)
        struct = ("bottom" if sh.get("bottom_field_flag", 0) else "top") if field else "frame"
        structs.add("field" if field else "frame")
        f["pic:" + struct] += 1
        if nal_t == 5:
            f["idr"] += 1
            if not ps_since_vcl and sh.get("first_mb_in_slice", 0) == 0:
                f["idr_without_ps"] += 1       # Astro Boy: the sets sent once, before the title
        elif sh.get("first_mb_in_slice", 0) == 0 and s == "I":
            f["i_non_idr"] += 1
        if sh.get("first_mb_in_slice", 0) != 0:
            f["multi_slice"] += 1
        if s == "B" and nal_ref:
            f["B_ref"] += 1                    # a B picture used for reference (a pyramid)
        if s == "B":
            f["direct:" + ("spatial" if sh.get("direct_spatial_mv_pred_flag", 1) else "temporal")] += 1
        n0 = sh.get("num_ref_idx_l0_active_minus1", p.get("num_ref_idx_l0_default_active_minus1", 0)) + 1
        n1 = sh.get("num_ref_idx_l1_active_minus1", p.get("num_ref_idx_l1_default_active_minus1", 0)) + 1
        if s in ("P", "B"):
            f["refs_l0:" + refs_bucket(n0)] += 1
        if s == "B":
            f["refs_l1:" + refs_bucket(n1)] += 1
        if s == "P" and p.get("weighted_pred_flag", 0):
            f["wp:explicit_P"] += 1
        if s == "B" and p.get("weighted_bipred_idc", 0) == 1:
            f["wp:explicit_B"] += 1
        if s == "B" and p.get("weighted_bipred_idc", 0) == 2:
            f["wp:implicit_B"] += 1
        dbi = sh.get("disable_deblocking_filter_idc", 0)
        f["deblock_idc:%d" % dbi] += 1
        if dbi != 1 and (sh.get("slice_alpha_c0_offset_div2", 0) or sh.get("slice_beta_offset_div2", 0)):
            f["deblock_offsets"] += 1
        f["cabac_init:%d" % sh.get("cabac_init_idc", 0)] += 1
        if p.get("constrained_intra_pred_flag", 0):
            f["constrained_intra"] += 1
        if p.get("chroma_qp_index_offset", 0):
            f["chroma_qp_offset"] += 1
        qp = 26 + p.get("pic_init_qp_minus26", 0) + sh.get("slice_qp_delta", 0)

    for r in rec:
        k = r[0]
        if k == "N":
            _, t, ref = r.split()
            if sh:
                slice_begin()
                sh = {}
            nal_t, nal_ref = int(t), int(ref)
            if nal_t in (7, 8):
                f["nal:%s" % ("SPS" if nal_t == 7 else "PPS")] += 1
                ps_since_vcl = True
            if nal_t == 8:
                cur_pps = {}
            continue
        if k == "S":
            _, name, val = r.split(None, 2)
            try:
                v = int(val)
            except ValueError:
                continue
            if nal_t == 8:
                if name == "pic_parameter_set_id":
                    pps[v] = cur_pps
                cur_pps[name] = v
            elif nal_t == 7:
                if name == "pic_order_cnt_type":
                    f["poc_type:%d" % v] += 1
                elif name == "pic_width_in_mbs_minus1":
                    widths.add(v + 1)
                elif name == "frame_cropping_flag" and v:
                    f["crop"] += 1
                elif name == "direct_8x8_inference_flag" and not v:
                    f["direct_8x8_inference_off"] += 1
                elif name == "max_dec_frame_buffering":
                    f["vui_dpb:%d" % v] += 1
            elif nal_t in (1, 5):
                sh[name] = v
                if name == "slice_type":
                    cur_type = ST.get(v % 5, "?")
                elif name == "memory_management_control_operation" and v:
                    f["mmco:%d" % v] += 1
                elif name == "long_term_reference_flag" and v:
                    f["long_term_idr"] += 1
                elif name.startswith("modification_of_pic_nums_idc_l") and v != 3:
                    f["listmod:l%s:%d" % (name[-1], v)] += 1
                elif name == "pic_struct":
                    # the picture timing SEI's fields ride the slice they apply to (the front
                    # end interprets them with the SPS that slice activates, P5c)
                    f["pic_struct:%d" % v] += 1
            continue
        if k == "M":
            if sh:
                slice_begin()
                sh = {}
                ps_since_vcl = False
            continue
        if k == "E":
            _, name, val = r.split()
            v = int(val)
            if name == "mb_type":
                s = cur_type
                if s == "I":
                    nm = intra_name(v)
                elif s == "P":
                    nm = P_MB[v] if v < 5 else "intra_" + intra_name(v - 5)
                else:
                    nm = B_MB[v] if v < 23 else "intra_" + intra_name(v - 23)
                f["mb:%s:%s" % (s, nm)] += 1
                if nm.endswith("I16x16"):
                    f["i16_mode:%d" % ((v - {"I": 0, "P": 5, "B": 23}[s] - 1) % 4)] += 1
            elif name == "sub_mb_type":
                f["sub:%s:%s" % (cur_type, (P_SUB if cur_type == "P" else B_SUB)[v])] += 1
            elif name == "mb_skip_flag" and v:
                f["skip:" + cur_type] += 1
            elif name == "intra_chroma_pred_mode":
                f["chroma_pred:%d" % v] += 1
            elif name == "mb_qp_delta":
                qp = (qp + v + 52) % 52
                f["qp6:%d" % (qp // 6)] += 1
            continue
        if k == "B":
            f["blk:" + r.split()[1]] += 1
    if sh:
        slice_begin()
    if len(structs) == 2:
        f["paff"] += 1                         # frame and field pictures in one window
    for w in widths:
        f["width_mbs:%d" % w] += 1
    return f


def write(path, feats):
    with open(path, "w") as fh:
        for k in sorted(feats):
            fh.write("%s %d\n" % (k, feats[k]))


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1:
        print(__doc__.strip().split("\n\n")[1])
        return 2
    sys.path.insert(0, __import__("os").path.dirname(__file__))
    import h264_fe_ref as FE
    rec = FE.decode_stream(open(argv[0], "rb").read())
    for k, v in sorted(features(rec).items()):
        print("%s %d" % (k, v))
    return 0


if __name__ == "__main__":
    sys.exit(main())
