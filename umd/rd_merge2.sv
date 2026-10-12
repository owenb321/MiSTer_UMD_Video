// umd/rd_merge2.sv -- two read-only burst masters on one read-only master: the raster
// readers on ram2's B side (the video display reader first, then the overlay plane
// reader; docs/subtitles.md §2, docs/menus.md §4 item 2)
//
// Why here and not a third master of ddr_mux2: both clients are raster-paced READERS
// with a deadline of one line each; the port's write rules (ddr_mux2) do not concern them
// and the subtitle writer (ddr_mux2's A) must not sit between them.
//   * Fixed priority: P (the video) whenever it presents a command, else Q (the plane).
//     Q cannot starve: P's line is finite (180 words); the deadlines of both are scored in
//     bench/umd/sub_ram2_tb.sv.
//   * A presented command is never swapped under waitrequest: the choice is held until the
//     command is accepted (an Avalon master holds its command; the port behind ddr_mux2
//     is such a master's slave).
//   * Responses return in command order: a FIFO of (owner, beats) per accepted burst,
//     with its own full guard (16 bursts): nothing relies on the downstream's limit.

`default_nettype none

module rd_merge2 (
    input  wire         clk,
    input  wire         rst_n,

    input  wire  [28:0] p_address,
    input  wire  [7:0]  p_burstcount,
    input  wire         p_read,
    output logic        p_waitrequest,
    output logic [63:0] p_readdata,
    output logic        p_readdatavalid,

    input  wire  [28:0] q_address,
    input  wire  [7:0]  q_burstcount,
    input  wire         q_read,
    output logic        q_waitrequest,
    output logic [63:0] q_readdata,
    output logic        q_readdatavalid,

    output logic [28:0] m_address,
    output logic [7:0]  m_burstcount,
    output logic        m_read,
    input  wire         m_waitrequest,
    input  wire  [63:0] m_readdata,
    input  wire         m_readdatavalid
);

    logic        held, hsel;               // a command presented and not yet accepted: its owner
    logic        own [0:15];
    logic [7:0]  own_n [0:15];
    logic [3:0]  o_wr, o_rd;
    logic [4:0]  o_cnt;
    logic [7:0]  head_left;
    wire         reads_out = (o_cnt != 5'd0);
    wire         own_full  = o_cnt[4];

    wire sel = held ? hsel : !p_read;      // 0 P, 1 Q
    always_comb begin
        m_address    = sel ? q_address : p_address;
        m_burstcount = sel ? q_burstcount : p_burstcount;
        m_read       = (sel ? q_read : p_read) && !own_full;
        p_waitrequest = sel || m_waitrequest || own_full;
        q_waitrequest = !sel || m_waitrequest || own_full;
        p_readdata = m_readdata; q_readdata = m_readdata;
        p_readdatavalid = m_readdatavalid && reads_out && !own[o_rd];
        q_readdatavalid = m_readdatavalid && reads_out && own[o_rd];
    end

    wire acc  = m_read && !m_waitrequest;
    wire last = m_readdatavalid && reads_out && (head_left == 8'd0 ? own_n[o_rd] : head_left) == 8'd1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            held <= 1'b0; hsel <= 1'b0; o_wr <= '0; o_rd <= '0; o_cnt <= '0; head_left <= '0;
            for (int i = 0; i < 16; i++) begin own[i] <= 1'b0; own_n[i] <= '0; end
        end else begin
            held <= (sel ? q_read : p_read) && !acc;
            hsel <= sel;
            if (acc) begin
                own[o_wr] <= sel; own_n[o_wr] <= m_burstcount; o_wr <= o_wr + 1'b1;
            end
            if (m_readdatavalid && reads_out) begin
                if (last) begin o_rd <= o_rd + 1'b1; head_left <= '0; end
                else head_left <= (head_left == 8'd0 ? own_n[o_rd] : head_left) - 8'd1;
            end
            o_cnt <= o_cnt + {4'd0, acc} - {4'd0, last};
        end
    end

endmodule

`default_nettype wire
