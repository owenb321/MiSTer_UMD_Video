// umd/aud_ring.sv -- the compressed-audio ring in front of the ATRAC3plus decoder, and
// the tag of every access unit: its PTS (docs/at3p_decoder.md S7).
//
// The demux's audio bytes (ps_demux aud_*: the selected track, AU aligned out of reset)
// go into a byte ring (umd/sfifo.sv, 2**AW bytes in M10K); the decoder (umd/at3p/
// at3p_top.sv) reads them out. in_ready is real back-pressure on the demux: a byte is
// never dropped here (the gate behind the decoder, umd/aud_out.sv, is what keeps that
// from wedging the shared stream before the first picture: S7 "the deadlock rule").
//
// THE TAGS. The decoder turns every access unit it frames into exactly one PCM frame
// (2,048 stereo pairs, silent when refused), and every AU is exactly 3,840 ticks of the
// 90 kHz clock (2,048 samples at 48 kHz). A PES PTS belongs to the first AU whose header
// STARTS in that PES (ISO 13818-1; the UMD's FAP points at it). So the write side frames
// the byte stream exactly as the decoder's microcode does (umd/at3p/at3p.uasm, AU /
// AU_SYN / AU_HDR: a two-byte window that must read 0F D0, else slides one byte; six more
// header bytes, the params word first; then (params & 0x3FF) * 8 + 8 frame bytes), and
// pushes one tag per AU header in order: {derived, has, pts}.
//   * has: a PTS is known -- the pending PES PTS if one is waiting (a PES that began at or
//     before the header's 0x0F byte), else the previous tag + 3,840 (derived = 1).
//     Before the first PES PTS after the reset there is nothing to derive: has = 0.
//   * The same framing on the same bytes, the same slides: the Nth tag is the Nth PCM
//     frame even through a corrupt stretch the decoder resyncs over (the bench proves
//     it with inserted garbage, run_av_sync.sh). A PES PTS that disagrees with the
//     running derivation is counted (`jumps`: a discontinuity in the audio stream).
// The tag FIFO (2**TAW) is flow control, not a limit: when it is full in_ready drops (the
// ring then holds 2**TAW AUs, which only AUs under 2**AW / 2**TAW bytes can reach; the
// library's smallest is 344 bytes).
//
// Status: fill (bytes held), its high-water mark, AUs framed, window slides (the
// decoder's U_RESYNC, counted independently), derived tags, PTS jumps, and the cycles the
// demux offered a byte the ring could not take.

