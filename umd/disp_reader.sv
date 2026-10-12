// umd/disp_reader.sv -- the display reader: a DPB store, straight from DDR3 on its own
// port (ram2), on the 720x480 raster (docs/display.md; born as the P4 smoke display,
// docs/h264_recon.md S4)
//
// WHICH picture is emu's business (until P5d the P4 smoke rule: the most recently
// completed one, decode order). A store of fields (pic_field: a field pair, or one field)
// holds them line-interleaved -- luma line y is field (y & 1)'s line y >> 1 -- and so
// does its chroma: chroma row c is field (c & 1)'s row c >> 1. Luma line y of a field
// store therefore takes chroma row 2 (y >> 2) + (y & 1), its OWN field's; a frame store
// takes row y >> 1. (The P4 smoke display took y >> 1 for both: on field content every
// other line pair showed the other field's colour -- chroma bleed on motion.)
//
// clk_sys side (the raster): at the first dot of every line, the display line TWO ahead is
// requested (a toggle across to clk_mem) into a ring of four line buffers (Y, Cb, Cr: one
// 64-bit word per 8 samples, dual-clock RAMs; the fetched line's chroma row travels with
// it), so the lines above (a), at (b) and below (d) the current one are all present: the
// deinterlacer's window (P5f, docs/display.md S8). Each plane has three copies written
// alike, one read port per window line. The window's samples go through the kernel, then
// BT.601 limited range -> RGB:
//   R = (298 C + 409 E + 128) >> 8, G = (298 C - 100 D - 208 E + 128) >> 8,
//   B = (298 C + 516 D + 128) >> 8     with C = Y - 16, D = Cb - 128, E = Cr - 128
// with LAT 4 dots from (h_pos, v_pos, de_in) to (r, g, b, de_out) -- xmb_wave's and
// the transport HUD's latency, so emu composes the three on one delayed sync.
// clk_mem side: the line's luma row (2W words) then its chroma rows (W words each, the
// row above) as read bursts of up to 8 words (a read-only master: DDRAM2).
// Addresses (docs/h264_recon.md S2.2): base + store << 17; Cb at 32 W HF, Cr at 40 W HF.
// Samples beyond the picture (a narrower or shorter one) are black.
//
// THE KERNEL (P5f, per channel on the line's own Y / Cb / Cr, i.e. after the field-aware
// chroma siting). Only a store of fields is ever filtered: a frame is b in every mode (film
// and progressive pass untouched; a frame-coded interlaced picture is shown woven -- H.264
// says which pictures are fields, so the deinterlacer never guesses).
//   Weave (mode 0, and 3)  b
//   Blend (mode 2)         (a + 2b + d + 1) >> 2     every line: half of each field, no comb
//   Bob   (mode 1)         keep field pic_parity: its lines b, the other field's lines
//                          (a + d + 1) >> 1 -- the kept lines above and below
// A SINGLE field (pic_single: unpaired, the store's other lines hold nothing of it) is
// bobbed on its own field in every mode. Blend's rounding is ffmpeg's `interlace`
// lowpass (vf_tinterlace, (1 + a + 2b + d) >> 2): its golden is that filter
// (tools/disp_golden.py). Edges MIRROR (a := d on line 0; d := a on the picture's last
// line), done by the read address: an interior line's balance of the two fields holds at
// the edges, and no line outside the picture is ever read. A picture taller than the
// raster (720x576, legal at Level 3.0) is clipped at line 479, whose d is the picture's
// real line 480 (fetched when the picture has it). The mode is latched once a frame
// (line 524), so a menu change never splits a picture.
//
// FIELD MATCHING (Forgejo fj#80, docs/telecine.md S5; 480p only, never in the window): hard-
// telecined film is 23.976 film coded as field pairs, the 3:2 baked in. disp_ctl's lock
// (umd/film_lock.sv) decides per refresh:
//   pic_match   weave the shown field (pic_parity) with the OTHER parity's lines of pic_pstore --
//               the request of a line of the other parity takes the partner store (req_alt): an
//               address choice, still one line fetched per raster line;
//   pic_film    1: a field pair shown woven (b) in every mode (a whole film frame); 2: the field
//               pic_parity bobbed in every mode (the partner absent); 0: the menu's kernel.
// THE COMB SUMS (the lock's evidence), over what was fetched: at every 8th dot of the picture's
// lines on the 480p raster (no window), C += |2b - a - d| and R += |a - d| on the window's luma
// (the samples the kernel reads, edges mirrored alike) -- tools/telecine_ref.py's observe(),
// variant (8, 1). Latched at line 480 (cm_c, cm_r; cm_v: the refresh was a 480p field pair) for
// disp_ctl's pickup at line 500, and cleared.
//
// CHROMA INTERPOLATED (docs/display.md S12; the H264 core's "chroma at the identity", ported):
// nearest chroma repeats each 4:2:0 sample over its 2 x 2 block, a hard two-pixel colour step
// beside saturated detail that the HDMI scaler widens into bands. At H.264's default siting
// (chroma_sample_loc_type 0 -- every clip of the library: no UMD declares another) chroma is
// co-sited with even luma columns and centred between luma rows 2m and 2m + 1, so
//   horizontally (480p, and 480i Fit / Letterbox: column x is the picture's, one a pixel) an odd
//     column x is (c[x >> 1] + c[(x + 1) >> 1] + 1) >> 1, the picture's last column replicated --
//     on rows b / d the halves' right tap (Crop's DR_HB at weight 8/16: bit-exact), on row a
//     (the 480p kernels') the sample AHEAD, (x + 1) >> 1 clamped, its left neighbour the
//     previous dot's read (480p: one dot a clock);
//   vertically (480p, a FRAME store only) row 2m = (3 h[m] + h[m - 1] + 2) >> 2, row 2m + 1 =
//     (3 h[m] + h[m + 1] + 2) >> 2: the neighbour is row a's chroma on an even line, row d's on
//     an odd one -- both in the ring; the chroma d copy reads row a's slot on an even line (a frame
//     store's kernel is b, so nothing else reads it), and the edges' mirror makes it row m itself.
// Crop and the video window keep their own taps (their positions are fractional). No RAM, no
// multiplier, LAT unchanged.
//
// A FIELD STORE'S VERTICAL STEP (docs/display.md S13): a field store's rows a / d are the OTHER
// field's, so its line's vertical neighbour -- its OWN field's chroma row above (an even field line
// 2m: row m - 1) or below (an odd one 2m + 1: row m + 1), the field's first / last row itself -- is
// two frame lines away, a line the ring of four no longer (or not yet) holds. So the 480p fetch of a
// field store's line brings that row too (req_nb: planes 3 / 4, the set-up run a second time; the
// store row is the line's own +- 2, or the same at the field's edges), into the neighbour RAMs beside
// the line's slot (even / odd halves, row b's addresses). Where the line is shown as stored -- Weave
// and the film weave, i.e. kernel b and not a bob -- its chroma is blended with it at H.264's field
// siting (Figure E-1: a field's row m a quarter / three quarters of the way down its line pair, the
// progressive positions): 7/8 + 1/8 on the line nearer its row, 5/8 + 3/8 on the other. Bob and
// Blend keep their kernels on the horizontal rows.
// 480i and the window fetch no neighbour (+4 M10K; a field title's 480p line reads 2W words more).
//
// 480i (`il`, docs/analog.md S2-S3): h_pos counts DOTS (a pixel is two: x = h_pos >> 1) and
// v_pos is the frame line {field line i, raster parity q}. The deinterlacer is off (a CRT
// interlaces; HDMI's ascal weaves or bobs). Each output line is built from SOURCE FIELD
// LINES of one parity ps -- source field line s is store line 2s + ps -- by a walker (s, k):
// the line shows source line s, or with k != 0 the average of s and s + 1, (a + d + 1) >> 1
// (the 480p Bob's rebuilt line). ps is the raster field's parity, except for a single field
// (pic_single) and a paused pair (pic_still): one field on both raster fields (V7), the other
// raster field's lines rebuilt half a line between the kept ones -- no stale lines, no
// bounce. The ring of four is indexed by source field line (slot s & 3); at the start of each
// line the lines the NEXT line needs that are not yet in it are requested (0..2: S2's
// Letterbox advances 4/3 of a line a line), and each field's last blank line requests the
// next field's first lines. Lines past the picture's last field line are clamped (mirrored).
//
// ANALOG ASPECT (S2, docs/analog.md V8-V10; 480i only, a 720x480 picture only -- any other is
// Fit; the mode latched at each field's set-up). The walker is incremental: its position N
// in sixths of a source field line starts each field (Fit / Crop: 3 (q - ps); Letterbox:
// 4q - 3ps at field line 30, the band's first) and steps 6 (Fit, Crop) or 8 (Letterbox: 4/3
// of a line) a line; N < 0 reads line 0 alone. Letterbox shows field lines 30..209 (black, de
// 0, above and below); the weight of line s + 1 is W[N mod 6] = 0 43 85 128 171 213 / 256,
// out = b + (((d - b) W + 128) >> 8) (W 128 = the (b + d + 1) >> 1 above, bit-exact). Crop
// stretches the centre 540 columns: column x samples source position 90 + 3x / 4 (Xq = 360 + 3x
// quarters), out = t0 + (((t1 - t0) f + 2) >> 2), f = Xq & 3, on each row BEFORE the vertical
// blend. Its two taps are one even and one odd sample, so the b / d line buffers are split in
// even- and odd-sample halves with their own addresses: both taps in one read.
//
// THE VIDEO WINDOW (P9, docs/p9.md §3.2 item 6; both rasters): `win` shows the picture scaled
// into the rectangle {win_x, win_y, win_w, win_h} (raster pixels / frame lines), black (de 0)
// around it, with the host's Q16 steps win_hs / win_vs and start positions win_x0 / win_y0
// (the UMD Main divides; the fabric multiplies). The steps are in the picture's FRAME rows (the
// host cannot know a store's kind: a field-coded title mixes frame and field pictures). The
// source is ROWS: a frame store's frame lines, a field store's KEPT field's (pic_parity: a window
// is small; a weave would comb) -- half as many, so a field store HALVES the position.
// Raster frame line Y in the window: A = y0 + (Y - wy) vs; a frame store's row s = A >> 16,
// weight f = A[15:12], a field store's s = A >> 17, f = A[16:13] -- sixteenths of row s + 1 (the
// last row: f 0). (Taken as field rows, a field-coded episode under a menu showed its field at
// 1:1 in the window's top half and its last line repeated below: the rig, Family Guy, 2026-10-02.)
// Column X: B = x0 + (X - wx) hs, t = B >> 16,
// g = B[15:12]. Each row is blended horizontally first (Crop's two taps, in sixteenths), then
// vertically (the 480i path's blend, its weight 16 f). At 480i a field shows the window's
// lines of its own parity. The walker runs at the end of each line's active dots (480p dot
// 720, 480i dot 1440) for the line after next; a downscale skips rows, so the ring's slots go
// in FETCH order (the last two rows fetched and their slots are remembered; a new row takes
// the oldest slot, never one the current line reads) -- at most two rows a line, the 480i
// path's rate. The geometry is latched once a frame (480p line 522, 480i field lines 259 /
// 260), not while the host is writing it (win_hold); a rectangle off the raster or empty is
// refused (win_bad: nothing shown). Rows up to 1,023 (a 720 x 576 picture's 576 lines).

