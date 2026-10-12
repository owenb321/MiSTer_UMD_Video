// umd/ps_demux.sv -- UMD Video (PSMF) program-stream demultiplexer (roadmap P2)
//
// Harvested from MiSTer_DVD's dvd/ps_demux.sv with the surgery docs/harvest.md lists.
// A UMD .MPS is an MPEG-2 program stream in 2048-byte packs (docs/umd_video_format.md
// "The stream"); this module parses pack/PES headers and routes:
//
//   0xE0                  H.264 Annex-B video           -> vid_*   (every byte, verbatim)
//   0xBD sub 0x00-0x0F    ATRAC3plus audio, the track   -> aud_*   sub-header 4 bytes
//                         whose id == aud_track                    [sub, 00, FAP hi, FAP lo]
//   0xBD sub 0x80-0x9F    subtitles, the track whose    -> sp_*    sub-header 2 bytes
//                         id - 0x80 == sp_track, when              [sub, 00]
//                         sp_enable
//   0xBB / 0xBE / 0xBF / anything else >= 0xBB          skipped BY LENGTH (0xBF = the
//                                                       per-GOP index packs, whose payload
//                                                       can hold 00 00 01: hunting past it
//                                                       would false-trigger)
//
// The golden is tools/psmf_ref.py (parse() / es()); the bench is
// bench/umd/ps_demux_tb.sv + run_ps_demux.sh.
//
// SURGERY vs the DVD module (each removal is a whole path, not a tie-off):
//   * substream ids: audio 0x00-0x0F with a 4-bit track compare (was AC-3 0x80-87 /
//     DTS 0x88-8F / LPCM 0xA0-A7 with 3 bits); subtitles 0x80-0x9F (was 0x20-0x3F) with
//     the 2-byte sub-header P1 measured (only then do unit lengths add up).
//   * audio sub-header 3 bytes after the id, [00, FAP hi, FAP lo]. FAP counts from the
//     byte AFTER the sub-header, 0 = the first payload byte (psmf_ref.py; the DVD AC-3
//     pointer is 1-based). On 33 discs every audio PES starts an access unit and FAP
//     is always inside the payload; a FAP at or past it drops the PES (the DVD's rule
//     for a nonsensical pointer, kept).
//   * the realign (aud_realign) is ARMED OUT OF RESET: the first audio byte forwarded
//     after a reset is an access unit's first byte (0F D0 ...), never the tail of a
//     frame the stream began inside. aud_frame_start still marks the first forwarded
//     byte of each PES (with that PES's PTS); AT3+ frame boundaries are the reframer's
//     (P6).
//   * aud_type / aud_lpcm_quant dropped: one codec. MPEG audio 0xC0-C7, NAV
//     (private_stream_2 PCI/DSI) routing, the CSS scrambling detector, the MPEG-1
//     system-stream header path, the raw-elementary-stream passthrough and the MPEG-2
//     still-frame flush (S_VID_FLUSH) are removed: none exists on a UMD, and a bare
//     elementary stream is not something this core loads.
//   * kept: pack/PES framing, skip-by-length, the PTS assembler, vid_mark, the
//     audio-substream observation tap (4-bit id), pes_hdr_ok, saw_pack.
//
// PES_packet_length == 0 ("unbounded") is not handled, as in the DVD module: ISO
// 13818-1 2.4.3.7 allows it only for video in TRANSPORT streams; psmf_ref.py accounts
// every byte of every undamaged clip on 33 discs with no such packet.

