// umd/sub/sub_flip.sv -- the subtitle plane's flips and hides, latched in the vertical blank
// (docs/subtitles.md §2 "sub_sched", docs/compositor.md §4)
//
// sub_sched (mclk) raises d_req with {d_buf, d_vis, d_x, d_y, d_w, d_h} and holds them
// until d_ack; the plane it replaces is free from d_ack on, so d_ack must mean "the
// display shows the new state from the next frame on and never reads the old plane
// again". The request is latched on clk_sys at `vbl` (a strobe inside the vertical blank,
// after the last line request of a frame and before the first of the next: emu's picture
// snapshot point, h_pos 0 of line 500), and only then acknowledged.
//
// Why a toggle handshake and not d_req as a level: after d_ack, sub_sched drops d_req for
// ONE mclk cycle and may raise the next request at once (a hide right after a late flip).
// 11 ns is invisible to a 27 MHz synchroniser: a level handshake would either miss the
// second request's edge (deadlock) or take the old one twice. So the mclk side captures a
// request into holding registers and flips req_tog; it takes no other until the ack
// toggle comes back; then it pulses d_ack (and ignores d_req in that cycle, still the old
// request's). The held fields are stable from before the toggle until the ack.
//
// The rectangle is clipped to 720x480 here: d_w / d_h are the PNG's size and the plane
// writer clips pixels, not the rectangle; the plane reader must not fetch past the
// 720-pixel row (it would read the next row). x >= 720, y >= 480 or an empty image hides.
// Out (clk_sys, changed only at vbl): the plane geometry for umd/plane_reader.sv at 1:1.
//
// THE HAND-OVER (P9, docs/hps_host.md §3.4, docs/p9.md §3.2 item 4), clk_sys: while `ui` is set
// the plane is the UMD Main's (a disc menu's page). sub_sched's requests are still latched and
// acknowledged at vbl -- it never waits -- but not APPLIED, so a flush's hide (a menu starting a
// clip) leaves the page up. The host's flip {hf_buf, hf_vis, x, y, w, h} (umd_host, held until
// acknowledged) is applied at the next vbl and acknowledged with an hf_ack pulse, clipped as a
// subtitle's. Any change of `ui` hides the plane at the next vbl (the subtitle under a menu that
// opens, the page when it closes) -- unless a host flip lands in that same vbl (a host that sets
// ui with its first page). A flip that arrives without ui is left pending (never applied).
//
// THE PANEL'S MODE (P6d, docs/panel.md §2): `ui_sub` gives the plane to the host as `ui` does, with
// the subtitles still running -- emu leaves the demux's subtitle output on and flushes on neither
// edge, so sub_sched keeps requesting decodes (into planes 0 / 1, the host writing them as ever) and
// flips, which are latched and acknowledged here but not applied while the host owns the plane. The
// LATEST of them is KEPT (k_*: what sub_sched shows). When the host gives the plane back from
// ui_sub alone, the kept state is applied at the next vblank instead of a hide: the subtitle on
// screen comes back whole (sub_sched only ever shows a plane whose decode completed, and decodes
// only into the other: panel.md §2). The host's flips address four planes (hf_buf): 0 / 1 the
// subtitles', 2 / 3 the panel's own, so a panel page never overwrites a subtitle unit.

