// umd/vbuf.sv -- the compressed-video buffer (the decoder's CPB) in DDR3: ps_demux's video
// bytes -> a ring on ram1 (ddr_mux2 master B) -> vidfeed_cdc (P6a, 2026-09-27;
// docs/h264_frontend.md "The compressed-video buffer").
//
// WHY. Without it the video path held 32 bytes: the demux could run ahead of the display
// only as far as free picture stores reach (~16 pictures, 0.45-0.6 s), while UMD
// multiplexes carry the audio up to 0.55 s BEHIND the video of the same moment -- so on
// Family Guy the audio reached its decoder after its time (docs/at3p_decoder.md S7.8).
// A multiplex assumes the decoder has a CPB (H.264 Annex C): Level 3's MaxCPB is
// 10,000 kbit = 1.25 MB; the ring is 2 MB (2**RING_AW words). Harvested from MiSTer_DVD's
// VBUF in idea only (a byte -> 64-bit packer, a DDR3 ring, the PTS carried by POSITION);
// its code lives inside the upstream MPEG-2 decoder's memory controller.
//
// TWO DOMAINS, ONE RULE: everything that counts is on clk_sys.
//   clk_sys  in: {pts, mark, byte} from the demux (valid / ready). A byte's POSITION is
//            the count of bytes before it (wpos). Bytes are packed eight to a 64-bit word
//            (lane k = byte k) into the write FIFO; a marked byte (the first payload byte
//            of a PES with a PTS) pushes {position, PTS} into the stamp queue. The side
//            also DESCRIBES the bursts: after 8 words, at the ring's end, or when no word
//            has followed for IDLE_T cycles (so a stream's pause does not strand words),
//            it pushes the burst length into the command FIFO -- after the words, so the
//            engine finds them (and waits a cycle if a crossing lags).
//            out: the read FIFO's words unpacked; a byte leaves with mark = 1 and the
//            head stamp's PTS when the head stamp's position is its position, exactly the
//            {pts, mark, byte} vidfeed_cdc carried before. Only bytes below wpos leave.
//            Flow control: wpos - rpos (bytes held, conservative: a word is counted until
//            its last byte LEAVES) under the ring less a margin, the stamp queue not full
//            (flow control, not a limit: a stream with a PTS on every picture fills 512
//            stamps only with ~8 s of video held).
//   clk_mem  the engine: a described write burst from the write FIFO; else, when words
//            are in the ring and the read FIFO has room for a whole burst, a read burst of
//            up to 8 into the read FIFO. Bursts of <= 8 beats: the envelope every client of
//            this port is built and benched to (bench/umd/ddr_model.sv polices it). It NEVER withdraws a command (ddr_mux2 has no
//            abort for B): a clear waits for the command it presents, an open write burst
//            is completed (with zeros if its words are gone -- the ring is being cleared),
//            read beats still owed are swallowed.
// THE TITLE'S END (flush_in = umd_reader's title_done, a clk_sys level): once the input
// has been quiet FLUSH_IDLE cycles the packer's partial word goes out, zero-padded; the
// padding never leaves (only bytes below wpos do). flush_out = flush_in, padded, every
// byte delivered: vidfeed_cdc's wr_flush. A byte arriving after the padding would sit at
// the wrong position: it is counted (late_bytes) and dropped -- never on a real stream
// (the demux has nothing after title_done + FLUSH_IDLE quiet).
// THE CLEAR (rst_n: the per-mount reset, and later a seek's discontinuity): the clk_sys
// side holds its FIFO sides in reset and raises clr_req; the engine finishes its command,
// resets its pointers and FIFO sides and raises clr_ack; the clk_sys side drops clr_req;
// the engine releases its sides and drops clr_ack; the clk_sys side runs. Both sides of
// every dual-clock FIFO are in reset together while nothing moves (umd/fifo_dc.sv: a side
// in reset reads as empty / not full to the other). The engine resets with the PLL lock
// only (mrst_n), like every DDR3 master here: a request it holds must survive a mount and
// a RESET (the reload hang, docs/hil_harness.md).
//
// Quartus 17: no functions, no N'() casts; power-of-two depths; FIFOs in M10K.

