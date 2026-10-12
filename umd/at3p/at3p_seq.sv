// umd/at3p/at3p_seq.sv -- the ATRAC3plus decoder's microcoded sequencer
//
// Runs umd/at3p/at3p.uasm (assembled into at3p_ucode.mem): the AU header, the whole
// parse and the synthesis control. The instruction set, the memory map and every
// instruction's effect are defined by tools/at3p_isa.py's emulator; the bench
// (bench/umd/run_at3p_seq.sh) scores this module's register-write trace and record
// RAM against it instruction by instruction. docs/at3p_decoder.md S3.4.
//
// Timing: one instruction a cycle for ALU ops, stores and branches (the next
// instruction's address goes to the program ROM while the current one executes); a load
// takes two cycles; GET n takes n + 1 (the reader is bit-serial: one bit a cycle, no
// barrel shifter); a Huffman read two cycles a code bit plus three; a vector op waits
// for its engine.
//
// The bit reader holds one byte, fetched only when a bit is needed. Inside a frame
// (FRAME n .. FEND) at most n bytes are taken; bits past them read 0 and set `overrun`.
// FEND drops the held byte and drains the frame's untaken bytes. Outside a frame (the
// AU header) bytes are taken as the program asks for them.
//
// The Huffman unit walks a canonical code one bit at a time: code = code << 1 | bit; the
// count of codes of this length is CNT[table][len]; the code is found when
// code - first < count, else first = (first + count) << 1. Bits are consumed as read,
// so a code in no codebook (12 bits, no match) cannot be un-read: the frame is refused
// (E_VLC_HOLE, docs/at3p_decoder.md S3.2), where ffmpeg reads on with -1.
//
// The quantised spectrum and the gain-exponent table are written by the program and
// read only by the vector engines (one write and one read port each: one M10K each).

