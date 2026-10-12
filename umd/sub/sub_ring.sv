// umd/sub/sub_ring.sv -- the compressed-unit ring in DDR3 and its record queue
// (docs/subtitles.md §2; A7: the HPS reads the units, docs/hps_host.md §3.2)
//
// Why DDR3: the demultiplexer cannot be stalled (ps_demux sp_* has no ready), so a unit
// is buffered whole before it is decoded, and a unit's length field is u32. A ring of
// 2**RAW 64-bit words (default 2**20 = 8 MB) holds any PNG that fits the frame (720x480
// RGBA16 stored is ~2.8 MB); a unit that does not fit, or would exceed 2**MAW units in the
// ring, is refused at its header (u_accept low) and sub_unit counts it.
//
// Writer: bytes pack 8 to a word (the unit's byte 8k+i at bits [8i+7:8i] of its word k),
// every unit starts on a word; words gather into one of two 8-word burst buffers
// (ping-pong), handed to the DDR engine when full, at the unit's last word, or before the
// ring's end (a burst never wraps). u_abort rewinds the write pointer to the aborted unit's
// start and empties the filling buffer; a buffer already handed off is written anyway -- in
// order, before the words that overwrite it, so harmless. A unit's record enters the queue
// only once the buffer carrying its last word is IN DDR3, so the reader never reads a word
// not yet written.
//
// The reader is the HPS (A7, docs/hps_host.md §3.2): q_take (the scheduler, with the head
// record) makes the head unit OUTSTANDING -- its start word and length go out as the
// request (q_start / q_len, held) and rd_busy holds the queue until `done`, the host's
// accepted completion. Only then are the unit's words free (the tail advances): the host
// reads them from DDR3 until it completes, and freeing them at the request would let the
// demux overwrite bytes it has not read yet. One unit outstanding at a time.
// (Until A7 the fabric read the unit back to its own PNG decoder; that reader is gone.)
//
// DDR3: one Avalon master, writes only (sub_mem registers it). flush: input refused, the
// engine finishes a write burst in progress, then everything is empty (one cycle of
// flush_clr) and the outstanding unit is dropped (its completion will be ignored).

