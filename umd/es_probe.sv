// umd/es_probe.sv -- elementary-stream telemetry for the P2 hardware gate
//
// NOW A BENCH INSTRUMENT ONLY (2026-10-03): it fed only the diagnostic HUD, which left the core
// (area_plan.md A11), so it is out of UMD.qsf; ps_demux_tb, p2_chain_tb and p3_chain_tb still
// score the demux with it.
//
// Sits beside ps_demux's outputs (it never stalls them) and measures what the demux
// actually delivered, so the HUD can say "nothing real happened" as well as "it works":
//
//   vid_bytes / aud_bytes / sub_bytes   bytes handed to each sink since the last clear
//   vid_crc   CRC-32 (zlib / IEEE 802.3: reflected 0xEDB88320, init and final XOR
//             0xFFFFFFFF) of the first CRC_BYTES video ES bytes; crc_done once that
//             many were seen. tools/psmf_golden.py --crc <disc> prints the expected
//             value for a disc's main clip, so a screenshot proves the demux is
//             byte-exact on silicon, not merely busy.
//   pes_rate  pes_hdr_ok pulses (packs carrying an A/V PES) in the last whole second
//
// The CRC step is an unrolled 8-iteration loop in an always block, not a `function
// automatic` (CLAUDE.md: Quartus 17 silently miscompiles some of those).

module es_probe #(
    parameter CRC_BYTES  = 1 << 20,        // 1 MiB of video ES
    parameter SEC_CYCLES = 27_000_000      // clk cycles per second (the bench shrinks it)
) (
    input             clk,
    input             rst_n,
    input             clear,               // pulse: a new mount

    input       [7:0] vid_byte,
    input             vid_take,            // vid_valid && vid_ready
    input             aud_take,
    input             sub_take,
    input             pes_hdr_ok,

    output reg [31:0] vid_bytes,
    output reg [31:0] aud_bytes,
    output reg [31:0] sub_bytes,
    output     [31:0] vid_crc,             // final-XORed: compare with zlib.crc32
    output reg        crc_done,
    output reg [15:0] pes_rate
);

reg  [31:0] crc;                           // running register (pre final XOR)
reg  [31:0] crc_nx;
integer b;
always @* begin
    crc_nx = crc ^ {24'd0, vid_byte};
    for (b = 0; b < 8; b = b + 1)
        crc_nx = crc_nx[0] ? ((crc_nx >> 1) ^ 32'hEDB88320) : (crc_nx >> 1);
end
assign vid_crc = ~crc;

reg [31:0] sec_cnt;
reg [15:0] pes_cnt;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        vid_bytes <= 32'd0;
        aud_bytes <= 32'd0;
        sub_bytes <= 32'd0;
        crc       <= 32'hFFFFFFFF;
        crc_done  <= 1'b0;
        pes_rate  <= 16'd0;
        sec_cnt   <= 32'd0;
        pes_cnt   <= 16'd0;
    end else if (clear) begin
        vid_bytes <= 32'd0;
        aud_bytes <= 32'd0;
        sub_bytes <= 32'd0;
        crc       <= 32'hFFFFFFFF;
        crc_done  <= 1'b0;
        pes_rate  <= 16'd0;
        sec_cnt   <= 32'd0;
        pes_cnt   <= 16'd0;
    end else begin
        if (vid_take) begin
            vid_bytes <= vid_bytes + 32'd1;
            if (!crc_done) begin
                crc <= crc_nx;
                if (vid_bytes == CRC_BYTES - 1) crc_done <= 1'b1;
            end
        end
        if (aud_take) aud_bytes <= aud_bytes + 32'd1;
        if (sub_take) sub_bytes <= sub_bytes + 32'd1;
        if (sec_cnt == SEC_CYCLES - 1) begin
            sec_cnt  <= 32'd0;
            pes_rate <= pes_cnt + {15'd0, pes_hdr_ok};
            pes_cnt  <= 16'd0;
        end else begin
            sec_cnt <= sec_cnt + 32'd1;
            if (pes_hdr_ok && pes_cnt != 16'hFFFF) pes_cnt <= pes_cnt + 16'd1;
        end
    end
end

endmodule