`default_nettype none

module vbuf #(
    parameter logic [28:0] BASE = 29'h0628_0000,   // word address (after the DPB's 20 stores)
    parameter int RING_AW  = 18,                    // 2**18 words = 2 MB
    parameter int IDLE_T   = 256,                   // clk_sys cycles before a partial burst
    parameter int FLUSH_IDLE = 4096                 // quiet clk_sys cycles after title_done
) (
    // ---- clk_sys ----
    input  wire          clk,
    input  wire          rst_n,          // per mount: runs the clear
    input  wire    [7:0] in_byte,
    input  wire          in_mark,
    input  wire   [32:0] in_pts,
    input  wire   [1:0]  in_ep,          // P6b3i: the PTS's item tag (with in_mark)
    input  wire          in_valid,
    output logic         in_ready,
    input  wire          flush_in,       // level: the title is over (the reader's title_done)
    output logic   [7:0] out_byte,
    output logic         out_mark,
    output logic  [32:0] out_pts,
    output logic  [1:0]  out_ep,         // P6b3i: with out_mark
    output logic         out_valid,
    input  wire          out_ready,
    output logic         flush_out,      // level: flush_in, and every byte delivered
    output logic  [31:0] fill,           // bytes held
    output logic  [31:0] fill_max,
    output logic  [31:0] bp_cycles,      // cycles a byte waited on the buffer
    output logic  [15:0] late_bytes,     // bytes after the title's padding (never: counted)
    output logic         running,        // not clearing

    // ---- clk_mem: ddr_mux2 master B ----
    input  wire          mclk,
    input  wire          mrst_n,         // the PLL lock only
    output logic  [28:0] b_address,
    output logic   [7:0] b_burstcount,
    output logic         b_read,
    output logic         b_write,
    output logic  [63:0] b_writedata,
    input  wire          b_waitrequest,
    input  wire   [63:0] b_readdata,
    input  wire          b_readdatavalid
);

    localparam logic [RING_AW:0] RING = 1 << RING_AW;
    localparam logic [31:0] CAP_BYTES = (32'd1 << (RING_AW + 3)) - 32'd2048;
    localparam logic [15:0] IDLE_W  = IDLE_T[15:0];     // sized, not a cast (Quartus 17)
    localparam logic [15:0] FLUSH_W = FLUSH_IDLE[15:0];

    // the clear's handshake (declared first: both sides read them)
    logic clr_ack;                       // clk_mem -> clk_sys
    logic req_m1, req_m2;                // clr_req into clk_mem
    logic m_frst_n;                      // the clk_mem side's FIFO resets

    // =================================================================== clk_sys side
    typedef enum logic [1:0] { C_REQ, C_WAIT_DROP, C_RUN } cst_t;
    cst_t cst;
    logic ack_s1, ack_s2;                // clr_ack into clk_sys
    logic clr_req;                       // -> clk_mem
    logic s_frst_n;                      // this side's FIFO resets
    always_ff @(posedge clk) begin ack_s1 <= clr_ack; ack_s2 <= ack_s1; end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cst <= C_REQ; clr_req <= 1'b1; s_frst_n <= 1'b0;
        end else case (cst)
            C_REQ:       if (ack_s2) begin clr_req <= 1'b0; cst <= C_WAIT_DROP; end
            C_WAIT_DROP: if (!ack_s2) begin s_frst_n <= 1'b1; cst <= C_RUN; end
            default:     ;
        endcase
    end
    wire run = (cst == C_RUN);
    assign running = run;

    // the FIFOs' clk_sys ports
    logic         wf_full, cf_full, rf_empty, rf_valid, rf_rd;
    logic [6:0]   wf_free, cf_free;
    logic [63:0]  rf_dout;
    logic         wf_wr, cf_wr;
    logic [63:0]  wf_din;
    logic [5:0]   cf_din;

    // positions (bytes) and the packer
    logic [31:0]  wpos, rpos;
    logic [63:0]  pack;
    logic         padded;            // the title's last partial word went out
    logic [31:0]  wwords;            // words pushed into the write FIFO (total)
    logic [5:0]   pend;              // words pushed and not yet described
    logic [15:0]  idle_w, quiet;
    // the stamp queue {item tag, position[23:0], pts}
    logic         st_full, st_valid, st_pop;
    logic [58:0]  st_head;
    logic [10:0]  st_count;

    wire [31:0] held    = wpos - rpos;
    assign in_ready = run && (held < CAP_BYTES) && !st_full && (wf_free >= 7'd2) && (cf_free >= 7'd2) && !padded;
    wire take   = in_valid && in_ready;
    wire [2:0]  lane = wpos[2:0];
    wire [63:0] pack_nx = take ? ((pack & ~(64'hFF << {lane, 3'b000})) | ({56'd0, in_byte} << {lane, 3'b000})) : pack;
    // the partial word at the title's end
    wire        pad_now = run && flush_in && !padded && (quiet >= FLUSH_W) && (lane != 3'd0) && !in_valid;
    // a word goes into the write FIFO: eight bytes, or the padded partial word
    assign wf_wr  = (take && lane == 3'd7) || pad_now;
    assign wf_din = pack_nx;
    // a burst is described: 8 words (the engine's burst), the ring's end, or IDLE_T
    // cycles with no new word
    wire [31:0] wwords_nx = wwords + {31'd0, wf_wr};
    wire [5:0]  pend_nx   = pend + {5'd0, wf_wr};
    wire        at_end    = wf_wr && (wwords_nx[RING_AW-1:0] == '0);
    assign cf_wr  = run && (pend_nx != 6'd0) &&
                    ((pend_nx == 6'd8) || at_end || (!wf_wr && idle_w >= IDLE_W));
    assign cf_din = pend_nx;

    sfifo #(.DW(59), .AW(9)) u_stamps (
        .clk, .rst_n(s_frst_n), .din({in_ep, wpos[23:0], in_pts}), .wr_en(take && in_mark), .full(st_full),
        .dout(st_head), .dout_valid(st_valid), .rd_en(st_pop), .count(st_count));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wpos <= '0; pack <= '0; padded <= 1'b0; wwords <= '0; pend <= '0;
            idle_w <= '0; quiet <= '0; fill_max <= '0; bp_cycles <= '0; late_bytes <= '0;
        end else begin
            if (take) wpos <= wpos + 32'd1;
            pack <= wf_wr ? 64'd0 : pack_nx;
            if (pad_now) begin padded <= 1'b1; wpos <= {wpos[31:3] + 29'd1, 3'b000}; end
            wwords <= wwords_nx;
            pend   <= cf_wr ? 6'd0 : pend_nx;
            idle_w <= (wf_wr || cf_wr) ? 16'd0 : (idle_w == 16'hFFFF ? idle_w : idle_w + 16'd1);
            quiet  <= in_valid ? 16'd0 : (quiet == 16'hFFFF ? quiet : quiet + 16'd1);
            if (held > fill_max) fill_max <= held;
            if (in_valid && !in_ready && run) bp_cycles <= bp_cycles + 32'd1;
            if (in_valid && padded && run && late_bytes != 16'hFFFF) late_bytes <= late_bytes + 16'd1;
        end
    end
    // the padding moved wpos to the word's end: the bytes that leave stop at the title's
    // real end, kept separately
    logic [31:0] endpos;               // wpos before the padding (the last real byte + 1)
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) endpos <= '0;
        else if (!padded && !pad_now) endpos <= wpos + {31'd0, take};
    assign fill = held;

    // ---- out: unpack the read FIFO's words ----
    logic        have;                 // a word in `word`
    logic        pulled;               // a pop is in flight (the word lands next cycle)
    logic [63:0] word;
    wire  [31:0] lim = padded ? endpos : wpos;
    assign rf_rd     = run && !rf_empty && !have && !pulled;
    assign out_byte  = word[{rpos[2:0], 3'b000} +: 8];
    assign out_valid = run && have && (rpos != lim);
    assign out_mark  = st_valid && (st_head[56:33] == rpos[23:0]);
    assign out_pts   = st_head[32:0];
    assign out_ep    = st_head[58:57];
    wire   give      = out_valid && out_ready;
    assign st_pop    = give && out_mark;
    assign flush_out = run && flush_in && (padded || lane == 3'd0) && (rpos == lim) && (quiet >= FLUSH_W);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rpos <= '0; have <= 1'b0; pulled <= 1'b0; word <= '0;
        end else begin
            pulled <= rf_rd;
            if (rf_valid && pulled) begin word <= rf_dout; have <= 1'b1; end
            if (give) begin
                rpos <= rpos + 32'd1;
                if (rpos[2:0] == 3'd7) have <= 1'b0;
            end
        end
    end

    // =================================================================== clk_mem side
    always_ff @(posedge mclk) begin req_m1 <= clr_req; req_m2 <= req_m1; end

    logic         wf_empty, wf_valid, wf_rd, cf_empty, cf_valid, cf_rd, rf_full, rf_wr;
    logic [63:0]  wf_dout;
    logic [5:0]   cf_dout;
    logic [6:0]   rf_free;

    fifo_dc #(.DW(64), .AW(6)) u_wf (
        .wr_clk(clk), .wr_rst_n(s_frst_n), .din(wf_din), .wr_en(wf_wr), .full(wf_full), .wr_free(wf_free),
        .rd_clk(mclk), .rd_rst_n(m_frst_n), .dout(wf_dout), .rd_en(wf_rd), .empty(wf_empty), .valid(wf_valid));
    fifo_dc #(.DW(6), .AW(6)) u_cf (
        .wr_clk(clk), .wr_rst_n(s_frst_n), .din(cf_din), .wr_en(cf_wr), .full(cf_full), .wr_free(cf_free),
        .rd_clk(mclk), .rd_rst_n(m_frst_n), .dout(cf_dout), .rd_en(cf_rd), .empty(cf_empty), .valid(cf_valid));
    fifo_dc #(.DW(64), .AW(6)) u_rf (
        .wr_clk(mclk), .wr_rst_n(m_frst_n), .din(b_readdata), .wr_en(rf_wr), .full(rf_full), .wr_free(rf_free),
        .rd_clk(clk), .rd_rst_n(s_frst_n), .dout(rf_dout), .rd_en(rf_rd), .empty(rf_empty), .valid(rf_valid));

    typedef enum logic [3:0] {
        E_IDLE, E_CMD, E_FETCH, E_LAND, E_BEAT, E_RCMD, E_RDATA, E_CLR_ACK, E_CLR_DROP
    } est_t;
    est_t        est;
    logic [RING_AW:0] ww, rw;          // words written to / read from the ring (mod 2**(RING_AW+1))
    logic [5:0]  n, k;                 // the burst's length, beats done
    logic        clr_seen;             // a clear is waiting for the current command
    wire  [RING_AW:0] avail = ww - rw;
    wire  [RING_AW:0] to_end = RING - {1'b0, rw[RING_AW-1:0]};
    wire  [RING_AW:0] rn_a   = (avail  < 8) ? avail  : 8;
    wire  [RING_AW:0] rn     = (to_end < rn_a) ? to_end : rn_a;

    assign cf_rd = (est == E_IDLE) && !req_m2 && !cf_empty;
    assign wf_rd = (est == E_FETCH) && !wf_empty;
    assign rf_wr = (est == E_RDATA) && b_readdatavalid && !clr_seen;

    always_ff @(posedge mclk or negedge mrst_n) begin
        if (!mrst_n) begin
            est <= E_CLR_ACK; ww <= '0; rw <= '0; n <= '0; k <= '0; clr_seen <= 1'b0;
            clr_ack <= 1'b0; m_frst_n <= 1'b0;
            b_address <= BASE; b_burstcount <= 8'd1; b_read <= 1'b0; b_write <= 1'b0; b_writedata <= '0;
        end else begin
            if (req_m2 && est != E_CLR_ACK && est != E_CLR_DROP) clr_seen <= 1'b1;
            case (est)
                E_IDLE: begin
                    if (req_m2) begin
                        est <= E_CLR_ACK;
                    end else if (!cf_empty) begin
                        est <= E_CMD;                           // cf_rd popped it
                    end else if (avail != '0 && rf_free >= 7'd8) begin
                        b_address <= BASE + {{(28-RING_AW){1'b0}}, rw[RING_AW-1:0]};
                        b_burstcount <= {2'd0, rn[5:0]};
                        n <= rn[5:0]; k <= '0; b_read <= 1'b1;
                        est <= E_RCMD;
                    end
                end
                E_CMD: if (cf_valid) begin
                    n <= cf_dout; k <= '0;
                    b_address <= BASE + {{(28-RING_AW){1'b0}}, ww[RING_AW-1:0]};
                    b_burstcount <= {2'd0, cf_dout};
                    est <= E_FETCH;
                end
                E_FETCH: begin                                   // the next word (wf_rd)
                    if (!wf_empty) est <= E_LAND;
                    else if (req_m2 || clr_seen) begin          // its words are gone: complete it
                        b_writedata <= '0; b_write <= 1'b1; est <= E_BEAT;
                    end
                end
                E_LAND: if (wf_valid) begin b_writedata <= wf_dout; b_write <= 1'b1; est <= E_BEAT; end
                E_BEAT: if (!b_waitrequest) begin               // a beat accepted
                    b_write <= 1'b0;
                    k <= k + 6'd1;
                    if (k + 6'd1 == n) begin
                        ww <= ww + {{(RING_AW+1-6){1'b0}}, n};
                        est <= E_IDLE;
                    end else est <= E_FETCH;
                end
                E_RCMD: if (!b_waitrequest) begin b_read <= 1'b0; est <= E_RDATA; end
                E_RDATA: if (b_readdatavalid) begin
                    k <= k + 6'd1;
                    if (k + 6'd1 == n) begin
                        rw <= rw + {{(RING_AW+1-6){1'b0}}, n};
                        est <= E_IDLE;
                    end
                end
                E_CLR_ACK: begin                                 // nothing outstanding: clear
                    ww <= '0; rw <= '0; m_frst_n <= 1'b0; clr_ack <= 1'b1; clr_seen <= 1'b0;
                    if (clr_ack && !req_m2) est <= E_CLR_DROP;
                end
                E_CLR_DROP: begin m_frst_n <= 1'b1; clr_ack <= 1'b0; est <= E_IDLE; end
                default: est <= E_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