`default_nettype none

module sub_flip #(
    parameter logic [28:0] PLANE0 = 29'h0650_0000,
    parameter logic [28:0] PLANE1 = 29'h0658_0000,
    parameter logic [28:0] PLANE2 = 29'h0670_0000,      // P6d: the panel's pages
    parameter logic [28:0] PLANE3 = 29'h0678_0000
) (
    // sub_sched (mclk)
    input  wire         mclk,
    input  wire         mrst_n,
    input  wire         d_req,
    input  wire         d_buf,
    input  wire         d_vis,
    input  wire  [15:0] d_x,
    input  wire  [15:0] d_y,
    input  wire  [15:0] d_w,
    input  wire  [15:0] d_h,
    output logic        d_ack,

    // the display (clk_sys)
    input  wire         clk,
    input  wire         rst_n,
    input  wire         vbl,
    output logic        vis,
    output logic [28:0] base,
    output logic [9:0]  x,
    output logic [8:0]  y,
    output logic [9:0]  w,
    output logic [8:0]  h,
    output logic [15:0] n_flips,             // requests latched (flips and hides)

    // the host (clk_sys, P9)
    input  wire         ui,
    input  wire         ui_sub,                         // P6d: the host's, the subtitles still running
    input  wire         hf_req,
    input  wire  [1:0]  hf_buf,
    input  wire         hf_vis,
    input  wire  [15:0] hf_x,
    input  wire  [15:0] hf_y,
    input  wire  [15:0] hf_w,
    input  wire  [15:0] hf_h,
    output logic        hf_ack
);

    logic        ack_tog;                  // clk_sys: the last request latched

    // ---- mclk: hold a request, toggle, wait for the ack --------------------------------------
    logic        req_tog, busy;
    logic [2:0]  ack_s;
    logic        hb, hv;
    logic [15:0] hx, hy, hw, hh;
    always_ff @(posedge mclk or negedge mrst_n) begin
        if (!mrst_n) begin
            req_tog <= 1'b0; busy <= 1'b0; ack_s <= '0; d_ack <= 1'b0;
            hb <= 1'b0; hv <= 1'b0; hx <= '0; hy <= '0; hw <= '0; hh <= '0;
        end else begin
            ack_s <= {ack_s[1:0], ack_tog};
            d_ack <= 1'b0;
            if (!busy && d_req && !d_ack) begin
                hb <= d_buf; hv <= d_vis; hx <= d_x; hy <= d_y; hw <= d_w; hh <= d_h;
                req_tog <= !req_tog;
                busy <= 1'b1;
            end else if (busy && ack_s[2] == req_tog) begin
                d_ack <= 1'b1;
                busy <= 1'b0;
            end
        end
    end

    // ---- clk_sys: latch at vbl, acknowledge --------------------------------------------------
    logic [2:0]  req_s;
    wire         own = ui | ui_sub;                      // the host owns the plane
    // the clips (the held fields are stable here while a request is pending): sub_sched's request
    // and the host's flip each have their own, so the kept state is ready whoever owns the plane
    wire  [16:0] m_xe = {1'b0, hx} + {1'b0, hw};
    wire  [16:0] m_ye = {1'b0, hy} + {1'b0, hh};
    wire         m_shown = hv && (hx < 16'd720) && (hy < 16'd480) && (hw != 16'd0) && (hh != 16'd0);
    wire  [16:0] h_xe = {1'b0, hf_x} + {1'b0, hf_w};
    wire  [16:0] h_ye = {1'b0, hf_y} + {1'b0, hf_h};
    wire         h_shown = hf_vis && (hf_x < 16'd720) && (hf_y < 16'd480) && (hf_w != 16'd0) && (hf_h != 16'd0);
    /* verilator lint_off UNUSEDSIGNAL */      // clipped: <= 720 / 480 whenever shown
    wire  [15:0] m_cw = (m_xe > 17'd720) ? 16'd720 - hx : hw;
    wire  [15:0] m_ch = (m_ye > 17'd480) ? 16'd480 - hy : hh;
    wire  [15:0] h_cw = (h_xe > 17'd720) ? 16'd720 - hf_x : hf_w;
    wire  [15:0] h_ch = (h_ye > 17'd480) ? 16'd480 - hf_y : hf_h;
    /* verilator lint_on UNUSEDSIGNAL */
    wire  [28:0] h_base = (hf_buf == 2'd3) ? PLANE3 : (hf_buf == 2'd2) ? PLANE2 : (hf_buf == 2'd1) ? PLANE1 : PLANE0;
    logic        own_q, sub_only_q, chg_owed, chg_back;
    // the kept state: sub_sched's latest request, clipped
    logic        k_vis, k_buf;
    logic [9:0]  k_x, k_w;
    logic [8:0]  k_y, k_h;
    wire         m_new = (req_s[2] != ack_tog);              // sub_sched's request pending
    wire         h_new = own && hf_req && !hf_ack;           // the host's, while it owns the plane
    // a change of owner at this vbl: back to sub_sched from ui_sub alone (restore), else a hide
    wire         chg_now  = (own != own_q);
    wire         back_now = !own && sub_only_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ack_tog <= 1'b0; req_s <= '0; vis <= 1'b0; base <= PLANE0;
            x <= '0; y <= '0; w <= '0; h <= '0; n_flips <= '0;
            own_q <= 1'b0; sub_only_q <= 1'b0; chg_owed <= 1'b0; chg_back <= 1'b0; hf_ack <= 1'b0;
            k_vis <= 1'b0; k_buf <= 1'b0; k_x <= '0; k_y <= '0; k_w <= '0; k_h <= '0;
        end else begin
            req_s <= {req_s[1:0], req_tog};
            own_q <= own;
            sub_only_q <= ui_sub && !ui;
            hf_ack <= 1'b0;
            if (chg_now) begin chg_owed <= 1'b1; chg_back <= back_now; end
            if (vbl) begin
                // a change of owner: hidden -- or, back from ui_sub alone, what sub_sched shows (a
                // request below may show something newer in this vbl)
                if (chg_owed || chg_now) begin
                    if (chg_now ? back_now : chg_back) begin
                        vis <= k_vis; base <= k_buf ? PLANE1 : PLANE0;
                        x <= k_x; y <= k_y; w <= k_w; h <= k_h;
                    end else
                        vis <= 1'b0;
                    chg_owed <= 1'b0;
                end
                if (m_new) begin
                    ack_tog <= req_s[2];                         // always taken: sub_sched never waits
                    k_vis <= m_shown; k_buf <= hb;
                    k_x <= hx[9:0]; k_y <= hy[8:0]; k_w <= m_cw[9:0]; k_h <= m_ch[8:0];
                end
                if (m_new && !own) begin
                    vis <= m_shown;
                    base <= hb ? PLANE1 : PLANE0;
                    x <= hx[9:0]; y <= hy[8:0]; w <= m_cw[9:0]; h <= m_ch[8:0];
                    n_flips <= n_flips + 16'd1;
                end
                if (h_new) begin
                    vis <= h_shown;
                    base <= h_base;
                    x <= hf_x[9:0]; y <= hf_y[8:0]; w <= h_cw[9:0]; h <= h_ch[8:0];
                    n_flips <= n_flips + 16'd1;
                    hf_ack <= 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
