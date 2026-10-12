// umd/at3p/at3p_vec.sv -- the ATRAC3plus decoder's vector engines
//
// The inner loops of the synthesis, started by the sequencer's `vop` (at3p_seq.sv) with
// their arguments in r8..r15 (a0..a7 here). Every op is defined by tools/at3p_isa.py
// (Machine.vop), i.e. by tools/at3p_fixed.py's arithmetic; bench/umd/run_at3p.sh scores
// the PCM bit-exact and each op's buffers by checksum. docs/at3p_decoder.md S3.4, S4.
//
// One datapath: a 27x27 signed multiplier, a 64-bit accumulator (a product can enter
// shifted by 20: the IMDCT output multiplies its 40-bit half transform in two 20-bit
// halves), one round-half-up shifter (v + 2^(s-1)) >> s, one post-adder and one
// width-selectable saturator. Loops: the reads of element k are issued while the data of
// element k - 1 is used (M10K reads are registered), one element a cycle; the IMDCT's
// 256 output samples take four cycles each.
//
// One cosine table (cos(pi m / 1024) x 2^25, m = 0..512) serves every angle: the IMDCT,
// the IPQF DCT, the windows, the oscillator, the Hann window; the angle -> (address,
// sign) map is one block, driven by the angle each state reads.
//
//   op  0 DQ     a0 spectrum address, a1 count, a2 X index, a3 wl, a4 sf
//   op  1 NZ     a0 rng, a1 count, a2 X index, a3 wl, a4 sf, a5 level, a6 gcv
//   op  2 XCLR
//   op  3 XNORM  a0 negate
//   op  4 IMDCT  a0 subband, a1 window pair, a2 time offset, a3 channel
//   op  5 TZERO  a0 time offset, a1 channel, a2 count
//   op  6 RCLR   a0 region
//   op  7 WAVE   a0 region, a1 freq, a2 phase, a3 amp_sf, a4 offset (0 / 128)
//   op  8 RSAT   a0 region, a1 invert
//   op  9 RWIN   a0 region, a1 first, a2 count, a3 Hann index, a4 step
//   op 10 RZERO  a0 region, a1 first, a2 count
//   op 11 ADDT   a0 time offset
//   op 12 IPQF   a0 channel
//   op 13 PCMZ

