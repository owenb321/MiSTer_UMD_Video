// umd/pcm_shot.sv -- the menus' sound effects: a one-shot of 16-bit PCM from DDR3, mixed over
// the film's audio (P9, docs/p9.md §3.2 item 5, decision P9-3)
//
// The UMD Main decodes a disc menu's VAG sound to 16-bit signed PCM at 48 kHz (resampling the
// VAG's own rate: 16-48 kHz in the library) and writes it into the PCM REGION of ram2's DDR3
// (2^RW 64-bit words from BASE: core word 0x0660_0000 = HPS byte 0x3300_0000, 8 MB). Each
// 64-bit word holds, little-endian from bit 0 (the HPS's own byte order through its uncached
// mapping): mono, four samples; stereo, two frames {L, R}. Then it TRIGGERS through umd_host
// (hp_req held until hp_ack): {stereo, start (the region-relative word), len (sample frames)}.
// A trigger replaces whatever is playing, at once; len 0 stops it.
//
// Two clocks:
//   mclk  the reader: bursts of BL words while the FIFO has room, its address wrapping inside
//         the region (it can never read outside it, whatever the host sends). A trigger is a
//         toggle with held fields and a generation; a new one waits for the beats of a burst
//         already issued (Avalon), then starts. Every word goes into the FIFO with its gen.
//   clk   the player: its OWN 48 kHz tick (2 / 1125 of clk_sys, aud_out's NCO) -- the film's
//         tick stops while it is paused or stopped, and menus play their sounds just then.
//         At each tick one sample (mono: L = R) or one frame; words of an older gen are
//         dropped as they come out. A word late at a tick plays silence (counted: under).
//
// pcm_l / pcm_r are 0 while nothing plays; emu adds them to the film's output, saturating.
// The PSP's own menu mix level is not known (docs/p9.md: measured against the captures in M3).
// No `function`, no N'(expr) cast (Quartus 17).

