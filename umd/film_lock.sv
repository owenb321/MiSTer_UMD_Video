// umd/film_lock.sv -- the cadence lock of field matching (Forgejo fj#80, docs/telecine.md S3.2, S5):
// on hard-telecined film (23.976 film coded as 59.94 field pairs, the 3:2 baked in), which pairs
// hold two film frames, and so which field each refresh weaves with. clk_sys; one step per
// pickup (disp_ctl). tools/telecine_ref.py's FilmLock is the model, bit for bit
// (bench/umd/run_film_lock.sh scores every step against it).
//
// At every pickup, in this order:
//   1. the evidence of the refresh just shown (mv, mc, mr): disp_reader's sums over what it
//      fetched, C = sum |2b - a - d| and R = sum |a - d| on every 8th dot's luma. Its class:
//      COMBED  C >= COMB8/8 R and C >= FLOOR16/16 a summed dot (real motion)
//      CLEAN   C <= CLEAN8/8 R            else UNSURE
//      Locked, a shown weave (IN, PREV, NEXT; never a bobbed field) at C >= BRK8/8 R breaks the
//      lock at once. Unlocked (after that), an in-store refresh (FALLBACK, IN) records its class.
//   2. a new store (pick): acquisition on the store just left (its last in-store class) -- with
//      no phase, two COMBED stores in a row set it (they are slots 0, 1); at slots 0 / 1 a
//      COMBED one is the cycle's hit; at 2-4 a COMBED one resets the phase and the confidence,
//      an UNSURE one costs DN_SOFT; at slot 4 a cycle with a hit and nothing UNSURE counts UP,
//      and ENGAGE cycles lock. Then the slot steps if the new store continues the pairs (np),
//      else everything resets.
//   3. the coming refresh (`show`): locked at slot 0 / 1 -- the first field with the previous
//      store's second (PREV, if prev_ok), the second with the next store's first (NEXT, if
//      next_ok), else that field bobbed (BOB); locked at slot 2-4, the store woven (IN);
//      unlocked, FALLBACK (the Deinterlace setting: T2).
// The constants and their sources: docs/telecine.md S4.3. `clr` (a seek, the 480i raster, the
// mount) resets everything. No `function`, no N'(expr) cast (Quartus 17).