`default_nettype none

module at3p_seq (
    input  wire         clk,
    input  wire         rst_n,

    input  wire   [7:0] in_byte,
    input  wire         in_valid,
    output logic        in_ready,

    // vector ops: a start pulse with the op and r8..r15; the sequencer waits for done
    output logic        vop_start,
    output logic  [3:0] vop_op,
    output logic [127:0] vop_args,          // {r15, r14, ..., r8}
    input  wire         vop_done,

    // the engines' read ports
    input  wire  [11:0] spec_raddr,
    output logic  [5:0] spec_rdata,
    input  wire   [7:0] e_raddr,
    output logic  [7:0] e_rdata,

    // status
    output logic        mark_valid,
    output logic [15:0] mark_id,
    output logic        err_valid,          // an ERR or a Huffman hole: the frame is refused
    output logic  [7:0] err_code,
    output logic        overrun,            // the current frame read past its end

    // the trace (benches): register writes (kind 0, addr = the register) and stores
    // (kind 1, addr = the address), in program order
    output logic        tr_valid,
    output logic [11:0] tr_pc,
    output logic        tr_kind,
    output logic [13:0] tr_addr,
    output logic [15:0] tr_val
);

`include "umd/at3p/at3p_ucode.svh"

    localparam [5:0] O_ALU = 6'd1, O_ALUI = 6'd2, O_LD = 6'd3, O_ST = 6'd4, O_GET = 6'd5,
                     O_GETR = 6'd6, O_VLC = 6'd7, O_BR = 6'd8, O_BRI = 6'd9, O_JMP = 6'd10,
                     O_CALL = 6'd11, O_RET = 6'd12, O_ERR = 6'd13, O_VOP = 6'd14,
                     O_BLEFT = 6'd15, O_FRAME = 6'd16, O_FEND = 6'd17, O_MARK = 6'd18;
    localparam [7:0] E_VLC_HOLE = 8'd18;

    // ------------------------------------------------------------------ memories
    (* ramstyle = "M10K" *) logic [39:0] prog [0:UC_WORDS-1];
    (* ramstyle = "M10K" *) logic [15:0] crom [0:CONST_WORDS-1];
    (* ramstyle = "M10K" *) logic [13:0] vhdr [0:145];
    (* ramstyle = "M10K" *) logic  [8:0] vcnt [0:2335];
    (* ramstyle = "M10K" *) logic  [7:0] vsym [0:VLC_SYMS-1];
    (* ramstyle = "M10K" *) logic [15:0] rec  [0:2047];
    (* ramstyle = "M10K" *) logic  [5:0] spec [0:4095];
    (* ramstyle = "M10K" *) logic  [7:0] etab [0:255];
    initial begin
        $readmemh("umd/at3p/at3p_ucode.mem", prog);
        $readmemh("umd/at3p/at3p_const.mem", crom);
        $readmemh("umd/at3p/at3p_vlc_hdr.mem", vhdr);
        $readmemh("umd/at3p/at3p_vlc_cnt.mem", vcnt);
        $readmemh("umd/at3p/at3p_vlc_sym.mem", vsym);
        for (int i = 0; i < 2048; i++) rec[i] = 16'd0;    // M10K powers up zero, as ffmpeg's context
    end

    // ------------------------------------------------------------------ state
    typedef enum logic [3:0] {S_RESET, S_DEC, S_LD, S_BITS, S_VLC_B, S_VLC_C, S_VLC_S,
                              S_VLC_W, S_HOLD, S_VOP, S_DRAIN} state_t;
    state_t state;

    logic [11:0] pc, npc, rom_addr;
    logic [39:0] ir;
    logic [15:0] rf [0:15];
    logic [11:0] stack [0:7];
    logic  [2:0] sp;

    wire  [5:0] op   = ir[39:34];
    wire  [3:0] rd   = ir[33:30];
    wire  [3:0] rs   = ir[29:26];
    wire  [3:0] rt   = ir[25:22];
    wire [15:0] imm  = ir[21:6];
    wire  [5:0] aux  = ir[5:0];
    wire [15:0] vrs  = (rs == 4'd0) ? 16'd0 : rf[rs];
    wire [15:0] vrt  = (rt == 4'd0) ? 16'd0 : rf[rt];
    wire [15:0] vrd  = (rd == 4'd0) ? 16'd0 : rf[rd];

    always_ff @(posedge clk) ir <= prog[rom_addr];

    // ------------------------------------------------------------------ the ALU
    logic [15:0] alu_b, alu_y, sx_mask, sx_top;
    logic  [4:0] lg;
    always_comb begin
        alu_b = (op == O_ALUI) ? imm : vrt;
        case (alu_b[4:0])                   // (1 << b) - 1, all ones from 16 up
            5'd0:  sx_mask = 16'h0000;  5'd1:  sx_mask = 16'h0001;  5'd2:  sx_mask = 16'h0003;
            5'd3:  sx_mask = 16'h0007;  5'd4:  sx_mask = 16'h000F;  5'd5:  sx_mask = 16'h001F;
            5'd6:  sx_mask = 16'h003F;  5'd7:  sx_mask = 16'h007F;  5'd8:  sx_mask = 16'h00FF;
            5'd9:  sx_mask = 16'h01FF;  5'd10: sx_mask = 16'h03FF;  5'd11: sx_mask = 16'h07FF;
            5'd12: sx_mask = 16'h0FFF;  5'd13: sx_mask = 16'h1FFF;  5'd14: sx_mask = 16'h3FFF;
            5'd15: sx_mask = 16'h7FFF;  default: sx_mask = 16'hFFFF;
        endcase
        sx_top = sx_mask & ~(sx_mask >> 1);
        lg = 5'd0;
        for (int i = 0; i < 16; i++) if (vrs[i]) lg = i[4:0];
        case (aux[4:0])
            5'd0:  alu_y = vrs + alu_b;
            5'd1:  alu_y = vrs - alu_b;
            5'd2:  alu_y = vrs & alu_b;
            5'd3:  alu_y = vrs | alu_b;
            5'd4:  alu_y = vrs ^ alu_b;
            5'd5:  alu_y = vrs << alu_b[3:0];
            5'd6:  alu_y = $signed(vrs) >>> alu_b[3:0];
            5'd7:  alu_y = vrs >> alu_b[3:0];
            5'd8:  alu_y = {15'd0, $signed(vrs) < $signed(alu_b)};
            5'd9:  alu_y = {15'd0, vrs < alu_b};
            5'd10: alu_y = {15'd0, vrs == alu_b};
            5'd11: alu_y = {15'd0, vrs != alu_b};
            5'd12: alu_y = ($signed(vrs) < $signed(alu_b)) ? vrs : alu_b;
            5'd13: alu_y = ($signed(vrs) < $signed(alu_b)) ? alu_b : vrs;
            5'd14: alu_y = ((vrs & sx_top) != 16'd0) ? ((vrs & sx_mask) | ~sx_mask)
                                                     : (vrs & sx_mask);
            5'd15: alu_y = {11'd0, lg};
            5'd16: alu_y = vrs[15] ? (16'd0 - vrs) : vrs;
            default: alu_y = 16'd0;
        endcase
    end

    // branches: the condition in rd (eq ne lt ge); bri's constant is {rt, aux}, 10 bits
    wire [15:0] br_b  = (op == O_BRI) ? {{6{rt[3]}}, rt, aux} : vrt;
    wire        br_lt = $signed(vrs) < $signed(br_b);
    wire        br_eq = vrs == br_b;
    wire        taken = (rd[1:0] == 2'd0) ? br_eq : (rd[1:0] == 2'd1) ? !br_eq :
                        (rd[1:0] == 2'd2) ? br_lt : !br_lt;

    wire [15:0] maddr = vrs + vrt + imm;
    wire  [1:0] mreg  = maddr[13:12];

    always_comb begin
        npc = pc + 12'd1;
        case (op)
            O_BR, O_BRI: if (taken) npc = imm[11:0];
            O_JMP, O_CALL: npc = imm[11:0];
            O_RET: npc = stack[sp - 3'd1];
            O_ERR: npc = UC_ERROR;
            default: ;
        endcase
    end
    wire multi = (op == O_LD) || (op == O_GET) || (op == O_GETR) || (op == O_VLC) ||
                 (op == O_VOP) || (op == O_FEND);

    // ------------------------------------------------------------------ bit reader
    logic  [7:0] cur;
    logic  [3:0] cur_n;                     // bits left in cur (0..8)
    logic        in_frame;
    logic [15:0] fbytes, ftaken;
    logic [16:0] fbits;                     // bits of the frame consumed
    logic        want_bit, bit_ok, bit_val;
    logic  [4:0] get_left;
    wire         zero_fill = in_frame && (ftaken == fbytes);
    always_comb begin
        want_bit = (state == S_BITS && get_left != 5'd0) || state == S_VLC_B;
        bit_ok   = 1'b0;
        bit_val  = 1'b0;
        in_ready = 1'b0;
        if (state == S_DRAIN) begin
            in_ready = ftaken != fbytes;
        end else if (want_bit) begin
            if (cur_n != 4'd0) begin
                bit_ok = 1'b1; bit_val = cur[cur_n - 4'd1];
            end else if (zero_fill) begin
                bit_ok = 1'b1;
            end else begin
                in_ready = 1'b1;
                bit_ok = in_valid; bit_val = in_byte[7];
            end
        end
    end
    wire [17:0] bl_raw  = {1'b0, fbytes, 3'd0} - {1'b0, fbits};
    wire [15:0] bleft_v = !in_frame ? 16'd0 : bl_raw[17] ? 16'd0 :
                          (bl_raw[16:0] > 17'd32767) ? 16'd32767 : bl_raw[15:0];

    // ------------------------------------------------------------------ the ROMs' reads
    logic  [7:0] v_tab;
    logic  [3:0] v_len;
    logic [11:0] v_code, v_first;
    logic [13:0] v_idx, v_symaddr, v_base;
    logic  [8:0] v_cnt;
    logic  [7:0] v_sym;
    logic [15:0] rec_q, crom_q, get_acc;
    logic        ld_const;
    always_ff @(posedge clk) begin
        v_cnt  <= vcnt[{v_tab, v_len}];
        v_base <= vhdr[v_tab];
        v_sym  <= vsym[v_symaddr];
        rec_q  <= rec[maddr[10:0]];
        crom_q <= crom[maddr[11:0]];
        spec_rdata <= spec[spec_raddr];
        e_rdata <= etab[e_raddr];
    end

    always_comb for (int i = 0; i < 8; i++) vop_args[16*i +: 16] = rf[8 + i];

    // the program ROM address: what the next S_DEC executes
    always_comb begin
        if (state == S_RESET)      rom_addr = UC_RESET;
        else if (state == S_HOLD)  rom_addr = pc;
        else if (state == S_DEC)   rom_addr = multi ? pc + 12'd1 : npc;
        else                       rom_addr = pc + 12'd1;
    end

    // one register write a cycle, traced
    // (the ROM already fetches the successor during a multi-cycle instruction: its rd
    // and vector op are held from S_DEC)
    logic        w_en;
    logic  [3:0] w_rd, rd_hold;
    logic [15:0] w_val;
    always_comb begin
        w_en = 1'b0; w_rd = (state == S_DEC) ? rd : rd_hold; w_val = alu_y;
        case (state)
            S_DEC: case (op)
                O_ALU, O_ALUI: w_en = 1'b1;
                O_BLEFT: begin w_en = 1'b1; w_val = bleft_v; end
                default: ;
            endcase
            S_LD: begin w_en = 1'b1; w_val = ld_const ? crom_q : rec_q; end
            S_BITS: if (get_left == 5'd0) begin w_en = 1'b1; w_val = get_acc; end
            S_VLC_W: begin w_en = 1'b1; w_val = {8'd0, v_sym}; end
            default: ;
        endcase
        if (w_rd == 4'd0) w_en = 1'b0;
    end

    always_ff @(posedge clk) begin
        vop_start  <= 1'b0;
        mark_valid <= 1'b0;
        err_valid  <= 1'b0;
        tr_valid   <= w_en || (state == S_DEC && op == O_ST);
        tr_pc      <= pc;
        tr_kind    <= !w_en;
        tr_addr    <= w_en ? {10'd0, w_rd} : maddr[13:0];
        tr_val     <= w_en ? w_val : vrd;
        if (w_en) rf[w_rd] <= w_val;
        if (bit_ok) begin
            if (cur_n != 4'd0) cur_n <= cur_n - 4'd1;
            else if (!zero_fill) begin
                cur <= in_byte; cur_n <= 4'd7;
                if (in_frame) ftaken <= ftaken + 16'd1;
            end
            if (in_frame) begin
                fbits <= fbits + 17'd1;
                if ({1'b0, fbits} >= {fbytes, 3'd0}) overrun <= 1'b1;
            end
        end
        if (!rst_n) begin
            state <= S_RESET;
            pc <= UC_RESET;
            sp <= 3'd0;
            cur_n <= 4'd0;
            in_frame <= 1'b0;
            fbytes <= 16'd0; ftaken <= 16'd0; fbits <= 17'd0;
            overrun <= 1'b0;
            for (int i = 0; i < 16; i++) rf[i] <= 16'd0;
        end else case (state)
            S_RESET: state <= S_DEC;
            S_DEC: begin
                rd_hold <= rd;
                case (op)
                    O_LD: begin ld_const <= (mreg == 2'd1); state <= S_LD; end
                    O_ST: begin
                        if (mreg == 2'd0) rec[maddr[10:0]] <= vrd;
                        if (mreg == 2'd2) spec[maddr[11:0]] <= vrd[5:0];
                        if (mreg == 2'd3) etab[maddr[7:0]] <= vrd[7:0];
                    end
                    O_GET, O_GETR: begin
                        get_acc <= 16'd0;
                        get_left <= (op == O_GET) ? imm[4:0] : vrt[4:0];
                        state <= S_BITS;
                    end
                    O_VLC: begin
                        v_tab <= vrs[7:0] + imm[7:0];
                        v_len <= 4'd1;
                        v_code <= 12'd0; v_first <= 12'd0; v_idx <= 14'd0;
                        state <= S_VLC_B;
                    end
                    O_CALL: begin stack[sp] <= pc + 12'd1; sp <= sp + 3'd1; end
                    O_RET: sp <= sp - 3'd1;
                    O_ERR: begin err_valid <= 1'b1; err_code <= imm[7:0]; sp <= 3'd0; end
                    O_VOP: begin vop_start <= 1'b1; vop_op <= imm[3:0]; state <= S_VOP; end
                    O_FRAME: begin
                        in_frame <= 1'b1; fbytes <= vrs; ftaken <= 16'd0; fbits <= 17'd0;
                        overrun <= 1'b0;
                    end
                    O_FEND: begin cur_n <= 4'd0; in_frame <= 1'b0; state <= S_DRAIN; end
                    O_MARK: begin mark_valid <= 1'b1; mark_id <= imm; end
                    default: ;
                endcase
                if (!multi) pc <= npc;
            end
            S_LD: begin pc <= pc + 12'd1; state <= S_DEC; end
            S_BITS: begin
                if (get_left == 5'd0) begin
                    pc <= pc + 12'd1; state <= S_DEC;
                end else if (bit_ok) begin
                    get_acc <= {get_acc[14:0], bit_val};
                    get_left <= get_left - 5'd1;
                end
            end
            S_VLC_B: if (bit_ok) begin          // a code bit; its length's count lands next
                v_code <= {v_code[10:0], bit_val};
                state <= S_VLC_C;
            end
            S_VLC_C: begin
                if (v_code - v_first < {3'd0, v_cnt}) begin
                    v_symaddr <= v_base + v_idx + {2'd0, v_code - v_first};
                    state <= S_VLC_S;
                end else if (v_len == 4'd12) begin      // a hole: refuse the frame
                    err_valid <= 1'b1; err_code <= E_VLC_HOLE;
                    sp <= 3'd0; pc <= UC_ERROR; state <= S_HOLD;
                end else begin
                    v_idx <= v_idx + {5'd0, v_cnt};
                    v_first <= (v_first + {3'd0, v_cnt}) << 1;
                    v_len <= v_len + 4'd1;
                    state <= S_VLC_B;
                end
            end
            S_VLC_S: state <= S_VLC_W;              // the symbol ROM reads v_symaddr
            S_VLC_W: begin pc <= pc + 12'd1; state <= S_DEC; end
            S_HOLD:  state <= S_DEC;                // the ROM fetches the ERROR vector
            S_VOP:   if (vop_done) begin pc <= pc + 12'd1; state <= S_DEC; end
            S_DRAIN: begin
                if (ftaken == fbytes) begin pc <= pc + 12'd1; state <= S_DEC; end
                else if (in_valid) ftaken <= ftaken + 16'd1;
            end
            default: state <= S_RESET;
        endcase
    end

endmodule
