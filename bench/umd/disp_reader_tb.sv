// bench/umd/disp_reader_tb.sv -- umd/disp_reader.sv on the real raster (umd/sync_gen.sv)
// and a store in bench/umd/ddr_model.sv holding a random picture: every active dot of the
// frame after the first compared with tools/disp_golden.py's expected raster ({de, R, G, B}:
// the BT.601 conversion of the kernel's output, de 0 and black beyond the picture),
// including LAT 4 against the raster.
// Plusargs (run_disp_reader.sh sets them per arm):
//   +arm=NAME      the arm a failure is reported under (default rgb)
//   +want=FILE     the expected raster (default the frame's)
//   +small         the 480x272 store (W 30, HF 17); +tall the 720x576 one (W 45, HF 36,
//                  clipped at line 479); else 720x480 (W 45, HF 30)
//   +field         the store holds fields (pic_field)   +single  one field (pic_single)
//   +mode=N        deint_mode (0 Weave, 1 Bob, 2 Blend)  +parity=N  pic_parity
//   +il            the 480i raster (docs/analog.md): a whole FRAME (two fields) scored, every
//                  pixel on both of its dots; the deinterlacer off; the expected raster is the
//                  480p one by definition (Fit's fields woven back = the woven picture; one kept
//                  field's other lines = the Bob's rebuilt line, V7)
//   +still         pic_still (480i: a paused pair shows one field)
//   +win ...       the video window (P9): its geometry from disp_golden.py's disp_win_*.args;
//                  the want files disp_want_win_* (a frame store, or a field store's kept field)
//   +aa=N          aa_mode (480i Analog Aspect, S2: 0 Fit, 1 Letterbox, 2 Crop); the want files
//                  disp_want_il_* from tools/disp_golden.py's il_aspect
//   +match         fj#80 field matching: pic_match, the partner store 5 holding disp_store_m.hex (the
//                  other parity's lines; want disp_want_match0/1)   +film=N  pic_film (1 woven, 2 bobbed)
//   +cmc=N +cmr=N  the comb sums the reader must latch at line 480 of the scored frame
//                  (disp_cm_*.args); without them only cm_v is checked (a 480p field pair, not single,
//                  not the window)
// Arms: [match] fj#80's partner lines; [film] fj#80's kernel override; [comb] the comb sums / cm_v;
//   [rgb] frame, Weave; [field] pair, Weave; [pass] frame in Bob / Blend (untouched);
//   [il] 480i frame / pair (Blend asked: off); [ilsingle] 480i one field; [ilstill] 480i a
//   paused pair; [lb] / [crop] 480i Analog Aspect (S2);
//   [blend] pair, Blend; [bob] pair, Bob, either parity; [single] one field in Weave /
//   Blend (bobbed on its own parity); [count] a whole frame of 720 x 480 dots scored.
// PASS marker: "PASS: disp_reader_tb".
`timescale 1ns/1ps
module disp_reader_tb;
`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end
localparam [28:0] BASE = 29'h0600_0000;
reg clk = 0, mclk = 0;
always #18.519 clk = ~clk;       // 27 MHz
always #5.556 mclk = ~mclk;      // 90 MHz
reg rst_n = 0;
wire [11:0] h_pos, v_pos; wire pixel_en, hs, vs, hb, vb, ft, fld;
reg il = 1'b0, still = 1'b0;
reg [1:0] aa = 2'd0;
// P9: the video window (+win +wx= +wy= +ww= +wh= +hs= +vs= +x0= +y0=: tools/disp_golden.py's disp_win_*.args)
reg win = 1'b0; reg [9:0] wx = 0, wy = 0, ww = 0, wh = 0; reg [25:0] whs = 0, wvs = 0, wx0 = 0, wy0 = 0; wire wbad;
sync_gen sg (.clk(clk), .clk_en(1'b1), .rst_n(rst_n), .interlaced(il), .h_pos(h_pos), .v_pos(v_pos),
             .pixel_en(pixel_en), .h_sync(hs), .v_sync(vs), .h_blank(hb), .v_blank(vb), .frame_tick(ft), .field(fld), .ce_pix());
wire [7:0] r, g, b; wire de_out;
wire [28:0] ddr_address; wire [7:0] ddr_burstcount; wire ddr_read, ddr_waitrequest, ddr_readdatavalid;
wire [63:0] ddr_readdata; int unwritten;
reg field = 1'b0, single = 1'b0, parity = 1'b0;
reg [1:0] mode = 2'd0;
reg match = 1'b0; reg [1:0] film = 2'd0;
wire [24:0] cm_c; wire [23:0] cm_r; wire cm_v;
integer e_cmc = -1, e_cmr = -1;
reg [7:0] w_mbs = 8'd45, hf_mbs = 8'd30;
disp_reader #(.DPB_BASE(BASE)) dut (.clk(clk), .rst_n(rst_n), .h_pos(h_pos), .v_pos(v_pos), .de_in(pixel_en),
    .pic_valid(1'b1), .pic_store(5'd17), .pic_field(field), .pic_w_mbs(w_mbs), .pic_hf_mbs(hf_mbs),
    .pic_parity(parity), .pic_single(single), .deint_mode(mode), .pic_match(match), .pic_pstore(5'd5), .pic_film(film),
    .cm_c(cm_c), .cm_r(cm_r), .cm_v(cm_v), .il(il), .pic_still(still), .aa_mode(aa), .fetch_changes(),
    .win(win), .win_hold(1'b0), .win_x(wx), .win_y(wy), .win_w(ww), .win_h(wh), .win_hs(whs), .win_vs(wvs), .win_x0(wx0), .win_y0(wy0), .win_bad(wbad), .r(r), .g(g), .b(b), .de_out(de_out),
    .mclk(mclk), .mrst_n(rst_n), .ddr_address(ddr_address), .ddr_burstcount(ddr_burstcount), .ddr_read(ddr_read),
    .ddr_waitrequest(ddr_waitrequest), .ddr_readdata(ddr_readdata), .ddr_readdatavalid(ddr_readdatavalid));
ddr_model #(.BASE(BASE), .AW(22)) ddr (.clk(mclk), .rst_n(rst_n), .address(ddr_address), .burstcount(ddr_burstcount),
    .read(ddr_read), .write(1'b0), .writedata(64'd0), .byteenable(8'hFF), .waitrequest(ddr_waitrequest),
    .readdata(ddr_readdata), .readdatavalid(ddr_readdatavalid), .unwritten_reads(unwritten));
reg [63:0] store [0:131071];
reg [24:0] want [0:345599];
integer n = 0, frames = 0, nwords, iv;
string arm, wfile;
reg [11:0] hq [0:3]; reg [11:0] vq [0:3]; reg dq [0:3];
initial begin
    if (!$value$plusargs("arm=%s", arm)) arm = "rgb";
    if (!$value$plusargs("want=%s", wfile)) wfile = "bench/umd/fixtures/gen/disp_want_frame.hex";
    field  = $test$plusargs("field");
    single = $test$plusargs("single");
    il     = $test$plusargs("il");
    still  = $test$plusargs("still");
    if ($value$plusargs("aa=%d", iv)) aa = iv[1:0];
    win = $test$plusargs("win");
    if ($value$plusargs("wx=%d", iv)) wx = iv[9:0];
    if ($value$plusargs("wy=%d", iv)) wy = iv[9:0];
    if ($value$plusargs("ww=%d", iv)) ww = iv[9:0];
    if ($value$plusargs("wh=%d", iv)) wh = iv[9:0];
    if ($value$plusargs("hs=%d", iv)) whs = iv[25:0];
    if ($value$plusargs("vs=%d", iv)) wvs = iv[25:0];
    if ($value$plusargs("x0=%d", iv)) wx0 = iv[25:0];
    if ($value$plusargs("y0=%d", iv)) wy0 = iv[25:0];
    if ($value$plusargs("mode=%d", iv)) mode = iv[1:0];
    match = $test$plusargs("match");
    if ($value$plusargs("film=%d", iv)) film = iv[1:0];
    if ($value$plusargs("cmc=%d", iv)) e_cmc = iv;
    if ($value$plusargs("cmr=%d", iv)) e_cmr = iv;
    if ($value$plusargs("parity=%d", iv)) parity = iv[0];
    if ($test$plusargs("small")) begin
        w_mbs = 8'd30; hf_mbs = 8'd17;
        $readmemh("bench/umd/fixtures/gen/disp_store_s.hex", store);
    end else if ($test$plusargs("tall")) begin
        hf_mbs = 8'd36;
        $readmemh("bench/umd/fixtures/gen/disp_store_t.hex", store);
    end else
        $readmemh("bench/umd/fixtures/gen/disp_store.hex", store);
    $readmemh(wfile, want);
    nwords = w_mbs * hf_mbs * 48;                  // luma 32 W HF words, chroma 16 W HF
    for (int i = 0; i < nwords; i++) ddr.poke(BASE + {5'd17, 17'd0} + i, store[i]);   // store 17: the fifth store bit
    if (match) begin                               // fj#80: the partner, store 5
        $readmemh("bench/umd/fixtures/gen/disp_store_m.hex", store);
        for (int i = 0; i < nwords; i++) ddr.poke(BASE + {5'd5, 17'd0} + i, store[i]);
    end
    #100 rst_n = 1;
end
// the raster position LAT 4 dots ago
always @(posedge clk) begin
    hq[0] <= h_pos; vq[0] <= v_pos; dq[0] <= pixel_en;
    for (int i = 1; i < 4; i++) begin hq[i] <= hq[i-1]; vq[i] <= vq[i-1]; dq[i] <= dq[i-1]; end
end
always @(posedge clk) if (rst_n) begin
    if (ft) frames = frames + 1;
    // (480i: frame_tick is a field's; fields 3 and 4 are a whole frame after a settled one)
    if ((il ? (frames == 3 || frames == 4) : frames == 2) && dq[3]) begin
        integer idx;
        idx = vq[3] * 720 + (il ? hq[3][11:1] : hq[3]);
        if ({de_out, r, g, b} !== want[idx])
            `FAIL(arm, $sformatf("(%0d, %0d): de %b %h %h %h, want %h", hq[3], vq[3], de_out, r, g, b, want[idx]))
        n = n + 1;
    end
    // fj#80: the comb sums latched at line 480 of the scored frame (480p)
    if (!il && frames == 2 && v_pos == 12'd481 && h_pos == 12'd0) begin
        if (cm_v !== (field && !single && !win))
            `FAIL("comb", $sformatf("cm_v %b on a %0s", cm_v, field ? (single ? "single field" : "pair") : "frame"))
        if (e_cmc >= 0 && (cm_c !== e_cmc[24:0] || cm_r !== e_cmr[23:0]))
            `FAIL("comb", $sformatf("C %0d R %0d, want %0d %0d", cm_c, cm_r, e_cmc, e_cmr))
    end
    if (il && cm_v !== 1'b0) `FAIL("comb", "cm_v at 480i")
    if (win && (wbad !== $test$plusargs("bad")))
        `FAIL(arm, $sformatf("win_bad %b, want %b (the geometry's refusal)", wbad, $test$plusargs("bad")))
    if (frames == (il ? 5 : 3)) begin
        if (n !== (il ? 691200 : 345600)) `FAIL("count", $sformatf("%0d dots scored", n))
        $display("disp_reader_tb: %0d dots identical (%0dx%0d, %0s, mode %0d, parity %0d%0s%0s)", n, w_mbs * 16, hf_mbs * 16,
                 field ? "fields" : "frame", mode, parity, single ? ", single" : "", il ? (still ? ", 480i, still" : ", 480i") : "");
        $display("PASS: disp_reader_tb");
        $finish;
    end
end
endmodule