`default_nettype none

module aud_ring #(
    parameter int AW  = 15,               // 32 KB: S7 has the sizing (the mux lead)
    parameter int TAW = 9
) (
    input  wire          clk,
    input  wire          rst_n,           // per mount

    input  wire    [7:0] in_byte,
    input  wire          in_valid,
    input  wire          in_frame_start,  // the first forwarded byte of a PES
    input  wire   [32:0] in_pts,          // that PES's PTS (held; read with in_frame_start)
    input  wire          in_pts_valid,
    input  wire   [1:0]  in_ep,           // P6b3i: that PES's item tag
    output logic         in_ready,

    output logic   [7:0] out_byte,
    output logic         out_valid,
    input  wire          out_ready,

    output logic         tag_valid,
    output logic         tag_derived,
    output logic         tag_has,
    output logic  [32:0] tag_pts,
    output logic  [1:0]  tag_ep,          // P6b3i: the AU's item (its PES's; a derived tag the last one's)
    input  wire          tag_pop,

    output logic [AW+1:0] fill,
    output logic [AW+1:0] fill_max,
    output logic  [15:0] aus,
    output logic  [15:0] slides,
    output logic  [15:0] derived,
    output logic  [15:0] jumps,
    output logic  [31:0] bp_cycles
);

    localparam [32:0] AU_TICKS = 33'd3840;

    // ---- the byte ring ----
    logic byte_full, tag_full;
    assign in_ready = !byte_full && !tag_full;
    wire take = in_valid && in_ready;

    sfifo #(.DW(8), .AW(AW)) u_bytes (
        .clk, .rst_n, .din(in_byte), .wr_en(take), .full(byte_full),
        .dout(out_byte), .dout_valid(out_valid), .rd_en(out_ready), .count(fill));

    // ---- the framer: the microcode's AU loop, on the bytes as they are taken ----
    typedef enum logic [1:0] { F_SYNC0, F_SYNC1, F_HDR, F_FRAME } fst_t;
    fst_t        fst;
    logic  [7:0] win_hi;                  // the window's first byte (a 0x0F candidate)
    logic  [2:0] hcnt;                    // header bytes after 0F D0 (6)
    logic  [7:0] par_hi;
    logic  [9:0] par_sz;                  // params & 0x3FF
    logic [13:0] fcnt;                    // frame bytes left

    // the PES PTS waiting for its AU, as of the previous byte taken
    logic        pend_v;
    logic [32:0] pend_pts;
    logic [1:0]  pend_ep, last_ep;
    // the running derivation
    logic        last_has;
    logic [32:0] last_pts;

    wire au_hit = take && (fst == F_SYNC1) && ({win_hi, in_byte} == 16'h0FD0);
    wire [32:0] next_pts = last_pts + AU_TICKS;
    wire        t_has    = pend_v || last_has;
    wire [32:0] t_pts    = pend_v ? pend_pts : next_pts;
    wire [1:0]  t_ep     = pend_v ? pend_ep : last_ep;
    wire        t_der    = !pend_v && last_has;
    wire [13:0] flen     = {par_sz, 3'b000} + 14'd8;

    // ---- the tag FIFO ----
    logic [TAW+1:0] tcount;
    sfifo #(.DW(37), .AW(TAW)) u_tags (
        .clk, .rst_n, .din({t_ep, t_der, t_has, t_pts}), .wr_en(au_hit), .full(tag_full),
        .dout({tag_ep, tag_derived, tag_has, tag_pts}), .dout_valid(tag_valid), .rd_en(tag_pop),
        .count(tcount));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fst <= F_SYNC0; win_hi <= 8'd0; hcnt <= 3'd0; par_hi <= 8'd0; par_sz <= 10'd0;
            fcnt <= 14'd0;
            pend_v <= 1'b0; pend_pts <= '0; last_has <= 1'b0; last_pts <= '0; pend_ep <= '0; last_ep <= '0;
            aus <= 16'd0; slides <= 16'd0; derived <= 16'd0; jumps <= 16'd0;
            bp_cycles <= 32'd0; fill_max <= '0;
        end else begin
            if (in_valid && !in_ready) bp_cycles <= bp_cycles + 32'd1;
            if (fill > fill_max) fill_max <= fill;
            if (take) begin
                case (fst)
                    F_SYNC0: begin win_hi <= in_byte; fst <= F_SYNC1; end
                    F_SYNC1: begin
                        if ({win_hi, in_byte} == 16'h0FD0) begin
                            fst <= F_HDR; hcnt <= 3'd0;
                        end else begin
                            win_hi <= in_byte;              // slide one byte
                            slides <= slides + 16'd1;
                        end
                    end
                    F_HDR: begin
                        if (hcnt == 3'd0) par_hi <= in_byte;
                        if (hcnt == 3'd1) par_sz <= {par_hi[1:0], in_byte};
                        hcnt <= hcnt + 3'd1;
                        if (hcnt == 3'd5) begin fst <= F_FRAME; fcnt <= flen; end
                    end
                    F_FRAME: begin
                        fcnt <= fcnt - 14'd1;
                        if (fcnt == 14'd1) fst <= F_SYNC0;
                    end
                endcase
                // the tag: the header's 0x0F byte was the previous byte, so pend_* (as of
                // it) is the PTS of a PES that began at or before it; a PES starting on
                // this 0xD0 byte belongs to the NEXT header
                if (au_hit) begin
                    aus      <= aus + 16'd1;
                    last_has <= t_has;
                    last_pts <= t_pts;
                    last_ep  <= t_ep;
                    if (t_der) derived <= derived + 16'd1;
                    if (pend_v && last_has && (pend_pts != next_pts)) jumps <= jumps + 16'd1;
                end
                if (in_frame_start && in_pts_valid) begin
                    pend_v <= 1'b1; pend_pts <= in_pts; pend_ep <= in_ep;
                end else if (au_hit) begin
                    pend_v <= 1'b0;
                end
            end
        end
    end

endmodule

`default_nettype wire