`default_nettype none

module sub_ring #(
    parameter logic [28:0] RING_BASE = 29'h0640_0000,
    parameter int          RAW = 20,        // log2 ring words
    parameter int          MAW = 6          // log2 units in the ring
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         flush,
    output logic        flushing,

    // from sub_unit
    input  wire         u_begin,
    input  wire  [31:0] u_len,
    input  wire  [31:0] u_words,            // u_len in words, rounded up (sub_unit registers it)
    output logic        u_accept,
    input  wire  [7:0]  u_byte,
    input  wire         u_valid,
    input  wire         u_last,
    output logic        u_ready,
    input  wire         u_abort,
    input  wire  [32:0] rec_pts,
    input  wire  [31:0] rec_dur,
    input  wire  [15:0] rec_x,
    input  wire  [15:0] rec_y,

    // the queue head, to the scheduler
    output logic        q_valid,
    output logic [32:0] q_pts,
    output logic [31:0] q_dur,
    output logic [15:0] q_x,
    output logic [15:0] q_y,
    output logic [31:0] q_len,
    output logic [RAW-1:0] q_start,         // the head unit's first word (ring-relative)
    input  wire         q_take,             // make the head unit outstanding (with q_valid)
    output logic        rd_busy,            // a unit is outstanding (taken, not yet done)
    input  wire         done,               // its accepted completion: its words are free

    // DDR3 (writes only)
    output logic [28:0] ddr_address,
    output logic [7:0]  ddr_burstcount,
    output logic        ddr_write,
    output logic [63:0] ddr_writedata,
    output logic [7:0]  ddr_byteenable,
    input  wire         ddr_waitrequest,

    output logic [MAW:0] n_units            // units in the ring (being written or queued)
);

    localparam int PW = RAW + 1;            // a ring pointer: word index + wrap bit
    localparam int RW = PW + 129;           // a record: {start, len 32, pts 33, dur 32, x 16, y 16}
    localparam logic [PW-1:0] RSIZE = {1'b1, {RAW{1'b0}}};

    // ---- pointers ---------------------------------------------------------------------------------
    logic [PW-1:0] wr_ptr, unit_start, tail;
    wire  [PW-1:0] used   = wr_ptr - tail;
    wire  [PW-1:0] free_w = RSIZE - used;
    wire  [31:0]   need_w = u_words;
    logic [MAW:0]  nunits;
    logic          flush_clr;
    assign n_units  = nunits;
    assign u_accept = !flushing && (nunits != {1'b1, {MAW{1'b0}}}) &&
                      ({{(32 - PW){1'b0}}, free_w} >= need_w);

    // ---- the packer and the two 8-word burst buffers ----------------------------------------------
    logic [63:0]   bbuf [0:15];             // buffer b is words [8b .. 8b+7]
    logic [63:0]   wacc;
    logic [2:0]    wbi;
    logic          fsel;                    // the buffer being filled
    logic [3:0]    fcnt;
    logic [RAW-1:0] faddr;
    logic [1:0]    bready, bend;
    logic [3:0]    bcnt0, bcnt1;
    logic [RAW-1:0] baddr0, baddr1;
    logic          wsel;                    // the engine's buffer (the older handed-off one)
    logic [31:0]   len_q;
    logic          commit, q_pop;           // (driven below)

    wire  [63:0]   wword    = wacc | ({56'd0, u_byte} << {wbi, 3'b000});
    wire           u_take   = u_valid && u_ready;
    wire           word_done = u_take && (wbi == 3'd7 || u_last);
    wire  [PW-1:0] wr_ptr_n = wr_ptr + {{RAW{1'b0}}, 1'b1};
    wire           close    = word_done && (fcnt == 4'd7 || u_last || wr_ptr_n[RAW-1:0] == '0);
    assign u_ready = !flushing && !bready[fsel];

    // ---- the record queue (and the two records waiting for their last word to land) ----------
    logic [RW-1:0] pend0, pend1;
    logic [1:0]    pend_n;
    wire  [RW-1:0] rec_in = {unit_start, len_q, rec_pts, rec_dur, rec_x, rec_y};
    logic [RW-1:0] q_head;
    /* verilator lint_off UNUSEDSIGNAL */
    logic          q_head_v, q_full;
    logic [MAW:0]  q_count;
    /* verilator lint_on UNUSEDSIGNAL */
    sub_q #(.DW(RW), .AW(MAW)) u_q (
        .clk, .rst_n, .clear (flush_clr), .din (pend0), .push (commit && !flushing), .full (q_full),
        .dout (q_head), .dout_valid (q_head_v), .pop (q_pop), .count (q_count)
    );
    wire  [PW-1:0] q_start_p = q_head[RW-1 -: PW];
    assign q_start = q_start_p[RAW-1:0];
    assign q_len   = q_head[128:97];
    assign q_pts   = q_head[96:64];
    assign q_dur   = q_head[63:32];
    assign q_x     = q_head[31:16];
    assign q_y     = q_head[15:0];
    assign q_valid = q_head_v && !rd_busy && !flushing;
    assign q_pop   = q_take && q_valid;
    /* verilator lint_off UNUSEDSIGNAL */      // a unit fits the ring: its words fit PW bits
    wire  [31:0]   q_words = (q_len >> 3) + {31'd0, (q_len[2:0] != 3'd0)};
    /* verilator lint_on UNUSEDSIGNAL */

    // ---- the outstanding unit ------------------------------------------------------------------------------
    logic [PW-1:0] r_end;                   // its end: the tail once it is done

    // ---- the DDR engine ---------------------------------------------------------------------------------
    typedef enum logic {E_IDLE, E_WRITE} estate_t;
    estate_t est;
    logic [3:0] beat;
    wire  [3:0] wcnt = wsel ? bcnt1 : bcnt0;
    always_comb begin
        ddr_address    = RING_BASE + {{(29 - RAW){1'b0}}, (wsel ? baddr1 : baddr0)};
        ddr_burstcount = {4'd0, wcnt};
        ddr_write      = (est == E_WRITE);
        ddr_writedata  = bbuf[{wsel, beat[2:0]}];
        ddr_byteenable = 8'hFF;
    end
    wire   wbeat   = ddr_write && !ddr_waitrequest;
    wire   wdone   = wbeat && (beat + 4'd1 == wcnt);
    assign commit  = wdone && bend[wsel];                 // a unit's last word is in DDR3
    wire   pend_ad = u_take && u_last;
    wire   release_ = done && rd_busy;                    // the host is done with it: its words are free
    wire   admit   = u_begin && u_accept;
    wire   quiet   = (est != E_WRITE);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr <= '0; unit_start <= '0; tail <= '0; nunits <= '0;
            wbi <= '0; wacc <= '0; fsel <= 1'b0; fcnt <= '0; bready <= '0; bend <= '0; wsel <= 1'b0;
            pend_n <= '0; rd_busy <= 1'b0; est <= E_IDLE; beat <= '0;
            flushing <= 1'b0; flush_clr <= 1'b0;
        end else begin
            flush_clr <= 1'b0;

            // -- admission, abort, packing
            if (admit) begin
                unit_start <= wr_ptr;
                len_q      <= u_len;
            end
            if (u_abort) begin
                wr_ptr <= unit_start;
                wbi <= '0; wacc <= '0; fcnt <= '0;
            end else if (u_take) begin
                if (word_done) begin
                    bbuf[{fsel, fcnt[2:0]}] <= wword;
                    if (fcnt == 4'd0) faddr <= wr_ptr[RAW-1:0];
                    wr_ptr <= wr_ptr_n;
                    wacc   <= '0;
                    wbi    <= '0;
                    if (close) begin
                        bready[fsel] <= 1'b1;
                        bend[fsel]   <= u_last;
                        if (fsel) begin
                            bcnt1  <= fcnt + 4'd1;
                            baddr1 <= (fcnt == 4'd0) ? wr_ptr[RAW-1:0] : faddr;
                        end else begin
                            bcnt0  <= fcnt + 4'd1;
                            baddr0 <= (fcnt == 4'd0) ? wr_ptr[RAW-1:0] : faddr;
                        end
                        fsel <= !fsel;
                        fcnt <= '0;
                    end else fcnt <= fcnt + 4'd1;
                end else begin
                    wacc <= wword;
                    wbi  <= wbi + 3'd1;
                end
            end
            nunits <= nunits + {{MAW{1'b0}}, admit} - {{MAW{1'b0}}, u_abort} - {{MAW{1'b0}}, release_};

            // -- records waiting for their last word: in at u_last, out (to the queue) at commit
            if (commit) pend0 <= pend1;         // pend0 went into the queue this cycle
            if (pend_ad) begin
                if (commit) begin
                    if (pend_n == 2'd1) pend0 <= rec_in; else pend1 <= rec_in;
                end else begin
                    if (pend_n == 2'd0) pend0 <= rec_in; else pend1 <= rec_in;
                end
            end
            pend_n <= pend_n + {1'b0, pend_ad} - {1'b0, commit};

            // -- the engine
            case (est)
                E_IDLE: begin
                    beat <= '0;
                    if (bready[wsel]) est <= E_WRITE;
                end
                E_WRITE: if (wbeat) begin
                    beat <= beat + 4'd1;
                    if (wdone) begin
                        bready[wsel] <= 1'b0;
                        wsel         <= !wsel;
                        est          <= E_IDLE;
                    end
                end
                default: est <= E_IDLE;
            endcase

            // -- the outstanding unit: taken by the scheduler, freed by the host's completion
            if (q_pop) begin
                rd_busy <= 1'b1;
                r_end   <= q_start_p + q_words[PW-1:0];
            end
            if (release_) begin
                rd_busy <= 1'b0;
                tail    <= r_end;
            end

            // -- flush: refuse input, let the engine finish, then clear (the outstanding unit dropped)
            if (flush) begin
                flushing <= 1'b1;
                rd_busy  <= 1'b0;
            end
            if (flushing && quiet) begin
                flushing  <= 1'b0;
                flush_clr <= 1'b1;
                wr_ptr <= '0; unit_start <= '0; tail <= '0; nunits <= '0;
                wbi <= '0; wacc <= '0; fsel <= 1'b0; fcnt <= '0; bready <= '0; bend <= '0; wsel <= 1'b0;
                pend_n <= '0;
            end
        end
    end

endmodule

`default_nettype wire
