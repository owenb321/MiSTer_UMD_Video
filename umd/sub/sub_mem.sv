// umd/sub/sub_mem.sv -- the subtitle side's DDR3 clients as one Avalon master
// (docs/subtitles.md §2: master A of ddr_mux2 on ram2; the raster readers are B)
//
//   a: sub_ring's writer (writes) -- first: it must not back up into the demux
//   r: sub_dec's ring reader (reads)
//   w: sub_dec's plane writer, sub_plane_wr (writes)
// (A12 SD1, docs/nav_engine.md §10: the decode is back in the fabric; from A7 to SD1 the ring
// writer was the only client -- the HPS read the ring and wrote the planes.)
//
// The clients are arbitrated into ONE OUTPUT REGISTER, which is the port: a command (or a
// write beat) is taken from the granted client when the register is empty or its command is
// being accepted this cycle, and it is held there, unchanged, until the port accepts it --
// Avalon's rule by construction. A write burst keeps the grant until its last beat is taken
// (beats may gap); otherwise the grant moves between commands. Why a register (2026-09-30):
// main's ddr_mux2 checks the whole held command (the write data included) to drive A's
// waitrequest, which fed back combinationally into the ring's queue: mclk closed at 76.8 MHz
// of 90 in the unit fit (the register: 93.4).
// Read responses go to the reader, the only one. The port rule (no write beat while read
// beats are outstanding, as before A7): a writer is granted a new burst only when no read
// beat is outstanding here, counting a read still in the register.

`default_nettype none

module sub_mem (
    input  wire         clk,
    input  wire         rst_n,

    input  wire  [28:0] a_address,
    input  wire  [7:0]  a_burstcount,
    input  wire         a_write,
    input  wire  [63:0] a_writedata,
    input  wire  [7:0]  a_byteenable,
    output logic        a_waitrequest,

    input  wire  [28:0] r_address,
    input  wire  [7:0]  r_burstcount,
    input  wire         r_read,
    output logic        r_waitrequest,
    output logic [63:0] r_readdata,
    output logic        r_readdatavalid,

    input  wire  [28:0] w_address,
    input  wire  [7:0]  w_burstcount,
    input  wire         w_write,
    input  wire  [63:0] w_writedata,
    input  wire  [7:0]  w_byteenable,
    output logic        w_waitrequest,

    output logic [28:0] ddr_address,
    output logic [7:0]  ddr_burstcount,
    output logic        ddr_read,
    output logic        ddr_write,
    output logic [63:0] ddr_writedata,
    output logic [7:0]  ddr_byteenable,
    input  wire         ddr_waitrequest,
    input  wire  [63:0] ddr_readdata,
    input  wire         ddr_readdatavalid
);

    localparam [1:0] GA = 2'd0, GR = 2'd1, GW = 2'd2;
    logic [1:0] g;                          // the client holding a write burst's grant
    logic [7:0] wleft;                      // beats left of the write burst being taken (0: none)
    logic [8:0] rout;                       // read beats outstanding at the port
    logic       o_v;                        // a command / beat is held in the register
    wire        take      = !o_v || !ddr_waitrequest;
    wire        o_rd_pend = o_v && ddr_read;
    wire        no_reads  = (rout == 9'd0) && !o_rd_pend;

    // between commands: a (no reads outstanding), then r, then w (no reads outstanding)
    wire a_ok = a_write && no_reads;
    wire w_ok = w_write && no_reads;
    wire [1:0] g_now = (wleft != 8'd0) ? g : a_ok ? GA : r_read ? GR : w_ok ? GW : GA;
    wire       load  = take && ((wleft != 8'd0) ? ((g == GA) ? a_write : w_write)
                                                : (a_ok || r_read || w_ok));

    always_comb begin
        a_waitrequest   = !(load && g_now == GA);
        r_waitrequest   = !(load && g_now == GR);
        w_waitrequest   = !(load && g_now == GW);
        r_readdata      = ddr_readdata;
        r_readdatavalid = ddr_readdatavalid;
    end

    wire wbeat = load && (g_now != GR);
    wire racc  = ddr_read && !ddr_waitrequest;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            g <= GA; wleft <= '0; rout <= '0; o_v <= 1'b0;
            ddr_address <= '0; ddr_burstcount <= 8'd1; ddr_read <= 1'b0; ddr_write <= 1'b0;
            ddr_writedata <= '0; ddr_byteenable <= '0;
        end else begin
            g <= g_now;
            rout <= rout + (racc ? {1'b0, ddr_burstcount} : 9'd0) - {8'd0, ddr_readdatavalid};
            if (take) begin
                o_v <= load;
                ddr_read <= 1'b0; ddr_write <= 1'b0;
                if (load) case (g_now)
                    GA: begin
                        ddr_address <= a_address; ddr_burstcount <= a_burstcount; ddr_write <= 1'b1;
                        ddr_writedata <= a_writedata; ddr_byteenable <= a_byteenable;
                    end
                    GR: begin
                        ddr_address <= r_address; ddr_burstcount <= r_burstcount; ddr_read <= 1'b1;
                    end
                    default: begin
                        ddr_address <= w_address; ddr_burstcount <= w_burstcount; ddr_write <= 1'b1;
                        ddr_writedata <= w_writedata; ddr_byteenable <= w_byteenable;
                    end
                endcase
            end
            if (wbeat) begin
                if (wleft == 8'd0) wleft <= ((g_now == GA) ? a_burstcount : w_burstcount) - 8'd1;
                else               wleft <= wleft - 8'd1;
            end
        end
    end

endmodule

`default_nettype wire
