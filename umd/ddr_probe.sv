// umd/ddr_probe.sv -- a passive watcher on one Avalon-MM DDR3 port (HIL telemetry,
// docs/hil_harness.md "Telemetry"): what the HPS f2sdram port sees at emu's DDRAM* /
// DDRAM2* wires. Built after the P5e rig round (2026-09-26): a freeze that followed the
// RIG, not the build (the previous build froze identically; a reboot cured it), with no
// instrument that could say whether the core had stopped issuing, the port was refusing,
// or read beats never came back. These counters tell the three apart:
//   wr_beats   write beats accepted (write && !waitrequest), 24-bit
//   rd_beats   read beats returned (readdatavalid), 24-bit (the telemetry sends [23:8])
//   owed       read beats accepted but not yet returned (sum of accepted burstcounts
//              minus returned beats; saturating at both ends)
//   busy       the current run of cycles with a request held under waitrequest
//              (saturating: 0xFFFF = at least 0.73 ms at 90 MHz -- a hang)
//   busy_max   the longest such run since reset (saturating)
// It only observes: no output reaches the port. clk_mem; emu carries the values to
// clk_sys through a cdc_snap for umd_telem. Every input is registered once first and the
// counters run on the copies -- the same counts a cycle later: P7's port signals come from
// ddr_mux2's orphan compare, and at 97 % ALM that compare into `owed`'s adder missed clk_mem
// (-0.25 ns at -40 C, 2026-09-30).

`default_nettype none

module ddr_probe (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         read,
    input  wire         write,
    input  wire  [7:0]  burstcount,
    input  wire         waitrequest,
    input  wire         readdatavalid,
    output logic [23:0] wr_beats,
    output logic [23:0] rd_beats,
    output logic [15:0] owed,
    output logic [15:0] busy,
    output logic [15:0] busy_max
);
    logic       rd_q, wr_q, wt_q, rv_q;
    logic [7:0] bc_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rd_q <= 1'b0; wr_q <= 1'b0; wt_q <= 1'b0; rv_q <= 1'b0; bc_q <= '0; end
        else begin rd_q <= read; wr_q <= write; wt_q <= waitrequest; rv_q <= readdatavalid; bc_q <= burstcount; end
    end
    wire req = rd_q || wr_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_beats <= '0; rd_beats <= '0; owed <= '0; busy <= '0; busy_max <= '0;
        end else begin
            if (wr_q && !wt_q) wr_beats <= wr_beats + 24'd1;
            if (rv_q) rd_beats <= rd_beats + 24'd1;
            // beats owed: + the accepted burst, - a returned beat (never below 0, never wraps)
            begin : owed_upd
                logic [16:0] o;
                o = {1'b0, owed};
                if (rd_q && !wt_q) o = o + {9'd0, bc_q};
                if (rv_q && o != 17'd0) o = o - 17'd1;
                owed <= (o > 17'h0FFFF) ? 16'hFFFF : o[15:0];
            end
            // the BUSY run: a request held under waitrequest
            if (req && wt_q) begin
                if (busy != 16'hFFFF) busy <= busy + 16'd1;
                if (busy >= busy_max && busy_max != 16'hFFFF) busy_max <= busy + ((busy != 16'hFFFF) ? 16'd1 : 16'd0);
            end else busy <= '0;
        end
    end
endmodule

`default_nettype wire
