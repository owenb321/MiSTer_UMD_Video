// umd/nav/nav_seq.sv -- the navigation engine (docs/nav_engine.md S7, A12): a microcoded
// sequencer that runs umd/nav/nav.uasm (assembled into nav_ucode.mem by tools/nav_isa.py, whose
// emulator is the executable definition of every instruction; this module must match it word
// for word and must not be slower than its cycle charges, S7 "Cycles").
//
// Strictly sequential, four cycles a word:
//   A  the program ROM reads pc
//   B  the word is in; the register file (two M10K copies: two read ports) reads rs / rt
//   C  execute: the ALU, a branch, the address of a load / store / I/O access; a file load
//      runs here, a byte every two cycles (fb_req -> fb_ack); a `wait` stalls here
//   D  write back (the register file, the carry), pc
// One word completes before the next is fetched, so the register file's write needs no
// forwarding. A data load (scratch RAM or I/O) issues its address in C and takes the data in D:
// the RAM reads C's address, and the parent answers an I/O read combinationally from io_addr.
// A store's data register is in rt too (the assembler puts it there): the second read port.
//
// Word: op[39:34] rd[33:30] rs[29:26] rt[25:22] imm[21:6] aux[5:0]. r0 reads 0. FN (aux):
// add sub adc sbc and or xor shl shr sltu seq sne; add / adc set C to the carry out, sub / sbc
// to the borrow. The data space: 0x000-0x1FF scratch RAM (512 x 32), 0x800 up I/O (the parent's).
//
// `restart` (start / stop: a hardware restart) sends pc to `vector` and abandons whatever the
// word in flight was doing (a file load's request is the parent's to drop).
// A reset is a stop: pc 1 (only a `start` walks).