`default_nettype none

module pcm_shot #(
    parameter logic [28:0] BASE = 29'h0660_0000,
    parameter int          RW   = 20,          // the region: 2^RW words (8 MB)
    parameter int          BL   = 8            // a burst
) (
    // the trigger (clk; umd_host's held record)
    input  wire         clk,
    input  wire         rst_n,
    input  wire         hp_req,
    input  wire         hp_stereo,
    /* verilator lint_off UNUSEDSIGNAL */      // the region is 2^RW words: the address wraps inside it
    input  wire  [23:0] hp_start,               // region-relative 64-bit word
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire  [23:0] hp_len,                 // sample frames
    output logic        hp_ack,
    output logic        busy,                   // a sound is playing
    output logic signed [15:0] pcm_l,
    output logic signed [15:0] pcm_r,
    output logic [15:0] n_under,                // ticks with no word ready (wrapping)

    // the reader (mclk), a read-only Avalon master
    input  wire         mclk,
    input  wire         mrst_n,
    output logic [28:0] ddr_address,
    output logic [7:0]  ddr_burstcount,
    output logic        ddr_read,
    input  wire         ddr_waitrequest,
    input  wire  [63:0] ddr_readdata,
    input  wire         ddr_readdatavalid
);

    // ---- clk: the trigger -> a record for mclk (toggle, held fields) --------------------------------------
    logic        t_tog;
    logic [1:0]  t_gen;
    logic [RW-1:0] t_start;
    logic [23:0] t_words;                       // words to read
    wire  [23:0] w_st = hp_len[23:1] + {23'd0, hp_len[0]};                 // stereo: 2 frames a word
    wire  [23:0] w_mo = {1'b0, hp_len[23:2]} + {23'd0, hp_len[1:0] != 2'd0};   // mono: 4 samples a word

    // ---- the player's state ----
    logic [1:0]  gen;
    logic        st;                            // stereo
    logic [23:0] left;                          // frames still to play
    logic [10:0] nco;
    logic        tick;
    logic [63:0] cw;                            // the word being played
    logic        cw_v;
    logic [1:0]  sub;                           // the sample / frame within it
    logic        started;                       // a word has played since the trigger (under counts after)

    // ---- the FIFO (mclk -> clk): {gen, word} ----
    localparam int FAW = 5;
    logic [65:0] f_dout;
    logic        f_empty, f_valid, f_rd;
    /* verilator lint_off UNUSEDSIGNAL */      // the reader asks for room (wr_free) before a burst
    logic        f_full;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [FAW:0] f_free;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            t_tog <= 1'b0; t_gen <= '0; t_start <= '0; t_words <= '0; hp_ack <= 1'b0;
            gen <= '0; st <= 1'b0; left <= '0; busy <= 1'b0;
        end else begin
            hp_ack <= 1'b0;
            if (hp_req && !hp_ack) begin
                hp_ack  <= 1'b1;
                t_tog   <= !t_tog;
                t_gen   <= t_gen + 2'd1;
                t_start <= hp_start[RW-1:0];
                t_words <= hp_stereo ? w_st : w_mo;
                gen     <= t_gen + 2'd1;
                st      <= hp_stereo;
                left    <= hp_len;
                busy    <= (hp_len != 24'd0);
            end else if (tick && busy && cw_v) begin
                left <= left - 24'd1;
                if (left == 24'd1) busy <= 1'b0;
            end
        end
    end

    // ---- clk: the 48 kHz tick (2 / 1125 of 27 MHz, as aud_out's) ----
    always_ff @(posedge clk) begin
        if (!rst_n) begin nco <= '0; tick <= 1'b0; end
        else if (nco >= 11'd1123) begin nco <= nco - 11'd1123; tick <= 1'b1; end
        else begin nco <= nco + 11'd2; tick <= 1'b0; end
    end

    // ---- clk: words out of the FIFO, samples out at the tick ----
    // a word is popped when none is held (or the held one is used up at this tick); a word of an
    // older gen is dropped as it arrives
    wire last_sub = st ? (sub == 2'd1) : (sub == 2'd3);
    wire use_up   = tick && busy && cw_v && last_sub;
    assign f_rd   = !f_empty && !f_valid && (!cw_v || use_up);
    logic [15:0] s0, s1;
    always_comb begin
        case (sub)
            2'd0: s0 = cw[15:0];
            2'd1: s0 = st ? cw[47:32] : cw[31:16];
            2'd2: s0 = cw[47:32];
            default: s0 = cw[63:48];
        endcase
        s1 = (sub == 2'd0) ? cw[31:16] : cw[63:48];
    end
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            cw <= '0; cw_v <= 1'b0; sub <= '0; pcm_l <= '0; pcm_r <= '0; n_under <= '0; started <= 1'b0;
        end else begin
            if (hp_req && !hp_ack) begin
                cw_v <= 1'b0; sub <= '0; started <= 1'b0;
            end else begin
                if (tick && busy) begin
                    if (cw_v) begin
                        started <= 1'b1;
                        pcm_l <= s0;
                        pcm_r <= st ? s1 : s0;
                        sub   <= last_sub ? 2'd0 : sub + 2'd1;
                        if (last_sub) cw_v <= 1'b0;
                    end else begin
                        pcm_l <= '0; pcm_r <= '0;
                        if (started) n_under <= n_under + 16'd1;
                    end
                end else if (tick) begin
                    pcm_l <= '0; pcm_r <= '0;
                end
                if (f_valid && f_dout[65:64] == gen) begin cw <= f_dout[63:0]; cw_v <= 1'b1; end
            end
        end
    end

    // ---- mclk: the reader ----
    logic [2:0]  m_s;                           // the trigger's toggle, synchronised
    logic        m_tog;
    logic [1:0]  m_gen;
    logic [RW-1:0] m_addr;
    logic [23:0] m_left;                        // words still to request
    logic [7:0]  m_beats;                       // beats of the issued burst still to come
    logic [1:0]  b_gen;                         // ... and its generation (a new trigger's beats are not its)
    logic        m_pend;                        // a new trigger waits for those beats
    wire  [7:0]  m_bl = (m_left < {16'd0, BL[7:0]}) ? m_left[7:0] : BL[7:0];
    always_ff @(posedge mclk) begin
        if (!mrst_n) begin
            m_s <= '0; m_tog <= 1'b0; m_gen <= '0; m_addr <= '0; m_left <= '0; m_beats <= '0; m_pend <= 1'b0; b_gen <= '0;
            ddr_read <= 1'b0; ddr_address <= BASE; ddr_burstcount <= '0;
        end else begin
            m_s <= {m_s[1:0], t_tog};
            if (ddr_readdatavalid && m_beats != 8'd0) m_beats <= m_beats - 8'd1;
            if (ddr_read && !ddr_waitrequest) ddr_read <= 1'b0;
            if (m_s[2] != m_tog) begin
                // a new trigger: the held fields are stable (they changed two clk cycles before
                // the toggle, which is three mclk flops behind); no new burst until the old beats
                m_tog <= m_s[2]; m_pend <= 1'b1;
                m_gen <= t_gen; m_addr <= t_start; m_left <= t_words;
            end else if (m_pend) begin
                if (m_beats == 8'd0 && !ddr_read) m_pend <= 1'b0;
            end else if (!ddr_read && m_beats == 8'd0 && m_left != 24'd0 &&
                         f_free > BL[FAW:0]) begin
                ddr_read       <= 1'b1;
                ddr_address    <= BASE + {{(29-RW){1'b0}}, m_addr};
                ddr_burstcount <= m_bl;
                m_beats        <= m_bl;
                b_gen          <= m_gen;
                m_addr         <= m_addr + {{(RW-8){1'b0}}, m_bl};
                m_left         <= m_left - {16'd0, m_bl};
            end
        end
    end

    fifo_dc #(.DW (66), .AW (FAW)) u_fifo (
        .wr_clk (mclk), .wr_rst_n (mrst_n), .din ({b_gen, ddr_readdata}),
        .wr_en (ddr_readdatavalid && m_beats != 8'd0), .full (f_full), .wr_free (f_free),
        .rd_clk (clk), .rd_rst_n (rst_n), .dout (f_dout), .rd_en (f_rd), .empty (f_empty), .valid (f_valid)
    );

endmodule

`default_nettype wire