`default_nettype none

module at3p_vec (
    input  wire          clk,
    input  wire          rst_n,

    input  wire          start,
    input  wire    [3:0] op,
    input  wire  [127:0] args,
    output logic         done,

    output logic  [11:0] spec_raddr,
    input  wire    [5:0] spec_rdata,
    output logic   [7:0] e_raddr,
    input  wire    [7:0] e_rdata,

    output logic  [15:0] pcm_l,
    output logic  [15:0] pcm_r,
    output logic         pcm_valid,
    input  wire          pcm_ready,

    output logic  [15:0] sat_count,          // internal stages that saturated (never on a legal stream)
    output logic  [15:0] clip_count          // PCM samples clipped (ffmpeg's s16 clips the same)
);

    localparam [3:0] OP_DQ = 4'd0, OP_NZ = 4'd1, OP_XCLR = 4'd2, OP_XNORM = 4'd3,
                     OP_IMDCT = 4'd4, OP_TZERO = 4'd5, OP_RCLR = 4'd6, OP_WAVE = 4'd7,
                     OP_RSAT = 4'd8, OP_RWIN = 4'd9, OP_RZERO = 4'd10, OP_ADDT = 4'd11,
                     OP_IPQF = 4'd12, OP_PCMZ = 4'd13;
    localparam [1:0] W16 = 2'd0, W24 = 2'd1, W27 = 2'd2, W40 = 2'd3;

    // ------------------------------------------------------------------ tables
    (* ramstyle = "M10K" *) logic [25:0] cosr  [0:512];
    (* ramstyle = "M10K" *) logic [15:0] noise [0:1023];
    (* ramstyle = "M10K" *) logic [26:0] qcoef [0:511];
    logic [25:0] ampq [0:63];
    logic [18:0] mant [0:7];
    logic [15:0] sfm  [0:63];
    logic  [4:0] sfe  [0:63];
    logic  [6:0] pwc  [0:15];
    logic [26:0] f4   [0:3];
    initial begin
        $readmemh("umd/at3p/at3p_cos.mem", cosr);
        $readmemh("umd/at3p/at3p_noise.mem", noise);
        $readmemh("umd/at3p/at3p_ipqf.mem", qcoef);
        $readmemh("umd/at3p/at3p_amp.mem", ampq);
        $readmemh("umd/at3p/at3p_mant.mem", mant);
        $readmemh("umd/at3p/at3p_sfm.mem", sfm);
        $readmemh("umd/at3p/at3p_sfe.mem", sfe);
        $readmemh("umd/at3p/at3p_pwc.mem", pwc);
        $readmemh("umd/at3p/at3p_f4.mem", f4);
    end

    // ------------------------------------------------------------------ buffers
    (* ramstyle = "M10K" *) logic [39:0] xb  [0:127];     // residual, then its normalised form
    (* ramstyle = "M10K" *) logic [39:0] hb  [0:127];     // the half transform
    (* ramstyle = "M10K" *) logic [23:0] tb  [0:2047];    // one channel's time signal
    (* ramstyle = "M10K" *) logic [23:0] pb  [0:4095];    // the overlap, gained (ch x 2048)
    (* ramstyle = "M10K" *) logic [26:0] rb  [0:255];     // the two tone regions
    (* ramstyle = "M10K" *) logic [26:0] rb2 [0:255];     // (a copy: ADDT reads both regions)
    (* ramstyle = "M10K" *) logic [26:0] ih  [0:1023];    // the IPQF history {ch, b2, pos, i}
    (* ramstyle = "M10K" *) logic [15:0] p0b [0:2047];    // channel 0's PCM
    initial begin                           // M10K powers up zero; so does ffmpeg's context
        for (int n = 0; n < 4096; n++) pb[n] = 24'd0;
        for (int n = 0; n < 2048; n++) begin tb[n] = 24'd0; p0b[n] = 16'd0; end
        for (int n = 0; n < 1024; n++) ih[n] = 27'd0;
        for (int n = 0; n < 256; n++) begin rb[n] = 27'd0; rb2[n] = 27'd0; end
        for (int n = 0; n < 128; n++) begin xb[n] = 40'd0; hb[n] = 40'd0; end
    end

    logic  [6:0] xb_ra, xb_wa;  logic [39:0] xb_q;  logic xb_we;
    logic  [6:0] hb_ra, hb_wa;  logic [39:0] hb_q;  logic hb_we;
    logic [10:0] tb_ra, tb_wa;  logic [23:0] tb_q;  logic tb_we;
    logic [11:0] pb_ra, pb_wa;  logic [23:0] pb_q;  logic pb_we;
    logic  [7:0] rb_ra, rb2_ra, rb_wa;  logic [26:0] rb_q, rb2_q;  logic rb_we;
    logic  [9:0] ih_ra, ih_wa;  logic [26:0] ih_q;  logic ih_we;
    logic [10:0] p0_ra, p0_wa;  logic [15:0] p0_q;  logic p0_we;
    logic  [9:0] cos_ra;        logic [25:0] cos_q;
    logic  [9:0] nz_ra;         logic [15:0] nz_q;
    logic  [8:0] qc_ra;         logic [26:0] qc_q;
    logic signed [63:0] res;
    // (the writes are stage Y's: x_* are the issue-side controls one cycle later)
    logic        x_xb_we, x_hb_we, x_tb_we, x_pb_we, x_rb_we, x_ih_we, x_p0_we;
    logic  [6:0] x_xb_wa, x_hb_wa;
    logic [10:0] x_tb_wa, x_p0_wa;
    logic [11:0] x_pb_wa;
    logic  [7:0] x_rb_wa;
    logic  [9:0] x_ih_wa;
    always_ff @(posedge clk) begin
        xb_q <= xb[xb_ra];   if (x_xb_we) xb[x_xb_wa] <= res[39:0];
        hb_q <= hb[hb_ra];   if (x_hb_we) hb[x_hb_wa] <= res[39:0];
        tb_q <= tb[tb_ra];   if (x_tb_we) tb[x_tb_wa] <= res[23:0];
        pb_q <= pb[pb_ra];   if (x_pb_we) pb[x_pb_wa] <= res[23:0];
        rb_q <= rb[rb_ra];   if (x_rb_we) rb[x_rb_wa] <= res[26:0];
        rb2_q <= rb2[rb2_ra]; if (x_rb_we) rb2[x_rb_wa] <= res[26:0];
        ih_q <= ih[ih_ra];   if (x_ih_we) ih[x_ih_wa] <= res[26:0];
        p0_q <= p0b[p0_ra];  if (x_p0_we) p0b[x_p0_wa] <= res[15:0];
        cos_q <= cosr[cos_ra];
        nz_q <= noise[nz_ra];
        qc_q <= qcoef[qc_ra];
    end

    // ------------------------------------------------------------------ state
    typedef enum logic [4:0] {
        V_IDLE, V_Q0, V_Q0W, V_Q1, V_Q1W, V_LOOP, V_NORM1, V_NSH, V_HA, V_HB, V_OA, V_OB,
        V_OBW, V_OC, V_OD, V_OE, V_DCT, V_DCTW, V_FIR, V_FIRW, V_FIRW2, V_PAIR, V_ZERO,
        V_DONE
    } vstate_t;
    vstate_t st;
    logic  [3:0] vop;
    logic [15:0] a0, a1, a2, a3, a4, a5, a6;
    logic [11:0] k, k_d, lcnt;
    logic        dv;
    logic signed [26:0] qm, qn, mfac;
    logic signed [6:0]  qsh;
    logic  [4:0] xs;
    logic [39:0] orv;
    logic  [7:0] n;                         // IMDCT: half-transform / output index
    logic [10:0] m, mstep;                  // the running angle and its step
    logic  [7:0] hj;                        // RWIN's Hann index
    logic  [6:0] s;                         // IPQF sample
    logic  [3:0] j;                         // IPQF output within a sample
    logic  [4:0] pos0, pos1;
    logic signed [40:0] yv;
    logic  [7:0] e_q;
    logic        wflat, wzero;
    logic        cneg_d;

    wire  [4:0] pos = a0[0] ? pos1 : pos0;
    wire signed [26:0] cosv = cneg_d ? -$signed({1'b0, cos_q}) : $signed({1'b0, cos_q});

    // ------------------------------------------------------------------ angles
    logic [10:0] cm;                        // the angle read this cycle
    logic  [9:0] cidx;
    logic        cneg;
    logic [10:0] cm_a, cm_b;
    logic [11:0] cm_c;
    always_comb begin
        cm_a = 11'd1024 - cm;
        cm_b = cm - 11'd1024;
        cm_c = 12'd2048 - {1'b0, cm};
        if (cm <= 11'd512)       begin cidx = cm[9:0];   cneg = 1'b0; end
        else if (cm <= 11'd1024) begin cidx = cm_a[9:0]; cneg = 1'b1; end
        else if (cm <= 11'd1536) begin cidx = cm_b[9:0]; cneg = 1'b1; end
        else                     begin cidx = cm_c[9:0]; cneg = 1'b0; end
    end

    // IMDCT output n's window: flat (weight 1), zero, else sin at angle wang
    logic [10:0] wang;
    logic        wfl, wze;
    logic  [7:0] wj;
    always_comb begin
        wj = n - 8'd128;
        wfl = 1'b0; wze = 1'b0; wang = 11'd0;
        if (!n[7]) begin
            if (a1[1]) begin
                if (n < 8'd32)      wze = 1'b1;
                else if (n < 8'd96) wang = 11'd508 - {n - 8'd32, 3'd0};
                else                wfl = 1'b1;
            end else                wang = 11'd510 - {1'b0, n, 2'd0};
        end else begin
            if (a1[0]) begin
                if (wj < 8'd32)      wfl = 1'b1;
                else if (wj < 8'd96) wang = 11'd508 - {8'd95 - wj, 3'd0};
                else                 wze = 1'b1;
            end else                 wang = 11'd510 - {1'b0, 8'd127 - wj, 2'd0};
        end
    end

    // the IPQF DCT: output j, input k: angle 16 (2k + 1) c, c = 31 - 2j (j < 8) or 33 + 2j
    // (j >= 8, negated): start 16 c, step 32 c
    logic [10:0] dc;
    always_comb dc = j[3] ? ({6'd0, j, 1'b0} + 11'd33) : (11'd31 - {6'd0, j, 1'b0});

    // max |X| -> the normalisation shift: max(0, bitlen - 25)
    logic [5:0] blen;
    always_comb begin
        blen = 6'd0;
        for (int b = 0; b < 40; b++) if (orv[b]) blen = b + 1;
    end

    // ------------------------------------------------------------------ the datapath
    // Two stages. Issue (the per-state wiring below): the operands, the rounding, the
    // addend and the write address of an element; the product is registered (in the DSP
    // block) with all of them. Stage Y, a cycle later: accumulate, round, add, saturate,
    // write. Timing: the multiply and the round / saturate chain in one cycle closed at
    // 27.4 MHz standalone; split, each half has its own cycle (docs/at3p_decoder.md S3.6).
    logic signed [26:0] ma, mb;
    logic               p_sh20, acc_clr, acc_en, direct;
    logic signed [63:0] acc, sum, rsrc, rnd, addend, post, dsrc;
    logic         [5:0] rsh;
    logic         [1:0] satw;
    logic               sat_hit;
    logic signed [53:0] x_prod;
    logic               x_p_sh20, x_acc_clr, x_acc_en, x_direct;
    logic signed [63:0] x_addend, x_dsrc;
    logic         [5:0] x_rsh;
    logic         [1:0] x_satw;
    always_ff @(posedge clk) begin
        x_prod <= ma * mb;
        x_p_sh20 <= p_sh20; x_acc_clr <= acc_clr; x_acc_en <= acc_en; x_direct <= direct;
        x_addend <= addend; x_dsrc <= dsrc; x_rsh <= rsh; x_satw <= satw;
        x_xb_we <= xb_we; x_hb_we <= hb_we; x_tb_we <= tb_we; x_pb_we <= pb_we;
        x_rb_we <= rb_we; x_ih_we <= ih_we; x_p0_we <= p0_we;
        x_xb_wa <= xb_wa; x_hb_wa <= hb_wa; x_tb_wa <= tb_wa; x_pb_wa <= pb_wa;
        x_rb_wa <= rb_wa; x_ih_wa <= ih_wa; x_p0_wa <= p0_wa;
        if (!rst_n) begin
            x_acc_en <= 1'b0;
            x_xb_we <= 1'b0; x_hb_we <= 1'b0; x_tb_we <= 1'b0; x_pb_we <= 1'b0;
            x_rb_we <= 1'b0; x_ih_we <= 1'b0; x_p0_we <= 1'b0;
        end
    end
    always_comb begin
        sum  = (x_acc_clr ? 64'sd0 : acc) + (x_p_sh20 ? ({{10{x_prod[53]}}, x_prod} <<< 20)
                                                       : {{10{x_prod[53]}}, x_prod});
        rsrc = x_direct ? x_dsrc : sum;
        rnd  = (x_rsh == 6'd0) ? rsrc : ((rsrc + (64'sd1 <<< (x_rsh - 6'd1))) >>> x_rsh);
        post = rnd + x_addend;
        sat_hit = 1'b0;
        res = post;
        case (x_satw)
            W16: if (post > 64'sd32767 || post < -64'sd32768) begin
                     sat_hit = 1'b1; res = post[63] ? -64'sd32768 : 64'sd32767; end
            W24: if (post > 64'sd8388607 || post < -64'sd8388608) begin
                     sat_hit = 1'b1; res = post[63] ? -64'sd8388608 : 64'sd8388607; end
            W27: if (post > 64'sd67108863 || post < -64'sd67108864) begin
                     sat_hit = 1'b1; res = post[63] ? -64'sd67108864 : 64'sd67108863; end
            default: if (post > 64'sd549755813887 || post < -64'sd549755813888) begin
                     sat_hit = 1'b1; res = post[63] ? -64'sd549755813888 : 64'sd549755813887; end
        endcase
    end

    // sat40 of +-X (the negation of -2^39 is the one that saturates), sat24 of a region value
    logic signed [63:0] xneg, rsat1;
    always_comb begin
        xneg = a0[0] ? -$signed({{24{xb_q[39]}}, xb_q}) : $signed({{24{xb_q[39]}}, xb_q});
        if (xneg > 64'sd549755813887) xneg = 64'sd549755813887;
        rsat1 = $signed({{37{rb_q[26]}}, rb_q});
        if (rsat1 > 64'sd8388607) rsat1 = 64'sd8388607;
        if (rsat1 < -64'sd8388608) rsat1 = -64'sd8388608;
    end

    // width helpers (explicit part-selects, no size casts: CLAUDE.md, Quartus 17)
    logic  [5:0] psum, pmod;
    logic signed [6:0] qneg, osh;
    logic signed [63:0] xabs;
    logic  [5:0] bsub;
    logic  [7:0] n1;
    always_comb begin
        psum = {1'b0, pos} + {1'b0, k[4:0]};
        pmod = (psum >= 6'd24) ? psum - 6'd24 : psum;
        qneg = -qsh;
        osh  = 7'sd39 - $signed({e_q[7], e_q[7:2]});
        xabs = -xneg;
        bsub = blen - 6'd25;
        n1   = n + 8'd1;
    end

    // ------------------------------------------------------------------ per-state wiring
    always_comb begin
        ma = 27'sd0; mb = 27'sd0; p_sh20 = 1'b0; acc_clr = 1'b1; acc_en = 1'b0;
        rsh = 6'd0; addend = 64'sd0; satw = W40; direct = 1'b0; dsrc = 64'sd0;
        xb_we = 1'b0; hb_we = 1'b0; tb_we = 1'b0; pb_we = 1'b0; rb_we = 1'b0;
        ih_we = 1'b0; p0_we = 1'b0;
        xb_wa = a2[6:0] + k_d[6:0];
        hb_wa = n[6:0];
        tb_wa = a0[10:0] + k_d[10:0];
        pb_wa = {a1[0], a0[10:0] + k_d[10:0]};
        rb_wa = {a0[0], k_d[6:0]};
        ih_wa = j[3] ? {a0[0], 1'b0, pos, j[2:0]} : {a0[0], 1'b1, pos, 3'd7 - j[2:0]};
        p0_wa = {s, j};
        // reads
        spec_raddr = a0[11:0] + k;
        e_raddr = n;
        xb_ra = a2[6:0] + k[6:0];
        hb_ra = (n < 8'd64) ? 7'd63 - n[6:0] : (n < 8'd192) ? n[6:0] - 7'd64 : 7'd127 - n[6:0] + 7'd64;
        tb_ra = a0[10:0] + k[10:0];
        pb_ra = {a3[0], a2[10:0] + {4'd0, n[6:0]}};
        rb_ra = {a0[0], k[6:0]};
        rb2_ra = {1'b1, k[6:0]};
        ih_ra = {a0[0], k[0], pmod[4:0], j[3] ? 3'd7 - j[2:0] : j[2:0]};
        p0_ra = {s, j};
        nz_ra = a0[9:0] + k[9:0];
        qc_ra = {k[0], k[4:1], j};
        cm = m;
        case (st)
            V_Q0: begin                         // qm = rsr(MANT[wl] SF_M[sf], 9)
                ma = $signed({8'd0, mant[a3[2:0]]}); mb = $signed({11'd0, sfm[a4[5:0]]});
                rsh = 6'd9;
            end
            V_Q1: begin                         // qn = rsr(qm PWC[level], 7)
                ma = qm; mb = $signed({20'd0, pwc[a5[3:0]]}); rsh = 6'd7;
            end
            V_LOOP: begin
                case (vop)
                    OP_XCLR: xb_ra = k[6:0];
                    OP_RWIN: begin rb_ra = {a0[0], a1[6:0] + k[6:0]}; cm = {hj, 3'd0}; end
                    OP_WAVE: cm = 11'd512 - m;
                    OP_ADDT: rb_ra = {1'b0, k[6:0]};
                    default: ;
                endcase
                if (dv) case (vop)
                    OP_DQ: begin
                        ma = (qsh < 0) ? ($signed({{21{spec_rdata[5]}}, spec_rdata}) <<< qneg[5:0])
                                       : $signed({{21{spec_rdata[5]}}, spec_rdata});
                        mb = qm; rsh = (qsh < 0) ? 6'd0 : qsh[5:0];
                        xb_we = 1'b1;
                    end
                    OP_NZ: begin
                        ma = $signed({{11{nz_q[15]}}, nz_q}); mb = qn; rsh = qsh[5:0];
                        addend = $signed({{24{xb_q[39]}}, xb_q});
                        xb_we = 1'b1;
                    end
                    OP_XCLR: begin direct = 1'b1; xb_we = 1'b1; xb_wa = k_d[6:0]; end
                    OP_TZERO: begin direct = 1'b1; tb_we = 1'b1; pb_we = 1'b1; end
                    OP_RCLR: begin direct = 1'b1; rb_we = 1'b1; end
                    OP_RZERO: begin direct = 1'b1; rb_we = 1'b1; rb_wa = {a0[0], a1[6:0] + k_d[6:0]}; end
                    OP_RSAT: begin
                        direct = 1'b1; satw = W24; dsrc = a1[0] ? -rsat1 : rsat1;
                        rb_we = 1'b1;
                    end
                    OP_RWIN: begin               // x Hann[j] = (2^25 - cos(pi 8 j / 1024)) / 2, floor
                        ma = $signed(rb_q);
                        mb = $signed(({1'b0, 26'h2000000} - {cosv[26], cosv}) >>> 1);
                        rsh = 6'd25;
                        rb_we = 1'b1; rb_wa = {a0[0], a1[6:0] + k_d[6:0]};
                    end
                    OP_WAVE: begin
                        ma = cosv; mb = $signed({1'b0, ampq[a3[5:0]]});
                        rsh = 6'd29; addend = $signed({{37{rb_q[26]}}, rb_q}); satw = W27;
                        rb_we = 1'b1;
                    end
                    OP_ADDT: begin
                        direct = 1'b1; satw = W24;
                        dsrc = $signed({{40{tb_q[23]}}, tb_q}) + $signed({{37{rb_q[26]}}, rb_q})
                             + $signed({{37{rb2_q[26]}}, rb2_q});
                        tb_we = 1'b1;
                    end
                    default: ;
                endcase
            end
            V_NORM1: xb_ra = k[6:0];
            V_NSH: begin                        // X = rsr(sat40(+-X), xs)
                xb_ra = k[6:0];
                if (dv) begin
                    direct = 1'b1; dsrc = xneg; rsh = {1'b0, xs};
                    xb_we = 1'b1; xb_wa = k_d[6:0];
                end
            end
            V_HA: begin                         // h[n] = sum_k X[k] cos(m_k): 128 MACs
                xb_ra = a0[0] ? 7'd127 - k[6:0] : k[6:0];
                acc_clr = (k_d == 12'd0); acc_en = dv;
                if (dv) begin ma = $signed(xb_q[26:0]); mb = cosv; end
            end
            V_HB: begin                         // h[n] = sat40(rsr(acc, 25 - xs))
                acc_clr = 1'b0; rsh = 6'd25 - {1'b0, xs};
                hb_we = 1'b1;
            end
            V_OA: cm = wang;                    // the window's sin, h, E[n], P
            V_OB: begin                         // M = rsr(w F4[E & 3], 25)
                ma = $signed({1'b0, wflat ? 26'h2000000 : cos_q});
                mb = $signed(f4[e_rdata[1:0]]); rsh = 6'd25;
            end
            V_OC: begin                         // acc = (y_hi M) << 20
                ma = {{6{yv[40]}}, yv[40:20]}; mb = mfac; p_sh20 = 1'b1; acc_en = 1'b1;
            end
            V_OD: begin                         // + y_lo M, rounded once; + P (first half)
                ma = $signed({7'd0, yv[19:0]}); mb = mfac; acc_clr = 1'b0;
                rsh = osh[5:0];
                satw = W24;
                if (wzero) begin direct = 1'b1; dsrc = 64'sd0; rsh = 6'd0; end
                if (!n[7]) begin
                    addend = $signed({{40{pb_q[23]}}, pb_q});
                    tb_we = 1'b1; tb_wa = a2[10:0] + {4'd0, n[6:0]};
                end else begin
                    pb_we = 1'b1; pb_wa = {a3[0], a2[10:0] + {4'd0, n[6:0]}};
                end
            end
            V_DCT: begin                        // d[j] = sum_k T[k][s] (+-cos): 16 MACs
                tb_ra = {k[3:0], s};
                acc_clr = (k_d == 12'd0); acc_en = dv;
                if (dv) begin
                    ma = $signed({{3{tb_q[23]}}, tb_q});
                    mb = j[3] ? -cosv : cosv;
                end
            end
            V_DCTW: begin                       // sat27(rsr(acc, 25)) into the history
                acc_clr = 1'b0; rsh = 6'd25; satw = W27; ih_we = 1'b1;
            end
            V_FIR: begin                        // 24 MACs: b1[pos + 2t] c1[t] + b2[pos + 2t + 1] c2[t]
                acc_clr = (k_d == 12'd0); acc_en = dv;
                if (dv) begin ma = $signed(ih_q); mb = $signed(qc_q); end
            end
            V_FIRW: begin                       // out = sat16(rsr(acc, 31))
                acc_clr = 1'b0; rsh = 6'd31; satw = W16;
                p0_we = !a0[0];
            end
            default: ;
        endcase
        cos_ra = cidx;
    end

    // ------------------------------------------------------------------ sequencing
    logic signed [26:0] fir_out;
    always_ff @(posedge clk) begin
        done <= 1'b0;
        if (pcm_valid && pcm_ready) pcm_valid <= 1'b0;
        cneg_d <= cneg;
        if (x_acc_en) acc <= sum;
        if (sat_hit && (x_xb_we || x_hb_we || x_tb_we || x_pb_we || x_rb_we || x_ih_we))
            sat_count <= sat_count + 16'd1;
        if (!rst_n) begin
            st <= V_IDLE; sat_count <= 16'd0; clip_count <= 16'd0;
            pos0 <= 5'd0; pos1 <= 5'd0; pcm_valid <= 1'b0;
        end else case (st)
            V_IDLE: if (start) begin
                vop <= op;
                a0 <= args[15:0];   a1 <= args[31:16];  a2 <= args[47:32];
                a3 <= args[63:48];  a4 <= args[79:64];  a5 <= args[95:80];
                a6 <= args[111:96];
                k <= 12'd0; dv <= 1'b0; n <= 8'd0; s <= 7'd0; j <= 4'd0;
                case (op)
                    OP_XCLR, OP_RCLR, OP_RSAT, OP_ADDT: lcnt <= 12'd128;
                    OP_TZERO, OP_RWIN, OP_RZERO: lcnt <= args[43:32];
                    OP_WAVE: lcnt <= 12'd128;
                    default: lcnt <= args[27:16];
                endcase
                hj <= args[55:48];
                // the oscillator's start: (phase << 6) - (offset ^ 128) freq
                m <= {args[36:32], 6'd0} - ((args[79:64] == 16'd0) ? {args[19:16], 7'd0} : 11'd0);
                case (op)
                    OP_DQ, OP_NZ: st <= V_Q0;
                    OP_XNORM: begin orv <= 40'd0; st <= V_NORM1; end
                    OP_IMDCT: begin m <= 11'd514; st <= V_HA; end
                    OP_IPQF: begin m <= 11'd496; st <= V_DCT; end      // 16 (31 - 0)
                    OP_PCMZ: st <= V_ZERO;
                    default: st <= V_LOOP;
                endcase
            end
            V_Q0: st <= V_Q0W;
            V_Q0W: begin
                qm <= res[26:0];
                if (vop == OP_DQ) begin qsh <= $signed({2'b0, sfe[a4[5:0]]}) - 7'sd10; st <= V_LOOP; end
                else st <= V_Q1;
            end
            V_Q1: st <= V_Q1W;
            V_Q1W: begin
                qn <= res[26:0];
                qsh <= $signed({2'b0, sfe[a4[5:0]]}) + $signed({3'b0, a3[3:0]}) + $signed(a6[6:0]) + 7'sd3;
                st <= V_LOOP;
            end
            V_LOOP: begin                        // issue k; the data of k - 1 is used now
                dv <= (k < lcnt);
                k_d <= k;
                if (k < lcnt) begin
                    k <= k + 12'd1;
                    if (vop == OP_RWIN) hj <= hj + a4[7:0];
                    if (vop == OP_WAVE) m <= m + a1[10:0];
                end else if (!dv) st <= V_DONE;
            end
            V_NORM1: begin                       // max |X| as an OR of magnitudes
                dv <= (k < 12'd128);
                if (k < 12'd128) k <= k + 12'd1;
                if (dv) orv <= orv | (xneg[63] ? xabs[39:0] : xneg[39:0]);
                if (k == 12'd128 && !dv) begin
                    xs <= (blen > 6'd25) ? bsub[4:0] : 5'd0;
                    k <= 12'd0; st <= V_NSH;
                end
            end
            V_NSH: begin
                dv <= (k < 12'd128);
                k_d <= k;
                if (k < 12'd128) k <= k + 12'd1;
                else if (!dv) st <= V_DONE;
            end
            V_HA: begin
                dv <= (k < 12'd128);
                k_d <= k;
                if (k < 12'd128) begin
                    k <= k + 12'd1;
                    m <= m + {n, 3'd0} + 11'd1028;           // step 4 (2n + 257), mod 2048
                end else if (!dv) st <= V_HB;
            end
            V_HB: begin
                k <= 12'd0;
                if (n == 8'd127) begin n <= 8'd0; st <= V_OA; end
                else begin
                    n <= n + 8'd1;
                    m <= {n1, 2'd0} + 11'd514;               // start 2 (2n + 257)
                    st <= V_HA;
                end
            end
            V_OA: begin wflat <= wfl; wzero <= wze; st <= V_OB; end
            V_OB: begin
                e_q <= e_rdata;
                yv <= (n < 8'd64) ? -$signed({hb_q[39], hb_q}) : $signed({hb_q[39], hb_q});
                st <= V_OBW;
            end
            V_OBW: begin mfac <= res[26:0]; st <= V_OC; end
            V_OC: st <= V_OD;
            V_OD: st <= V_OE;                    // (stage Y of y_lo M writes in V_OE)
            V_OE: begin
                if (n == 8'd255) st <= V_DONE;
                else begin n <= n + 8'd1; st <= V_OA; end
            end
            V_DCT: begin
                dv <= (k < 12'd16);
                k_d <= k;
                if (k < 12'd16) begin k <= k + 12'd1; m <= m + {dc[5:0], 5'd0}; end
                else if (!dv) st <= V_DCTW;
            end
            V_DCTW: begin
                k <= 12'd0;
                if (j == 4'd15) begin j <= 4'd0; st <= V_FIR; end
                else begin
                    j <= j + 4'd1;
                    m <= (j + 4'd1 >= 4'd8) ? {({6'd0, j + 4'd1, 1'b0} + 11'd33), 4'd0}
                                            : {(11'd31 - {6'd0, j + 4'd1, 1'b0}), 4'd0};
                    st <= V_DCT;
                end
            end
            V_FIR: begin
                dv <= (k < 12'd24);
                k_d <= k;
                if (k < 12'd24) k <= k + 12'd1;
                else if (!dv) st <= V_FIRW;
            end
            V_FIRW: st <= V_FIRW2;
            V_FIRW2: begin
                k <= 12'd0;
                if (x_satw == W16 && sat_hit) clip_count <= clip_count + 16'd1;
                if (a0[0]) begin                  // channel 1: the pair out
                    pcm_l <= p0_q; pcm_r <= res[15:0]; pcm_valid <= 1'b1;
                    st <= V_PAIR;
                end else if (j == 4'd15) begin
                    j <= 4'd0;
                    pos0 <= (pos0 == 5'd0) ? 5'd23 : pos0 - 5'd1;
                    if (s == 7'd127) st <= V_DONE;
                    else begin s <= s + 7'd1; m <= 11'd496; st <= V_DCT; end
                end else begin j <= j + 4'd1; st <= V_FIR; end
            end
            V_PAIR: if (!pcm_valid || pcm_ready) begin
                if (j == 4'd15) begin
                    j <= 4'd0;
                    pos1 <= (pos1 == 5'd0) ? 5'd23 : pos1 - 5'd1;
                    if (s == 7'd127) st <= V_DONE;
                    else begin s <= s + 7'd1; m <= 11'd496; st <= V_DCT; end
                end else begin j <= j + 4'd1; st <= V_FIR; end
            end
            V_ZERO: if (!pcm_valid || pcm_ready) begin
                if (k == 12'd2048) st <= V_DONE;
                else begin pcm_l <= 16'd0; pcm_r <= 16'd0; pcm_valid <= 1'b1; k <= k + 12'd1; end
            end
            V_DONE: if (!pcm_valid || pcm_ready) begin done <= 1'b1; st <= V_IDLE; end
            default: st <= V_IDLE;
        endcase
    end

endmodule
