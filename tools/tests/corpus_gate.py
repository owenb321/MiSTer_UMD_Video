#!/usr/bin/env python3
"""Verdicts over a umd_census JSON (tools/tests/corpus_umd.sh). Every rule names what it
checks; a damaged image (zero-filled clips) is reported and exempted clip by clip, never
silently. Prints 'corpus_gate: ALL GREEN' only when every rule holds on every disc."""
import json
import sys

V = json.load(open(sys.argv[1]))
fails = []
notes = []


def need(ok, what):
    if not ok:
        fails.append(what)


for v in V:
    f = v["file"]
    if "error" in v:
        fails.append("%s: parser exception\n%s" % (f, v["error"]))
        continue
    need(not v["playlist_problems"], "%s: playlist verify %s" % (f, v["playlist_problems"][:2]))
    notes += ["%s: %s" % (f, n) for n in v["playlist_notes"]]
    need(not v["multi_extent"], "%s: multi-extent files %s" % (f, v["multi_extent"]))
    for c in v["clip_detail"]:
        tag = "%s clip %d" % (f, c["clip"])
        if c["zero_fraction"] > 0.5:
            notes.append("%s: DAMAGED image (%.0f %% zero sectors) -- exempt" % (tag, 100 * c["zero_fraction"]))
            continue
        need(c["acct_exact"] and not c["junk"], "%s: byte accounting (junk %d)" % (tag, c["junk"]))
        need(not c["unaligned_packs"], "%s: %d packs off the 2048 grid" % (tag, c["unaligned_packs"]))
        if c["has_clpi"]:
            need(not v["clpi"][str(c["clip"])]["verify"],
                 "%s: CLPI verify %s" % (tag, v["clpi"][str(c["clip"])]["verify"][:1]))
            ix = c.get("index", {})
            need(not ix.get("problems"), "%s: index packs %s" % (tag, ix.get("sample")))
        for t, a in c["audio"].items():
            need(a["resyncs"] == 0, "%s audio %s: %d resyncs" % (tag, t, a["resyncs"]))
            need("ff_fail" not in a, "%s audio %s: ffmpeg failed %s" % (tag, t, a.get("ff_fail")))
            need((a.get("ff_codec"), a.get("ff_rate"), a.get("ff_channels")) == ("atrac3p", 48000, 2),
                 "%s audio %s: ffmpeg says %s/%s/%s" % (tag, t, a.get("ff_codec"), a.get("ff_rate"),
                                                       a.get("ff_channels")))
            need(a.get("ff_samples_per_au") == 2048.0,
                 "%s audio %s: %s samples per AU" % (tag, t, a.get("ff_samples_per_au")))
            if "full_rc" in a:
                need(a["full_rc"] == 0 and a["full_samples"] == 2048 * a["full_aus"],
                     "%s audio %s: full decode rc %d, %d samples for %d AUs %s" % (
                         tag, t, a["full_rc"], a["full_samples"], a["full_aus"], a["full_errors"][:120]))
        for s, u in c["subs"].items():
            need(not (u["bad_png"] or u["truncated"] or u["overrun"] or u["orphan"]),
                 "%s sub %s: bad %d trunc %d overrun %d orphan %d" % (
                     tag, s, u["bad_png"], u["truncated"], u["overrun"], u["orphan"]))
        need(c["video_decode_errors"] == 0,
             "%s: %d ffmpeg video errors %s" % (tag, c["video_decode_errors"],
                                                c["video_decode_error_sample"][:1]))
        if c.get("video_missing_ref"):
            notes.append("%s: ffmpeg 'Missing reference picture' x%d (open GOPs; see "
                         "umd_census.EXPECTED_ERR)" % (tag, c["video_missing_ref"]))

for n in notes:
    print("note: " + n)
for x in fails:
    print("FAIL " + x)
print("corpus_gate: %d images, %s" % (len(V), "ALL GREEN" if not fails else "%d FAILURE(S)" % len(fails)))
sys.exit(1 if fails else 0)
