// umd/sub/sub_q.sv -- a small single-clock FIFO with a synchronous clear and a
// first-word-fall-through head, the array read synchronously so it is inferred as a RAM
// (CLAUDE.md "LUT-RAM").
//
// The array's read port is a plain registered read of the word that will be the head
// next cycle (ram_q <= mem[rptr_n]); nothing sits between the array and that register, so
// Quartus absorbs it into the M10K / MLAB. When that word is being written in the same
// cycle (a push into an empty queue, or the head's successor arriving as it is popped) the
// array would return old data, so the written word is kept in a bypass register and the
// head is taken from there: dout = byp ? byp_d : ram_q, a mux AFTER the RAM. (A first
// version muxed the bypass in front of the output register; Quartus then could not infer
// the RAM and a 64 x 149-bit queue became 9,500 registers.) `clear` empties it in one cycle
// (a subtitle flush); umd/sfifo.sv has only an asynchronous reset.

`default_nettype none

module sub_q #(
    parameter int DW = 32,
    parameter int AW = 4
) (
    input  wire           clk,
    input  wire           rst_n,
    input  wire           clear,
    input  wire  [DW-1:0] din,
    input  wire           push,
    output logic          full,
    output logic [DW-1:0] dout,
    output logic          dout_valid,
    input  wire           pop,
    output logic [AW:0]   count
);

    logic [DW-1:0] mem [0:(1<<AW)-1];
    logic [AW:0]   wptr, rptr;
    logic [DW-1:0] ram_q, byp_d;
    logic          byp;

    wire         do_pop  = pop && dout_valid;
    wire         do_push = push && !full;
    wire [AW:0]  rptr_n  = rptr + {{AW{1'b0}}, do_pop};
    wire [AW:0]  wptr_n  = wptr + {{AW{1'b0}}, do_push};
    wire [AW:0]  cnt_n   = wptr_n - rptr_n;

    assign full = (count == (1 << AW));
    assign dout = byp ? byp_d : ram_q;

    always_ff @(posedge clk) begin
        if (do_push) mem[wptr[AW-1:0]] <= din;
        ram_q <= mem[rptr_n[AW-1:0]];
        byp_d <= din;
    end

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            wptr <= '0; rptr <= '0; count <= '0; dout_valid <= 1'b0; byp <= 1'b0;
        end else begin
            wptr       <= wptr_n;
            rptr       <= rptr_n;
            count      <= cnt_n;
            dout_valid <= (cnt_n != '0);
            byp        <= do_push && (wptr == rptr_n);
        end
    end

endmodule

`default_nettype wire