`default_nettype none

module film_lock #(
    parameter int COMB8   = 20,            // 2.5
    parameter int CLEAN8  = 10,            // 1.25
    parameter int BRK8    = 12,            // 1.5
    parameter int FLOOR16 = 16,            // 1.0 a summed dot
    parameter int UP      = 1,
    parameter int DN_SOFT = 2,
    parameter int ENGAGE  = 8,
    parameter int CONF_MAX = 15
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         clr,
    input  wire         step,              // a pickup
    input  wire         pick,              //   a new store is taken
    input  wire         np,                //   ... and it continues the pairs
    input  wire         first,             //   the coming refresh shows the store's first field
    input  wire         prev_ok,           //   the previous store is held, a partner
    input  wire         next_ok,           //   the queue's head is the next store, a partner
    input  wire         mv,                // the evidence: valid
    input  wire  [24:0] mc,                //   C
    input  wire  [23:0] mr,                //   R
    input  wire  [19:0] npix,              // the dots summed (min(16 hf, 480) x 2 w)
    output logic [2:0]  show,              // 0 FALLBACK, 1 IN, 2 PREV, 3 NEXT, 4 BOB
    output logic        locked,
    output logic [2:0]  slot,              // 7: no phase
    output logic [3:0]  conf
);

    localparam logic [2:0] S_FALL = 3'd0, S_IN = 3'd1, S_PREV = 3'd2, S_NEXT = 3'd3, S_BOB = 3'd4;
    localparam logic [2:0] NOPH = 3'd7;
    localparam logic [1:0] K_NONE = 2'd0, K_CLEAN = 2'd1, K_UNS = 2'd2, K_COMB = 2'd3;

    logic        hit, bad;
    logic [1:0]  prev_cls, last_cls;

    // the class of the evidence (constant multiplies: shifts and adds)
    wire  [31:0] c8   = {4'd0, mc, 3'd0};
    wire  [31:0] r_cb = {8'd0, mr} * COMB8;
    wire  [31:0] r_cl = {8'd0, mr} * CLEAN8;
    wire  [31:0] r_bk = {8'd0, mr} * BRK8;
    wire  [31:0] c16  = {3'd0, mc, 4'd0};
    wire  [31:0] p_fl = {12'd0, npix} * FLOOR16;
    wire         is_comb  = (c8 >= r_cb) && (c16 >= p_fl);
    wire         is_clean = (c8 <= r_cl);
    wire  [1:0]  cls      = is_comb ? K_COMB : is_clean ? K_CLEAN : K_UNS;
    wire         brk      = (c8 >= r_bk);

    // the step, in the model's order
    logic        n_locked, n_hit, n_bad;
    logic [3:0]  n_conf;
    logic [2:0]  n_slot, n_show;
    logic [1:0]  n_prev, n_last;
    always_comb begin
        n_locked = locked; n_conf = conf; n_slot = slot; n_hit = hit; n_bad = bad;
        n_prev = prev_cls; n_last = last_cls; n_show = show;
        // 1. the evidence
        if (mv) begin
            if (n_locked && (show == S_IN || show == S_PREV || show == S_NEXT) && brk) begin
                n_locked = 1'b0; n_conf = 4'd0; n_slot = NOPH;
            end
            if (!n_locked && (show == S_FALL || show == S_IN)) n_last = cls;
        end
        // 2. a new store
        if (pick) begin
            if (!n_locked && n_last != K_NONE) begin
                if (n_slot == NOPH) begin
                    if (n_last == K_COMB && n_prev == K_COMB) begin
                        n_slot = 3'd1; n_conf = 4'd0; n_hit = 1'b1; n_bad = 1'b0;
                    end
                end else if (n_slot == 3'd0 || n_slot == 3'd1) begin
                    if (n_last == K_COMB) n_hit = 1'b1;
                end else if (n_last == K_COMB) begin
                    n_conf = 4'd0; n_slot = NOPH;
                end else if (n_last == K_UNS) begin
                    n_bad = 1'b1;
                    n_conf = (n_conf > DN_SOFT) ? n_conf - DN_SOFT : 4'd0;
                end
                if (n_slot == 3'd4) begin
                    if (n_hit && !n_bad) n_conf = (n_conf + UP > CONF_MAX) ? CONF_MAX : n_conf + UP;
                    if (n_conf >= ENGAGE) n_locked = 1'b1;
                end
                n_prev = n_last;
            end else n_prev = K_NONE;
            n_last = K_NONE;
            if (np) begin
                if (n_slot != NOPH) begin
                    n_slot = (n_slot == 3'd4) ? 3'd0 : n_slot + 3'd1;
                    if (n_slot == 3'd0) begin n_hit = 1'b0; n_bad = 1'b0; end
                end
            end else begin
                n_locked = 1'b0; n_conf = 4'd0; n_slot = NOPH; n_prev = K_NONE;
            end
        end
        // 3. the coming refresh
        if (n_locked && (n_slot == 3'd0 || n_slot == 3'd1))
            n_show = first ? (prev_ok ? S_PREV : S_BOB) : (next_ok ? S_NEXT : S_BOB);
        else if (n_locked) n_show = S_IN;
        else n_show = S_FALL;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            locked <= 1'b0; conf <= '0; slot <= NOPH; hit <= 1'b0; bad <= 1'b0;
            prev_cls <= K_NONE; last_cls <= K_NONE; show <= S_FALL;
        end else if (clr) begin
            locked <= 1'b0; conf <= '0; slot <= NOPH; hit <= 1'b0; bad <= 1'b0;
            prev_cls <= K_NONE; last_cls <= K_NONE; show <= S_FALL;
        end else if (step) begin
            locked <= n_locked; conf <= n_conf; slot <= n_slot; hit <= n_hit; bad <= n_bad;
            prev_cls <= n_prev; last_cls <= n_last; show <= n_show;
        end
    end

endmodule

`default_nettype wire