`default_nettype none

module ps_demux (
    input  wire         clk,
    input  wire         rst_n,

    // Input: held valid/ready byte stream (ps_stream_fifo)
    input  wire  [7:0]  in_byte,
    input  wire  [1:0]  in_ep,             // P6b3i: in_byte's item tag (umd_reader stream_ep)
    input  wire         in_valid,
    output logic        in_ready,

    // Audio track select: substream 0x00-0x0F. Only that substream is forwarded.
    input  wire  [3:0]  aud_track,
    // Pulse: the audio chain is being reset (a track switch). The rest of the old
    // track's PES in flight is dropped and forwarding resumes at an access unit
    // (see the realign block). ⚠ TIE IT OFF where unused: a floating port reads x.
    input  wire         aud_realign,

    // Subtitle select: substream 0x80 + sp_track, forwarded only when sp_enable.
    input  wire  [4:0]  sp_track,
    input  wire         sp_enable,

    // Video elementary stream (Annex-B, verbatim)
    output logic [7:0]  vid_byte,
    output logic        vid_valid,
    input  wire         vid_ready,
    // The FIRST payload byte of a video PES that carried a PTS (positional PTS
    // association: the PTS belongs to the first access unit starting at or after it)
    output logic        vid_mark,

    // Audio (ATRAC3plus AU stream of the selected track, from an AU start)
    output logic [7:0]  aud_byte,
    output logic        aud_valid,
    output logic        aud_frame_start,   // first forwarded byte of each PES
    input  wire         aud_ready,

    // PTS (33-bit, 90 kHz)
    output logic [32:0] vid_pts,
    output logic [1:0]  vid_ep,            // P6b3i: the item tag of the PES header vid_pts came in
    output logic        vid_pts_valid,
    output logic [32:0] aud_pts,
    output logic        aud_pts_valid,
    output logic [32:0] aud_frame_pts,       // held; valid with aud_frame_start
    output logic [1:0]  aud_frame_ep,        // P6b3i: its item tag (the PES header's sector's)
    output logic        aud_frame_pts_valid, // this PES carried a PTS

    // Subtitle payload (unit bytes after the 2-byte sub-header; units span PES)
    output logic [7:0]  sp_byte,
    output logic        sp_valid,
    output logic        sp_frame_start,
    output logic [32:0] sp_pts,
    output logic        sp_pts_valid,

    // One-cycle pulse per checkable PES header with a valid '10' marker, the first
    // after a pack header (a liveness denominator; see the DVD module's history)
    output logic        pes_hdr_ok,

    // Audio-substream observation (passive): which audio ids the stream carries and
    // whether the selected track is getting PES at all
    output logic        aud_ss_seen,
    output logic [3:0]  aud_ss_id,
    // P8 (docs/bare_streams.md): the same for subtitle substreams 0x80-0x9F -- a bare stream
    // file's tracks are learned from these two taps (no CLP declares them)
    output logic        sub_ss_seen,
    output logic [4:0]  sub_ss_id,
    output logic        aud_pes_hit,

    // Held: a 0xBA pack header has been seen since reset
    output logic        saw_pack
);

logic [1:0] aud_ep;                     // P6b3i: the audio PTS's item tag

// ============================================================================
// State machine
// ============================================================================
typedef enum logic [4:0] {
    S_HUNT,           // searching for 0x000001, then dispatch on stream_id
    S_PACK_SKIP,      // pack header bytes after 0xBA, incl. stuffing
    S_PES_LEN_HI,
    S_PES_LEN_LO,
    S_PES_HDR_FLAGS1,
    S_PES_HDR_FLAGS2, // PTS_DTS_flags
    S_PES_HDR_LEN,
    S_PES_HDR_SKIP,
    S_PTS,            // 5-byte PTS
    S_SUBSTREAM_ID,   // first byte of a private_stream_1 payload
    S_AUD_SUBHDR,     // [00, FAP hi, FAP lo]
    S_SP_SUBHDR,      // [00]
    S_SYS_LEN_HI,     // skip-by-length PES
    S_SYS_LEN_LO,
    S_VIDEO_DATA,
    S_AUDIO_DATA,
    S_AUD_SKIP,       // skip to the PES's first access unit
    S_SP_DATA,
    S_DISCARD         // discard bytes_remaining bytes, then hunt
} state_t;

state_t state;

logic [23:0] start_shift;
logic        start_code_detected;
assign start_code_detected = (start_shift == 24'h000001) && in_valid;

logic [15:0] pes_length;       // bytes left in the PES (after the length field)
logic  [7:0] pes_len_hi;
logic [15:0] bytes_remaining;
logic  [7:0] stream_id_r;
logic        mark_pending;
logic  [7:0] pts_buf [4:0];
logic  [2:0] pts_byte_count;
logic        pts_present;
logic        first_aud_byte;
logic        rlgn_pend;        // next forwarded audio must start on an access unit
logic  [3:0] aud_ssid_r;
logic  [7:0] fap_hi_r;
logic        first_sp_byte;
logic        aud_pes_has_pts;
logic        ever_seen_pack;
logic        pack_fresh;
assign saw_pack = ever_seen_pack;

// ============================================================================
// Output handshake (1:1 passthrough, no buffering)
// ============================================================================
always_comb begin
    in_ready  = 1'b1;
    vid_valid = 1'b0;
    vid_byte  = in_byte;
    vid_mark  = (state == S_VIDEO_DATA) && mark_pending;
    case (state)
        S_VIDEO_DATA: begin in_ready = vid_ready; vid_valid = in_valid; end
        S_AUDIO_DATA: in_ready = aud_ready;
        // subtitle sink is accept-always: never stall the shared stream on it
        S_SP_DATA:    in_ready = 1'b1;
        default:      in_ready = 1'b1;
    endcase
end

wire consume = in_valid && in_ready;
// the audio sub-header's last byte is being consumed and a payload follows
wire sub_exit = consume && (state == S_AUD_SUBHDR) && (pes_length != 16'd1) &&
                (bytes_remaining <= 16'd1);
wire [15:0] fap = {fap_hi_r, in_byte};     // valid on the sub-header's last byte

// ---- audio-substream observation tap (no FSM interaction) -------------------
wire obs_bd_aud = (state == S_SUBSTREAM_ID) && (pes_length != 16'd1) &&
                  (in_byte[7:4] == 4'h0);
wire obs_bd_sub = (state == S_SUBSTREAM_ID) && (pes_length != 16'd1) &&
                  (in_byte[7:5] == 3'b100);
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        aud_ss_seen <= 1'b0;
        aud_ss_id   <= 4'd0;
        sub_ss_seen <= 1'b0;
        sub_ss_id   <= 5'd0;
        aud_pes_hit <= 1'b0;
    end else begin
        aud_ss_seen <= consume && obs_bd_aud;
        if (consume && obs_bd_aud)
            aud_ss_id <= in_byte[3:0];         // holds the LAST seen id
        aud_pes_hit <= consume && obs_bd_aud && (in_byte[3:0] == aud_track);
        sub_ss_seen <= consume && obs_bd_sub;
        if (consume && obs_bd_sub)
            sub_ss_id <= in_byte[4:0];
    end
end

assign aud_byte        = in_byte;
assign aud_valid       = (state == S_AUDIO_DATA) && in_valid;
assign aud_frame_start = (state == S_AUDIO_DATA) && in_valid && first_aud_byte;
assign aud_frame_pts       = aud_pts;
assign aud_frame_ep        = aud_ep;
assign aud_frame_pts_valid = aud_pes_has_pts;

// Subtitle outputs. S_PTS assembles every non-video PTS into aud_pts, so it is the
// subtitle PES's PTS here too (the FSM is serial per PES).
assign sp_byte        = in_byte;
assign sp_valid       = (state == S_SP_DATA) && in_valid;
assign sp_frame_start = (state == S_SP_DATA) && in_valid && first_sp_byte;
assign sp_pts         = aud_pts;
assign sp_pts_valid   = aud_pes_has_pts;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)       start_shift <= 24'h0;
    else if (consume) start_shift <= {start_shift[15:0], in_byte};
end

// ============================================================================
// Main FSM. PTS bits: [32]=b0[3] [31:30]=b0[2:1] [29:22]=b1 [21:15]=b2[7:1]
// [14:7]=b3 [6:0]=b4[7:1]
// ============================================================================
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state          <= S_HUNT;
        pes_length     <= 16'd0;
        pes_len_hi     <= 8'd0;
        bytes_remaining<= 16'd0;
        stream_id_r    <= 8'd0;
        pts_byte_count <= 3'd0;
        pts_present    <= 1'b0;
        first_aud_byte <= 1'b0;
        rlgn_pend      <= 1'b1;     // UMD: start the audio chain on an access unit
        aud_ssid_r     <= 4'd0;
        fap_hi_r       <= 8'd0;
        first_sp_byte  <= 1'b0;
        aud_pes_has_pts<= 1'b0;
        ever_seen_pack <= 1'b0;
        vid_pts        <= 33'd0;
        vid_ep         <= 2'd0;
        vid_pts_valid  <= 1'b0;
        mark_pending   <= 1'b0;
        aud_pts        <= 33'd0;
        aud_ep         <= 2'd0;
        aud_pts_valid  <= 1'b0;
        pes_hdr_ok     <= 1'b0;
        pack_fresh     <= 1'b0;
    end else begin
        vid_pts_valid <= 1'b0;
        aud_pts_valid <= 1'b0;
        pes_hdr_ok    <= 1'b0;

        if (consume) begin
            case (state)

            S_HUNT: begin
                if (start_code_detected) begin
                    stream_id_r <= in_byte;
                    if (in_byte == 8'hBA) begin
                        ever_seen_pack  <= 1'b1;
                        pack_fresh      <= 1'b1;
                        bytes_remaining <= 16'd9;
                        state           <= S_PACK_SKIP;
                    end else if (in_byte == 8'hE0 || in_byte == 8'hBD)
                        state <= S_PES_LEN_HI;
                    else if (in_byte >= 8'hBB)
                        state <= S_SYS_LEN_HI;          // skip the whole packet by length
                    else
                        state <= S_HUNT;                 // 0xB9 end code, low codes
                end
            end

            // MPEG-2 pack header: 9 fixed bytes, then pack_stuffing_length (low 3 bits)
            S_PACK_SKIP: begin
                if (bytes_remaining != 16'd0)
                    bytes_remaining <= bytes_remaining - 16'd1;
                else if (in_byte[2:0] == 3'd0)
                    state <= S_HUNT;
                else begin
                    bytes_remaining <= {13'd0, in_byte[2:0]};
                    state           <= S_DISCARD;
                end
            end

            S_DISCARD: begin
                if (bytes_remaining <= 16'd1) state <= S_HUNT;
                else bytes_remaining <= bytes_remaining - 16'd1;
            end

            S_PES_LEN_HI: begin pes_len_hi <= in_byte; state <= S_PES_LEN_LO; end
            S_PES_LEN_LO: begin
                pes_length <= {pes_len_hi, in_byte};
                state      <= S_PES_HDR_FLAGS1;
            end

            S_PES_HDR_FLAGS1: begin
                if (in_byte[7:6] == 2'b10 && pack_fresh) pes_hdr_ok <= 1'b1;
                pack_fresh <= 1'b0;
                pes_length <= pes_length - 16'd1;
                state      <= S_PES_HDR_FLAGS2;
            end
            S_PES_HDR_FLAGS2: begin
                pts_present     <= in_byte[7];
                aud_pes_has_pts <= in_byte[7];
                pes_length      <= pes_length - 16'd1;
                state           <= S_PES_HDR_LEN;
            end
            S_PES_HDR_LEN: begin
                bytes_remaining <= {8'd0, in_byte};
                pts_byte_count  <= 3'd0;
                pes_length      <= pes_length - 16'd1;
                if (in_byte == 8'd0) begin
                    if (pes_length == 16'd1)        state <= S_HUNT;
                    else if (stream_id_r == 8'hE0)  state <= S_VIDEO_DATA;
                    else                            state <= S_SUBSTREAM_ID;
                end else if (pts_present)
                    state <= S_PTS;
                else
                    state <= S_PES_HDR_SKIP;
            end

            S_PTS: begin
                pts_buf[pts_byte_count] <= in_byte;
                pes_length      <= pes_length - 16'd1;
                bytes_remaining <= bytes_remaining - 16'd1;
                if (pts_byte_count == 3'd4) begin
                    if (stream_id_r == 8'hE0) begin
                        vid_pts <= {pts_buf[0][3], pts_buf[0][2:1], pts_buf[1],
                                    pts_buf[2][7:1], pts_buf[3], in_byte[7:1]};
                        vid_ep  <= in_ep;   // P6b3i: this header's own sector's item
                        vid_pts_valid <= 1'b1;
                        mark_pending  <= (pes_length != 16'd1);
                    end else begin
                        aud_pts <= {pts_buf[0][3], pts_buf[0][2:1], pts_buf[1],
                                    pts_buf[2][7:1], pts_buf[3], in_byte[7:1]};
                        aud_ep  <= in_ep;   // P6b3i
                        aud_pts_valid <= 1'b1;
                    end
                    if (pes_length == 16'd1) state <= S_HUNT;
                    else if (bytes_remaining == 16'd1) begin
                        if (stream_id_r == 8'hE0) state <= S_VIDEO_DATA;
                        else                      state <= S_SUBSTREAM_ID;
                    end else state <= S_PES_HDR_SKIP;
                end else
                    pts_byte_count <= pts_byte_count + 3'd1;
            end

            S_PES_HDR_SKIP: begin
                pes_length <= pes_length - 16'd1;
                if (pes_length == 16'd1) state <= S_HUNT;
                else if (bytes_remaining <= 16'd1) begin
                    if (stream_id_r == 8'hE0) state <= S_VIDEO_DATA;
                    else                      state <= S_SUBSTREAM_ID;
                end else bytes_remaining <= bytes_remaining - 16'd1;
            end

            // ---- private_stream_1: audio 0x00-0x0F, subtitles 0x80-0x9F ----------
            S_SUBSTREAM_ID: begin
                pes_length <= pes_length - 16'd1;
                if (pes_length == 16'd1)
                    state <= S_HUNT;                         // the id was the only byte
                else if (in_byte[7:5] == 3'b100) begin
                    if (sp_enable && in_byte[4:0] == sp_track)
                        state <= S_SP_SUBHDR;
                    else begin
                        bytes_remaining <= pes_length - 16'd1;
                        state           <= S_DISCARD;
                    end
                end else if (in_byte[7:4] == 4'h0 && in_byte[3:0] == aud_track) begin
                    aud_ssid_r      <= in_byte[3:0];
                    bytes_remaining <= 16'd3;
                    state           <= S_AUD_SUBHDR;
                end else begin
                    // another audio track, or an id outside both ranges
                    bytes_remaining <= pes_length - 16'd1;
                    state           <= S_DISCARD;
                end
            end

            S_AUD_SUBHDR: begin
                pes_length <= pes_length - 16'd1;
                if (bytes_remaining == 16'd2) fap_hi_r <= in_byte;
                if (pes_length == 16'd1) state <= S_HUNT;   // no payload
                else if (bytes_remaining <= 16'd1) begin
                    if (!(rlgn_pend || aud_realign)) begin
                        first_aud_byte <= 1'b1;
                        state          <= S_AUDIO_DATA;
                    end else if (aud_ssid_r != aud_track) begin
                        // an old-track PES whose id matched before the switch
                        rlgn_pend       <= 1'b1;
                        bytes_remaining <= pes_length - 16'd1;
                        state           <= S_DISCARD;
                    end else if (fap >= pes_length - 16'd1) begin
                        // no access unit starts in this payload: wait for the next PES
                        rlgn_pend       <= 1'b1;
                        bytes_remaining <= pes_length - 16'd1;
                        state           <= S_DISCARD;
                    end else if (fap == 16'd0) begin
                        rlgn_pend      <= 1'b0;             // an AU starts right here
                        first_aud_byte <= 1'b1;
                        state          <= S_AUDIO_DATA;
                    end else begin
                        rlgn_pend       <= 1'b0;             // skip the partial AU
                        bytes_remaining <= fap;
                        state           <= S_AUD_SKIP;
                    end
                end else bytes_remaining <= bytes_remaining - 16'd1;
            end

            // skip bytes_remaining payload bytes, then forward (the FAP check above
            // leaves at least one byte after them)
            S_AUD_SKIP: begin
                pes_length <= pes_length - 16'd1;
                if (bytes_remaining <= 16'd1) begin
                    first_aud_byte <= 1'b1;
                    state          <= S_AUDIO_DATA;
                end else bytes_remaining <= bytes_remaining - 16'd1;
            end

            // subtitle sub-header [00]
            S_SP_SUBHDR: begin
                pes_length <= pes_length - 16'd1;
                if (pes_length == 16'd1) state <= S_HUNT;
                else begin
                    first_sp_byte <= 1'b1;
                    state         <= S_SP_DATA;
                end
            end

            S_SYS_LEN_HI: begin pes_len_hi <= in_byte; state <= S_SYS_LEN_LO; end
            S_SYS_LEN_LO: begin
                bytes_remaining <= {pes_len_hi, in_byte};
                if ({pes_len_hi, in_byte} == 16'd0) state <= S_HUNT;
                else                                state <= S_DISCARD;
            end

            S_VIDEO_DATA: begin
                mark_pending <= 1'b0;
                pes_length   <= pes_length - 16'd1;
                if (pes_length == 16'd1) state <= S_HUNT;
            end
            S_AUDIO_DATA: begin
                first_aud_byte <= 1'b0;
                pes_length     <= pes_length - 16'd1;
                if (pes_length == 16'd1) state <= S_HUNT;
            end
            S_SP_DATA: begin
                first_sp_byte <= 1'b0;
                pes_length    <= pes_length - 16'd1;
                if (pes_length == 16'd1) state <= S_HUNT;
            end

            default: state <= S_HUNT;
            endcase
        end

        // Audio realign (a track switch). After the FSM step so it wins this cycle.
        // An old-track payload in flight is dropped: the rest of it would otherwise
        // be the first thing the reset chain receives.
        if (aud_realign) begin
            if (!sub_exit) rlgn_pend <= 1'b1;   // on sub_exit the FSM branch owns it
            if (state == S_AUDIO_DATA) begin
                if (consume && pes_length == 16'd1)
                    state <= S_HUNT;
                else begin
                    bytes_remaining <= consume ? pes_length - 16'd1 : pes_length;
                    state           <= S_DISCARD;
                end
            end else if (state == S_AUD_SKIP) begin
                bytes_remaining <= consume ? pes_length - 16'd1 : pes_length;
                state           <= S_DISCARD;
            end
        end
    end
end

endmodule

`default_nettype wire
