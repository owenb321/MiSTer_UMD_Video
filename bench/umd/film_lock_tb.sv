// bench/umd/film_lock_tb.sv -- umd/film_lock.sv, the cadence lock of field matching (Forgejo fj#80,
// docs/telecine.md), step by step against tools/telecine_ref.py's FilmLock: the vectors
// (`telecine_ref.py --vectors`) are the model's walk over a window's stores -- every step's
// inputs and the model's outputs after it. Between steps the inputs are scrambled for a few
// cycles with `step` low: nothing may change then.
// Plusargs: +vec=FILE the vectors; +arm=NAME the label of the PASS line.
// Arms (the FAIL label): [show] the coming refresh's choice; [lock] locked / slot / conf;
// [hold] a change without a step; [count] the vectors read (none, or a short file).
// PASS marker: "PASS: film_lock_tb".
`timescale 1ns/1ps
`default_nettype none
module film_lock_tb;
`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end
reg clk = 0;
always #18.5 clk = ~clk;
reg rst_n = 0, clr = 0, step = 0, pick = 0, np = 0, first = 0, prev_ok = 0, next_ok = 0, mv = 0;
reg [24:0] mc = 0; reg [23:0] mr = 0; reg [19:0] npix = 0;
wire [2:0] show, slot; wire locked; wire [3:0] conf;
film_lock dut (.clk(clk), .rst_n(rst_n), .clr(clr), .step(step), .pick(pick), .np(np), .first(first),
               .prev_ok(prev_ok), .next_ok(next_ok), .mv(mv), .mc(mc), .mr(mr), .npix(npix),
               .show(show), .locked(locked), .slot(slot), .conf(conf));
string vfile, arm;
integer fd, rc, n = 0, nlock = 0, i;
integer v_pick, v_np, v_first, v_prev, v_next, v_mv, v_c, v_r, v_npix, e_show, e_locked, e_slot, e_conf;
reg [7:0] op;
reg [2:0] h_show, h_slot; reg h_locked; reg [3:0] h_conf;
initial begin
    if (!$value$plusargs("vec=%s", vfile)) `FAIL("count", "+vec= missing")
    if (!$value$plusargs("arm=%s", arm)) arm = vfile;
    fd = $fopen(vfile, "r");
    if (fd == 0) `FAIL("count", {"cannot open ", vfile})
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk);
    while (!$feof(fd)) begin
        rc = $fscanf(fd, "%c %d %d %d %d %d %d %d %d %d %d %d %d %d\n", op, v_pick, v_np, v_first, v_prev, v_next, v_mv,
                     v_c, v_r, v_npix, e_show, e_locked, e_slot, e_conf);
        if (rc != 14) begin
            if (rc <= 0) break;
            `FAIL("count", $sformatf("line %0d: %0d fields", n + 1, rc))
        end
        @(negedge clk);
        if (op == "C") begin
            clr = 1;
        end else begin
            step = 1; pick = v_pick; np = v_np; first = v_first; prev_ok = v_prev; next_ok = v_next;
            mv = v_mv; mc = v_c; mr = v_r;
        end
        npix = v_npix;
        @(negedge clk);
        step = 0; clr = 0;
        n = n + 1;
        if (show !== e_show[2:0])
            `FAIL("show", $sformatf("%0s step %0d: show %0d, want %0d (locked %b slot %0d conf %0d)", arm, n, show, e_show,
                                    locked, slot, conf))
        if ({locked, slot, conf} !== {e_locked[0], e_slot[2:0], e_conf[3:0]})
            `FAIL("lock", $sformatf("%0s step %0d: locked %b slot %0d conf %0d, want %0d %0d %0d", arm, n, locked, slot, conf,
                                    e_locked, e_slot, e_conf))
        nlock = nlock + locked;
        // between steps: the inputs scrambled, step low -- the state must hold
        h_show = show; h_slot = slot; h_locked = locked; h_conf = conf;
        for (i = 0; i < 3; i++) begin
            pick = $random; np = $random; first = $random; prev_ok = $random; next_ok = $random; mv = $random;
            mc = $random; mr = $random;
            @(negedge clk);
            if ({show, slot, locked, conf} !== {h_show, h_slot, h_locked, h_conf})
                `FAIL("hold", $sformatf("%0s after step %0d: the state changed without a step", arm, n))
        end
    end
    if (n < 100) `FAIL("count", $sformatf("%0s: %0d steps read", arm, n))
    $display("film_lock_tb: %0s: %0d steps identical to the model, %0d locked", arm, n, nlock);
    $display("PASS: film_lock_tb");
    $finish;
end
endmodule
`default_nettype wire