`default_nettype none

module disp_reader #(
    parameter logic [28:0] DPB_BASE = 29'h0600_0000
) (
    // the raster (clk_sys)
    input  wire         clk,
    input  wire         rst_n,
    input  wire  [11:0] h_pos,
    input  wire  [11:0] v_pos,
    input  wire         de_in,
    input  wire         pic_valid,         // a picture has been decoded (quasi-static)
    input  wire  [4:0]  pic_store,         // its store (changes only between lines matter)
    input  wire         pic_field,         // the store holds fields (chroma rows per field)
    input  wire  [7:0]  pic_w_mbs,
    input  wire  [7:0]  pic_hf_mbs,
    input  wire         pic_parity,        // the field to show (P5e; Bob keeps it)
    input  wire         pic_single,        // the store holds ONE field (bobbed in every mode)
    input  wire  [1:0]  deint_mode,        // 0 Weave, 1 Bob, 2 Blend, 3 Weave (the menu, status[4:3])
    input  wire         pic_match,         // fj#80: the other parity's lines from pic_pstore (480p)
    input  wire  [4:0]  pic_pstore,
    input  wire  [1:0]  pic_film,          // fj#80: 0 the menu's kernel, 1 woven, 2 bobbed (pic_parity)
    input  wire         il,                // the 480i raster (docs/analog.md)
    input  wire         pic_still,         // 480i: the display is frozen (a paused pair shows one field)
    input  wire  [1:0]  aa_mode,           // 480i Analog Aspect (S2): 0 Fit, 1 Letterbox, 2 Crop (Auto resolved)
    // the video window (P9, above; latched once a frame)
    input  wire         win,
    input  wire         win_hold,          // the host is writing the geometry: keep the last one
    input  wire  [9:0]  win_x,
    input  wire  [9:0]  win_y,
    input  wire  [9:0]  win_w,
    input  wire  [9:0]  win_h,
    input  wire  [25:0] win_hs,            // Q10.16 source columns a raster pixel
    input  wire  [25:0] win_vs,            // Q10.16 source rows a raster frame line
    input  wire  [25:0] win_x0,            // Q10.16 the first window pixel's source column
    input  wire  [25:0] win_y0,            //   ... and the first window line's source row
    output logic        win_bad,           // the rectangle refused (empty, or off the raster)
    output logic [7:0]  r,
    output logic [7:0]  g,
    output logic [7:0]  b,
    output logic        de_out,            // the dot is inside the picture
    // fj#80: the comb sums of the last refresh (latched at line 480; see the header)
    output logic [24:0] cm_c,
    output logic [23:0] cm_r,
    output logic        cm_v,

    // DDR3 reads (clk_mem): a read-only master (emu: DDRAM2, ram2)
    input  wire         mclk,
    input  wire         mrst_n,
    output logic [28:0] ddr_address,
    output logic [7:0]  ddr_burstcount,
    output logic        ddr_read,
    input  wire         ddr_waitrequest,
    input  wire  [63:0] ddr_readdata,
    input  wire         ddr_readdatavalid,
    // the judder gate's independent half (clk_mem): the (store, parity) changes this
    // reader FETCHED, frame by frame (captured with line 0's request) -- disp_ctl counts
    // the ones it decided; over any span the two are equal (docs/display.md S7)
    output logic [31:0] fetch_changes
);

    // ---- the line buffers: a ring of 4 lines, Y 4 x 128 words, Cb / Cr 4 x 64 --------------
    // Three copies of each plane (a, b, d), written alike, each read at its own window line:
    // simple dual-clock RAMs (one read port each; M10K), never one array read three ways. The
    // b and d copies are split in EVEN- and ODD-sample halves (32 bits: 4 samples a word), each
    // with its own read address (Crop's two taps, S2); the a copy stays whole (the 480p kernel's).
    logic [63:0] ybuf_a [0:511];
    logic [31:0] ybe_b [0:511], ybo_b [0:511], ybe_d [0:511], ybo_d [0:511];
    logic [63:0] cbbuf_a [0:255];
    logic [31:0] cbe_b [0:255], cbo_b [0:255], cbe_d [0:255], cbo_d [0:255];
    logic [63:0] crbuf_a [0:255];
    logic [31:0] cre_b [0:255], cro_b [0:255], cre_d [0:255], cro_d [0:255];
    // (A FIELD STORE'S VERTICAL STEP) the neighbour row of each slot's line, even / odd halves
    logic [31:0] cbe_n [0:255], cbo_n [0:255], cre_n [0:255], cro_n [0:255];
    logic        lb_we_y, lb_we_cb, lb_we_cr, lb_we_cbn, lb_we_crn;
    logic [8:0]  lb_waddr;
    logic [63:0] lb_wdata;
    wire  [31:0] lb_we = {lb_wdata[55:48], lb_wdata[39:32], lb_wdata[23:16], lb_wdata[7:0]};    // samples 0 2 4 6
    wire  [31:0] lb_wo = {lb_wdata[63:56], lb_wdata[47:40], lb_wdata[31:24], lb_wdata[15:8]};   // samples 1 3 5 7
    always_ff @(posedge mclk) begin
        if (lb_we_y) begin
            ybuf_a[lb_waddr] <= lb_wdata;
            ybe_b[lb_waddr] <= lb_we; ybo_b[lb_waddr] <= lb_wo; ybe_d[lb_waddr] <= lb_we; ybo_d[lb_waddr] <= lb_wo;
        end
        if (lb_we_cb) begin
            cbbuf_a[lb_waddr[7:0]] <= lb_wdata;
            cbe_b[lb_waddr[7:0]] <= lb_we; cbo_b[lb_waddr[7:0]] <= lb_wo; cbe_d[lb_waddr[7:0]] <= lb_we; cbo_d[lb_waddr[7:0]] <= lb_wo;
        end
        if (lb_we_cr) begin
            crbuf_a[lb_waddr[7:0]] <= lb_wdata;
            cre_b[lb_waddr[7:0]] <= lb_we; cro_b[lb_waddr[7:0]] <= lb_wo; cre_d[lb_waddr[7:0]] <= lb_we; cro_d[lb_waddr[7:0]] <= lb_wo;
        end
        if (lb_we_cbn) begin cbe_n[lb_waddr[7:0]] <= lb_we; cbo_n[lb_waddr[7:0]] <= lb_wo; end
        if (lb_we_crn) begin cre_n[lb_waddr[7:0]] <= lb_we; cro_n[lb_waddr[7:0]] <= lb_wo; end
    end

    // ---- clk_sys: the requests and the read-out -----------------------------------------------
    // A request: {req_line, req_line1} (store lines; the second when req_n), into ring slots
    // req_slot and req_slot + 1; req_first marks a frame's (480i: a field's) first request,
    // where the fetched (store, parity) change is counted.
    logic        req_tog;
    logic [9:0]  req_line;                 // the first store line to fetch (10 bits: a window reads 576)
    logic [9:0]  req_line1;                // the second (480i, req_n)
    logic        req_n;                    // two lines
    logic [1:0]  req_slot;                 // the first line's ring slot
    logic        req_first;
    logic        req_alt;                  // fj#80: the line comes from the partner store (pic_pstore)
    logic        req_nb;                   // (S13) fetch the line's field neighbour chroma row too (480p, a field store)
    logic [1:0]  k_mode;                   // the deinterlace mode, latched once a frame
    // ---- the 480i walker (docs/analog.md S3; see the header): per field line j, the source
    // field line s, the weight k (sixths) of s + 1 and whether the line is shown (Letterbox's
    // band). The state (w_s signed, w_r = N mod 6, w_band) is the walker AT INDEX widx; the
    // per-line step at dot 1440 (the line's active dots are done) moves it one index on:
    // `cur` (this line's) <= `nxt`, `nxt` <= the walker one further, and the source lines it
    // needs that the ring lacks are requested (fetched during the coming line; while a line
    // reads slots s, s + 1, the fetch writes s + 2, s + 3). The field's set-up is two blank
    // lines before its line 0 (v_pos 521 / 522: the pickup at field line 250 is done): index 0
    // and its lines; the last blank line (523 / 524) steps to index 1.
    logic        f_q, f_ps;                // the field's raster parity, its source parity
    logic [1:0]  f_aa;                     // its Analog Aspect (0 Fit, 1 Letterbox, 2 Crop)
    logic [8:0]  f_last;                   // its last source field line (the picture's)
    logic [9:0]  f_have;                   // the next source line to fetch this field
    logic [8:0]  widx;                     // the walker's index
    logic signed [10:0] w_s;               // the walker: source line (may be -1 at the top)
    logic [2:0]  w_r;                      //   N mod 6
    logic        w_band;                   //   the line is shown
    logic [8:0]  cur_s, nxt_s;             // this line's s, the next line's (clamped)
    logic [2:0]  cur_k, nxt_k;             //   the weight of s + 1, sixths
    logic        cur_in, nxt_in;           //   shown
    wire  [10:0] fl     = v_pos[11:1];     // the field line
    wire         ini    = (v_pos == 12'd521 || v_pos == 12'd522);   // the next field's set-up
    wire         nq     = ~v_pos[0];       // (at the set-up) the next field's parity
    wire         n_ps   = (pic_single || (pic_still && pic_field)) ? pic_parity : nq;
    // field lines - 1 (hf x 8 - 1); a taller picture (> 511 field lines: only 240 are shown)
    // saturates, so the clamp below never wraps
    wire  [10:0] n_last_w = {pic_hf_mbs, 3'd0} - 11'd1;
    wire  [8:0]  n_last = (n_last_w[10:9] != 2'd0) ? 9'd511 : n_last_w[8:0];
    // the Analog Aspect a field takes: a 720x480 picture only
    wire  [1:0]  n_aa   = (pic_w_mbs == 8'd45 && pic_hf_mbs == 8'd30 && aa_mode != 2'd3) ? aa_mode : 2'd0;
    // the next walker state: at the set-up index 0, else index widx + 1
    wire         w_q    = ini ? nq : f_q;
    wire         w_ps   = ini ? n_ps : f_ps;
    wire  [1:0]  w_aa   = ini ? n_aa : f_aa;
    wire  [8:0]  w_last = ini ? n_last : f_last;
    wire  [8:0]  w_j    = ini ? 9'd0 : widx + 9'd1;
    logic signed [10:0] v_s; logic [2:0] v_r; logic v_band;
    logic signed [10:0] s0_s; logic [2:0] s0_r;   // the start: N0 = 3 (q - ps), or 4q - 3ps
    always_comb begin
        if (w_aa == 2'd1) begin
            case ({w_q, w_ps})                     // N0 = 4q - 3ps: 0, 1, 4, -3
                2'b00:   begin s0_s = 11'sd0;  s0_r = 3'd0; end
                2'b11:   begin s0_s = 11'sd0;  s0_r = 3'd1; end
                2'b10:   begin s0_s = 11'sd0;  s0_r = 3'd4; end
                default: begin s0_s = -11'sd1; s0_r = 3'd3; end
            endcase
        end else begin
            case ({w_q, w_ps})                     // N0 = 3 (q - ps): 0, 0, 3, -3
                2'b10:   begin s0_s = 11'sd0;  s0_r = 3'd3; end
                2'b01:   begin s0_s = -11'sd1; s0_r = 3'd3; end
                default: begin s0_s = 11'sd0;  s0_r = 3'd0; end
            endcase
        end
        v_s = w_s; v_r = w_r; v_band = w_band;
        if (w_aa == 2'd1) begin
            if (w_j == 9'd30)            begin v_s = s0_s; v_r = s0_r; v_band = 1'b1; end
            else if (w_j == 9'd210 || w_j == 9'd0) v_band = 1'b0;
            else if (w_band) begin                 // + 8 sixths
                if (w_r >= 3'd4) begin v_s = w_s + 11'sd2; v_r = w_r - 3'd4; end
                else             begin v_s = w_s + 11'sd1; v_r = w_r + 3'd2; end
            end
        end else begin
            v_band = 1'b1;
            if (w_j == 9'd0) begin v_s = s0_s; v_r = s0_r; end
            else             v_s = w_s + 11'sd1;      // + 6 sixths
        end
    end
    // clamped: a negative s reads line 0 alone; at the last field line, no line below
    wire  [9:0]  v_s0   = v_s[10] ? 10'd0 : v_s[9:0];
    wire         v_neg  = v_s[10];
    wire  [8:0]  v_sc   = (v_s0 >= {1'b0, w_last}) ? w_last : v_s0[8:0];
    wire  [2:0]  v_k    = (v_neg || v_s0 >= {1'b0, w_last}) ? 3'd0 : v_r;
    wire  [9:0]  w_need = {1'b0, v_sc} + {9'd0, v_k != 3'd0};       // the last line it needs
    wire  [9:0]  w_have = ini ? 10'd0 : f_have;                      // the next to fetch
    wire  [9:0]  w_hv1  = w_have + 10'd1;

    // ---- the video window (P9; see the header) ----------------------------------------------------
    // the geometry, latched once a frame (480p line 522, 480i field lines 259 / 260: after the
    // pickup, before the set-up), never while the host is writing it
    logic        fw_on, fw_kp, fw_fld;
    logic        fw_bad;                   // a refused rectangle: nothing shown (the refusal is visible)
    logic [9:0]  fw_x, fw_y, fw_w, fw_h, fw_lastr, fw_lastc;
    logic [25:0] fw_hs, fw_vs, fw_x0, fw_y0;
    wire  [10:0] wxe     = {1'b0, win_x} + {1'b0, win_w};
    wire  [10:0] wye     = {1'b0, win_y} + {1'b0, win_h};
    wire         w_ok    = (win_w != 10'd0) && (win_h != 10'd0) && (wxe <= 11'd720) && (wye <= 11'd480);
    assign       win_bad = win && !w_ok;
    wire         w_latch = (h_pos == 12'd0) && (il ? (v_pos == 12'd519 || v_pos == 12'd520) : (v_pos == 12'd522));
    // the source's last row (a frame store's lines, a field store's kept field's) and column
    wire  [11:0] w_rows1 = (pic_field ? {1'b0, pic_hf_mbs, 3'd0} : {pic_hf_mbs, 4'd0}) - 12'd1;
    wire  [11:0] w_cols1 = {pic_w_mbs, 4'd0} - 12'd1;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fw_on <= 1'b0; fw_bad <= 1'b0; fw_kp <= 1'b0; fw_fld <= 1'b0; fw_x <= '0; fw_y <= '0; fw_w <= '0; fw_h <= '0;
            fw_lastr <= '0; fw_lastc <= '0; fw_hs <= '0; fw_vs <= '0; fw_x0 <= '0; fw_y0 <= '0;
        end else if (w_latch && !win_hold) begin
            fw_on <= win && w_ok;
            fw_bad <= win && !w_ok;
            fw_x <= win_x; fw_y <= win_y; fw_w <= win_w; fw_h <= win_h;
            fw_hs <= win_hs; fw_vs <= win_vs; fw_x0 <= win_x0; fw_y0 <= win_y0;
            fw_kp <= pic_parity; fw_fld <= pic_field;
            fw_lastr <= (w_rows1[11:10] != 2'd0) ? 10'h3FF : w_rows1[9:0];
            fw_lastc <= w_cols1[9:0];
        end
    end
    // the walker: index wj is the line the NEXT step's `nxt` shows (480p: raster line wj; 480i:
    // field line wj of the field's parity wq). A = y0 + (Y - wy) vs: its row and sixteenths.
    logic        wq;
    logic [9:0]  wj;
    logic [9:0]  wl0, wl1;                 // the last two rows fetched (wl1 the latest) ...
    logic [1:0]  ws0, ws1, walloc;         // ... their ring slots, and the next slot to fill
    logic        wv0, wv1;
    logic [1:0]  cur_sb, cur_sd, nxt_sb, nxt_sd;   // the slots of rows s and s + 1
    logic [3:0]  cur_wf, nxt_wf;           // the weight of row s + 1, sixteenths
    logic        cur_wi, nxt_wi;           // the line is in the window
    wire         wini   = il ? ini : (v_pos == 12'd523);
    wire         wstep  = il ? (h_pos == 12'd1440 && (ini || v_pos == 12'd523 || v_pos == 12'd524 || fl < 11'd240))
                             : (h_pos == 12'd720  && (v_pos == 12'd523 || v_pos == 12'd524 || v_pos < 12'd479));
    wire  [9:0]  wj_n   = wini ? 10'd0 : wj + 10'd1;
    wire         wq_n   = wini ? nq : wq;
    wire  [9:0]  wY     = il ? {wj_n[8:0], wq_n} : wj_n;
    wire  [10:0] wYd    = {1'b0, wY} - {1'b0, fw_y};
    wire         w_in   = !wYd[10] && (wYd[9:0] < fw_h);
    wire  [35:0] wA     = {10'd0, fw_y0} + {26'd0, wYd[9:0]} * {10'd0, fw_vs};
    wire  [19:0] wA_r   = fw_fld ? {1'b0, wA[35:17]} : wA[35:16];     // the row: a field store halves
    wire  [3:0]  wA_f   = fw_fld ? wA[16:13] : wA[15:12];
    wire         w_cl   = (wA_r >= {10'd0, fw_lastr});
    wire  [9:0]  wn_s   = w_cl ? fw_lastr : wA_r[9:0];
    wire  [3:0]  wn_f   = w_cl ? 4'd0 : wA_f;
    wire  [9:0]  wn_s1  = wn_s + 10'd1;
    wire         wv0n   = !wini && wv0;    // (a frame starts with nothing remembered)
    wire         wv1n   = !wini && wv1;
    wire         h1_s   = wv1n && (wl1 == wn_s);
    wire         hit_s  = h1_s || (wv0n && (wl0 == wn_s));
    wire  [1:0]  sl_s   = h1_s ? ws1 : ws0;
    wire         h1_s1  = wv1n && (wl1 == wn_s1);
    wire         hit_s1 = h1_s1 || (wv0n && (wl0 == wn_s1));
    wire  [1:0]  sl_s1  = h1_s1 ? ws1 : ws0;
    wire  [1:0]  wal    = wini ? 2'd0 : walloc;
    wire  [1:0]  wal1   = wal + 2'd1;
    wire  [9:0]  st_s   = fw_fld ? {wn_s[8:0], fw_kp} : wn_s;      // a row's store line
    wire  [9:0]  st_s1  = fw_fld ? {wn_s1[8:0], fw_kp} : wn_s1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_tog <= 1'b0; req_line <= '0; req_line1 <= '0; req_n <= 1'b0; req_slot <= '0; req_first <= 1'b0;
            req_alt <= 1'b0; req_nb <= 1'b0;
            k_mode <= 2'd0;
            f_q <= 1'b0; f_ps <= 1'b0; f_aa <= 2'd0; f_last <= '0; f_have <= '0; widx <= '0;
            w_s <= '0; w_r <= '0; w_band <= 1'b0;
            cur_s <= '0; nxt_s <= '0; cur_k <= '0; nxt_k <= '0; cur_in <= 1'b0; nxt_in <= 1'b0;
            wq <= 1'b0; wj <= '0; wl0 <= '0; wl1 <= '0; ws0 <= '0; ws1 <= '0; walloc <= '0; wv0 <= 1'b0; wv1 <= 1'b0;
            cur_sb <= '0; cur_sd <= '0; nxt_sb <= '0; nxt_sd <= '0; cur_wf <= '0; nxt_wf <= '0; cur_wi <= 1'b0; nxt_wi <= 1'b0;
        end else if (fw_on) begin
            // ---- the video window: both rasters ----
            req_alt <= 1'b0; req_nb <= 1'b0;
            if (wstep) begin
                if (wini) wq <= nq;
                else begin cur_sb <= nxt_sb; cur_sd <= nxt_sd; cur_wf <= nxt_wf; cur_wi <= nxt_wi; end
                wj <= wj_n; nxt_wi <= w_in; nxt_wf <= wn_f;
                req_first <= wini;
                if (wini) begin wv0 <= 1'b0; wv1 <= 1'b0; walloc <= 2'd0; end
                if (w_in && !hit_s) begin
                    // row s (and s + 1) new: the oldest slots
                    req_line <= st_s; req_line1 <= st_s1; req_n <= (wn_f != 4'd0); req_slot <= wal; req_tog <= !req_tog;
                    nxt_sb <= wal; nxt_sd <= (wn_f != 4'd0) ? wal1 : wal;
                    if (wn_f != 4'd0) begin
                        wl0 <= wn_s; ws0 <= wal; wl1 <= wn_s1; ws1 <= wal1; wv0 <= 1'b1; wv1 <= 1'b1; walloc <= wal + 2'd2;
                    end else begin
                        wl0 <= wl1; ws0 <= ws1; wv0 <= wv1n; wl1 <= wn_s; ws1 <= wal; wv1 <= 1'b1; walloc <= wal1;
                    end
                end else if (w_in && wn_f != 4'd0 && !hit_s1) begin
                    // row s held, s + 1 new
                    req_line <= st_s1; req_n <= 1'b0; req_slot <= wal; req_tog <= !req_tog;
                    nxt_sb <= sl_s; nxt_sd <= wal;
                    wl0 <= wl1; ws0 <= ws1; wv0 <= wv1n; wl1 <= wn_s1; ws1 <= wal; wv1 <= 1'b1; walloc <= wal1;
                end else begin
                    nxt_sb <= sl_s; nxt_sd <= (wn_f != 4'd0) ? sl_s1 : sl_s;
                    // nothing to fetch at the set-up: still count the frame's change (fetch_changes)
                    if (wini) begin req_n <= 1'b0; req_line <= 10'h3FF; req_tog <= !req_tog; end
                end
            end
        end else if (!il) begin
            if (h_pos == 12'd0) begin
                // the line two after this one (the blank lines 523 and 524 fetch lines 0 and 1;
                // the last, 480 -- the clipped line 479's d, fetched only when the picture has
                // it -- at 478: before the line-500 release, disp_ctl)
                req_n <= 1'b0;
                req_nb <= pic_field;           // (S13) a field store's line brings its neighbour row
                // fj#80: a line of the other parity than the shown field's comes from the partner
                if (v_pos == 12'd523) begin
                    req_line <= 10'd0; req_slot <= 2'd0; req_first <= 1'b1; req_tog <= !req_tog;
                    req_alt <= pic_match && pic_parity;
                end else if (v_pos == 12'd524) begin
                    req_line <= 10'd1; req_slot <= 2'd1; req_first <= 1'b0; req_tog <= !req_tog; k_mode <= deint_mode;
                    req_alt <= pic_match && !pic_parity;
                end else if (v_pos < 12'd479) begin
                    req_line <= {1'b0, v_pos[8:0]} + 10'd2; req_slot <= v_pos[1:0] + 2'd2; req_first <= 1'b0; req_tog <= !req_tog;
                    req_alt <= pic_match && (v_pos[0] != pic_parity);
                end
            end
        end else if (h_pos == 12'd1440 && (ini || v_pos == 12'd523 || v_pos == 12'd524 || fl < 11'd240)) begin
            req_alt <= 1'b0; req_nb <= 1'b0;
            if (ini) begin
                f_q <= nq; f_ps <= n_ps; f_aa <= n_aa; f_last <= n_last;
                k_mode <= deint_mode;          // (unused at 480i -- `kern` is the walker's -- but kept
                                               //  current, so a switch back to 480p and run_disp_reader's
                                               //  I2 see the menu's mode)
            end else begin
                cur_s <= nxt_s; cur_k <= nxt_k; cur_in <= nxt_in;
            end
            // the walker one index on (none past the field's 240 lines)
            if (ini || widx < 9'd239) begin
                w_s <= v_s; w_r <= v_r; w_band <= v_band; widx <= w_j;
                nxt_s <= v_sc; nxt_k <= v_k; nxt_in <= v_band;
                req_first <= ini;
                req_slot  <= w_have[1:0];
                req_line  <= {1'b0, w_have[7:0], w_ps};
                req_line1 <= {1'b0, w_hv1[7:0], w_ps};
                if (ini) f_have <= 10'd0;
                if (v_band && w_need >= w_have) begin
                    req_n <= (w_need > w_have); req_tog <= !req_tog;
                    f_have <= w_need + 10'd1;
                end else if (ini) begin
                    // nothing to fetch for line 0 (Letterbox's bar): still count the field's change
                    req_n <= 1'b0; req_line <= 10'h3FF; req_tog <= !req_tog;
                end
            end
        end
    end

    // the request crosses as {toggle, line} held for a whole line: the line is stable long
    // before the toggle is seen (two flops, then one more)
    logic [2:0]  m_tog;
    logic [9:0]  m_line_q, m_line1_q;
    logic        m_n_q, m_first;
    logic        m_nb_q;                   // (S13) the request asks for its field neighbour row
    logic [1:0]  m_slot_q;
    logic [4:0]  m_store;
    logic [7:0]  m_w, m_hf;
    logic        m_valid, m_field;
    logic        fc_seen, fc_par;
    logic [4:0]  fc_store;

    // read-out: stage 1 the RAM words, stage 2 the bytes + the kernel + C/D/E, stage 3 the
    // products, stage 4 the sums and the clip
    wire  [9:0]  x = il ? h_pos[10:1] : h_pos[9:0];      // the column (480i: a pixel is two dots)
    // the window's ring slots; the edges mirror by address (a := d on line 0, d := a on the
    // picture's last line)
    wire         top  = (v_pos == 12'd0);
    wire         last = (v_pos + 12'd1 >= {pic_hf_mbs, 4'd0});
    // (480i: b = a = source line s, d = s + 1 when the line blends, the walker's)
    wire  [1:0]  bk_b = fw_on ? cur_sb : il ? cur_s[1:0] : v_pos[1:0];
    wire  [1:0]  bk_a = il ? cur_s[1:0] : top  ? v_pos[1:0] + 2'd1 : v_pos[1:0] - 2'd1;
    wire  [1:0]  bk_d = fw_on ? cur_sd : il ? ((cur_k != 3'd0) ? cur_s[1:0] + 2'd1 : cur_s[1:0]) :
                        last ? v_pos[1:0] - 2'd1 : v_pos[1:0] + 2'd1;
    // this line's kernel (480p): 0 b, 1 the bob's rebuilt line (a + d + 1) >> 1, 2 the blend;
    // fj#80's film kernel overrides the menu's (woven: a whole film frame; bobbed: no partner)
    wire         film_w = (pic_film == 2'd1);
    wire         bob  = pic_field && (pic_single || pic_film == 2'd2 || (k_mode == 2'd1 && !film_w));
    wire  [1:0]  kern = (il || fw_on) ? 2'd0 :         // (480i, the window: the walker's blend, below)
                        !pic_field ? 2'd0 :
                        bob ? ((v_pos[0] == pic_parity) ? 2'd0 : 2'd1) :
                        (k_mode == 2'd2 && !film_w) ? 2'd2 : 2'd0;
    // the b / d rows' two taps: t0 (Crop: source column (360 + 3x) >> 2, else x) and t0 + 1,
    // one even and one odd sample -- the even half read at the even one, the odd at the odd
    wire         crop = il && (f_aa == 2'd2) && !fw_on;
    wire  [11:0] xq   = 12'd360 + {1'b0, x, 1'b0} + {2'd0, x};      // 360 + 3x, quarters
    // the window's column: B = x0 + (x - wx) hs (P9)
    wire  [10:0] wxd  = {1'b0, x} - {1'b0, fw_x};
    wire         wx_in = !wxd[10] && (wxd[9:0] < fw_w);
    wire  [35:0] wB   = {10'd0, fw_x0} + {26'd0, wxd[9:0]} * {10'd0, fw_hs};
    wire         wc_cl = (wB[35:16] >= {10'd0, fw_lastc});
    wire  [9:0]  t0   = fw_on ? (wc_cl ? fw_lastc : wB[25:16]) : crop ? xq[11:2] : x;
    // the weight of t0 + 1, sixteenths (Crop's quarters x 4: the same arithmetic)
    wire  [3:0]  hf_x = fw_on ? (wc_cl ? 4'd0 : wB[15:12]) : crop ? {xq[1:0], 2'b00} : 4'd0;
    wire  [9:0]  t_e  = t0 + {9'd0, t0[0]};                          // the even of {t0, t0 + 1}
    wire  [8:0]  c0   = t0[9:1];                                     // t0's chroma sample
    wire  [8:0]  c_e  = c0 + {8'd0, c0[0]};                          // the even of {c0, c0 + 1}
    // (CHROMA INTERPOLATED, the header) where chroma is interpolated horizontally (ch_h), an odd
    // column inside the picture (ch_x: its right tap exists), the frame's vertical step (ch_v);
    // row a's sample ahead, (x + 1) >> 1 clamped to the picture's last chroma sample
    wire         ch_h = !fw_on && !crop;
    wire         ch_x = ch_h && x[0] && ({2'd0, x} + 12'd1 < {pic_w_mbs, 4'd0});
    wire         ch_v = !il && !fw_on && !pic_field;
    wire  [10:0] ca_u = ({1'b0, x} + 11'd1) >> 1;
    wire  [10:0] ca_l = {pic_w_mbs, 3'd0} - 11'd1;
    wire  [8:0]  ca   = (ca_u > ca_l) ? ca_l[8:0] : ca_u[8:0];
    wire  [1:0]  bk_dc = (ch_v && !v_pos[0]) ? bk_a : bk_d;         // the chroma d copy's slot
    // (A FIELD STORE'S VERTICAL STEP) a field store's line shown as stored (Weave, the film weave);
    // not a bob's kept line. (kern 0 restates it: Blend's and the bob's rebuilt lines take their
    // kernel's chroma first in uk / vk.)
    wire         ch_f = !il && !fw_on && pic_field && !bob && (kern == 2'd0);
    logic [63:0] q_ya, q_cba, q_cra;
    logic [31:0] q_ybe, q_ybo, q_yde, q_ydo, q_cbbe, q_cbbo, q_cbde, q_cbdo, q_crbe, q_crbo, q_crde, q_crdo;
    logic [2:0]  s1_by, s1_bc;
    logic [1:0]  s1_le, s1_lo, s1_lce, s1_lco;
    logic [3:0]  s1_f, s1_wf, s1_fc;       // (s1_fc: chroma's horizontal weight, sixteenths)
    logic        s1_cx, s1_cv;             // (CHROMA INTERPOLATED) an odd column's blend; the frame's vertical step
    logic        s1_cf, s1_cfn;            // (S13) a field store's vertical step; the line nearer its row (7/8)
    logic [31:0] q_cbne, q_cbno, q_crne, q_crno;   // the line's neighbour row (row b's addresses)
    logic [7:0]  p_ua, p_va;               // row a's previous dot (the left neighbour of an odd column)
    logic        s1_win;
    logic        s1_t0o, s1_c0o;
    logic [2:0]  s1_wk;
    logic [1:0]  s1_k;
    logic        s1_in, s2_in, s3_in;
    logic        s1_cm;                    // fj#80: this dot is summed (stage 2)
    logic [24:0] acc_c;
    logic [23:0] acc_r;
    logic [3:0]  de_d;
    wire  in_pic = pic_valid && de_in && !fw_bad &&
                   (fw_on ? (wx_in && cur_wi) :                       // (P9: black around the window)
                    (({2'd0, x} < {pic_w_mbs, 4'd0}) && (v_pos < {pic_hf_mbs, 4'd0}) &&
                     (!il || cur_in)));                               // (Letterbox's bars: black)
    always_ff @(posedge clk) begin
        q_ya  <= ybuf_a[{bk_a, x[9:3]}];
        q_cba <= cbbuf_a[{bk_a, ca[8:3]}];                             // (the sample ahead: the header)
        q_cra <= crbuf_a[{bk_a, ca[8:3]}];
        q_ybe <= ybe_b[{bk_b, t_e[9:3]}];  q_ybo <= ybo_b[{bk_b, t0[9:3]}];
        q_yde <= ybe_d[{bk_d, t_e[9:3]}];  q_ydo <= ybo_d[{bk_d, t0[9:3]}];
        q_cbbe <= cbe_b[{bk_b, c_e[8:3]}]; q_cbbo <= cbo_b[{bk_b, c0[8:3]}];
        q_cbde <= cbe_d[{bk_dc, c_e[8:3]}]; q_cbdo <= cbo_d[{bk_dc, c0[8:3]}];
        q_crbe <= cre_b[{bk_b, c_e[8:3]}]; q_crbo <= cro_b[{bk_b, c0[8:3]}];
        q_crde <= cre_d[{bk_dc, c_e[8:3]}]; q_crdo <= cro_d[{bk_dc, c0[8:3]}];
        q_cbne <= cbe_n[{bk_b, c_e[8:3]}]; q_cbno <= cbo_n[{bk_b, c0[8:3]}];
        q_crne <= cre_n[{bk_b, c_e[8:3]}]; q_crno <= cro_n[{bk_b, c0[8:3]}];
    end
    // stage 2: the taps out of the halves (the lane: the sample's bits [2:1])
    wire  [7:0]  yb_e = q_ybe[8*s1_le +: 8],   yb_o = q_ybo[8*s1_lo +: 8];
    wire  [7:0]  yd_e = q_yde[8*s1_le +: 8],   yd_o = q_ydo[8*s1_lo +: 8];
    wire  [7:0]  ub_e = q_cbbe[8*s1_lce +: 8], ub_o = q_cbbo[8*s1_lco +: 8];
    wire  [7:0]  ud_e = q_cbde[8*s1_lce +: 8], ud_o = q_cbdo[8*s1_lco +: 8];
    wire  [7:0]  vb_e = q_crbe[8*s1_lce +: 8], vb_o = q_crbo[8*s1_lco +: 8];
    wire  [7:0]  vd_e = q_crde[8*s1_lce +: 8], vd_o = q_crdo[8*s1_lco +: 8];
    // t0's own sample (b, d: the 480p kernel's) and its right neighbour; chroma: t0's pixel's
    // and t0 + 1's (the same sample when t0 is even)
    wire  [7:0]  yb  = s1_t0o ? yb_o : yb_e,   yb1 = s1_t0o ? yb_e : yb_o;
    wire  [7:0]  yd  = s1_t0o ? yd_o : yd_e,   yd1 = s1_t0o ? yd_e : yd_o;
    wire  [7:0]  ub  = s1_c0o ? ub_o : ub_e,   ub1 = !s1_t0o ? ub : (s1_c0o ? ub_e : ub_o);
    wire  [7:0]  ud  = s1_c0o ? ud_o : ud_e,   ud1 = !s1_t0o ? ud : (s1_c0o ? ud_e : ud_o);
    wire  [7:0]  vb  = s1_c0o ? vb_o : vb_e,   vb1 = !s1_t0o ? vb : (s1_c0o ? vb_e : vb_o);
    wire  [7:0]  vd  = s1_c0o ? vd_o : vd_e,   vd1 = !s1_t0o ? vd : (s1_c0o ? vd_e : vd_o);
    // (S13) the neighbour row's two taps, as row b's
    wire  [7:0]  un_e = q_cbne[8*s1_lce +: 8], un_o = q_cbno[8*s1_lco +: 8];
    wire  [7:0]  vn_e = q_crne[8*s1_lce +: 8], vn_o = q_crno[8*s1_lco +: 8];
    wire  [7:0]  un  = s1_c0o ? un_o : un_e,   un1 = !s1_t0o ? un : (s1_c0o ? un_e : un_o);
    wire  [7:0]  vn  = s1_c0o ? vn_o : vn_e,   vn1 = !s1_t0o ? vn : (s1_c0o ? vn_e : vn_o);
    wire  [7:0]  ya = q_ya[8*s1_by +: 8];
    wire  [7:0]  ua = q_cba[8*s1_bc +: 8];
    wire  [7:0]  va = q_cra[8*s1_bc +: 8];
    // the 480i path: each row's horizontal blend (quarters), then the vertical one (sixths).
    // Every shift is on a SIGNED intermediate of its own (an unsigned operand in the same
    // expression would make the whole of it unsigned and >>> a logical shift); no N'() cast
    // (Quartus 17 miscompiles them).
    logic [7:0]  w6;
    always_comb begin
        case (s1_wk)
            3'd1: w6 = 8'd43;  3'd2: w6 = 8'd85;  3'd3: w6 = 8'd128;
            3'd4: w6 = 8'd171; 3'd5: w6 = 8'd213; default: w6 = 8'd0;
        endcase
        if (s1_win) w6 = {s1_wf, 4'd0};      // the window: sixteenths, x 16 (Q8)
    end
    logic [7:0]  hyb, hyd, hub, hud, hvb, hvd, hun, hvn, iy, iu, iv;
    logic signed [9:0]  dh;
    logic signed [13:0] ht, hs;
    logic signed [10:0] hsum;
    logic signed [17:0] pv, ps8;
    logic signed [10:0] vsum;
    // o = a + (((b - a) f + 8) >> 4), f in 0..15 sixteenths (no multiplier; Crop's quarters x 4);
    // f 8 is (a + b + 1) >> 1 exactly (CHROMA INTERPOLATED)
    `define DR_HB(o, a, b, f) begin dh = $signed({2'b0, b}) - $signed({2'b0, a}); \
        ht = (f[0] ? {{4{dh[9]}}, dh} : 14'sd0) + (f[1] ? {{3{dh[9]}}, dh, 1'b0} : 14'sd0) + \
             (f[2] ? {{2{dh[9]}}, dh, 2'b0} : 14'sd0) + (f[3] ? {dh[9], dh, 3'b0} : 14'sd0) + 14'sd8; \
        hs = ht >>> 4; hsum = $signed({3'b0, a}) + hs[10:0]; o = hsum[7:0]; end
    // o = a + (((b - a) w + 128) >> 8)
    `define DR_VB(o, a, b) begin pv = ($signed({2'b0, b}) - $signed({2'b0, a})) * $signed({1'b0, w6}); \
        ps8 = (pv + 18'sd128) >>> 8; vsum = $signed({3'b0, a}) + ps8[10:0]; o = vsum[7:0]; end
    always_comb begin
        `DR_HB(hyb, yb, yb1, s1_f) `DR_HB(hyd, yd, yd1, s1_f)
        `DR_HB(hub, ub, ub1, s1_fc) `DR_HB(hud, ud, ud1, s1_fc)
        `DR_HB(hvb, vb, vb1, s1_fc) `DR_HB(hvd, vd, vd1, s1_fc)
        `DR_HB(hun, un, un1, s1_fc) `DR_HB(hvn, vn, vn1, s1_fc)
        `DR_VB(iy, hyb, hyd) `DR_VB(iu, hub, hud) `DR_VB(iv, hvb, hvd)
    end
    `undef DR_HB
    `undef DR_VB
    // (CHROMA INTERPOLATED) row a's chroma at an odd column: (c[x >> 1] + c[(x + 1) >> 1] + 1) >> 1,
    // the left tap the previous dot's read; rows b / d are hub / hud (their weight s1_fc)
    wire  [8:0]  ua_s = {1'b0, p_ua} + {1'b0, ua} + 9'd1, va_s = {1'b0, p_va} + {1'b0, va} + 9'd1;
    wire  [7:0]  hua = s1_cx ? ua_s[8:1] : ua, hva = s1_cx ? va_s[8:1] : va;
    wire  [9:0]  yl = {2'd0, ya} + {1'd0, yb, 1'b0} + {2'd0, yd} + 10'd1;
    wire  [9:0]  ul = {2'd0, hua} + {1'd0, hub, 1'b0} + {2'd0, hud} + 10'd1;
    wire  [9:0]  vl = {2'd0, hva} + {1'd0, hvb, 1'b0} + {2'd0, hvd} + 10'd1;
    wire  [8:0]  ym = {1'd0, ya} + {1'd0, yd} + 9'd1;
    wire  [8:0]  um = {1'd0, hua} + {1'd0, hud} + 9'd1;
    wire  [8:0]  vm = {1'd0, hva} + {1'd0, hvd} + 9'd1;
    // (CHROMA INTERPOLATED) a frame store's vertical step: (3 b + n + 2) >> 2, n the neighbouring
    // chroma row (the d copy: row a's slot on an even line, row d's on an odd one)
    wire  [9:0]  uy = {1'b0, hub, 1'b0} + {2'd0, hub} + {2'd0, hud} + 10'd2;
    wire  [9:0]  vy = {1'b0, hvb, 1'b0} + {2'd0, hvb} + {2'd0, hvd} + 10'd2;
    // (S13) a field store's: H.264 Figure E-1 sites a field's chroma row m a quarter (top field) or
    // three quarters (bottom) of the way from its field line 2m to 2m + 1 -- the progressive positions,
    // field by field -- so the line nearer its row (field line parity = field parity: frame line bits
    // [1] == [0], s1_cfn) takes (7 own + n + 4) >> 3, the other (5 own + 3 n + 4) >> 3; n the line's
    // neighbour row, fetched with it
    wire  [10:0] uf = s1_cfn ? ({hub, 3'b000} - {3'd0, hub} + {3'd0, hun} + 11'd4)
                             : ({1'b0, hub, 2'b00} + {3'd0, hub} + {2'd0, hun, 1'b0} + {3'd0, hun} + 11'd4);
    wire  [10:0] vf = s1_cfn ? ({hvb, 3'b000} - {3'd0, hvb} + {3'd0, hvn} + 11'd4)
                             : ({1'b0, hvb, 2'b00} + {3'd0, hvb} + {2'd0, hvn, 1'b0} + {3'd0, hvn} + 11'd4);
    wire         two = il || s1_win;      // the walkers' two-tap path (480i, the window)
    // fj#80: one dot's comb terms, |2b - a - d| and |a - d| (the window's raw luma)
    wire signed [10:0] cm_s = $signed({2'b0, yb, 1'b0}) - $signed({3'b0, ya}) - $signed({3'b0, yd});
    wire  [10:0] cm_t = cm_s[10] ? -cm_s : cm_s;
    wire  [8:0]  cr_s = {1'b0, ya} - {1'b0, yd};
    wire  [7:0]  cr_t = cr_s[8] ? -cr_s[7:0] : cr_s[7:0];
    wire  [7:0]  yk = two ? iy : (s1_k == 2'd2) ? yl[9:2] : (s1_k == 2'd1) ? ym[8:1] : yb;
    wire  [7:0]  uk = two ? iu : (s1_k == 2'd2) ? ul[9:2] : (s1_k == 2'd1) ? um[8:1] : s1_cv ? uy[9:2] : s1_cf ? uf[10:3] : hub;
    wire  [7:0]  vk = two ? iv : (s1_k == 2'd2) ? vl[9:2] : (s1_k == 2'd1) ? vm[8:1] : s1_cv ? vy[9:2] : s1_cf ? vf[10:3] : hvb;
    logic signed [9:0]  c2, d2, e2;
    logic signed [19:0] p_c, p_ecr, p_dcb, p_dg, p_eg;
    logic signed [19:0] rr, gg, bb;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_by <= '0; s1_bc <= '0; s1_k <= '0; s1_in <= 1'b0;
            s1_le <= '0; s1_lo <= '0; s1_lce <= '0; s1_lco <= '0; s1_f <= '0; s1_t0o <= 1'b0; s1_c0o <= 1'b0; s1_wk <= '0; s2_in <= 1'b0; s3_in <= 1'b0; de_d <= '0;
            s1_wf <= '0; s1_win <= 1'b0;
            s1_fc <= '0; s1_cx <= 1'b0; s1_cv <= 1'b0; s1_cf <= 1'b0; s1_cfn <= 1'b0; p_ua <= '0; p_va <= '0;
            s1_cm <= 1'b0; acc_c <= '0; acc_r <= '0; cm_c <= '0; cm_r <= '0; cm_v <= 1'b0;
            c2 <= '0; d2 <= '0; e2 <= '0; p_c <= '0; p_ecr <= '0; p_dcb <= '0; p_dg <= '0; p_eg <= '0;
            r <= '0; g <= '0; b <= '0; de_out <= 1'b0;
        end else begin
            // stage 1 (the RAM read above) -- remember which bytes
            s1_by <= x[2:0]; s1_bc <= ca[2:0]; s1_k <= kern; s1_in <= in_pic;
            s1_le <= t_e[2:1]; s1_lo <= t0[2:1]; s1_lce <= c_e[2:1]; s1_lco <= c0[2:1];
            s1_t0o <= t0[0]; s1_c0o <= c0[0]; s1_f <= hf_x; s1_wk <= cur_k;
            s1_wf <= cur_wf; s1_win <= fw_on;
            s1_fc <= ch_h ? (ch_x ? 4'd8 : 4'd0) : hf_x; s1_cx <= ch_x; s1_cv <= ch_v; s1_cf <= ch_f; s1_cfn <= (v_pos[1] == v_pos[0]);
            p_ua <= ua; p_va <= va;              // (stage 2's row-a bytes: the next dot's left neighbour)
            s1_cm <= in_pic && !il && !fw_on && (x[2:0] == 3'd0);
            // fj#80: the comb sums (stage 2: the window's raw luma), latched at line 480
            if (!il && v_pos == 12'd480 && h_pos == 12'd0) begin
                cm_c <= acc_c; cm_r <= acc_r; acc_c <= '0; acc_r <= '0;
                cm_v <= pic_valid && pic_field && !pic_single && !fw_on;
            end else if (s1_cm) begin
                acc_c <= acc_c + {14'd0, cm_t};
                acc_r <= acc_r + {16'd0, cr_t};
            end
            if (il) cm_v <= 1'b0;
            // stage 2: the samples, through the kernel
            c2 <= $signed({2'b0, yk}) - 10'sd16;
            d2 <= $signed({2'b0, uk}) - 10'sd128;
            e2 <= $signed({2'b0, vk}) - 10'sd128;
            s2_in <= s1_in;
            // stage 3: the products
            p_c <= 20'sd298 * c2; p_ecr <= 20'sd409 * e2; p_dcb <= 20'sd516 * d2;
            p_dg <= 20'sd100 * d2; p_eg <= 20'sd208 * e2;
            s3_in <= s2_in;
            // stage 4: sums, clip
            rr = (p_c + p_ecr + 20'sd128) >>> 8;
            gg = (p_c - p_dg - p_eg + 20'sd128) >>> 8;
            bb = (p_c + p_dcb + 20'sd128) >>> 8;
            r <= !s3_in ? 8'd0 : (rr < 0) ? 8'd0 : (rr > 255) ? 8'd255 : rr[7:0];
            g <= !s3_in ? 8'd0 : (gg < 0) ? 8'd0 : (gg > 255) ? 8'd255 : gg[7:0];
            b <= !s3_in ? 8'd0 : (bb < 0) ? 8'd0 : (bb > 255) ? 8'd255 : bb[7:0];
            de_out <= s3_in;
        end
    end

    // ---- clk_mem: fetch the requested line ---------------------------------------------------
    // The picture fields and the line number cross from clk_sys as quasi-static values,
    // captured only when a request's toggle has crossed: the line was set with the toggle
    // (two or more mclk cycles earlier), the picture fields change at raster line 500 and
    // the next request comes at line 523. umd/umd.sdc bounds these captures (and every
    // synchroniser's first stage) instead of the 3.7 ns window the 27 / 90 MHz edges give.
    // The row addresses are computed in two setup cycles before the bursts (the multiply
    // in the burst loop missed 90 MHz by 1.7 ns).
    typedef enum logic [2:0] {F_IDLE, F_SETUP1, F_SETUP2, F_CMD, F_WAIT} fstate_t;
    fstate_t fs;
    logic [2:0]  plane;                    // 0 Y, 1 Cb, 2 Cr; (S13) 3 / 4 the neighbour row's Cb / Cr
    logic        f_nbp;                    // (S13) the set-up's second pass: the neighbour row
    logic [9:0]  f_line;
    logic [1:0]  f_slot;                   // its ring slot
    logic        f_more;                   // a second line follows (480i)
    logic        f_sec;                    // fetching the request's second line
    logic [8:0]  f_word;                   // next word to request in the plane row
    logic [8:0]  f_got;                    // words received of the plane row
    logic [8:0]  f_words;                  // words in the plane row
    logic [20:0] pm_r;                     // W * HF (macroblocks a plane)
    logic [28:0] ly_r, lc_r;               // the line's offset in the luma / chroma plane
    logic [28:0] rb_cb, rb_cr;             // the chroma rows' addresses
    logic [28:0] row_base;                 // the current plane row's first word
    wire  [28:0] store_base = DPB_BASE + {7'd0, m_store, 17'd0};
    wire  [8:0]  left = f_words - f_word;
    // the line's chroma row: its own field's (see the header) or the frame's
    wire  [8:0]  c_row_o = m_field ? {m_line_q[9:2], m_line_q[0]} : m_line_q[9:1];
    // (S13) a field store's neighbour row: field line k = line >> 1, its row m = k >> 1; an even k
    // takes row m - 1, an odd one m + 1, the field's first / last row itself (the last: 4 HF - 1)
    wire  [7:0]  nb_m   = m_line_q[9:2];
    wire  [9:0]  nb_lst = {m_hf, 2'b00} - 10'd1;
    wire  [7:0]  nb_r   = !m_line_q[1] ? ((nb_m == 8'd0) ? nb_m : nb_m - 8'd1) :
                          (({2'b00, nb_m} >= nb_lst) ? nb_m : nb_m + 8'd1);
    wire  [8:0]  c_row  = f_nbp ? {nb_r, m_line_q[0]} : c_row_o;
    wire  [28:0] rb_cb_w = store_base + {3'd0, pm_r, 5'd0} + lc_r;

    always_ff @(posedge mclk or negedge mrst_n) begin
        if (!mrst_n) begin
            m_tog <= '0; m_line_q <= '0; m_line1_q <= '0; m_n_q <= 1'b0; m_nb_q <= 1'b0; f_nbp <= 1'b0; m_first <= 1'b0; m_slot_q <= '0; m_store <= '0; m_w <= '0; m_hf <= '0; m_valid <= 1'b0; m_field <= 1'b0;
            fc_seen <= 1'b0; fc_par <= 1'b0; fc_store <= '0; fetch_changes <= '0;
            fs <= F_IDLE; plane <= '0; f_line <= '0; f_slot <= '0; f_more <= 1'b0; f_sec <= 1'b0; f_word <= '0; f_got <= '0; f_words <= '0;
            pm_r <= '0; ly_r <= '0; lc_r <= '0; rb_cb <= '0; rb_cr <= '0; row_base <= '0;
            ddr_address <= '0; ddr_burstcount <= 8'd1; ddr_read <= 1'b0;
            lb_we_y <= 1'b0; lb_we_cb <= 1'b0; lb_we_cr <= 1'b0; lb_we_cbn <= 1'b0; lb_we_crn <= 1'b0; lb_waddr <= '0; lb_wdata <= '0;
        end else begin
            m_tog <= {m_tog[1:0], req_tog};
            lb_we_y <= 1'b0; lb_we_cb <= 1'b0; lb_we_cr <= 1'b0; lb_we_cbn <= 1'b0; lb_we_crn <= 1'b0;
            // the words returning: into the plane's ring slot (line & 3)
            if (ddr_readdatavalid) begin
                lb_wdata <= ddr_readdata;
                lb_waddr <= (plane == 3'd0) ? {f_slot, f_got[6:0]} : {1'b0, f_slot, f_got[5:0]};
                lb_we_y <= (plane == 3'd0); lb_we_cb <= (plane == 3'd1); lb_we_cr <= (plane == 3'd2);
                lb_we_cbn <= (plane == 3'd3); lb_we_crn <= (plane == 3'd4);
                f_got <= f_got + 1'b1;
            end
            // a request crossed: capture it and the picture (stable, see above)
            if (m_tog[2] != m_tog[1]) begin
                m_line_q <= req_line; m_line1_q <= req_line1; m_n_q <= req_n; m_nb_q <= req_nb; m_slot_q <= req_slot; m_first <= req_first;
                m_store <= req_alt ? pic_pstore : pic_store; m_w <= pic_w_mbs; m_hf <= pic_hf_mbs; m_valid <= pic_valid;
                m_field <= pic_field;
                if (req_first && pic_valid) begin
                    if (!fc_seen || pic_store != fc_store || pic_parity != fc_par) fetch_changes <= fetch_changes + 32'd1;
                    fc_seen <= 1'b1; fc_store <= pic_store; fc_par <= pic_parity;
                end
            end
            case (fs)
                F_IDLE: if (m_tog[2] != m_tog[1]) begin fs <= F_SETUP1; f_sec <= 1'b0; f_nbp <= 1'b0; end
                F_SETUP1: begin
                    // (the request's fields were captured with the toggle, a cycle ago)
                    if (!f_sec && !f_nbp) begin f_slot <= m_slot_q; f_more <= m_n_q; end
                    if (m_valid && m_line_q < {m_hf, 4'd0}) begin
                        f_line <= m_line_q;
                        pm_r <= {13'd0, m_w} * {13'd0, m_hf};
                        ly_r <= {19'd0, m_line_q} * {20'd0, m_w, 1'b0};
                        lc_r <= {20'd0, c_row} * {21'd0, m_w};
                        fs <= F_SETUP2;
                    end else fs <= F_IDLE;
                end
                F_SETUP2: begin
                    // (S13) the neighbour pass skips luma: its Cb row first
                    row_base <= f_nbp ? rb_cb_w : store_base + ly_r;
                    rb_cb <= rb_cb_w;
                    rb_cr <= store_base + {3'd0, pm_r, 5'd0} + {5'd0, pm_r, 3'd0} + lc_r;
                    plane <= f_nbp ? 3'd3 : 3'd0; f_word <= '0; f_got <= '0; f_words <= f_nbp ? {1'b0, m_w} : {m_w, 1'b0};
                    fs <= F_CMD;
                end
                F_CMD: begin
                    // a command is held until accepted; the next one follows in the same cycle
                    if (!ddr_read || !ddr_waitrequest) begin
                        if (f_word < f_words) begin
                            ddr_read <= 1'b1;
                            ddr_address <= row_base + {20'd0, f_word};
                            ddr_burstcount <= (left > 9'd8) ? 8'd8 : left[7:0];
                            f_word <= f_word + ((left > 9'd8) ? 9'd8 : left);
                        end else begin
                            ddr_read <= 1'b0;
                            fs <= F_WAIT;
                        end
                    end
                end
                F_WAIT: begin
                    if (f_got == f_words) begin
                        if (plane == 3'd2 && m_nb_q && !f_nbp) begin
                            // (S13) the line's field neighbour row: the set-up again, its row
                            f_nbp <= 1'b1; fs <= F_SETUP1;
                        end else if (plane == 3'd2 || plane == 3'd4) begin
                            // the request's second line (480i): the same set-up, the next slot
                            f_nbp <= 1'b0;
                            if (f_more) begin
                                f_more <= 1'b0; f_sec <= 1'b1; f_slot <= f_slot + 2'd1; m_line_q <= m_line1_q; fs <= F_SETUP1;
                            end else fs <= F_IDLE;
                        end
                        else begin
                            row_base <= (plane == 3'd0) ? rb_cb : rb_cr;
                            plane <= plane + 1'b1; f_word <= '0; f_got <= '0; f_words <= {1'b0, m_w};
                            fs <= F_CMD;
                        end
                    end
                end
                default: fs <= F_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