module nav_seq #(
    parameter UCODE = "umd/nav/nav_ucode.mem"
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        restart,
    input  wire        vector,          // 0: start (pc 0), 1: stop (pc 1)

    // I/O (addresses 0x800 up): a write in C; a read's address in C, its data in D
    output logic [15:0] io_addr,
    output logic [31:0] io_wdata,
    output logic        io_we,
    output logic        io_re,
    input  wire  [31:0] io_rdata,

    // file loads: one byte a request; the parent answers fb_ack with fb_byte (two cycles when
    // the sector is in a slot)
    output logic        fb_req,
    output logic [31:0] fb_off,
    input  wire         fb_ack,
    input  wire   [7:0] fb_byte,

    // `wait`: stall until (status & mask) != 0
    input  wire  [15:0] status,

    // the trace (benches): pc of the word that completed, and its register write
    output logic        tr_valid,
    output logic [11:0] tr_pc,
    output logic        tr_we,
    output logic  [3:0] tr_rd,
    output logic [31:0] tr_val
);
    // ---- the ISA (tools/nav_isa.py OPS / FNS / CONDS) ----------------------------------------
    localparam [5:0] O_NOP = 6'd0, O_ALU = 6'd1, O_ALUI = 6'd2, O_LUI = 6'd3, O_LD = 6'd4,
                     O_ST = 6'd5, O_LBF = 6'd6, O_LBL = 6'd7, O_BR = 6'd8, O_BRI = 6'd9,
                     O_BCS = 6'd10, O_BCC = 6'd11, O_JMP = 6'd12, O_CALL = 6'd13, O_RET = 6'd14,
                     O_WAIT = 6'd15;
    localparam [3:0] F_ADD = 4'd0, F_SUB = 4'd1, F_ADC = 4'd2, F_SBC = 4'd3, F_AND = 4'd4,
                     F_OR = 4'd5, F_XOR = 4'd6, F_SHL = 4'd7, F_SHR = 4'd8, F_SLTU = 4'd9,
                     F_SEQ = 4'd10, F_SNE = 4'd11;

    // ---- the program ROM --------------------------------------------------------------------
    (* ramstyle = "M10K" *) logic [39:0] prog [0:2047];
    initial $readmemh(UCODE, prog);
    logic [10:0] pc, npc;
    logic [39:0] ir;
    always_ff @(posedge clk) ir <= prog[pc];

    wire  [5:0] op  = ir[39:34];
    wire  [3:0] rd  = ir[33:30];
    wire  [3:0] rs  = ir[29:26];
    wire  [3:0] rt  = ir[25:22];
    wire [15:0] imm = ir[21:6];
    wire  [5:0] aux = ir[5:0];

    // ---- the register file: two copies, one read port each -----------------------------------
    (* ramstyle = "M10K" *) logic [31:0] rfa [0:15];
    (* ramstyle = "M10K" *) logic [31:0] rfb [0:15];
    logic [31:0] ra_q, rb_q;
    logic        rf_we;
    logic  [3:0] rf_wa;
    logic [31:0] rf_wd;
    integer i;
    initial for (i = 0; i < 16; i = i + 1) begin rfa[i] = 32'd0; rfb[i] = 32'd0; end
    always_ff @(posedge clk) begin
        if (rf_we) begin rfa[rf_wa] <= rf_wd; rfb[rf_wa] <= rf_wd; end
        ra_q <= rfa[rs];
        rb_q <= rfb[rt];
    end
    wire [31:0] ra = (rs == 4'd0) ? 32'd0 : ra_q;   // r0 reads 0 (its copy is never written)
    wire [31:0] rb = (rt == 4'd0) ? 32'd0 : rb_q;

    // ---- the scratch RAM ----------------------------------------------------------------------
    (* ramstyle = "M10K" *) logic [31:0] ram [0:511];
    logic [31:0] ram_q;
    logic        ram_we;
    logic  [8:0] ram_a;
    logic [31:0] ram_wd;
    wire  [8:0] ram_ra;                 // the read address: C's own (the word is in at D)
    always_ff @(posedge clk) begin
        if (ram_we) ram[ram_a] <= ram_wd;
        ram_q <= ram[ram_ra];
    end

    // ---- the call stack (8 deep) -------------------------------------------------------------
    logic [10:0] stk [0:7];
    logic  [2:0] sp;

    // ---- the ALU ------------------------------------------------------------------------------
    // operand b: a register (alu), or the zero-extended immediate (alui)
    wire [31:0] opb  = (op == O_ALU) ? rb : {16'd0, imm};
    wire  [3:0] fn   = aux[3:0];
    logic       c;                      // the carry / borrow flag
    // one 33-bit adder: a + b (+ C) or a + ~b + (1, or !C)
    wire        subop = (fn == F_SUB) || (fn == F_SBC) || (fn == F_SLTU);
    wire        cin   = (fn == F_ADC) ? c : (fn == F_SBC) ? !c : subop;
    wire [32:0] sum   = {1'b0, ra} + {1'b0, subop ? ~opb : opb} + {32'd0, cin};
    wire        borrow = !sum[32];
    // one shifter: shl as shr of the bit-reversed operand
    logic [31:0] sh_in, sh_out, sh_rev;
    always_comb begin
        for (int k = 0; k < 32; k++) sh_in[k] = (fn == F_SHL) ? ra[31 - k] : ra[k];
        sh_out = sh_in >> opb[4:0];
        for (int k = 0; k < 32; k++) sh_rev[k] = (fn == F_SHL) ? sh_out[31 - k] : sh_out[k];
    end
    logic [31:0] alu_y;
    logic        alu_c, alu_cw;
    always_comb begin
        alu_y = 32'd0; alu_c = c; alu_cw = 1'b0;
        case (fn)
            F_ADD, F_ADC: begin alu_y = sum[31:0]; alu_c = sum[32]; alu_cw = 1'b1; end
            F_SUB, F_SBC: begin alu_y = sum[31:0]; alu_c = borrow;  alu_cw = 1'b1; end
            F_AND:  alu_y = ra & opb;
            F_OR:   alu_y = ra | opb;
            F_XOR:  alu_y = ra ^ opb;
            F_SHL, F_SHR: alu_y = sh_rev;
            F_SLTU: alu_y = {31'd0, borrow};
            F_SEQ:  alu_y = {31'd0, ra == opb};
            F_SNE:  alu_y = {31'd0, ra != opb};
            default: ;
        endcase
    end

    // branches: rd holds the condition (eq ne ltu geu); bri's constant is {rt, aux}
    wire [31:0] cmp_b = (op == O_BR) ? rb : {22'd0, rt, aux};
    wire        eq    = (ra == cmp_b);
    wire        ltu   = (ra < cmp_b);
    logic       taken;
    always_comb begin
        case (rd[1:0])
            2'd0: taken = eq;
            2'd1: taken = !eq;
            2'd2: taken = ltu;
            default: taken = !ltu;
        endcase
    end

    // ---- the sequencer -------------------------------------------------------------------------
    localparam [2:0] SA = 3'd0, SB = 3'd1, SC = 3'd2, SD = 3'd3, SL = 3'd4;
    logic  [2:0] st;
    logic [31:0] addr_q;                // the data address (C)
    logic        dsrc_io;               // D takes io_rdata (else ram_q)
    logic [31:0] lb_acc;
    logic  [2:0] lb_k;
    logic [31:0] lb_off;
    logic        wb_we;
    logic [31:0] wb_val;
    logic        wb_ld;                 // D writes the loaded word
    logic        c_next;
    logic        c_we;

    wire [31:0] daddr = ra + {16'd0, imm};
    assign ram_ra = daddr[8:0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // THE RESET IS A STOP (fj#64): pc 1, the stop vector (INIT, then halt), as the pre-A12 reader
            // reset to its idle state. At pc 0 (the start vector) a reset with the image still held --
            // the OSD's Reset, part of rst_n -- walked and played the disc behind the idle screen
            st <= SA; pc <= 11'd1; sp <= 3'd0; c <= 1'b0;
            io_we <= 1'b0; io_re <= 1'b0; fb_req <= 1'b0; ram_we <= 1'b0; rf_we <= 1'b0;
            wb_we <= 1'b0; wb_ld <= 1'b0; c_we <= 1'b0; tr_valid <= 1'b0;
        end else begin
            io_we <= 1'b0; io_re <= 1'b0; fb_req <= 1'b0; ram_we <= 1'b0; rf_we <= 1'b0;
            tr_valid <= 1'b0;
            if (restart) begin
                st <= SA; pc <= {10'd0, vector}; sp <= 3'd0;
                wb_we <= 1'b0; wb_ld <= 1'b0; c_we <= 1'b0;
            end else case (st)
            SA: st <= SB;                                   // prog[pc] -> ir
            SB: st <= SC;                                   // rfa[rs], rfb[rt]
            SC: begin
                npc   <= pc + 11'd1;
                wb_we <= 1'b0; wb_ld <= 1'b0; c_we <= 1'b0;
                st    <= SD;
                case (op)
                    O_ALU, O_ALUI: begin
                        wb_we <= (rd != 4'd0); wb_val <= alu_y; c_we <= alu_cw; c_next <= alu_c;
                    end
                    O_LUI: begin wb_we <= (rd != 4'd0); wb_val <= {imm, 16'd0}; end
                    O_LD: begin
                        wb_we <= (rd != 4'd0); wb_ld <= 1'b1;
                        if (daddr[15:0] >= 16'h0800) begin
                            io_addr <= daddr[15:0]; io_re <= 1'b1; dsrc_io <= 1'b1;
                        end else
                            dsrc_io <= 1'b0;
                    end
                    O_ST: begin
                        if (daddr[15:0] >= 16'h0800) begin
                            io_addr <= daddr[15:0]; io_wdata <= rb; io_we <= 1'b1;
                        end else begin
                            ram_a <= daddr[8:0]; ram_wd <= rb; ram_we <= 1'b1;
                        end
                    end
                    O_LBF, O_LBL: begin
                        lb_off <= daddr; lb_k <= 3'd0; lb_acc <= 32'd0;
                        fb_off <= daddr; fb_req <= 1'b1;
                        st <= SL;
                    end
                    O_BR, O_BRI: if (taken) npc <= imm[10:0];
                    O_BCS: if (c)  npc <= imm[10:0];
                    O_BCC: if (!c) npc <= imm[10:0];
                    O_JMP: npc <= imm[10:0];
                    O_CALL: begin stk[sp] <= pc + 11'd1; sp <= sp + 3'd1; npc <= imm[10:0]; end
                    O_RET: begin npc <= stk[sp - 3'd1]; sp <= sp - 3'd1; end
                    O_WAIT: if ((status & imm) == 16'd0) st <= SC;   // stall
                    default: ;
                endcase
            end
            SL: if (fb_ack) begin                           // a file byte: big- or little-endian
                if (op == O_LBF) lb_acc <= {lb_acc[23:0], fb_byte};
                else             lb_acc <= lb_acc | ({24'd0, fb_byte} << {lb_k, 3'b000});
                if ({1'b0, lb_k} + 4'd1 == {1'b0, aux[2:0]}) begin
                    wb_we <= (rd != 4'd0); st <= SD;
                end else begin
                    lb_k   <= lb_k + 3'd1;
                    fb_off <= lb_off + {29'd0, lb_k} + 32'd1;
                    fb_req <= 1'b1;
                end
            end
            SD: begin
                if (wb_we) begin
                    rf_we <= 1'b1; rf_wa <= rd;
                    rf_wd <= wb_ld ? (dsrc_io ? io_rdata : ram_q) :
                             (op == O_LBF || op == O_LBL) ? lb_acc : wb_val;
                end
                if (c_we) c <= c_next;
                tr_valid <= 1'b1; tr_pc <= {1'b0, pc}; tr_we <= wb_we; tr_rd <= rd;
                tr_val <= wb_ld ? (dsrc_io ? io_rdata : ram_q) :
                          (op == O_LBF || op == O_LBL) ? lb_acc : wb_val;
                pc <= npc;
                st <= SA;
            end
            default: st <= SA;
            endcase
        end
    end

endmodule
