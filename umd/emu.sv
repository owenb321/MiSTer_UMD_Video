// umd/emu.sv -- MiSTer UMD Video player core, top level (roadmap P3: the H.264 front end)
//
// What this build does: brings up the MiSTer framework (OSD, file picker, sd block
// interface, HDMI + analog rasters) and draws the idle screen (umd/xmb_wave.sv). On a
// mount, umd/umd_reader.sv walks the image to the main title and streams its packs
// through umd/ps_demux.sv; the video ES crosses into the 81 MHz clk_dec domain
// (umd/vidfeed_cdc.sv) and is parsed to its last syntax element by the H.264 front
// end (umd/h264/h264_top.sv), whose words a sink only COUNTS until P4 reconstructs
// pixels from them. (P2's header; the diagnostic HUD it describes left the core 2026-10-03,
// area_plan.md A11: telemetry, umd/umd_telem.sv, carries its counters.)
// Every later phase (docs/roadmap.md) adds modules under umd/ and wires them here.
//
// Port list: MiSTer's stock emu ports plus the two analog composite-sync ports
// (VGA_CS / VGA_CS_EN) inherited from MiSTer_DVD's sys_top.v, which this repo keeps
// for the CRT work in P5. The list MUST match the `emu emu (...)` instance in
// sys/sys_top.v exactly; tools/check_emu_wiring.py pins the seam.

module emu (
	input         CLK_50M,
	input         RESET,
	inout  [48:0] HPS_BUS,

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,
	output        VGA_DISABLE,

	output        CLK_SYS,
	output        CLK_MEM,

	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,
	output        VGA_F1,
	output  [1:0] VGA_SL,
	output        VGA_SCALER,
	output        VGA_DITHER,     // UMD-FORK (2026-10-06, docs/analog.md S9): the OSD's Analog Dither -> sys_top's dac_dither

	// UMD-FORK (inherited from MiSTer_DVD): composite sync generated from the core's
	// OWN raster, with the equalizing pulses the framework's csync module cannot
	// produce. sys_top delays it by CS_PIPE and uses it whenever VGA_CS_EN is high.
	// Tied off until umd/csync_smpte.sv is harvested (roadmap P5).
	output        VGA_CS,
	output        VGA_CS_EN,

	// Canonical MiSTer direction is OUTPUT: b[0] is the core's virtual OSD button.
	output  [1:0] BUTTONS,

	output        LED_USER,
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,
	output  [1:0] AUDIO_MIX,   // 2 bits, matching sys_top's `wire [1:0] audio_mix`

	inout   [3:0] ADC_BUS,

	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	// UMD-FORK (roadmap P5): a second DDR3 master on ram2 (sys/sys_top.v), the display
	// reader's own port -- docs/hw_budget_and_lessons.md S2: occupancy, not bandwidth
	output        DDRAM2_CLK,
	input         DDRAM2_BUSY,
	output  [7:0] DDRAM2_BURSTCNT,
	output [28:0] DDRAM2_ADDR,
	input  [63:0] DDRAM2_DOUT,
	input         DDRAM2_DOUT_READY,
	output        DDRAM2_RD,
	output [63:0] DDRAM2_DIN,
	output  [7:0] DDRAM2_BE,
	output        DDRAM2_WE,

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	output [6:0]  USER_OUT,
	input  [6:0]  USER_IN,

	input         OSD_STATUS,

	output        CLK_VIDEO,
	output        CE_PIXEL,

	input         CLK_AUDIO,
	output        LOCKED
);

// =========================================================================
// Clocks and reset
// =========================================================================
// sys_pll: 27 MHz clk_sys (also CLK_VIDEO), 90 MHz clk_mem (DDRAM_CLK), 25.116 MHz
// spare, 81 MHz clk_dec (decoder compute domain). The instance MUST be named sys_pll:
// tools/fmax_check.sh finds clk_dec in the timing report by the hierarchical name
// emu|sys_pll|altera_pll_i|general[3]...
wire clk_sys, clk_mem, clk_vid, clk_dec, locked;
sys_pll sys_pll (
	.refclk   (CLK_50M),
	.rst      (1'b0),
	.outclk_0 (clk_sys),
	.outclk_1 (clk_mem),
	.outclk_2 (clk_vid),
	.outclk_3 (clk_dec),
	.locked   (locked)
);

// OSD "Reset" (status[0]) joins the framework reset. user_rst_qn is a REGISTERED copy
// because reset_n is consumed as an async clear all over the core (MiSTer_DVD's
// reasoning, kept). Declared here, driven beside hps_io below.
wire user_rst_qn;
wire reset_n = locked & ~RESET & user_rst_qn;

assign CLK_SYS   = clk_sys;
assign CLK_MEM   = clk_mem;
assign CLK_VIDEO = clk_sys;      // 27 MHz: exactly the 480p dot clock; 480i repeats each pixel
                                 // (CE_PIXEL every other dot: the output stage, docs/analog.md V2)
assign LOCKED    = locked;

// =========================================================================
// Version and the OSD definition (CONF_STR)
// =========================================================================
`include "build_id.v"            // `BUILD_DATE "yymmdd", generated by sys/build_id.tcl

// VERSIONING (the rules build_release.sh enforces; see CLAUDE.md "Versioning"):
//   * `dev-<slug>` on every feature branch, set in the branch's FIRST commit; a bare
//     `vX.Y.Z` lives in exactly one commit per release.
//   * <= 18 characters, and none of , ; " -- stock Main truncates the About line at
//     30 chars and splits CONF_STR on those characters.
//   * This string is INSIDE CONF_STR = inside the netlist. Changing it re-rolls the
//     pinned fitter SEED, so change it once per branch and never per commit.
`define CORE_VERSION "dev-pubtarget"

// The OSD definition. Every option, button and file extension here MUST be documented
// in the manual: tools/docs_check.py parses this block (by its terminator, never a
// grep) and fails the build otherwise. Any change here re-rolls the fitter seed.
//
// Status bits: [0] Reset, [2:1] Aspect Ratio (3 Zoom: fj#71, docs/zoom.md -- the field's spare value, no new bit), [4:3] Deinterlace (the 480p raster),
// [5] HDMI Deinterlace (the 480i raster: ascal's Bob / Weave, HDMI_BOB_DEINT), [7:6] Video
// Output, [8] retired, never reuse (was Diagnostics, the HUD removed 2026-10-03: a saved config may still hold it set), [10:9] Analog Aspect (the 480i raster: V8, shown with h0),
// [14:11] Menu Language (P9: the UMD Main reads it to pick the disc's startup menu, <XX>100000.RCO,
// as the PSP's "UMD Menu Language" video setting does -- docs/p9.md; nothing in the fabric reads it;
// four bits for the seven languages the library's startup menus carry, room for the PSP's others),
// [15] Disc Menus (P9 M3b, the maintainer 2026-10-03: On runs the disc's menus, Off plays the longest
// playlist as on a stock Main; the UMD Main reads it at a mount; shown only with the UMD Main up --
// h1 on status_menumask[1] = umd_host's host_ok, its heartbeat -- so a stock Main never offers it),
// [16] Analog Dither (docs/analog.md S9: the 18-bit I/O board's 6-bit DAC; at 480p and 480i alike, so never hidden). docs/analog.md V1 / V5: the raster's two deinterlace lines
// swap on status_menumask[0] (= the 480i raster) with the H0 / h0 hide prefixes (stock Main's
// lowercase h: hide when the bit is CLEAR, checked in menu.cpp), so the menu never offers a
// mode the raster cannot do (ascal cannot blend).
// Bits are allocated once and never reordered: `status[]` powers up at zero, so index 0 of every option is its default,
// and a relayout of existing bits needs the "v,N" config version bumped (which resets
// every saved setting).
//
// The J1 list (P6b6, docs/transport.md D10): its ORDER is the joystick bits (B1 = bit 4),
// which kbd_map.sv's table and the command wiring below follow; tools/check_emu_wiring.py
// pins it. `jn` gives each button its default pad button by name (MiSTer's virtual SNES pad):
// the PSP's layout (D4) -- Start Play/Pause, A (x) Select (P9: a menu's choice, the PSP's x;
// the maintainer, 2026-10-03; in playback it is Play/Pause's PLAYPAUSE since 2026-10-07, named
// Select alone: docs/transport.md D10), B (o) Stop, L / R chapters -- with
// UMD Menu on Y (square) and Audio on Select; Subtitle, Go To and Display have no default (the
// keyboard, or Define buttons). P6d (docs/panel.md K3): Repeat (inert since P6b6) became Control
// Panel, on X -- the PSP's triangle, its panel's own button -- which Display had held (D10).
// Control Panel is the UMD Main's (it grabs the button); without one the HUD says so (pmsg below).
// S0 (P8, docs/bare_streams.md): a UMD Video .ISO or a bare .MPS (a disc's STREAM/NNNNN.MPS). The
// extensions are the picker's filter only: umd_reader sniffs sector 0 whatever the path (an MGL or
// the HIL's mount send no usable index). .PMF is out of scope (the maintainer, 2026-10-05: every game
// PMF's audio is 44.1 kHz, refused): the reader still recognises one, picture only, never offered.
localparam CONF_STR = {
	"UMD;;",
	"S0,ISOMPS,Load Video;",
	"-;",
	"O[7:6],Video Output,Auto,Interlaced,Progressive;",
	"O[2:1],Aspect Ratio,Auto,4:3,16:9,Zoom;",
	"H0O[4:3],Deinterlace,Weave,Bob,Blend;",
	"h0O[5],HDMI Deinterlace,Weave,Bob;",
	"h0O[10:9],Analog Aspect,Auto,Fit,Letterbox,Crop;",
	"O[16],Analog Dither,Off,On;",
	"-;",
	"O[14:11],Menu Language,English,French,Spanish,German,Italian,Dutch,Japanese;",
	"h1O[15],Disc Menus,On,Off;",
	"-;",
	"R[0],Reset;",
	"v,1;",
	"J1,Play/Pause,Select,Stop,Prev Chapter,Next Chapter,Audio,Display,UMD Menu,Subtitle,Go To,Control Panel;",
	"jn,Start,A,B,L,R,Select,,Y,,,X;",
	"V,",`CORE_VERSION," ",`BUILD_DATE,";"
};

// =========================================================================
// HPS IO: OSD, file mount, sd blocks, timestamp
// =========================================================================
wire        ioctl_download, ioctl_wr, ioctl_wait;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire [15:0] ioctl_index;
wire  [1:0] buttons;
wire [127:0] status;
wire [31:0] joystick_0;
wire [10:0] ps2_key;
wire        forced_scandoubler, direct_video;
wire        ini_vga_scaler, ini_csync, ini_ypbpr, ini_sog, cfg_seen, cfg_wr;
wire [31:0] sd_lba;
wire        sd_rd, sd_ack, sd_buff_wr;
wire [13:0] sd_buff_addr;
wire  [7:0] sd_buff_dout;
wire  [0:0] img_mounted;
wire        img_readonly;
wire [63:0] img_size;
wire [32:0] hps_timestamp;
wire        interlaced_eff;               // the 480i raster (Video Output, below)
wire        host_ok;                      // the UMD Main's heartbeat (umd_host, below): status_menumask[1]
wire  [1:0] aa_mode;                      // its Analog Aspect (the aspect section, below)
wire        aa_live;

assign ioctl_wait = 1'b0;

// OSD R0 Reset -> core reset (see reset_n above)
reg user_rst_q = 1'b0;
always @(posedge clk_sys) user_rst_q <= status[0];
assign user_rst_qn = ~user_rst_q;

// BLKSZ=4: one 2048-byte block per sd request, sd_lba in 2048-byte units. That is one
// ISO9660 sector, one UMD MPEG-PS pack, so every reader in this core addresses the
// image in sectors with no scaling.
wire [35:0] ext_bus;                      // hps_io's EXT_BUS: umd_telem and umd_host drive [32] and [15:0]
hps_io #(.CONF_STR(CONF_STR), .BLKSZ(4)) hps_io_inst (
	.clk_sys        (clk_sys),
	.HPS_BUS        (HPS_BUS),
	.EXT_BUS        (ext_bus),      // UMD: the HIL telemetry responder (umd_telem, below)

	.ioctl_download (ioctl_download),
	.ioctl_wr       (ioctl_wr),
	.ioctl_addr     (ioctl_addr),
	.ioctl_dout     (ioctl_dout),
	.ioctl_index    (ioctl_index),
	.ioctl_wait     (ioctl_wait),

	.buttons        (buttons),
	.status         (status),
	.joystick_0     (joystick_0),
	.ps2_key        (ps2_key),

	.status_menumask ({14'd0, host_ok, interlaced_eff}),   // [0]: the 480i raster (the H0 / h0 lines); [1]: the UMD Main (h1)
	.forced_scandoubler (forced_scandoubler),
	.gamma_bus      (),
	.direct_video   (direct_video),
	.ini_vga_scaler (ini_vga_scaler),
	.ini_csync      (ini_csync),
	.ini_ypbpr      (ini_ypbpr),
	.ini_sog        (ini_sog),
	.cfg_seen       (cfg_seen),
	.cfg_wr         (cfg_wr),

	.sd_lba         ('{sd_lba}),
	.sd_blk_cnt     ('{6'd0}),
	.sd_rd          (sd_rd),
	.sd_wr          (1'b0),
	.sd_ack         (sd_ack),
	.sd_buff_addr   (sd_buff_addr),
	.sd_buff_dout   (sd_buff_dout),
	.sd_buff_din    ('{8'd0}),
	.sd_buff_wr     (sd_buff_wr),

	.img_mounted    (img_mounted),
	.img_readonly   (img_readonly),
	.img_size       (img_size),

	// Wall clock (UTC seconds since the epoch), sent by Main once at core load.
	// Bit 32 toggles per delivery. Tints the idle wave by month.
	.TIMESTAMP      (hps_timestamp)
);

// =========================================================================
// Mount handling (inherited from MiSTer_DVD, issue #48 there)
// -------------------------------------------------------------------------
// A mount notification with img_size == 0 is NOT a mount. Main sends UIO_SET_SDSTAT
// even when the open failed, and hps_io raises img_mounted for an all-zero status
// word -- which is also how an EJECT arrives. So the pulse means "the slot changed",
// and the size says whether there is media.
// =========================================================================
reg  img_mounted_prev;
wire img_evt         = img_mounted[0] && !img_mounted_prev;   // slot changed
wire start_streaming = img_evt &&  (img_size != 64'd0);       // ...with media
wire img_ejected     = img_evt && !(img_size != 64'd0);       // ...without
always @(posedge clk_sys or negedge reset_n) begin
	if (!reset_n) img_mounted_prev <= 1'b0;
	else          img_mounted_prev <= img_mounted[0];
end

// media_seen: "an image is loaded" -- the level that selects the idle screen vs
// content, and the content aspect. Set on a mount with media; cleared on an eject or
// failed mount. In P0 nothing plays, so the clear needs no "picture has run out"
// latch yet; when the display pipeline exists (P5), gate the clear on video_live the
// way MiSTer_DVD's slot_empty latch does, or an eject mid-title flips VIDEO_ARX under
// live content.
reg media_seen;
always @(posedge clk_sys or negedge reset_n) begin
	if (!reset_n)             media_seen <= 1'b0;
	else if (start_streaming) media_seen <= 1'b1;
	else if (img_ejected)     media_seen <= 1'b0;
end

// =========================================================================
// STARTUP OSD POPUP (inherited from MiSTer_DVD's launch-feedback work)
// -------------------------------------------------------------------------
// Pop the framework OSD ~0.9 s after core load when nothing was auto-mounted, so a
// bare launch lands in the file picker instead of on the idle screen with nothing
// to do -- the console-core convention. BUTTONS[0] is the core->HPS virtual OSD
// button; menu.cpp acts on its RELEASE edge, hence a wait-then-PULSE rather than a
// hold (a hold would fire even for an MGL mount landing mid-window). Must stay well
// under 3 s: a >= 3 s hold means "enter Bluetooth pairing".
//   * arm on the falling edge of status[0] (the framework's core-load reset, released
//     at the END of user_io_init, after every init-time auto-load);
//   * one-shot per FPGA configuration (the counter saturates; OSD Reset cannot
//     re-fire it), and disc_ever has no reset term so a played-then-reset session
//     never pops it either;
//   * gated on ~status[0] so a reset inside the window cannot freeze the count with
//     the button HELD (the >= 3 s trap).
// =========================================================================
localparam [24:0] OSD_T_FIRE = 25'd24_300_000;   // ~0.90 s @ 27 MHz
localparam [24:0] OSD_T_END  = 25'd27_000_000;   // ~1.00 s (100 ms pulse)

reg        osd_btn      = 1'b0;
reg        hps_rst_seen = 1'b0;   // status[0] observed high since power-up
reg        disc_ever    = 1'b0;   // any nonzero-size mount since power-up
reg [24:0] osd_wait     = 25'd0;

always @(posedge clk_sys) begin
	if (img_mounted[0] && img_size != 64'd0) disc_ever <= 1'b1;
	if (status[0])                           hps_rst_seen <= 1'b1;
	if (hps_rst_seen && !status[0] && osd_wait != OSD_T_END)
		osd_wait <= osd_wait + 25'd1;
	osd_btn <= (osd_wait >= OSD_T_FIRE) && (osd_wait != OSD_T_END)
	           && !disc_ever && !status[0];
end

assign BUTTONS = {1'b0, osd_btn};

// =========================================================================
// The transport (P6b3, umd/player_ctl.sv; docs/transport.md S2): its outputs, used from the
// reader down to the final mux. The instance is with the display (below).
//   pc_flush   a seek's discontinuity: pipe_rst_n (below) resets everything behind the
//              reader -- NOT the parameter sets (fe_rst_dec_n, the mount's), not the output
//              queue (the display drains it: disp_ctl resync), not the display
//   pc_rd_hold the reader's stream held through the flush
//   pc_freeze  pause / stop / a seek's hold: the display's refresh-aligned freeze (ds_frz)
//              holds the STC and the audio gate together
// =========================================================================
wire        pc_flush, pc_rd_hold, pc_aud_rst, pc_realign, pc_freeze, pc_idle;
wire        pc_sub_on, pc_sub_flush;   // P7: the subtitles (player_ctl, below)
wire  [4:0] pc_sub_track;
wire        pc_one;                   // P6b4: the landing is a trick-play hop (h264_top's one_frame)
wire  [1:0] pc_tkspd;                 //   trick play's speed (0 off) and direction
wire        pc_tkrev;
wire        pc_ep_we, pc_ep_last, pc_ep_skip, pc_item_hold;   // P6b3i: the display's item table, the reader's hold
wire  [1:0] pc_ep_wi;
wire [32:0] pc_ep_in, pc_ep_out;
wire  [3:0] pc_aud_track;
wire        pc_nav_req, pc_nav_ready, pc_nav_done;
// (declared here: umd_host, above player_ctl's instance, reads them -- P9)
wire  [2:0] pc_state, pc_nerr;
wire        pc_ev_v;
wire  [3:0] pc_ev_code;
wire [15:0] pc_ev_data;
wire [15:0] pc_chapter, pc_nch, pc_seeks;
wire        pc_seeking;
wire [31:0] pc_key_item;
wire [15:0] pc_nav_pl;                 // P9: NAV_PLAY's playlist (player_ctl -> the reader)
// P9 (docs/p9.md S3.2): the host's rows (umd_host, below)
wire        host_bad;                  // (host_ok: declared with the OSD wires, its menumask bit)
wire [15:0] host_grab;                 // the buttons the UMD Main takes (joystick bit order)
wire        host_ui, host_menu, host_mute;
wire        host_uis;                  // P6d (docs/panel.md §2): the plane the host's, the subtitles still running
wire        hx_v;                      // P6d (F1): the host's press record -- buttons pressed, one cycle
// fj#71 Zoom (docs/zoom.md; zoom_ctl below, beside the aspect): in force (changes at the vblank), and
// this raster line outside its band (60 .. 419)
wire        zoom, zoom_cut;
wire [15:0] hx_mask;
wire        gt_open;                   // P6c: Go To's editor is open (goto_ctl, below; P6d: in HOST_RD too)
wire        th_tag_aud, th_tag_sub;    // P6d follow-up: the HUD's audio / subtitle tag is up (transport_hud, below)
wire  [1:0] menu_aa;                       // P9: a menu's fit at 480i (the aspect section, below)
wire        menu_aa_on;        // the plane is the host's; a disc menu is up (HUD hidden, stop black)
wire        vui_sar_known, vui_wide;   // the shown picture's aspect (aspect_vui, the aspect section below)
wire        hc_v, hc_take;             // a player command from the host, held until taken
wire  [3:0] hc_code, hc_arg;
wire [15:0] hc_pl;
wire [31:0] hc_item;
wire [47:0] hc_pts;
wire [15:0] hk_press;                  // every button / key press edge, joystick bit order (below)
wire        host_win, host_win_hold, host_win_bad;   // the video window (umd_host -> disp_reader)
wire  [9:0] host_win_x, host_win_y, host_win_w, host_win_h;
wire [25:0] host_win_hs, host_win_vs, host_win_x0, host_win_y0;
wire        hf_req, hf_vis, hf_ack;    // the host's plane flip (umd_host -> sub_overlay's sub_flip)
wire  [1:0] hf_buf;                    // ... its plane: 0 / 1 the subtitles', 2 / 3 the panel's (P6d)
wire [15:0] hf_x, hf_y, hf_w, hf_h;
wire        hp_req, hp_stereo, hp_ack, pcm_busy;   // the sound one-shot's trigger (umd_host -> pcm_shot)
wire [15:0] pcm_under;                 // ... its late words (HOST_RD)
wire [23:0] hp_start, hp_len;
wire [28:0] px_address;                // ... and its reader on ram2 (sub_overlay's x_*)
wire  [7:0] px_burstcount;
wire        px_read, px_waitrequest, px_readdatavalid;
wire [63:0] px_readdata;
wire  [2:0] pc_nav_op;                 // (3 bits since P6c: NAV_TIME)
wire [31:0] pc_nav_item, rd_nav_land;
wire [47:0] pc_nav_pts, rd_nav_skip;
wire  [2:0] rd_nav_err, rd_ch_valid;
wire [15:0] rd_ch_rank, rd_ch_count;
wire [63:0] rd_ch_cur, rd_ch_prev, rd_ch_next;

// The per-mount reset (the front end's; docs/h264_frontend.md S6 has the reasoning) and the
// pipeline's (P6b3). A mount or an eject holds fe_rst_n 16 clk_sys cycles so the 3x faster
// clk_dec side sees it, released into clk_dec through cdc_reset.
reg [3:0] fe_clr_cnt;
always @(posedge clk_sys or negedge reset_n) begin
	if (!reset_n)                            fe_clr_cnt <= 4'd0;
	else if (start_streaming || img_ejected) fe_clr_cnt <= 4'd15;
	else if (fe_clr_cnt != 4'd0)             fe_clr_cnt <= fe_clr_cnt - 4'd1;
end
wire fe_rst_n = reset_n & (fe_clr_cnt == 4'd0);
// P6b3 (docs/transport.md S2.1): a seek resets the pipeline behind the reader, not the
// mount's state. pipe_rst_n = the mount OR a seek's flush (player_ctl holds it >= 16 cycles,
// the mount's length, and until the output queue is drained); the audio chain also resets
// on a track switch. fe_rst_n / fe_rst_dec_n stay the MOUNT's: the parameter sets (ps_rst_n),
// the output queue (a seek drains it; its dual-clock FIFOs must reset both sides together),
// the display, the HUD snapshots.
wire pipe_rst_n = fe_rst_n & ~pc_flush;
wire aud_rst_n  = pipe_rst_n & ~pc_aud_rst;
wire pipe_rst_dec_n, fe_rst_dec_n;
cdc_reset pipe_rst_cdc (
	.clk       (clk_dec),
	.rst_n_in  (pipe_rst_n),
	.rst_n_out (pipe_rst_dec_n)
);
cdc_reset fe_rst_cdc (
	.clk       (clk_dec),
	.rst_n_in  (fe_rst_n),
	.rst_n_out (fe_rst_dec_n)
);

// =========================================================================
// The image reader (docs/umd_reader.md): PVD -> UMD_VIDEO/ -> PARAM.SFO (TITLE) ->
// PLAYLIST.UMD (the LONGEST playlist) -> per item the CLP stream table and the .MPS
// packs, out as a byte stream. A mount with media starts it; an eject stops it.
// =========================================================================
wire  [7:0] stream_data;
wire  [1:0] stream_ep, dmx_in_ep, vid_ep, vb_ep, aud_frame_ep, at_ep;   // P6b3i: the item tag (video and audio)
wire        stream_valid, stream_busy;
wire  [5:0] rd_state;
wire  [3:0] rd_err;
wire        rd_streaming, rd_done, rd_active, rd_sfo_warn, rd_title_trunc, rd_dur_sat;
wire        rd_item_start;
wire [31:0] rd_secs, rd_n_items, rd_item_idx, rd_mps_lba, rd_mps_bytes, rd_sub_present;
wire [31:0] rd_ep_map_off;
wire  [2:0] rd_ep_flags;          // the playing item's EP lookups (no map / past / wide): P6b7 telemetry
wire  [6:0] title_addr = 7'd0;      // (the reader's first title port was the diagnostic HUD's, removed: A11; unread, it folds away)
wire  [7:0] title_q, title_len, rd_vattr0, rd_vattr1;
wire [15:0] rd_main_pl, rd_n_pl, rd_n_streams, rd_n_video, rd_n_unknown, rd_aud_present;
wire [15:0] rd_lang_q;
wire [63:0] rd_clip_name;
wire [47:0] rd_item_in, rd_item_out, rd_clip_start, rd_clip_end;
wire [47:0] rd_item_base;          // P6b5
wire [63:0] rd_pl_dur;
wire  [1:0] rd_bare;               // P8: 0 an image, 1 a bare .MPS, 2 a .PMF (the reader sniffs sector 0)
wire        rd_pmf_warn;           // P8: the PSMF's stream size disagrees with the file's
wire  [6:0] th_title_addr;
wire  [7:0] th_title_q;
wire  [5:0] th_lang_sel;
umd_reader umd_reader_inst (
	.clk            (clk_sys),
	.rst_n          (reset_n),
	.start          (start_streaming),
	.stop           (img_ejected),
	.file_size      (img_size),
	.sd_lba         (sd_lba),
	.sd_rd          (sd_rd),
	.sd_ack         (sd_ack),
	.sd_buff_addr   (sd_buff_addr),
	.sd_buff_dout   (sd_buff_dout),
	.sd_buff_wr     (sd_buff_wr),
	.stream_data    (stream_data),
	.stream_valid   (stream_valid),
	.stream_ep      (stream_ep),       // P6b3i: each byte's item tag
	.item_hold      (pc_item_hold),
	.busy           (stream_busy | pc_rd_hold),   // P6b3: held through a seek's flush
	.state_o        (rd_state),
	.active         (rd_active),
	.err_code       (rd_err),
	.streaming      (rd_streaming),
	.title_done     (rd_done),
	.secs_streamed  (rd_secs),
	.sfo_warn       (rd_sfo_warn),
	.title_trunc    (rd_title_trunc),
	.dur_sat        (rd_dur_sat),
	.bare           (rd_bare),         // P8 (docs/bare_streams.md)
	.pmf_warn       (rd_pmf_warn),
	.title_addr     (title_addr),
	.title_q        (title_q),
	.title_addr2    (th_title_addr),   // P6b5: the transport HUD's read port
	.title_q2       (th_title_q),
	.title_len      (title_len),
	.main_pl        (rd_main_pl),
	.n_playlists    (rd_n_pl),
	.n_items        (rd_n_items),
	.item_idx       (rd_item_idx),
	.clip_name      (rd_clip_name),
	.item_in_pts    (rd_item_in),
	.item_out_pts   (rd_item_out),
	.item_base      (rd_item_base),    // P6b5: the HUD's elapsed time
	.pl_dur         (rd_pl_dur),
	.item_start     (rd_item_start),
	.mps_lba        (rd_mps_lba),
	.mps_bytes      (rd_mps_bytes),
	.clip_start_pts (rd_clip_start),
	.clip_end_pts   (rd_clip_end),
	.n_streams      (rd_n_streams),
	.n_video        (rd_n_video),
	.n_unknown      (rd_n_unknown),
	.vid_attr0      (rd_vattr0),
	.vid_attr1      (rd_vattr1),
	.aud_present    (rd_aud_present),
	.sub_present    (rd_sub_present),
	.ep_map_off     (rd_ep_map_off),
	.lang_sel       (th_lang_sel),     // P6b5: the HUD's track tag
	.lang_q         (rd_lang_q),
	// the navigation port (P6b2, docs/transport.md S2.4): player_ctl's (P6b3)
	.nav_req        (pc_nav_req),
	.nav_op         (pc_nav_op),
	.nav_item       (pc_nav_item),
	.nav_pts        (pc_nav_pts),
	.nav_pl         (pc_nav_pl),       // P9 NAV_PLAY's playlist: player_ctl's PLAYLIST (the host rows, docs/p9.md S3.2)
	.nav_ready      (pc_nav_ready),
	.nav_done       (pc_nav_done),
	.nav_err        (rd_nav_err),
	.nav_land       (rd_nav_land),
	.nav_ep_idx     (),
	.nav_ep_pts     (),
	.nav_ep_sec     (),
	.nav_skip       (rd_nav_skip),
	.ep_flags       (rd_ep_flags),
	.ch_rank        (rd_ch_rank),
	.ch_count       (rd_ch_count),
	.ch_valid       (rd_ch_valid),
	.ch_cur         (rd_ch_cur),
	.ch_prev        (rd_ch_prev),
	.ch_next        (rd_ch_next)
);

// The audio track is player_ctl's (P6b3: the lowest declared by default, the Audio
// command steps it). The subtitle track is player_ctl's too (P7, docs/subtitles.md §7: off at
// a mount, the Subtitle button steps Off -> the declared tracks -> Off); the demux forwards it
// only while it is on, not during a change's flush (a unit cut by the switch is dropped), and
// not in trick play (every hop is a seek that flushes them anyway).
wire [3:0] aud_track = pc_aud_track;
wire [4:0] sp_track  = pc_sub_track;
// (P9: off while the UMD Main owns the plane -- a disc menu's page; docs/p9.md S3.2 item 4)
wire       sp_on     = pc_sub_on & ~pc_sub_flush & (pc_tkspd == 2'd0) & ~host_ui;

// =========================================================================
// Program-stream demux (umd/ps_demux.sv) behind its handshake FIFO. The video sink is
// the front end behind vidfeed_cdc (its vid_ready is REAL backpressure: FIFO full ->
// demux stalls -> ps_stream_fifo fills -> umd_reader's busy); so is the audio sink, the
// ring in front of the ATRAC3plus decoder (aud_ready, P6a, below). Subtitles have no
// decoder yet: that sink is always ready and only counted (P2's es_probe, a bench instrument now).
// =========================================================================
wire  [7:0] dmx_in_byte, vid_byte, aud_byte, sp_byte;
wire        dmx_in_valid, dmx_in_ready, vid_ready;
wire        vid_valid, vid_mark, aud_valid, aud_frame_start, sp_valid, sp_frame_start;
wire [32:0] vid_pts, aud_pts, aud_frame_pts, sp_pts;
wire        vid_pts_valid, aud_pts_valid, aud_frame_pts_valid, sp_pts_valid;
wire        pes_hdr_ok, aud_ss_seen, aud_pes_hit, saw_pack;
wire  [3:0] aud_ss_id;
wire        sub_ss_seen;                  // P8
wire  [4:0] sub_ss_id;
wire        aud_ready;                    // aud_ring's in_ready: real back-pressure (P6a)
ps_stream_fifo #(.DW(10)) ps_stream_fifo_inst (   // P6b3i: {the item tag, the byte}
	.clk         (clk_sys),
	.rst_n       (pipe_rst_n),     // P6b3: a mount or a seek empties it (16 stale bytes otherwise)
	.wr_data     ({stream_ep, stream_data}),
	.wr_en       (stream_valid),
	.almost_full (stream_busy),
	.out_byte    ({dmx_in_ep, dmx_in_byte}),
	.out_valid   (dmx_in_valid),
	.out_ready   (dmx_in_ready)
);

// the demux restarts with every mount and every seek: its framing and the audio realign
// start clean
wire dmx_rst_n = pipe_rst_n;
ps_demux ps_demux_inst (
	.clk                 (clk_sys),
	.rst_n               (dmx_rst_n),
	.in_byte             (dmx_in_byte),
	.in_ep               (dmx_in_ep),
	.in_valid            (dmx_in_valid),
	.in_ready            (dmx_in_ready),
	.aud_track           (aud_track),
	.aud_realign         (pc_realign),        // P6b3: the track switch
	.sp_track            (sp_track),
	.sp_enable           (sp_on),
	.vid_byte            (vid_byte),
	.vid_valid           (vid_valid),
	.vid_ready           (vid_ready),
	.vid_mark            (vid_mark),
	.aud_byte            (aud_byte),
	.aud_valid           (aud_valid),
	.aud_frame_start     (aud_frame_start),
	.aud_ready           (aud_ready),
	.vid_pts             (vid_pts),
	.vid_ep              (vid_ep),
	.vid_pts_valid       (vid_pts_valid),
	.aud_pts             (aud_pts),
	.aud_pts_valid       (aud_pts_valid),
	.aud_frame_pts       (aud_frame_pts),
	.aud_frame_ep        (aud_frame_ep),      // P6b3i: the audio's item tag
	.aud_frame_pts_valid (aud_frame_pts_valid),
	.sp_byte             (sp_byte),
	.sp_valid            (sp_valid),
	.sp_frame_start      (sp_frame_start),
	.sp_pts              (sp_pts),
	.sp_pts_valid        (sp_pts_valid),
	.pes_hdr_ok          (pes_hdr_ok),
	.aud_ss_seen         (aud_ss_seen),
	.aud_ss_id           (aud_ss_id),
	.sub_ss_seen         (sub_ss_seen),       // P8: the subtitle tap
	.sub_ss_id           (sub_ss_id),
	.aud_pes_hit         (aud_pes_hit),
	.saw_pack            (saw_pack)
);

// ---- P8: the tracks of a bare stream file (docs/bare_streams.md) --------------------------------
// An image declares its tracks in each clip's CLP (the reader's masks and languages). A bare .MPS /
// .PMF has no CLP: its tracks are what the stream carries, learned as the demux meets them (its
// substream taps) -- a mask that only grows from the mount (a bare title has no seek to re-read
// anything; player_ctl judges its default track every cycle on it), with no language (two spaces:
// the HUD's track tag shows the number alone).
reg  [15:0] bare_aud;
reg  [31:0] bare_sub;
always @(posedge clk_sys or negedge reset_n) begin
	if (!reset_n) begin bare_aud <= 16'd0; bare_sub <= 32'd0; end
	else if (start_streaming) begin bare_aud <= 16'd0; bare_sub <= 32'd0; end
	else begin
		if (aud_ss_seen) bare_aud[aud_ss_id] <= 1'b1;
		if (sub_ss_seen) bare_sub[sub_ss_id] <= 1'b1;
	end
end
wire        is_bare  = (rd_bare != 2'd0);
wire [15:0] trk_aud  = is_bare ? bare_aud : rd_aud_present;
wire [31:0] trk_sub  = is_bare ? bare_sub : rd_sub_present;
wire [15:0] trk_lang = is_bare ? 16'h2020 : rd_lang_q;


// =========================================================================
// The H.264 front end (umd/h264/h264_top.sv) on clk_dec, behind the video-ES CDC
// (umd/vidfeed_cdc.sv). docs/h264_frontend.md S6 has the reasoning; the seams are
// pinned by tools/check_emu_wiring.py and exercised by bench/umd/p3_chain_tb.sv.
//
// Reset: a mount or an eject resets the WHOLE front end -- the CDC FIFO on both sides,
// the parser chain and its parameter-set store -- held for 16 clk_sys cycles so the 3x
// faster clk_dec side sees it, released into clk_dec through cdc_reset (the block is with
// the transport, above). A seek (P6b3) pulls the same resets (pipe_rst_n / pipe_rst_dec_n)
// except the parameter sets' (fe_rst_dec_n, the mount's alone). Nothing arrives in that
// window: the reader has a walk or a seek to do before the next pack. h264_top's own
// `clear` is therefore tied off.
//
// The syntax-element stream goes to the reconstruction (umd/h264/recon_top.sv, below),
// whose FIFO back-pressures the front end; se_words counts the words it accepted.
// Telemetry for the HUD crosses back through ONE cdc_snap, so every number on screen is
// a value the counters held in the same clk_dec cycle.
// =========================================================================
// (fe_clr_cnt, fe_rst_n, pipe_rst_n and their clk_dec copies: with the transport, above)

// The compressed-video buffer (P6a, umd/vbuf.sv; docs/h264_frontend.md "The compressed-video
// buffer"): the demux's video bytes into a 2 MB ring on ram1 (ddr_mux2 master B, word
// 0x0628_0000, after the DPB's 20 stores) and out to vidfeed_cdc, the PES PTS carried by
// position. It is the CPB a multiplex assumes: without it the demux ran ahead of the display
// only as far as free picture stores reach, and audio the multiplex carries behind the video
// arrived after its time (docs/at3p_decoder.md S7.8). The title's end passes through it:
// flush_out once every byte is delivered. Its engine resets with the PLL lock only (a
// DDR3 master: a request it holds survives a mount and a RESET); the clear runs per mount.
wire  [7:0] vb_byte;
wire        vb_mark, vb_valid, vb_ready, vb_flush, vb_running;
wire [32:0] vb_pts;
wire [31:0] vb_fill, vb_fill_max, vb_bp;
wire [15:0] vb_late;
wire [28:0] vbm_address;
wire  [7:0] vbm_burstcount;
wire        vbm_read, vbm_write, vbm_waitrequest, vbm_readdatavalid;
wire [63:0] vbm_writedata, vbm_readdata;
wire        pipe_rst_mem_n, mem_rst_n, mem_lock_n;   // clk_mem resets (made below, with the DPB's port)
vbuf #(.BASE(29'h0628_0000), .RING_AW(18)) vbuf_inst (
	.clk             (clk_sys),
	.rst_n           (pipe_rst_n),     // the clear: per mount and per seek (P6b3)
	.in_byte         (vid_byte),
	.in_mark         (vid_mark),
	.in_pts          (vid_pts),
	.in_ep           (vid_ep),
	.in_valid        (vid_valid),
	.in_ready        (vid_ready),
	.flush_in        (rd_done),
	.out_byte        (vb_byte),
	.out_mark        (vb_mark),
	.out_pts         (vb_pts),
	.out_ep          (vb_ep),
	.out_valid       (vb_valid),
	.out_ready       (vb_ready),
	.flush_out       (vb_flush),
	.fill            (vb_fill),
	.fill_max        (vb_fill_max),
	.bp_cycles       (vb_bp),
	.late_bytes      (vb_late),
	.running         (vb_running),
	.mclk            (clk_mem),
	.mrst_n          (mem_lock_n),
	.b_address       (vbm_address),
	.b_burstcount    (vbm_burstcount),
	.b_read          (vbm_read),
	.b_write         (vbm_write),
	.b_writedata     (vbm_writedata),
	.b_waitrequest   (vbm_waitrequest),
	.b_readdata      (vbm_readdata),
	.b_readdatavalid (vbm_readdatavalid)
);

wire [43:0] es_data;                      // {item tag, pts[32:0], mark, byte} (P5c: the PES PTS rides with its marked byte; P6b3i its item)
wire       es_valid, es_ready, es_flush, fe_flushed;
vidfeed_cdc #(.DW(44)) vidfeed_cdc_inst (
	.wr_clk     (clk_sys),
	.wr_rst_n   (pipe_rst_n),
	.wr_data    ({vb_ep, vb_pts, vb_mark, vb_byte}),
	.wr_valid   (vb_valid),
	.wr_ready   (vb_ready),
	.wr_flush   (vb_flush),
	.rd_clk     (clk_dec),
	.rd_rst_n   (pipe_rst_dec_n),
	.rd_data    (es_data),
	.rd_valid   (es_valid),
	.rd_ready   (es_ready),
	.rd_flush   (es_flush),
	.rd_flushed (fe_flushed)
);

// P6b4: trick play's one_frame (clk_sys, player_ctl) to clk_dec, two flops. It changes only
// at a seek's accepting edge, where the flush holds h264_top in reset >= 16 clk_sys cycles
// (pipe_rst_n through cdc_reset): settled long before the front end runs. Timed like
// frz_dec_s (the 12.3 ns clk_sys / clk_dec edge pair: no exception needed).
reg  [1:0] one_dec_s;
always @(posedge clk_dec) one_dec_s <= {one_dec_s[0], pc_one};

wire        se_valid, se_ready;
wire  [7:0] se_kind, se_aux;
wire [31:0] se_val;
wire        fe_busy;
wire [31:0] fe_nal, fe_slice, fe_pic, fe_sps, fe_pps, fe_refused, fe_err;
wire  [3:0] fe_refused_code, fe_err_code;
wire [39:0] fe_bins;
// P5c: the picture timing SEI / PTS counters (h264_top -> pt_snap_inst -> the HUD's P5 row)
wire [31:0] fe_pt_seen, fe_pt_missing, fe_pt_bad, fe_sei_err, fe_pts_tag, fe_pts_drop;
wire  [3:0] fe_last_ps;
h264_top h264_top_inst (
	.clk           (clk_dec),
	.rst_n         (pipe_rst_dec_n),   // a mount or a seek (P6b3)
	.ps_rst_n      (fe_rst_dec_n),     // P6b1: the parameter sets' reset -- the mount's alone
	.clear         (1'b0),
	.es_byte       (es_data[7:0]),
	.es_valid      (es_valid),
	.es_ready      (es_ready),
	.es_flush      (es_flush),
	.es_mark       (es_data[8]),
	.es_pts        (es_data[41:9]),
	.es_ep         (es_data[43:42]),
	.one_frame     (one_dec_s[1]),     // P6b4: a trick-play hop decodes the entry's first frame
	.se_valid      (se_valid),
	.se_ready      (se_ready),            // the reconstruction's SE FIFO
	.se_kind       (se_kind),
	.se_aux        (se_aux),
	.se_val        (se_val),
	.sp_pps        (),                    // P4 reads the slice parameters
	.sp_sps        (),
	.sp_slice_type (),
	.sp_field      (),
	.sp_bottom     (),
	.sp_idr        (),
	.sp_frame_num  (),
	.sp_poc_lsb    (),
	.busy          (fe_busy),
	.nal_count     (fe_nal),
	.slice_count   (fe_slice),
	.pic_count     (fe_pic),
	.sps_count     (fe_sps),
	.pps_count     (fe_pps),
	.refused_count (fe_refused),
	.refused_code  (fe_refused_code),
	.err_count     (fe_err),
	.err_code      (fe_err_code),
	.bin_total     (fe_bins),
	.pt_seen_count    (fe_pt_seen),
	.pt_missing_count (fe_pt_missing),
	.pt_bad_count     (fe_pt_bad),
	.sei_err_count    (fe_sei_err),
	.pts_tag_count    (fe_pts_tag),
	.pts_drop_count   (fe_pts_drop),
	.last_pic_struct  (fe_last_ps)
);


// SE words the reconstruction accepted (wraps; a liveness readout, not an accounting)
reg [31:0] se_words;
always @(posedge clk_dec or negedge pipe_rst_dec_n) begin
	if (!pipe_rst_dec_n)           se_words <= 32'd0;
	else if (se_valid && se_ready) se_words <= se_words + 32'd1;
end

// clk_sys cycles the demux spent waiting on the front end (saturating): with the SD
// path at ~2x real time, a growing count says the front end is the slower stage
reg [31:0] vid_stall;
always @(posedge clk_sys or negedge pipe_rst_n) begin
	if (!pipe_rst_n)                                            vid_stall <= 32'd0;
	else if (vid_valid && !vid_ready && vid_stall != 32'hFFFFFFFF) vid_stall <= vid_stall + 32'd1;
end

localparam FE_SNAP_W = 32 * 10 + 4 + 4 + 1;
wire [FE_SNAP_W-1:0] fe_snap;
wire [31:0] sn_nal, sn_slice, sn_pic, sn_sps, sn_pps, sn_refused, sn_err, sn_se, sn_bins;
wire  [3:0] sn_refused_code, sn_err_code;
wire        sn_flushed;
cdc_snap #(.W(FE_SNAP_W)) fe_snap_inst (
	.src_clk   (clk_dec),
	.src_rst_n (fe_rst_dec_n),
	.src_data  ({fe_nal, fe_slice, fe_pic, fe_sps, fe_pps, fe_refused, fe_refused_code,
	             fe_err, fe_err_code, se_words, fe_bins[31:0], fe_flushed}),
	.dst_clk   (clk_sys),
	.dst_rst_n (reset_n),
	.dst_data  (fe_snap),
	.dst_tick  ()
);

// P5c: the picture timing SEI / PTS counters to the HUD's P5 row (their own snapshot)
wire [31:0] sn_pt, sn_pm, sn_pb, sn_sx, sn_ts, sn_td;
wire  [3:0] sn_ps;
cdc_snap #(.W(32 * 6 + 4)) pt_snap_inst (
	.src_clk   (clk_dec),
	.src_rst_n (fe_rst_dec_n),
	.src_data  ({fe_pt_seen, fe_pt_missing, fe_pt_bad, fe_sei_err, fe_pts_tag, fe_pts_drop, fe_last_ps}),
	.dst_clk   (clk_sys),
	.dst_rst_n (reset_n),
	.dst_data  ({sn_pt, sn_pm, sn_pb, sn_sx, sn_ts, sn_td, sn_ps}),
	.dst_tick  ()
);
assign {sn_nal, sn_slice, sn_pic, sn_sps, sn_pps, sn_refused, sn_refused_code,
        sn_err, sn_err_code, sn_se, sn_bins, sn_flushed} = fe_snap;

// =========================================================================
// Raster and the idle screen
// -------------------------------------------------------------------------
// Video Output (O[7:6], docs/analog.md V1): ONE raster for HDMI and the analog pins. Auto =
// Interlaced when the ini says analog (csync / YPbPr / SoG without vga_scaler, or direct_video),
// latched while no picture is shown: Main re-sends its cfg on every resolution report and on
// leaving the OSD, so a live wire would switch the raster under a playing title. A forced
// mode applies at once (sync_gen restarts at a top field; disp_ctl re-aligns; ascal re-detects).
// =========================================================================
// (interlaced_eff is declared with the OSD wires above; its latch sits after disp_ctl,
// whose sh_valid it reads)
wire [11:0] h_pos, v_pos;
wire        pixel_en, h_sync, v_sync, h_blank, v_blank, frame_tick, field, ce_pix;
sync_gen sync_gen_inst (
	.clk        (clk_sys),
	.clk_en     (1'b1),
	.rst_n      (reset_n),
	.interlaced (interlaced_eff),
	.h_pos      (h_pos),
	.v_pos      (v_pos),
	.pixel_en   (pixel_en),
	.h_sync     (h_sync),
	.v_sync     (v_sync),
	.h_blank    (h_blank),
	.v_blank    (v_blank),
	.frame_tick (frame_tick),
	.field      (field),
	.ce_pix     (ce_pix)
);

// =========================================================================
// P4: the reconstruction (umd/h264/recon_top.sv), its DPB client on clk_mem, its output
// queue (umd/recon_out.sv, P5d: the stores in OUTPUT order, C.4.5.3) and the display
// reader (umd/disp_reader.sv). docs/h264_recon.md S4, docs/display.md S6.
//
// The reconstruction runs on clk_dec with the front end (the syntax elements go straight
// across, real back-pressure). Until 2026-09-24 it ran on clk_sys (the P4 smoke clocking,
// umd/se_cdc.sv): the first fits closed clk_dec at 40.9 MHz with it on (docs/h264_recon.md
// S6.2); the area work brought the core to 61 % and the reconstruction back.
//
// Crossings: recon_out. A store the output process emits is held (disp_hold) from that
// clk_dec cycle until the display's release comes back through recon_out's release
// FIFO, so no picture can be written while it is queued or shown (the P4 smoke rule's
// snapshot race is gone). The HUD's counters cross in their own snapshots.
//
// Resets: the reconstruction takes the pipeline's reset on clk_dec (pipe_rst_dec_n: a mount
// or a seek, P6b3; its parameter sets the mount's alone, fe_rst_dec_n); its clk_mem side the
// same released into clk_mem (pipe_rst_mem_n). A mount -- or a seek -- can
// land inside a DDR3 write burst, so the port mux (umd/ddr_mux2.sv) is never reset with
// the decoder: on the mount (and on RESET) it ABORTS the decoder's master, holds a
// request the port had not yet accepted until it is (an Avalon request must never be
// withdrawn under waitrequest), completes an open burst with masked beats and swallows
// the decoder's outstanding read beats.
//
// mem_lock_n: the reset of every master that drives a DDR3 port directly (the mux, its
// abort register, the display reader's fetch side) is the PLL lock alone, never RESET.
// A master reset while a request is held under waitrequest withdraws it; the HPS
// f2sdram port then stops returning read beats (the reload hang: docs/hil_harness.md
// "The reload hang"). With RESET the display reader's fetch side finishes its line and
// idles; nothing it does depends on the clk_sys side's state.
//
// ram1 is the decoder's, and since P6a its master B is the compressed-video buffer (vbuf,
// above; bursts of <= 8, a few per millisecond). The display reads through its own port,
// ram2 (DDRAM2_*, a UMD-FORK in sys/sys_top.v; docs/hw_budget_and_lessons.md S2).
// (pipe_rst_mem_n, mem_rst_n, mem_lock_n are declared with the vbuf, their first reader.)
// =========================================================================
cdc_reset pipe_rst_mem_cdc (
	.clk       (clk_mem),
	.rst_n_in  (pipe_rst_n),       // a mount or a seek: the decoder's master aborted either way
	.rst_n_out (pipe_rst_mem_n)
);
cdc_reset mem_rst_cdc (
	.clk       (clk_mem),
	.rst_n_in  (reset_n),
	.rst_n_out (mem_rst_n)
);
cdc_reset mem_lock_cdc (
	.clk       (clk_mem),
	.rst_n_in  (locked),
	.rst_n_out (mem_lock_n)
);
// P7: the same lock on clk_sys, for the subtitle overlay's clk_sys sides (its demux intake and
// its raster), whose clock-crossing FIFOs and handshakes pair with mclk sides reset by
// mem_lock_n: both ends must reset together (docs/subtitles.md §7). A mount / seek is a flush.
wire lock_sys_n;
cdc_reset lock_sys_cdc (
	.clk       (clk_sys),
	.rst_n_in  (locked),
	.rst_n_out (lock_sys_n)
);
// the abort, synchronous to clk_mem (pipe_rst_mem_n asserts asynchronously)
reg [1:0] dpb_abort_q;
always @(posedge clk_mem or negedge mem_lock_n) begin
	if (!mem_lock_n) dpb_abort_q <= 2'b11;
	else            dpb_abort_q <= {dpb_abort_q[0], ~pipe_rst_mem_n};
end

wire [28:0] dpb_address;
wire  [7:0] dpb_burstcount, dpb_byteenable;
wire        dpb_read, dpb_write, dpb_waitrequest, dpb_readdatavalid;
wire [63:0] dpb_writedata, dpb_readdata;
wire [19:0] disp_hold;                    // one bit per DPB store (h264_pkg NSTORE)
// P5d: the output process -- per picture its display facts (pinfo_*), per store shown
// an emission (emit_*), the end-of-stream flush (eos_done), and its counters
wire        pi_we, pi_second, pi_ps_v, pi_pts_v, pi_idr, pi_timing_v;
wire [31:0] pi_nuit, pi_ts;
wire  [4:0] pi_store;
wire  [1:0] pi_ep, rq_ep, ds_sh_ep;       // P6b3i: the picture's item tag, the record's, the shown one's
wire  [3:0] ds_left;                      // P6b3i: the items the display has left (the audio drops their leftovers)
wire        ds_stalled;                   // P6b3i: the display starved a second (the audio's stall breaker)
wire  [7:0] pi_w, pi_hf;
wire [39:0] pi_crop, pi_aspect;
wire  [3:0] pi_ps;
wire [32:0] pi_pts;
wire        em_valid, em_unpaired, em_first_bot, em_frame, em_dec_t, em_dec_b, rc_eos_done;
wire  [4:0] em_store;
wire [31:0] rc_out_dropped, rc_out_direct, rc_out_over, rc_stall;
wire  [4:0] rc_dpb_fill;
wire [31:0] rc_pics, rc_mbs, rc_err, rc_ref_size;
wire  [3:0] rc_err_code;
wire [15:0] rc_rp_nidr, rc_rp_pre, rc_rp_lead, rc_rp_mmco;   // since the last landing (the pipe reset)
// P6b3i: the display's freeze (clk_sys, refresh-aligned) to clk_dec, two flops: while the
// display is frozen its holds on the DPB are legitimate, and recon_dpb does not count its
// wait on them as err_no_store (a pause counted ~8 a second: transport.md S9)
wire       ds_frz;                    // disp_ctl's freeze level (below)
reg  [1:0] frz_dec_s;
always @(posedge clk_dec) frz_dec_s <= {frz_dec_s[0], ds_frz};
recon_top #(.DPB_BASE(29'h0600_0000)) recon_top_inst (
	.clk              (clk_dec),
	.rst_n            (pipe_rst_dec_n),  // a mount or a seek (P6b3)
	.ps_rst_n         (fe_rst_dec_n),    // P6b1 (as h264_top's): the mount's alone
	.clear            (1'b0),
	.se_valid         (se_valid),
	.se_ready         (se_ready),
	.se_kind          (se_kind),
	.se_aux           (se_aux),
	.se_val           (se_val),
	.disp_hold        (disp_hold),
	.disp_frz         (frz_dec_s[1]),
	.pic_start        (),
	.cur_store        (),
	.cur_struct       (),
	.pic_done         (),
	.done_store       (),
	.done_struct      (),
	.width_mbs        (),
	.frame_height_mbs (),
	.aspect_idc       (),
	.sar_w            (),
	.sar_h            (),
	.idle             (),
	.pinfo_we         (pi_we),
	.pinfo_store      (pi_store),
	.pinfo_second     (pi_second),
	.pinfo_w_mbs      (pi_w),
	.pinfo_hf_mbs     (pi_hf),
	.pinfo_crop       (pi_crop),
	.pinfo_aspect     (pi_aspect),
	.pinfo_timing_v   (pi_timing_v),
	.pinfo_nuit       (pi_nuit),
	.pinfo_ts         (pi_ts),
	.pinfo_ps         (pi_ps),
	.pinfo_ps_v       (pi_ps_v),
	.pinfo_pts        (pi_pts),
	.pinfo_pts_v      (pi_pts_v),
	.pinfo_idr        (pi_idr),
	.pinfo_ep         (pi_ep),
	.emit_valid       (em_valid),
	.emit_store       (em_store),
	.emit_unpaired    (em_unpaired),
	.emit_first_bot   (em_first_bot),
	.emit_frame       (em_frame),
	.emit_dec_t       (em_dec_t),
	.emit_dec_b       (em_dec_b),
	.emit_poc_t       (),
	.emit_poc_b       (),
	.eos_done         (rc_eos_done),
	.out_dropped      (rc_out_dropped),
	.out_direct       (rc_out_direct),
	.out_over         (rc_out_over),
	.stall_cycles     (rc_stall),
	.dpb_fill         (rc_dpb_fill),
	.mclk             (clk_mem),
	.mrst_n           (pipe_rst_mem_n),
	.ddr_address      (dpb_address),
	.ddr_burstcount   (dpb_burstcount),
	.ddr_read         (dpb_read),
	.ddr_write        (dpb_write),
	.ddr_writedata    (dpb_writedata),
	.ddr_byteenable   (dpb_byteenable),
	.ddr_waitrequest  (dpb_waitrequest),
	.ddr_readdata     (dpb_readdata),
	.ddr_readdatavalid(dpb_readdatavalid),
	.pic_count        (rc_pics),
	.mb_count         (rc_mbs),
	.err_count        (rc_err),
	.err_code         (rc_err_code),
	.ref_size         (rc_ref_size),
	.rp_starts        (),
	.rp_non_idr       (rc_rp_nidr),      // P6b7 telemetry: the landing's recovery-point start
	.rp_pre           (rc_rp_pre),
	.rp_lead          (rc_rp_lead),
	.rp_mmco          (rc_rp_mmco)
);

// The output queue (umd/recon_out.sv): the emitted stores as records on clk_sys, the
// display's releases back as the decoder's holds.
wire        rq_valid, rq_end, rq_frame, rq_unpaired, rq_first_bot, rq_dec_t, rq_dec_b, rq_timing_v;
wire        rq_ps_a_v, rq_ps_b_v, rq_pts_v, rq_pts_b_v;
wire  [4:0] rq_store;
wire  [7:0] rq_w, rq_hf;
wire [39:0] rq_aspect;
wire [31:0] rq_nuit, rq_ts;
wire  [3:0] rq_ps_a, rq_ps_b;
wire [32:0] rq_pts, rq_pts_b;
wire [31:0] oq_emit, oq_rel;
wire        oq_ovf, oq_bad;
wire        rq_take, rl_valid, rq_idle, rq_ep_v;
wire  [4:0] rl_store;
recon_out #(.NST(20)) recon_out_inst (
	.clk            (clk_dec),
	.rst_n          (fe_rst_dec_n),
	.pinfo_we       (pi_we),
	.pinfo_store    (pi_store),
	.pinfo_second   (pi_second),
	.pinfo_w_mbs    (pi_w),
	.pinfo_hf_mbs   (pi_hf),
	.pinfo_crop     (pi_crop),
	.pinfo_aspect   (pi_aspect),
	.pinfo_timing_v (pi_timing_v),
	.pinfo_nuit     (pi_nuit),
	.pinfo_ts       (pi_ts),
	.pinfo_ps       (pi_ps),
	.pinfo_ps_v     (pi_ps_v),
	.pinfo_pts      (pi_pts),
	.pinfo_pts_v    (pi_pts_v),
	.pinfo_idr      (pi_idr),
	.pinfo_ep       (pi_ep),
	.emit_valid     (em_valid),
	.emit_store     (em_store),
	.emit_unpaired  (em_unpaired),
	.emit_first_bot (em_first_bot),
	.emit_frame     (em_frame),
	.emit_dec_t     (em_dec_t),
	.emit_dec_b     (em_dec_b),
	.eos_done       (rc_eos_done),
	.oq_hold        (disp_hold),
	.n_emit         (oq_emit),
	.n_rel          (oq_rel),
	.rec_ovf        (oq_ovf),
	.rel_bad        (oq_bad),
	.sclk           (clk_sys),
	.srst_n         (fe_rst_n),
	.rec_valid      (rq_valid),
	.rec_take       (rq_take),
	.rec_end        (rq_end),
	.rec_store      (rq_store),
	.rec_frame      (rq_frame),
	.rec_unpaired   (rq_unpaired),
	.rec_first_bot  (rq_first_bot),
	.rec_dec_t      (rq_dec_t),
	.rec_dec_b      (rq_dec_b),
	.rec_w_mbs      (rq_w),
	.rec_hf_mbs     (rq_hf),
	.rec_crop       (),
	.rec_aspect     (rq_aspect),
	.rec_timing_v   (rq_timing_v),
	.rec_nuit       (rq_nuit),
	.rec_ts         (rq_ts),
	.rec_ps_a       (rq_ps_a),
	.rec_ps_a_v     (rq_ps_a_v),
	.rec_ps_b       (rq_ps_b),
	.rec_ps_b_v     (rq_ps_b_v),
	.rec_pts        (rq_pts),
	.rec_pts_v      (rq_pts_v),
	.rec_pts_b      (rq_pts_b),
	.rec_pts_b_v    (rq_pts_b_v),
	.rec_idr        (),
	.rec_ep_v       (rq_ep_v),
	.rec_ep         (rq_ep),
	.rel_valid      (rl_valid),
	.rel_store      (rl_store),
	.rec_idle       (rq_idle)        // P6b3: a seek's drain is complete
);

// The display's control (umd/disp_ctl.sv + umd/disp_sched.sv, P5e; docs/display.md S7):
// every record is shown when its PTS is due against a 90 kHz STC phased to this raster,
// for its Table E-6 duration; at line 500 a due record is taken and the store shown until
// then released (its last fetch was line 478, line 0's comes at 523); the END record
// leaves the last store up, held. sh_field: the store holds fields (a pair, or one
// field), whose chroma rows belong to their own field; sh_parity: the field to show;
// sh_single: one field alone (the reader bobs it whatever the Deinterlace setting).
wire        sh_valid, sh_field, sh_parity, sh_single, ds_ended;
wire  [4:0] sh_store;
wire  [7:0] sh_w, sh_hf;
wire [39:0] sh_aspect;
wire  [7:0] sh_ar_idc = sh_aspect[39:32];
wire [15:0] sh_sar_w = sh_aspect[31:16], sh_sar_h = sh_aspect[15:0];
wire [31:0] ds_dc, ds_pick;
wire  [7:0] ds_reanchor;
wire  [3:0] ds_lone;
wire [15:0] ds_late, ds_starve, ds_cadence;
wire  [2:0] ds_flags;
wire signed [15:0] ds_lag_ms;
wire [32:0] ds_stc, ds_sh_pts;
wire        ds_stc_run, ds_sh_pts_v, ds_out_hit;     // (ds_frz: declared by recon_top's instance)
wire [15:0] ds_n_skip, ds_n_drain, ds_n_pdefer;
// fj#80 field matching (docs/telecine.md S5): disp_ctl's lock (umd/film_lock.sv) on the reader's comb
// sums; the reader weaves the shown field with a held neighbouring store's other field (480p, in
// every Deinterlace mode: T1 Auto; unlocked, the menu's kernel: T2)
wire        sh_match;
wire  [4:0] sh_pstore;
wire  [1:0] sh_film;
wire [24:0] rd_cm_c;
wire [23:0] rd_cm_r;
wire        rd_cm_v, fl_locked;
wire  [2:0] fl_slot;
wire  [3:0] fl_conf;
wire [15:0] fl_lost;
disp_ctl disp_ctl_inst (
	.clk            (clk_sys),
	.rst_n          (fe_rst_n),
	.h_pos          (h_pos),
	.v_pos          (v_pos),
	.il             (interlaced_eff),
	.rec_valid      (rq_valid),
	.rec_take       (rq_take),
	.rec_end        (rq_end),
	.rec_store      (rq_store),
	.rec_frame      (rq_frame),
	.rec_unpaired   (rq_unpaired),
	.rec_first_bot  (rq_first_bot),
	.rec_dec_t      (rq_dec_t),
	.rec_dec_b      (rq_dec_b),
	.rec_w_mbs      (rq_w),
	.rec_hf_mbs     (rq_hf),
	.rec_aspect     (rq_aspect),
	.rec_timing_v   (rq_timing_v),
	.rec_nuit       (rq_nuit),
	.rec_ts         (rq_ts),
	.rec_ps_a       (rq_ps_a),
	.rec_ps_a_v     (rq_ps_a_v),
	.rec_ps_b       (rq_ps_b),
	.rec_ps_b_v     (rq_ps_b_v),
	.rec_pts        (rq_pts),
	.rec_pts_v      (rq_pts_v),
	.rec_pts_b      (rq_pts_b),
	.rec_pts_b_v    (rq_pts_b_v),
	.rel_valid      (rl_valid),
	.rel_store      (rl_store),
	.sh_valid       (sh_valid),
	.sh_field       (sh_field),
	.sh_store       (sh_store),
	.sh_w           (sh_w),
	.sh_hf          (sh_hf),
	.sh_parity      (sh_parity),
	.sh_single      (sh_single),
	.sh_aspect      (sh_aspect),
	.n_dc           (ds_dc),
	.n_pick         (ds_pick),
	.n_reanchor     (ds_reanchor),
	.n_lone         (ds_lone),
	.n_late         (ds_late),
	.n_starve       (ds_starve),
	.n_cadence      (ds_cadence),
	.flags          (ds_flags),
	.lag_ms         (ds_lag_ms),
	.stc            (ds_stc),
	.stc_run        (ds_stc_run),
	.ended          (ds_ended),
	// the transport (P6b3)
	.freeze         (pc_freeze),
	.frz            (ds_frz),
	.resync         (pc_flush),        // a seek: the queue drained, the scheduler cleared
	.rec_ep_v       (rq_ep_v),         // P6b3i: the record's item tag
	.rec_ep         (rq_ep),
	.ep_we          (pc_ep_we),        // P6b3i: the item table (player_ctl)
	.ep_wi          (pc_ep_wi),
	.ep_in          (pc_ep_in),
	.ep_out         (pc_ep_out),
	.ep_last        (pc_ep_last),
	.ep_skip        (pc_ep_skip),
	.sh_pts         (ds_sh_pts),
	.sh_pts_v       (ds_sh_pts_v),
	.sh_ep          (ds_sh_ep),
	.left_mask      (ds_left),         // P6b3i: to the audio gate
	.vid_stalled    (ds_stalled),
	.waiting        (),
	.skipping       (),
	.out_hit        (ds_out_hit),
	.n_pdefer       (ds_n_pdefer),     // 480i: pickups deferred for field order (V6)
	.n_skip         (ds_n_skip),
	.n_drain        (ds_n_drain),
	.cm_c           (rd_cm_c),         // fj#80: the reader's comb sums of the refresh shown
	.cm_r           (rd_cm_r),
	.cm_v           (rd_cm_v),
	.sh_match       (sh_match),        // fj#80: the lock's choice for the reader
	.sh_pstore      (sh_pstore),
	.sh_film        (sh_film),
	.fl_locked      (fl_locked),       // fj#80: telemetry (`film`)
	.fl_slot        (fl_slot),
	.fl_conf        (fl_conf),
	.n_flost        (fl_lost)
);

// Video Output's Auto latch (see "Raster and the idle screen"): held while a picture is shown
reg  analog_want_l = 1'b0;
wire analog_want_raw = ((ini_csync | ini_ypbpr | ini_sog) & ~ini_vga_scaler & ~forced_scandoubler) | direct_video;
always @(posedge clk_sys or negedge reset_n)
	if (!reset_n) analog_want_l <= 1'b0;
	else if (cfg_seen && !sh_valid) analog_want_l <= analog_want_raw;
wire [1:0] video_out_mode = status[7:6];      // 0 Auto, 1 Interlaced, 2 Progressive
assign     interlaced_eff = (video_out_mode == 2'd1) | ((video_out_mode == 2'd0) & analog_want_l);

wire [31:0] rd_fetch_changes, sn_ft;
wire  [7:0] pic_r, pic_g, pic_b;
wire        pic_de;
// the decoded picture where it covers the raster (LAT 4); stopped (P6b3), not shown
wire        pic_on = pic_de & ~pc_idle;
disp_reader #(.DPB_BASE(29'h0600_0000)) disp_reader_inst (
	.clk               (clk_sys),
	.rst_n             (fe_rst_n),
	.h_pos             (h_pos),
	.v_pos             (v_pos),
	.de_in             (pixel_en),
	.pic_valid         (sh_valid),
	.pic_store         (sh_store),
	.pic_field         (sh_field),
	.pic_w_mbs         (sh_w),
	.pic_hf_mbs        (sh_hf),
	.pic_parity        (sh_parity),
	.pic_single        (sh_single),
	.deint_mode        (status[4:3]),     // Deinterlace: Weave / Bob / Blend (P5f; latched per frame)
	.pic_match         (sh_match),        // fj#80: field matching (disp_ctl's lock)
	.pic_pstore        (sh_pstore),
	.pic_film          (sh_film),
	.cm_c              (rd_cm_c),
	.cm_r              (rd_cm_r),
	.cm_v              (rd_cm_v),
	.il                (interlaced_eff),  // 480i: fields from source field lines (docs/analog.md S2)
	.aa_mode           (aa_mode),         // 480i Analog Aspect (S2): Fit / Letterbox / Crop
	.win               (host_win),        // P9: the video window (umd_host's geometry; docs/p9.md S3.2 item 6)
	.win_hold          (host_win_hold),
	.win_x             (host_win_x),
	.win_y             (host_win_y),
	.win_w             (host_win_w),
	.win_h             (host_win_h),
	.win_hs            (host_win_hs),
	.win_vs            (host_win_vs),
	.win_x0            (host_win_x0),
	.win_y0            (host_win_y0),
	.win_bad           (host_win_bad),
	.pic_still         (ds_frz),          // 480i: a paused pair shows one field (V7)
	.r                 (pic_r),
	.g                 (pic_g),
	.b                 (pic_b),
	.de_out            (pic_de),
	.mclk              (clk_mem),
	.mrst_n            (mem_lock_n),
	.ddr_address       (vr_address),       // P7: through the subtitle overlay's read merge (first)
	.ddr_burstcount    (vr_burstcount),
	.ddr_read          (vr_read),
	.ddr_waitrequest   (vr_waitrequest),
	.ddr_readdata      (vr_readdata),
	.ddr_readdatavalid (vr_readdatavalid),
	.fetch_changes     (rd_fetch_changes)
);

// =========================================================================
// Subtitles (P7, docs/subtitles.md §7, docs/compositor.md §8): umd/sub/sub_overlay.sv is
// everything the subtitles put on ram2 and on the raster -- the demux's subtitle bytes into
// a DDR3 ring, decoded into premultiplied planes, shown / hidden on the STC, read back at
// 1:1 and blended over the picture. ram2 is now its port: disp_reader's master is its read
// merge's first input (the video before the plane), and the subtitle writer is ddr_mux2's A
// (B_FIRST). The picture enters at LAT 4 and the composite leaves at LAT 7 (the raster's
// pixel consumers below take a copy delayed 3). Resets: the lock alone on both sides of
// every crossing; a mount or a seek is `flush` (the port is never reset mid-burst).
// =========================================================================
wire [28:0] vr_address;
wire  [7:0] vr_burstcount;
wire        vr_read, vr_waitrequest, vr_readdatavalid;
wire [63:0] vr_readdata;
// the STC to clk_mem (a handshake snapshot, a few cycles old: the scheduler's 90 kHz grain)
wire [33:0] sb_stc;
cdc_snap #(.W(34)) stc_snap_inst (
	.src_clk   (clk_sys),
	.src_rst_n (reset_n),
	.src_data  ({ds_stc_run, ds_stc}),
	.dst_clk   (clk_mem),
	.dst_rst_n (mem_lock_n),
	.dst_data  (sb_stc),
	.dst_tick  ()
);
// the flush: a mount or a seek (pipe_rst_mem_n asserts asynchronously: registered here)
// ... or a subtitle change (player_ctl's sub_flush: a clk_sys level held 16 cycles, ~53 of
// clk_mem, through two flops)
// ... or (P9) either edge of host_ui: the subtitle side drops what it holds when the UMD Main
// takes the plane (its output is off meanwhile: sp_on) and starts clean when it gives it back
reg [1:0] sb_flush_q, sb_sfl_q;
reg [2:0] sb_ui_q;
always @(posedge clk_mem or negedge mem_lock_n) begin
	if (!mem_lock_n) begin sb_flush_q <= 2'b11; sb_sfl_q <= 2'b00; sb_ui_q <= 3'b000; end
	else begin
		sb_sfl_q   <= {sb_sfl_q[0], pc_sub_flush};
		sb_ui_q    <= {sb_ui_q[1:0], host_ui};
		sb_flush_q <= {sb_flush_q[0], ~pipe_rst_mem_n | sb_sfl_q[1] | (sb_ui_q[2] ^ sb_ui_q[1])};
	end
end
wire  [7:0] sb_r, sb_g, sb_b;              // the composite, LAT 7
wire [15:0] sb_units, sb_shown, sb_late, sb_missed, sb_refused, sb_ring_full, sb_line_late, sb_flips;
wire [15:0] sb_trunc, sb_overrun, sb_orphan, sb_lost, sb_badhdr, sb_oddfield, sb_in_lost, sb_in_pts_lost;
wire        sb_geo_bad;
// A7 (docs/hps_host.md §3.2): the units are decoded by the UMD Main. The overlay's host
// handshake (clk_mem) and umd_host (below) carry it to hps_io's EXT_BUS.
wire        sh_req, sh_buf, sh_vis, sh_done;
wire  [7:0] sh_seq, sh_gen, sh_shown, sh_done_seq;
wire        sh_sbuf;                       // A12 SD2: the shown unit's plane and rectangle
wire [15:0] sh_sx, sh_sy, sh_sw, sh_sh;
wire [15:0] sh_x, sh_y, sh_done_w, sh_done_h, sb_stale;
wire [19:0] sh_start;
wire [31:0] sh_len;
wire  [4:0] sh_done_err;
sub_overlay sub_overlay_inst (
	.sclk            (clk_sys),
	.srst_n          (lock_sys_n),
	.sp_byte         (sp_byte),
	.sp_valid        (sp_valid),
	.sp_frame_start  (sp_frame_start),
	.sp_pts          (sp_pts),
	.sp_pts_valid    (sp_pts_valid),
	.pclk            (clk_sys),         // A12 SD1: png_top's clock, as before A7
	.mclk            (clk_mem),
	.mrst_n          (mem_lock_n),
	.flush           (sb_flush_q[1]),
	.stc             (sb_stc[32:0]),
	.stc_valid       (sb_stc[33]),
	.v_address       (vr_address),
	.v_burstcount    (vr_burstcount),
	.v_read          (vr_read),
	.v_waitrequest   (vr_waitrequest),
	.v_readdata      (vr_readdata),
	.v_readdatavalid (vr_readdatavalid),
	.ddr_address     (DDRAM2_ADDR),
	.ddr_burstcount  (DDRAM2_BURSTCNT),
	.ddr_read        (DDRAM2_RD),
	.ddr_write       (DDRAM2_WE),
	.ddr_writedata   (DDRAM2_DIN),
	.ddr_byteenable  (DDRAM2_BE),
	.ddr_waitrequest (DDRAM2_BUSY),
	.ddr_readdata    (DDRAM2_DOUT),
	.ddr_readdatavalid (DDRAM2_DOUT_READY),
	.clk             (clk_sys),
	.rst_n           (lock_sys_n),
	.h_pos           (h_pos),
	.v_pos           (v_pos),
	.il              (interlaced_eff),
	.de_in           (pixel_en),
	// the picture snapshot's strobe; 480i: the bottom field's blank, so a flip lands at a frame's end
	.vbl             (h_pos == 12'd0 && v_pos == (interlaced_eff ? 12'd501 : 12'd500)),
	.zoom            (zoom),            // fj#71: the subtitle moved inside the band (docs/zoom.md Z3)
	.vid_r           (pic_on ? pic_r : 8'd0),                // the picture, LAT 4 (black outside it)
	.vid_g           (pic_on ? pic_g : 8'd0),
	.vid_b           (pic_on ? pic_b : 8'd0),
	.out_r           (sb_r),
	.out_g           (sb_g),
	.out_b           (sb_b),
	.h_req           (sh_req),
	.h_seq           (sh_seq),
	.h_buf           (sh_buf),
	.h_x             (sh_x),
	.h_y             (sh_y),
	.h_start         (sh_start),
	.h_len           (sh_len),
	.h_gen           (sh_gen),
	.h_vis           (sh_vis),
	.h_shown_seq     (sh_shown),
	.h_sbuf          (sh_sbuf),
	.h_sx            (sh_sx),
	.h_sy            (sh_sy),
	.h_sw            (sh_sw),
	.h_sh            (sh_sh),
	.h_done          (sh_done),
	.h_done_seq      (sh_done_seq),
	.h_done_err      (sh_done_err),
	.h_done_w        (sh_done_w),
	.h_done_h        (sh_done_h),
	.in_lost         (sb_in_lost),
	.in_pts_lost     (sb_in_pts_lost),
	.n_units         (sb_units),
	.n_truncated     (sb_trunc),
	.n_overrun       (sb_overrun),
	.n_orphan        (sb_orphan),
	.n_lost          (sb_lost),
	.n_ring_full     (sb_ring_full),
	.n_badhdr        (sb_badhdr),
	.n_oddfield      (sb_oddfield),
	.n_shown         (sb_shown),
	.n_late          (sb_late),
	.n_missed        (sb_missed),
	.n_refused       (sb_refused),
	.n_stale         (sb_stale),
	.n_line_late     (sb_line_late),
	.n_flips         (sb_flips),
	.geo_bad         (sb_geo_bad),
	.ui              (host_ui),         // P9: the plane is the UMD Main's (a disc menu's page)
	.ui_sub          (host_uis),        // P6d: ... the panel's, the subtitles still running (docs/panel.md §2)
	.hf_req          (hf_req),
	.hf_buf          (hf_buf),
	.hf_vis          (hf_vis),
	.hf_x            (hf_x),
	.hf_y            (hf_y),
	.hf_w            (hf_w),
	.hf_h            (hf_h),
	.hf_ack          (hf_ack),
	.x_address       (px_address),      // P9: the sound one-shot's reader, the lowest on ram2
	.x_burstcount    (px_burstcount),
	.x_read          (px_read),
	.x_waitrequest   (px_waitrequest),
	.x_readdata      (px_readdata),
	.x_readdatavalid (px_readdatavalid)
);
// The host port (A7, docs/hps_host.md §2): umd/umd_host.sv on hps_io's EXT_BUS beside the
// telemetry (0x7B HOST_RD, 0x7C HOST_WR; the bus muxed above umd_telem). host_ok: the UMD
// Main's heartbeat (SUB needs it: player_ctl); host_bad: a UMD Main with the wrong PROTO.
// Resets: the PLL locks alone on both sides (the completion's toggle and its clk_mem copy
// must start together; a core reset never fakes a completion).
wire        host_drive;
wire [15:0] host_dout;
umd_host umd_host_inst (
	.clk         (clk_sys),
	.rst_n       (lock_sys_n),
	.io_enable   (ext_bus[34]),
	.io_strobe   (ext_bus[33]),
	.io_din      (ext_bus[31:16]),
	.drive       (host_drive),
	.dout        (host_dout),
	.host_ok     (host_ok),
	.host_bad    (host_bad),
	.mclk        (clk_mem),
	.mrst_n      (mem_lock_n),
	.h_req       (1'b0),            // A12 SD1: the fabric decodes (sub_dec): the UMD Main is never asked
	.h_seq       (sh_seq),
	.h_buf       (sh_buf),
	.h_x         (sh_x),
	.h_y         (sh_y),
	.h_start     (sh_start),
	.h_len       (sh_len),
	.h_gen       (sh_gen),
	.h_vis       (sh_vis),
	.h_shown_seq (sh_shown),
	.h_sbuf      (sh_sbuf),
	.h_sx        (sh_sx),
	.h_sy        (sh_sy),
	.h_sw        (sh_sw),
	.h_sh        (sh_sh),
	.n_stale     (sb_stale),
	.h_done      (sh_done),
	.h_done_seq  (sh_done_seq),
	.h_done_err  (sh_done_err),
	.h_done_w    (sh_done_w),
	.h_done_h    (sh_done_h),
	// P9 (docs/p9.md S3.2): the player's state, the events, the host's commands and levels
	.p_state     (pc_state),
	.p_seeking   (pc_seeking),
	.p_tk_speed  (pc_tkspd),
	.p_tk_rev    (pc_tkrev),
	.p_sub_on    (pc_sub_on),
	.p_sub_track (pc_sub_track),
	.p_aud_track (pc_aud_track),
	.p_chapter   (pc_chapter),
	.p_n_chapters(pc_nch),
	.p_playlist  (rd_main_pl),
	.p_n_items   (rd_n_items),
	.p_key_item  (pc_key_item),
	.p_pts       (ds_sh_pts),
	.p_pts_v     (ds_sh_pts_v),
	.p_goto_open (gt_open),          // P6d (F2): the panel hides while Go To's editor is up
	.p_sub_any   (trk_sub != 32'd0),   // P6d (F2): the panel's Subtitles item dark without a track (P8: a bare stream's seen)
	.ev_in_v     (pc_ev_v),
	.ev_in_code  (pc_ev_code),
	.ev_in_data  (pc_ev_data),
	.key_press   (hk_press),
	.grab        (host_grab),
	.ui          (host_ui),
	.menu        (host_menu),
	.mute        (host_mute),
	.ui_sub      (host_uis),         // P6d: the panel's mode (sub_overlay)
	.hx_v        (hx_v),             // P6d (F1): the press record, ORed into the presses below
	.hx_mask     (hx_mask),
	.hc_v        (hc_v),
	.hc_code     (hc_code),
	.hc_arg      (hc_arg),
	.hc_pl       (hc_pl),
	.hc_item     (hc_item),
	.hc_pts      (hc_pts),
	.hc_take     (hc_take),
	.hf_req      (hf_req),           // the host's flip: the plane hand-over (S3.2 item 4, sub_overlay)
	.hf_buf      (hf_buf),
	.hf_vis      (hf_vis),
	.hf_x        (hf_x),
	.hf_y        (hf_y),
	.hf_w        (hf_w),
	.hf_h        (hf_h),
	.hf_ack      (hf_ack),
	.hp_req      (hp_req),           // the PCM one-shot (item 5, pcm_shot below)
	.hp_stereo   (hp_stereo),
	.hp_start    (hp_start),
	.hp_len      (hp_len),
	.hp_ack      (hp_ack),
	.pcm_busy    (pcm_busy),
	.pcm_under   (pcm_under),
	.pic_wide    (vui_wide),         // the shown picture's aspect (aspect_vui, below): the host
	.pic_known   (vui_sar_known),    // pillarboxes a 4:3 clip under a menu (P9)
	.menu_aa     (menu_aa),          // ... and fits the menu to a 4:3 CRT at 480i (P9)
	.zoom        (zoom),             // fj#71: Zoom in force -- the panel's subtitle moved as the fabric's
	.win         (host_win),         // the video window (P9 item 6) -> disp_reader
	.win_hold    (host_win_hold),
	.win_x       (host_win_x),
	.win_y       (host_win_y),
	.win_w       (host_win_w),
	.win_h       (host_win_h),
	.win_hs      (host_win_hs),
	.win_vs      (host_win_vs),
	.win_x0      (host_win_x0),
	.win_y0      (host_win_y0),
	.win_bad     (host_win_bad),
	.ev_lost     ()
);
// the subtitle chain's losses for telemetry (the `subs` word; area_plan.md A11 -- the diagnostic HUD's
// subtitle row's counters, slimmed to what a bound hit is visible by): two saturating sums made on
// clk_mem -- dropped (ring full, refused, overrun, truncated, bad header) and late (flips late or
// missed, plane lines late) -- copied to clk_sys in one cdc_snap; the intake's lost bytes (clk_sys)
// join the dropped sum there. Orphans are not counted: a track switch or a seek makes them by design.
wire [17:0] sb_drop_s = {2'd0, sb_ring_full} + {2'd0, sb_refused} + {2'd0, sb_overrun} + {2'd0, sb_trunc} + {2'd0, sb_badhdr};
wire [17:0] sb_late_s = {2'd0, sb_late} + {2'd0, sb_missed} + {2'd0, sb_line_late};
reg  [7:0]  sb_drop_m, sb_late_m;
always @(posedge clk_mem) begin
	sb_drop_m <= (sb_drop_s > 18'd255) ? 8'hFF : sb_drop_s[7:0];
	sb_late_m <= (sb_late_s > 18'd255) ? 8'hFF : sb_late_s[7:0];
end
wire [15:0] sn_sub;
cdc_snap #(.W(16)) sb_snap_inst (
	.src_clk   (clk_mem),
	.src_rst_n (mem_lock_n),
	.src_data  ({sb_drop_m, sb_late_m}),
	.dst_clk   (clk_sys),
	.dst_rst_n (reset_n),
	.dst_data  (sn_sub),
	.dst_tick  ()
);
wire [8:0]  sb_drop_t = {1'b0, sn_sub[15:8]} + ((sb_in_lost > 16'd255) ? 9'd255 : {1'b0, sb_in_lost[7:0]});
wire [7:0]  sb_drop   = sb_drop_t[8] ? 8'hFF : sb_drop_t[7:0];
// the reader's own count of the (store, parity) changes it fetched (clk_mem -> clk_sys
// for the HUD; it resets only with the PLL lock, not per mount: the judder gate compares its
// DELTA with the decided changes' over a span of settled playback)
cdc_snap #(.W(32)) ft_snap_inst (
	.src_clk   (clk_mem),
	.src_rst_n (mem_rst_n),
	.src_data  (rd_fetch_changes),
	.dst_clk   (clk_sys),
	.dst_rst_n (reset_n),
	.dst_data  (sn_ft),
	.dst_tick  ()
);

ddr_mux2 ddr_mux2_inst (
	.clk               (clk_mem),
	.rst_n             (mem_lock_n),
	.a_address         (dpb_address),
	.a_burstcount      (dpb_burstcount),
	.a_read            (dpb_read),
	.a_write           (dpb_write),
	.a_writedata       (dpb_writedata),
	.a_byteenable      (dpb_byteenable),
	.a_abort           (dpb_abort_q[1]),
	.a_waitrequest     (dpb_waitrequest),
	.a_readdata        (dpb_readdata),
	.a_readdatavalid   (dpb_readdatavalid),
	.b_address         (vbm_address),     // master B: the compressed-video buffer (P6a)
	.b_burstcount      (vbm_burstcount),
	.b_read            (vbm_read),
	.b_write           (vbm_write),
	.b_writedata       (vbm_writedata),
	.b_waitrequest     (vbm_waitrequest),
	.b_readdata        (vbm_readdata),
	.b_readdatavalid   (vbm_readdatavalid),
	.ddr_address       (DDRAM_ADDR),
	.ddr_burstcount    (DDRAM_BURSTCNT),
	.ddr_read          (DDRAM_RD),
	.ddr_write         (DDRAM_WE),
	.ddr_writedata     (DDRAM_DIN),
	.ddr_byteenable    (DDRAM_BE),
	.ddr_waitrequest   (DDRAM_BUSY),
	.ddr_readdata      (DDRAM_DOUT),
	.ddr_readdatavalid (DDRAM_DOUT_READY)
);

// the reconstruction's counters to the HUD (clk_dec -> clk_sys, one snapshot: never torn)
// (P6b7: + the landing's recovery-point start for telemetry, the two counts saturated at 7)
wire [31:0] sn_rp, sn_rm, sn_re, sn_rz;
wire  [3:0] sn_rq;
wire  [2:0] sn_rlead, sn_rpre;
wire        sn_rnidr, sn_rmmco;
wire  [2:0] rc_lead_s = (rc_rp_lead > 16'd7) ? 3'd7 : rc_rp_lead[2:0];
wire  [2:0] rc_pre_s  = (rc_rp_pre  > 16'd7) ? 3'd7 : rc_rp_pre[2:0];
cdc_snap #(.W(140)) rc_snap_inst (
	.src_clk   (clk_dec),
	.src_rst_n (fe_rst_dec_n),
	.src_data  ({rc_pics, rc_mbs, rc_err, rc_ref_size, rc_err_code,
	             rc_lead_s, rc_pre_s, (rc_rp_nidr != 16'd0), (rc_rp_mmco != 16'd0)}),
	.dst_clk   (clk_sys),
	.dst_rst_n (reset_n),
	.dst_data  ({sn_rp, sn_rm, sn_re, sn_rz, sn_rq, sn_rlead, sn_rpre, sn_rnidr, sn_rmmco}),
	.dst_tick  ()
);

// P5d: the output process's counters to the HUD (their own snapshot): stores emitted,
// direct outputs, stores dropped, the DPB fullness, the cycles the decoder waited on the
// display's holds (/4096), faults {DPB full of references, queue overflow, bad release}
wire [31:0] sn_oe, sn_od, sn_ox;
wire  [4:0] sn_of;
wire [19:0] sn_ow;
wire  [2:0] sn_oo;
cdc_snap #(.W(32 * 3 + 5 + 20 + 3)) oq_snap_inst (
	.src_clk   (clk_dec),
	.src_rst_n (fe_rst_dec_n),
	.src_data  ({oq_emit, rc_out_direct, rc_out_dropped, rc_dpb_fill, rc_stall[31:12],
	             (rc_out_over != 32'd0), oq_ovf, oq_bad}),
	.dst_clk   (clk_sys),
	.dst_rst_n (reset_n),
	.dst_data  ({sn_oe, sn_od, sn_ox, sn_of, sn_ow, sn_oo}),
	.dst_tick  ()
);

// =========================================================================
// The transport (P6b3, umd/player_ctl.sv; docs/transport.md S2): the player control block.
// Its commands are the J1 buttons' press edges (P6b6, D10: the order in CONF_STR's J1 list
// is the bit order), ORed with the same bits from the keyboard (umd/kbd_map.sv: every action
// has a default key -- FLIRC / IR remotes, CEC, the harness's virtual keyboard). The D-pad's
// Right / Left (and their keys) are FF / REW (P6b4), the framework's own bits. Two presses in
// the very same cycle: the first in Stop, Play/Pause, Pause, Prev, Next, Right, Left, Audio,
// Subtitle order wins (one command a cycle). Display toggles the transport HUD's overlay; UMD
// Menu is the UMD Main's (P9); Control Panel (B11, bit 14; key L) is the UMD Main's too (P6d), and
// bit 15 (no J1 button: the keyboard's B, the panel's item) is A-B Repeat (umd/ab_ctl.sv, below). Subtitle (B9, bit 12; keys S / F4) is SUB (P7). Go To (B10, bit 13; keys G / F2) opens
// goto_ctl's editor (P6c), which then takes the D-pad, Pause and Stop (the routing below).
// =========================================================================
wire [24:0] kbd_joy;
kbd_map kbd_map_inst (
	.clk     (clk_sys),
	.rst_n   (reset_n),
	.ps2_key (ps2_key),
	.joy     (kbd_joy)
);
reg  [14:4] joy_q;
always @(posedge clk_sys) joy_q <= joystick_0[14:4];
// B1..B11 = bits 4..14 (the J1 list); bit 15 is the keyboard's A-B Repeat alone (and the panel's)
wire [15:4] btn_all   = {1'b0, joystick_0[14:4] & ~joy_q} | kbd_joy[15:4];
// P6b4: the D-pad's Right / Left are FF / REW (the PSP's -> / <-), a speed a press. Its press
// edges are gated with the OSD open (the D-pad navigates the menu there); the keyboard's
// arrows reach the core only with the OSD closed (Main keeps them). Up / Down (P9) only ever
// reach the UMD Main's menus.
reg  [3:0] dpad_q;
always @(posedge clk_sys) dpad_q <= joystick_0[3:0];
wire [3:0] dpad_all   = (joystick_0[3:0] & ~dpad_q & {4{~OSD_STATUS}}) | kbd_joy[3:0];
// P6c (docs/p6c.md §9): GO TO (umd/goto_ctl.sv) takes its button always, and while its editor is
// open the D-pad, Pause (x: open a box / confirm) and Stop (o: back out) -- BEFORE the host's grab
// (P9-6 grabs Stop during playback) and the D-pad's FF / REW, so none of them reaches the UMD Main
// or player_ctl then. UMD Menu closes the editor and goes on as itself.
wire [15:0] gt_take   = {2'b00, 1'b1, 6'd0, gt_open, gt_open, 1'b0, {4{gt_open}}};
// P9 (docs/p9.md S3.2 item 3, the menu gate): every press goes to umd_host, which posts the
// GRABBED ones to the UMD Main as KEY events; the transport sees only the others (grab is
// 0 without the UMD Main's heartbeat, so a stock Main changes nothing)
assign     hk_press   = {btn_all, dpad_all} & ~gt_take;
// P6d (docs/panel.md F1): the host's press record -- the control panel's item IS its button -- ORed in
// AFTER the grab and Go To's take, into the transport's presses and Go To's open (k_goto) only: never
// into hk_press (the panel grabs those buttons: a press there would come back to it as a KEY)
wire [15:0] hx_press  = hx_v ? hx_mask : 16'd0;
wire [15:4] btn_press = btn_all & ~host_grab[15:4] & ~gt_take[15:4] | hx_press[15:4];
wire [1:0] dpad_press = dpad_all[1:0] & ~host_grab[1:0] & ~gt_take[1:0] | hx_press[1:0];
// P6d follow-up (the maintainer, 2026-10-05): Audio and Subtitle SHOW the current track first, as the PSP's
// options do -- a press while that tag is not up pops it with the current values (th_show_*, no command);
// a press while it is up is the cycle (AUDIO / SUB). The panel's items are these presses, so they follow.
// (A12 SD3: Subtitle no longer needs the UMD Main -- the fabric decodes -- so its tag shows on a stock Main.)
wire       th_show_aud = btn_press[9] & ~th_tag_aud;
wire       th_show_sub = btn_press[12] & ~th_tag_sub;
// A-B Repeat (docs/ab_repeat.md §2, the PSP): while it loops Next / Prev Chapter are ab_ctl's (both
// jump to A) and FF / REW do nothing -- none of them reaches player_ctl (nor Go To, below)
wire       ab_loop;
wire [15:4] btn_cmd  = {btn_press[15:13], btn_press[12] & ~th_show_sub, btn_press[11:10],
                        btn_press[9] & ~th_show_aud, btn_press[8:7] & ~{2{ab_loop}}, btn_press[6:4]};
wire [1:0] dpad_cmd  = dpad_press & ~{2{ab_loop}};
wire       pc_cmd_v  = |btn_cmd[9:4] | btn_cmd[12] | |dpad_cmd;
wire [3:0] pc_cmd    = btn_cmd[6] ? 4'd4 :             // Stop         -> STOP
                       btn_cmd[4] ? 4'd1 :             // Play/Pause   -> PLAYPAUSE
                       btn_cmd[5] ? 4'd1 :             // Select       -> PLAYPAUSE (the maintainer, 2026-10-07)
                       btn_cmd[7] ? 4'd6 :             // Prev Chapter -> PREV
                       btn_cmd[8] ? 4'd5 :             // Next Chapter -> NEXT
                       dpad_cmd[0] ? 4'd10 :           // Right -> FF
                       |dpad_cmd   ? 4'd11 :           // Left -> REW
                       btn_cmd[9]  ? 4'd8  : 4'd12;    // Audio -> AUDIO; Subtitle -> SUB (P7)
wire       bp_disp   = btn_press[10];                  // Display: the HUD's overlay
// P9: a host command (umd_host's held record) takes a cycle with no button command (and, P6c,
// no Go To jump: goto_ctl's one-cycle command goes first -- a button pressed in that very cycle is lost)
wire        gt_cmd_v;
wire  [3:0] gt_cmd_code;
wire [31:0] gt_cmd_item;
wire [47:0] gt_cmd_pts;
// (A-B Repeat's SEEK to A goes before it: ab_take, below)
wire        ab_req, ab_take;
assign     hc_take   = hc_v & ~pc_cmd_v & ~gt_cmd_v & ~ab_req;
assign     ab_take   = ab_req & ~pc_cmd_v & ~gt_cmd_v;
// the host's code 0 is A-B Repeat's CLEAR (the panel's item): ab_ctl's alone, never player_ctl's
wire        hc_pc     = hc_v & (hc_code != 4'd0);
wire        ab_clear  = hc_take & (hc_code == 4'd0);
wire        ab_hnav   = hc_take & (hc_code == 4'd7 || hc_code == 4'd13 || hc_code == 4'd15);   // a host seek clears it
wire [31:0] ab_item;
wire [47:0] ab_pts;
// a new store on screen: disp_ctl's pickup count moved
reg  [31:0] ds_pick_q;
always @(posedge clk_sys) ds_pick_q <= ds_pick;
wire        ds_pick_evt = (ds_pick != ds_pick_q);
wire  [7:0] pc_wd;
wire [32:0] pc_land;                 // P6b7 telemetry: the landing's first picture, the seek's latency
wire [19:0] pc_slat;
wire        th_disp, th_tph, th_tbad, th_tcut;    // transport_hud's flags (below), for telemetry
wire  [7:0] pc_holds;
wire [15:0] ao_left, ao_yield;
player_ctl player_ctl_inst (
	.clk            (clk_sys),
	.rst_n          (reset_n),         // the CORE reset: a gesture survives its own flush
	.mount          (start_streaming),
	.eject          (img_ejected),
	.cmd_valid      (gt_cmd_v | pc_cmd_v | ab_take | hc_pc), // Go To's jump, the buttons, A-B's SEEK, the host's (P9)
	.cmd_code       (gt_cmd_v ? gt_cmd_code : pc_cmd_v ? pc_cmd : ab_take ? 4'd7 : hc_code),
	.cmd_item       (gt_cmd_v ? gt_cmd_item : pc_cmd_v ? 32'd0 : ab_take ? ab_item : hc_item),
	.cmd_pts        (gt_cmd_v ? gt_cmd_pts : pc_cmd_v ? 48'd0 : ab_take ? ab_pts : hc_pts),
	.cmd_arg        ((gt_cmd_v | pc_cmd_v | ab_take) ? 4'd0 : hc_arg),
	.cmd_pl         (hc_pl),           // P9: PLAYLIST's playlist (the host's only)
	.rd_item_start  (rd_item_start),
	.rd_item_idx    (rd_item_idx),
	.rd_n_items     (rd_n_items),
	.rd_item_out    (rd_item_out),
	.rd_aud_present (trk_aud),         // P8: a bare stream's from the stream
	.rd_sub_present (trk_sub),         // P7
	.rd_n_playlists (rd_n_pl),         // P9: PLAYLIST's bound
	.bare           (is_bare),         // P8: no seek (UNAVAIL); the default track judged as the mask grows
	.nav_req        (pc_nav_req),
	.nav_op         (pc_nav_op),
	.nav_item       (pc_nav_item),
	.nav_pts        (pc_nav_pts),
	.nav_pl         (pc_nav_pl),       // P9
	.nav_ready      (pc_nav_ready),
	.nav_done       (pc_nav_done),
	.nav_err        (rd_nav_err),
	.nav_land       (rd_nav_land),
	.nav_skip       (rd_nav_skip),
	.ch_rank        (rd_ch_rank),
	.ch_count       (rd_ch_count),
	.ch_valid       (rd_ch_valid),
	.ch_cur         (rd_ch_cur),
	.ch_prev        (rd_ch_prev),
	.ch_next        (rd_ch_next),
	.gq_req         (gt_gq_req),       // P6c: Go To's chapter queries
	.gq_key         (gt_gq_key),
	.gq_done        (gt_gq_done),
	.rd_hold        (pc_rd_hold),
	.seek_flush     (pc_flush),
	.aud_rst        (pc_aud_rst),
	.aud_track      (pc_aud_track),
	.aud_realign    (pc_realign),
	.host_ok        (1'b1),            // A12 SD3: the fabric decodes (sub_dec), so SUB no longer needs the
	                                   //   UMD Main (A7 gated it on umd_host's heartbeat; that path is pruned)
	.host_bad       (host_bad),
	.sub_on         (pc_sub_on),       // P7: the subtitles (the demux, the overlay's flush)
	.sub_track      (pc_sub_track),
	.sub_flush      (pc_sub_flush),
	.one_frame      (pc_one),
	.freeze         (pc_freeze),
	.idle_screen    (pc_idle),
	.ep_we          (pc_ep_we),
	.ep_wi          (pc_ep_wi),
	.ep_in          (pc_ep_in),
	.ep_out         (pc_ep_out),
	.ep_last        (pc_ep_last),
	.ep_skip        (pc_ep_skip),
	.item_hold      (pc_item_hold),
	.sh_ep          (ds_sh_ep),
	.sh_pts         (ds_sh_pts),
	.sh_pts_v       (ds_sh_pts_v),
	.pick           (ds_pick_evt),
	.ended          (ds_ended),
	.rec_idle       (rq_idle),
	.state          (pc_state),        // the HUD (P6b5) and telemetry (P6b7) read these
	.seeking        (pc_seeking),
	.chapter        (pc_chapter),
	.n_chapters     (pc_nch),
	.key_item       (pc_key_item),     // P9: the host's rows
	.n_hold         (pc_holds),
	.n_seeks        (pc_seeks),
	.n_wd           (pc_wd),
	.n_bad          (),
	.n_press_lost   (),
	.last_nav_err   (pc_nerr),
	.land_pts       (pc_land),         // P6b7: telemetry
	.seek_lat       (pc_slat),
	.tk_speed       (pc_tkspd),        // P6b4: trick play (the HUD P6b5, telemetry)
	.tk_rev         (pc_tkrev),
	.ev_valid       (pc_ev_v),         // the event FIFO's client: the transport HUD (P6b5)
	.ev_code        (pc_ev_code),
	.ev_data        (pc_ev_data),
	.ev_pop         (1'b1),
	.ev_lost        ()
);

// =========================================================================
// A-B Repeat (umd/ab_ctl.sv; docs/ab_repeat.md, the PSP measured 2026-10-07): its press is bit 15 as it
// reaches the transport (the keyboard's B, the panel's item: btn_press), its CLEAR the host's code 0;
// at B (or a chapter press while it loops) a SEEK (7) to A on player_ctl's command port in a cycle
// with no Go To jump and no button command (ab_take, above). While it loops it takes Next / Prev and
// masks FF / REW and Go To (ab_loop, above). The HUD draws its tag (ab_tag_up / ab_tag_b).
// =========================================================================
wire        ab_tag_up, ab_tag_b, ab_na;
wire  [1:0] ab_st;
ab_ctl ab_ctl_inst (
	.clk       (clk_sys),
	.rst_n     (reset_n),
	.mount     (start_streaming),
	.eject     (img_ejected),
	.k_ab      (btn_press[15]),
	.k_clear   (ab_clear),
	.k_next    (btn_press[8]),
	.k_prev    (btn_press[7]),
	.state     (pc_state),
	.tk_speed  (pc_tkspd),
	.seeking   (pc_seeking),
	.key_item  (pc_key_item),
	.bare      (is_bare),
	.sh_pts    (ds_sh_pts),
	.sh_pts_v  (ds_sh_pts_v),
	.pick      (ds_pick_evt),
	.ended     (ds_ended),
	.host_ui   (host_ui),
	.host_nav  (ab_hnav),
	.cmd_req   (ab_req),
	.cmd_item  (ab_item),
	.cmd_pts   (ab_pts),
	.cmd_take  (ab_take),
	.ab_st     (ab_st),
	.loop      (ab_loop),
	.tag_up    (ab_tag_up),
	.tag_b     (ab_tag_b),
	.unavail   (ab_na),
	.n_loops   (),
	.n_refused (),
	.n_ign     (),
	.n_retry   ()
);

// =========================================================================
// Go To (P6c, umd/goto_ctl.sv; docs/p6c.md §9): the editor -- a chapter, or the playing playlist's
// time -- drawn by transport_hud, its chapter steps asked on player_ctl's Go To query port, its jump
// a SEEK (7) or a TIME (15) on player_ctl's command port. Its keys: the routing above.
// =========================================================================
wire        gt_gq_req, gt_gq_done;
wire [63:0] gt_gq_key;
wire        gt_sel, gt_mv;
wire  [2:0] gt_edit;
wire [15:0] gt_chap;
wire [38:0] gt_t, gt_mark, th_el;
goto_ctl goto_ctl_inst (
	.clk          (clk_sys),
	.rst_n        (reset_n),
	.mount        (start_streaming),
	.eject        (img_ejected),
	.k_goto       ((btn_all[13] | hx_press[13]) & ~ab_loop),   // P6d: the panel's Go To; nothing while A-B loops
	.k_up         (dpad_all[3]),
	.k_down       (dpad_all[2]),
	.k_left       (dpad_all[1]),
	.k_right      (dpad_all[0]),
	.k_ok         (btn_all[5]),        // Pause (x)
	.k_back       (btn_all[6]),        // Stop (o)
	.k_menu       (btn_all[11]),       // UMD Menu: closes it, and goes on to the host
	.state        (pc_state),
	.sh_pts_v     (ds_sh_pts_v),
	.host_ui      (host_ui),
	.key_item     (pc_key_item),
	.sh_pts       (ds_sh_pts),
	.chapter      (pc_chapter),
	.n_chapters   (pc_nch),
	.el_ticks     (th_el),
	.pl_dur       (rd_pl_dur),
	.rd_item_idx  (rd_item_idx),
	.rd_item_in   (rd_item_in),
	.rd_item_out  (rd_item_out),
	.rd_item_base (rd_item_base),
	.ch_rank      (rd_ch_rank),
	.ch_valid     (rd_ch_valid),
	.ch_cur       (rd_ch_cur),
	.ch_next      (rd_ch_next),
	.gq_req       (gt_gq_req),
	.gq_key       (gt_gq_key),
	.gq_done      (gt_gq_done),
	.cmd_v        (gt_cmd_v),
	.cmd_code     (gt_cmd_code),
	.cmd_item     (gt_cmd_item),
	.cmd_pts      (gt_cmd_pts),
	.open         (gt_open),
	.sel          (gt_sel),
	.edit         (gt_edit),
	.g_chapter    (gt_chap),
	.t_ticks      (gt_t),
	.mark_v       (gt_mv),
	.mark_ticks   (gt_mark)
);

// =========================================================================
// Audio (P6a, docs/at3p_decoder.md S7): the demux's ATRAC3plus bytes -> aud_ring (32 KB,
// the tag of every access unit: its PTS) -> at3p_top (the decoder) -> aud_out (4,096
// pairs, a per-frame tag, the 48 kHz tick, the gate against the display's STC) ->
// AUDIO_L/R. All clk_sys, reset per mount and per seek with the demux (aud_rst_n: the
// demux's realign and the ring's framer start together), and on a track switch (P6b3). The demux waits on the ring
// (aud_ready); the gate yields audio from its stale end while the STC has not started
// and the ring blocks the demux (the deadlock rule), and bench/umd/run_av_sync.sh
// proves the chain: the tags, every pair, and when every pair plays.
// =========================================================================
wire  [7:0] ar_byte;
wire        ar_valid, ar_ready, at_valid, at_der, at_has, at_pop;
wire [32:0] at_pts;
wire [16:0] ar_fill, ar_fill_max;
wire [15:0] ar_aus, ar_slides, ar_derived, ar_jumps;
wire [31:0] ar_bp;
aud_ring #(.AW(15)) aud_ring_inst (
	.clk            (clk_sys),
	.rst_n          (aud_rst_n),
	.in_byte        (aud_byte),
	.in_valid       (aud_valid),
	.in_frame_start (aud_frame_start),
	.in_pts         (aud_frame_pts),
	.in_pts_valid   (aud_frame_pts_valid),
	.in_ep          (aud_frame_ep),
	.in_ready       (aud_ready),
	.out_byte       (ar_byte),
	.out_valid      (ar_valid),
	.out_ready      (ar_ready),
	.tag_valid      (at_valid),
	.tag_derived    (at_der),
	.tag_has        (at_has),
	.tag_pts        (at_pts),
	.tag_ep         (at_ep),
	.tag_pop        (at_pop),
	.fill           (ar_fill),
	.fill_max       (ar_fill_max),
	.aus            (ar_aus),
	.slides         (ar_slides),
	.derived        (ar_derived),
	.jumps          (ar_jumps),
	.bp_cycles      (ar_bp)
);

wire [15:0] pcm_l, pcm_r, at3_frames, at3_refused, at3_overruns, at3_sat, at3_clip;
wire  [7:0] at3_last_err;
wire        pcm_valid, pcm_ready;
at3p_top at3p_top_inst (
	.clk        (clk_sys),
	.rst_n      (aud_rst_n),
	.in_byte    (ar_byte),
	.in_valid   (ar_valid),
	.in_ready   (ar_ready),
	.pcm_l      (pcm_l),
	.pcm_r      (pcm_r),
	.pcm_valid  (pcm_valid),
	.pcm_ready  (pcm_ready),
	.frames     (at3_frames),
	.refused    (at3_refused),
	.last_err   (at3_last_err),
	.overruns   (at3_overruns),
	.sat_count  (at3_sat),
	.clip_count (at3_clip),
	.mark_valid (),
	.mark_id    (),
	.vop_start  (),
	.vop_op     (),
	.vop_done   (),
	.tr_valid   (),
	.tr_pc      (),
	.tr_kind    (),
	.tr_addr    (),
	.tr_val     ()
);

wire [15:0] ao_l, ao_r, ao_frames, ao_stale, ao_pre;
wire  [7:0] ao_under, ao_resync, ao_fb, ao_miss;
wire signed [15:0] ao_err;
wire        ao_running, ao_err_seen;
wire [13:0] ao_fill;
aud_out #(.AW(12)) aud_out_inst (
	.clk           (clk_sys),
	.rst_n         (aud_rst_n),
	.pcm_l         (pcm_l),
	.pcm_r         (pcm_r),
	.pcm_valid     (pcm_valid),
	.pcm_ready     (pcm_ready),
	.tag_valid     (at_valid),
	.tag_has       (at_has),
	.tag_pts       (at_pts),
	.tag_pop       (at_pop),
	.stc           (ds_stc),
	.stc_run       (ds_stc_run),
	.ring_blocked  (aud_valid & ~aud_ready),
	.freeze        (ds_frz),          // P6b3: pause -- the STC's own freeze
	.tag_ep        (at_ep),           // P6b3i: a left item's audio is dropped; the stall breaker
	.left_mask     (ds_left),
	.vid_stalled   (ds_stalled),
	.n_left        (ao_left),
	.n_yield       (ao_yield),
	.audio_l       (ao_l),
	.audio_r       (ao_r),
	.running       (ao_running),
	.frames_played (ao_frames),
	.under         (ao_under),
	.resync        (ao_resync),
	.fallback      (ao_fb),
	.tag_miss      (ao_miss),
	.stale         (ao_stale),
	.pre_drop      (ao_pre),
	.err_ticks     (ao_err),
	.err_seen      (ao_err_seen),
	.sample_tick   (),
	.play          (),
	.fill          (ao_fill)
);
// the last frame start's STC - PTS in ms for the HUD (ticks x 728 / 65536, as disp_ctl's lag)
wire signed [31:0] ao_err_x = ao_err * 16'sd728;
wire signed [15:0] ao_err_ms = ao_err_x[31:16];

// P9 (docs/p9.md S3.2 item 5): the menus' sound effects, a one-shot of 16-bit PCM the UMD Main
// writes into ram2 (core word 0x0660_0000, 8 MB) and triggers through umd_host; mixed over the
// film's output, saturating. Resets: the PLL locks alone (a sound plays across a mount, as the
// host's page does).
wire signed [15:0] ps_l, ps_r;
pcm_shot #(.BASE (29'h0660_0000), .RW (20)) pcm_shot_inst (
	.clk             (clk_sys),
	.rst_n           (lock_sys_n),
	.hp_req          (hp_req),
	.hp_stereo       (hp_stereo),
	.hp_start        (hp_start),
	.hp_len          (hp_len),
	.hp_ack          (hp_ack),
	.busy            (pcm_busy),
	.pcm_l           (ps_l),
	.pcm_r           (ps_r),
	.n_under         (pcm_under),       // -> HOST_RD (the host plays the sounds)
	.mclk            (clk_mem),
	.mrst_n          (mem_lock_n),
	.ddr_address     (px_address),
	.ddr_burstcount  (px_burstcount),
	.ddr_read        (px_read),
	.ddr_waitrequest (px_waitrequest),
	.ddr_readdata    (px_readdata),
	.ddr_readdatavalid (px_readdatavalid)
);
// host_mute (P9): a menu's play() with its audio off -- the film's sound silent, the one-shot heard
wire signed [15:0] am_l = host_mute ? 16'sd0 : ao_l;
wire signed [15:0] am_r = host_mute ? 16'sd0 : ao_r;
wire signed [16:0] mx_l = $signed({am_l[15], am_l}) + $signed({ps_l[15], ps_l});
wire signed [16:0] mx_r = $signed({am_r[15], am_r}) + $signed({ps_r[15], ps_r});
assign AUDIO_L   = (mx_l[16] != mx_l[15]) ? {mx_l[16], {15{~mx_l[16]}}} : mx_l[15:0];
assign AUDIO_R   = (mx_r[16] != mx_r[15]) ? {mx_r[16], {15{~mx_r[16]}}} : mx_r[15:0];
assign AUDIO_S   = 1'b1;                  // signed s16
assign AUDIO_MIX = 2'd0;

// =========================================================================
// HIL telemetry (docs/hil_harness.md "Telemetry"): the DDR3 ports as the HPS sees them
// (umd/ddr_probe.sv on emu's DDRAM* / DDRAM2* wires, clk_mem, carried to clk_sys by a
// cdc_snap each), and the responder on hps_io's EXT_BUS (umd/umd_telem.sv, command
// 0x7A, the words of tools/telem_layout.py) -- read by the custom Main's umd_ctl only
// when the rig is armed for HIL; stock Main never sends 0x7A and the core stays off the
// bus. Every source is clk_sys (disp_ctl's, or a snapshot copy).
// =========================================================================
wire [23:0] d1_wr, d1_rdb, d2_wr, d2_rdb;
wire [15:0] d1_owed, d1_busy, d1_busy_max, d2_owed, d2_busy, d2_busy_max;
ddr_probe ddr1_probe_inst (
	.clk           (clk_mem),
	.rst_n         (mem_rst_n),
	.read          (DDRAM_RD),
	.write         (DDRAM_WE),
	.burstcount    (DDRAM_BURSTCNT),
	.waitrequest   (DDRAM_BUSY),
	.readdatavalid (DDRAM_DOUT_READY),
	.wr_beats      (d1_wr),
	.rd_beats      (d1_rdb),
	.owed          (d1_owed),
	.busy          (d1_busy),
	.busy_max      (d1_busy_max)
);
ddr_probe ddr2_probe_inst (
	.clk           (clk_mem),
	.rst_n         (mem_rst_n),
	.read          (DDRAM2_RD),
	.write         (DDRAM2_WE),
	.burstcount    (DDRAM2_BURSTCNT),
	.waitrequest   (DDRAM2_BUSY),
	.readdatavalid (DDRAM2_DOUT_READY),
	.wr_beats      (d2_wr),
	.rd_beats      (d2_rdb),
	.owed          (d2_owed),
	.busy          (d2_busy),
	.busy_max      (d2_busy_max)
);
// only the 16-bit views the telemetry sends cross (beats / 256)
wire [15:0] sn_d1_wr, sn_d1_rdb, sn_d2_rdb;
wire [15:0] sn_d1_owed, sn_d1_busy, sn_d1_busy_max, sn_d2_owed, sn_d2_busy, sn_d2_busy_max;
cdc_snap #(.W(16 * 5)) d1_snap_inst (
	.src_clk   (clk_mem),
	.src_rst_n (mem_rst_n),
	.src_data  ({d1_wr[23:8], d1_rdb[23:8], d1_owed, d1_busy, d1_busy_max}),
	.dst_clk   (clk_sys),
	.dst_rst_n (reset_n),
	.dst_data  ({sn_d1_wr, sn_d1_rdb, sn_d1_owed, sn_d1_busy, sn_d1_busy_max}),
	.dst_tick  ()
);
cdc_snap #(.W(16 * 4)) d2_snap_inst (
	.src_clk   (clk_mem),
	.src_rst_n (mem_rst_n),
	.src_data  ({d2_rdb[23:8], d2_owed, d2_busy, d2_busy_max}),
	.dst_clk   (clk_sys),
	.dst_rst_n (reset_n),
	.dst_data  ({sn_d2_rdb, sn_d2_owed, sn_d2_busy, sn_d2_busy_max}),
	.dst_tick  ()
);
wire        telem_drive;
wire [15:0] telem_dout;
// two responders on EXT_BUS: each drives only for its own command (0x7A / 0x7B), never both
assign ext_bus[32]   = telem_drive | host_drive;
assign ext_bus[15:0] = host_drive ? host_dout : telem_dout;
umd_telem umd_telem_inst (
	.clk           (clk_sys),
	.io_enable     (ext_bus[34]),
	.io_strobe     (ext_bus[33]),
	.io_din        (ext_bus[31:16]),
	.drive         (telem_drive),
	.dout          (telem_dout),
	.refresh       (frame_tick),
	.t_pickups     (ds_pick),
	.t_dc          (ds_dc),
	.t_ft          (sn_ft),
	.t_stc         (ds_stc),
	.t_late        (ds_late),
	.t_starve      (ds_starve),
	.t_cadence     (ds_cadence),
	.t_reanchor    (ds_reanchor),
	.t_ended       (ds_ended),
	.t_sflags      (ds_flags),
	.t_lag_ms      (ds_lag_ms),
	.t_emitted     (sn_oe),
	.t_dpb_fill    (sn_of),
	.t_oq_flags    (sn_oo),
	.t_wait4k      (sn_ow),
	.t_pics        (sn_rp),
	.t_mbs         (sn_rm),
	.t_rerr        (sn_re),
	.t_rcode       (sn_rq),
	.t_slices      (sn_slice),
	.t_se          (sn_se),
	.t_ferr        (sn_err),
	.t_fcode       (sn_err_code),
	.t_packs       (rd_secs),
	.t_vstall      (vid_stall),
	.t_d1_wr       (sn_d1_wr),
	.t_d1_rdb      (sn_d1_rdb),
	.t_d1_busy     (sn_d1_busy),
	.t_d1_busy_max (sn_d1_busy_max),
	.t_d1_owed     (sn_d1_owed),
	.t_d2_rdb      (sn_d2_rdb),
	.t_d2_busy     (sn_d2_busy),
	.t_d2_busy_max (sn_d2_busy_max),
	.t_d2_owed     (sn_d2_owed),
	.t_pt          (sn_pt),
	.t_pts         (sn_ts),
	.t_af          (at3_frames),
	.t_ar          (at3_refused),
	.t_ak          (at3_last_err),
	.t_aplayed     (ao_frames),
	.t_under       (ao_under),
	.t_resync      (ao_resync),
	.t_av_err      (ao_err),
	.t_adrop       (ao_stale + ao_pre),
	.t_arun        (ao_running),
	.t_stc_run     (ds_stc_run),
	.t_aerr_seen   (ao_err_seen),
	.t_afb         (ao_fb),
	.t_amiss       (ao_miss),
	.t_apre_nz     (ao_pre != 16'd0),
	.t_rfill       (ar_fill[15:0]),
	.t_rmax        (ar_fill_max[15:0]),
	.t_rbp         (ar_bp),
	.t_rslides     (ar_slides),
	.t_rjumps      (ar_jumps),
	.t_vfill       (vb_fill),
	.t_vmax        (vb_fill_max),
	.t_vbp         (vb_bp),
	.t_vlate       (vb_late),
	.t_rdst        (rd_state),
	.t_rdec        (rd_err),
	.t_rbare       (rd_bare),          // P8
	.t_rpw         (rd_pmf_warn),
	.t_epf         (rd_ep_flags),
	.t_xstate      (pc_state),
	.t_xseek       (pc_seeking),
	.t_xshep       (ds_sh_ep),
	.t_xleft       (ds_left),
	.t_xstall      (ds_stalled),
	.t_xhold       (pc_item_hold),
	.t_xnerr       (pc_nerr),
	.t_chap        (pc_chapter),
	.t_seeks       (pc_seeks),
	.t_holds       (pc_holds),
	.t_shpts       (ds_sh_pts),
	.t_aleft       (ao_left),
	.t_ayield      (ao_yield),
	.t_tkspd       (pc_tkspd),         // P6b4
	.t_tkrev       (pc_tkrev),
	.t_tkone       (pc_one),
	.t_hud         ({th_disp, th_tph, th_tbad, th_tcut}),   // P6b7
	.t_land        (pc_land),
	.t_slat        (pc_slat),
	.t_wd          (pc_wd),
	.t_rlead       (sn_rlead),
	.t_rpre        (sn_rpre),
	.t_rnidr       (sn_rnidr),
	.t_rmmco       (sn_rmmco),
	.t_lone        (ds_lone),
	.t_il          (interlaced_eff),
	.t_aa          (aa_live ? aa_mode : 2'd0),
	.t_pdefer      (ds_n_pdefer),
	.t_frn         (sn_refused[7:0]),
	.t_frc         (sn_refused_code),
	.t_rzn         (sn_rz[3:0]),
	.t_rwarn       ({rd_dur_sat, rd_title_trunc, rd_sfo_warn}),
	.t_odir        (sn_od[3:0]),
	.t_odrp        (sn_ox[7:0]),
	.t_sdrop       (sb_drop),
	.t_slate       (sn_sub[7:0]),
	.t_flk         (fl_locked),        // fj#80: field matching
	.t_fslot       (fl_slot),
	.t_fconf       (fl_conf),
	.t_flost       (fl_lost)
);

// (The diagnostic HUD -- p2_diag + diag_hud, O[8] Diagnostics -- left the core 2026-10-03 to
// make room for Go To in fabric: area_plan.md A11, which reverses A8. What only it showed is in
// telemetry now, and a disc that cannot be played says so on the transport HUD's message band.)

// The wave shows whenever no media is loaded, and over the held picture while stopped
// (P6b3, D5: the idle screen is the PSP's XMB; a display-layer term, never a media_seen
// clear -- MiSTer_DVD's docs/screensaver.md has the reasoning).
wire       wave_vis = ~media_seen | (pc_idle & ~host_menu);   // P9: under a disc menu, stop is black
wire [7:0] wave_r, wave_g, wave_b;
wire       wave_de;
wire [3:0] wave_month;
// The raster for the pixel-only consumers, delayed 3 (P7): the subtitle overlay's composite
// is LAT 7, so the wave and the transport HUD (each LAT 4 from its own
// raster input) take this copy and land at LAT 7 with it. Everything that talks to the
// display scheduler or a reader (disp_ctl, disp_reader, sub_overlay, player_ctl's pick)
// stays on the undelayed raster (docs/subtitles.md §7).
reg [11:0] h_pos_q1, h_pos_q2, h_pos_l7, v_pos_q1, v_pos_q2, v_pos_l7;
reg        pe_q1, pe_q2, pixel_en_l7;
always @(posedge clk_sys) begin
	h_pos_q1 <= h_pos;    h_pos_q2 <= h_pos_q1; h_pos_l7    <= h_pos_q2;
	v_pos_q1 <= v_pos;    v_pos_q2 <= v_pos_q1; v_pos_l7    <= v_pos_q2;
	pe_q1    <= pixel_en; pe_q2    <= pe_q1;    pixel_en_l7 <= pe_q2;
end
// the pixel layers draw in COLUMNS: at 480i h_pos counts dots, a pixel is two (docs/analog.md
// V3; the fork's W40: the idle screen squeezed into the left half)
wire [11:0] h_col_l7 = interlaced_eff ? {1'b0, h_pos_l7[11:1]} : h_pos_l7;

xmb_wave xmb_wave_inst (
	.clk         (clk_sys),
	.rst_n       (reset_n),
	.h_pos       (h_col_l7),
	.v_pos       (v_pos_l7),
	.de_in       (pixel_en_l7),
	.frame_tick  (frame_tick),
	.vis         (wave_vis),
	.timestamp   (hps_timestamp),
	.month_force (4'd0),
	.r           (wave_r),
	.g           (wave_g),
	.b           (wave_b),
	.de_out      (wave_de),
	.month_o     (wave_month)
);

// The background at LAT 7 (P7): playing, the subtitle overlay's composite (the picture, black
// outside it, the subtitles over both); stopped (P6b3) or with no media, the wave (black while
// an image is loaded): so a held subtitle never shows over the idle screen. (Before P7: the
// picture where pic_on, else the wave, at LAT 4 -- the same image without subtitles.)
// P9 M4: a disc menu's page over a STOPPED player is the composite too (black video, the page
// over it): Ghost in the Shell 2.0's onMenu stops the film and opens its chapter menu over black;
// with the wave's black alone the page never showed (the rig, 2026-10-03). Only while the host owns
// the plane (host_ui): a held subtitle never shows over a stop (docs/p9.md M4)
wire       show_pic = media_seen & (~pc_idle | host_ui | host_uis);   // P6d: the panel over a stop (on black: panel.md §7)
wire [7:0] bg_r = show_pic ? sb_r : wave_de ? wave_r : 8'd0;
wire [7:0] bg_g = show_pic ? sb_g : wave_de ? wave_g : 8'd0;
wire [7:0] bg_b = show_pic ? sb_b : wave_de ? wave_b : 8'd0;

// The transport HUD (P6b5, docs/transport_hud.md S6): the state icon, the pop-up captions, the
// message band and the Display overlay, over the picture. Its pixel path is LAT = 4 like
// xmb_wave's; `th_rgb` is the picture with the HUD over it,
// combinational from bg_* at the output stage.
// A11: the core stopped on the disc -- a NEW front-end refusal (an unsupported coding: CLAUDE.md's
// "refused loudly"; the count is per mount, the snapshot's copy) or the reader stopping on an error --
// pops "This disc cannot be played." on the transport HUD's message band (the diagnostic HUD that
// showed REF / ERR left the core; telemetry's `refused` / `reader` words keep the codes)
reg  [31:0] unp_ref_q;
reg         unp_err_q;
always @(posedge clk_sys) begin
	unp_ref_q <= sn_refused;
	unp_err_q <= (rd_err != 4'd0);
end
// P6d (docs/panel.md F4): the Control Panel button reached the transport -- no UMD Main took it: none
// at all (1: "needs the UMD Main"), or one without the panel / of another PROTO (2: "Update ...")
wire  [1:0] th_pmsg = btn_press[14] ? ((host_ok | host_bad) ? 2'd2 : 2'd1) : 2'd0;
wire        th_unplay = ((sn_refused != unp_ref_q) && (sn_refused != 32'd0)) || ((rd_err != 4'd0) && !unp_err_q);
wire [23:0] th_rgb;
// fj#71 Zoom (docs/zoom.md): the HUD in its title-safe layout (the 480i twin, lines 54 .. 411), moved
// down 7 lines -- 61 .. 418, inside the band the scaler shows (60 .. 419). The lines above wrap past
// 4095 - 6, which the HUD draws nothing on (its v_pos[11:10] guard); they are cut anyway.
wire [11:0] hud_v_pos = zoom ? v_pos_l7 - 12'd7 : v_pos_l7;
transport_hud transport_hud_inst (
	.clk         (clk_sys),
	.rst_n       (reset_n),
	.mount       (start_streaming),
	.show        (media_seen & ~host_menu),   // P9: hidden while a disc menu is up (the PSP shows none)
	.il          (interlaced_eff),     // its pop-up timer counts fields (V3)
	.safe        (interlaced_eff | zoom),   // the title-safe layout: 480i (analog.md S8), or Zoom's band (fj#71)
	.h_pos       (h_col_l7),
	.v_pos       (hud_v_pos),
	.de_in       (pixel_en_l7),
	.bg          ({bg_r, bg_g, bg_b}),
	.rgb         (th_rgb),
	.state       (pc_state),
	.tk_speed    (pc_tkspd),
	.tk_rev      (pc_tkrev),
	.chapter     (pc_chapter),
	.n_chapters  (pc_nch),
	.ev_valid    (pc_ev_v),
	.ev_code     (pc_ev_code),
	.ev_data     (pc_ev_data),
	.cmd_next    (pc_cmd_v && !gt_cmd_v && pc_cmd == 4'd5),   // (a press lost to Go To's jump pops nothing)
	.cmd_prev    (pc_cmd_v && !gt_cmd_v && pc_cmd == 4'd6),
	.disp_toggle (bp_disp),
	.unplay      (th_unplay),
	.pmsg        (th_pmsg),            // P6d: the Control Panel button with no UMD Main to take it
	.ab_up       (ab_tag_up),          // A-B Repeat (ab_ctl): its tag (docs/ab_repeat.md §4)
	.ab_b        (ab_tag_b),
	.ab_loop     (ab_loop),
	.ab_na       (ab_na),              //   pressed on a bare file: "Not available for this file."
	.show_aud    (th_show_aud),        // P6d follow-up: Audio / Subtitle show the current track first
	.show_sub    (th_show_sub),
	.aud_cur     (pc_aud_track),
	.sub_on_cur  (pc_sub_on),
	.sub_cur     (pc_sub_track),
	.tag_aud     (th_tag_aud),
	.tag_sub     (th_tag_sub),
	.aud_present (trk_aud),            // (P8: a bare stream's from the stream)
	.sub_present (trk_sub),            // P7: the subtitle tag's rank
	.sh_pts      (ds_sh_pts),
	.sh_pts_v    (ds_sh_pts_v),
	.sh_ep       (ds_sh_ep),
	.item_start  (rd_item_start),
	.item_tag    (rd_item_idx[1:0]),
	.item_in     (rd_item_in),
	.item_base   (rd_item_base),
	.pl_dur      (rd_pl_dur),
	.el_ticks    (th_el),              // P6c: Go To opens on it
	.goto_open   (gt_open),            // P6c: Go To's editor (goto_ctl)
	.goto_sel    (gt_sel),
	.goto_edit   (gt_edit),
	.goto_chap   (gt_chap),
	.goto_t      (gt_t),
	.goto_mv     (gt_mv),
	.goto_mark   (gt_mark),
	.title_addr  (th_title_addr),
	.title_q     (th_title_q),
	.title_len   (title_len),
	.title_trunc (rd_title_trunc),
	.lang_sel    (th_lang_sel),
	.lang_q      (trk_lang),           // P8: none on a bare stream
	.display     (th_disp),
	.t_ph        (th_tph),
	.t_bad       (th_tbad),
	.t_cut       (th_tcut)
);

// Sync delayed to match the composite and the HUDs (LAT 7 since P7: the subtitle overlay's
// LAT 4 -> 7, the others LAT 4 from the raster delayed 3), then one output register. The HUD
// composes over the background: fill white, outline black, a glyph cell's transparent dots
// at half the background.
reg [6:0] hs_dly, vs_dly, de_dly, ce_dly, f1_dly, cut_dly;
always @(posedge clk_sys) begin
	hs_dly <= {hs_dly[5:0], h_sync};
	vs_dly <= {vs_dly[5:0], v_sync};
	de_dly <= {de_dly[5:0], pixel_en & ~zoom_cut};   // the raster's active area, LAT 7 like hs / vs;
	                                                 // fj#71: under Zoom only its band (the scaler's capture)
	cut_dly <= {cut_dly[5:0], zoom_cut};  // fj#71 Z5: the cut lines' RGB black too (the analog pins: not DE-gated in sys)
	ce_dly <= {ce_dly[5:0], ce_pix};      // 480i: a pixel every other dot (V2), LAT 7 like hs / vs
	f1_dly <= {f1_dly[5:0], field};       // VGA_F1: 0 on the TOP field (ascal's Weave, DVD #41)
end

reg [7:0] vga_r_q, vga_g_q, vga_b_q;
reg       vga_hs_q, vga_vs_q, vga_de_q, vga_ce_q, vga_f1_q;
always @(posedge clk_sys) begin
	vga_r_q  <= cut_dly[6] ? 8'd0 : th_rgb[23:16];
	vga_g_q  <= cut_dly[6] ? 8'd0 : th_rgb[15:8];
	vga_b_q  <= cut_dly[6] ? 8'd0 : th_rgb[7:0];
	vga_hs_q <= hs_dly[6];
	vga_vs_q <= vs_dly[6];
	vga_de_q <= de_dly[6];
	vga_ce_q <= ce_dly[6];
	vga_f1_q <= f1_dly[6];
end
assign VGA_R  = vga_r_q;
assign VGA_G  = vga_g_q;
assign VGA_B  = vga_b_q;
assign VGA_HS = vga_hs_q;
assign VGA_VS = vga_vs_q;
assign VGA_DE = vga_de_q;
assign CE_PIXEL = vga_ce_q;      // 1 at 480p; every other dot at 480i
assign VGA_F1 = vga_f1_q;        // 0 at 480p and on the 480i top field
assign VGA_SL = 2'd0;
assign VGA_SCALER  = 1'b0;
assign VGA_DITHER  = status[16];   // Analog Dither (Off by default: an 18-bit I/O board's DAC bands, a 24-bit one does not)
assign VGA_DISABLE = 1'b0;
// Composite sync at 480i (docs/analog.md V4): SMPTE 170M equalising and serrated pulses, both
// fields' vertical intervals the same shape half a line apart. Its h_sync is the tap VGA_HS's
// register takes (hs_dly[6]), so cs lands in VGA_HS's clock as sys_top's CS_PIPE expects; 480p
// keeps the framework's csync (cs_en 0).
wire cs_smpte, cs_smpte_en;
csync_smpte csync_smpte_inst (
	.clk    (clk_sys),
	.rst_n  (reset_n),
	.mode   (1'b0),
	.en     (interlaced_eff),
	.prog   (1'b0),
	.pal    (1'b0),
	.h_sync (hs_dly[6]),
	.v_pos  (v_pos),
	.cs     (cs_smpte),
	.cs_en  (cs_smpte_en)
);
assign VGA_CS    = cs_smpte;
assign VGA_CS_EN = cs_smpte_en;
assign HDMI_FREEZE    = 1'b0;
assign HDMI_BLACKOUT  = 1'b0;
assign HDMI_BOB_DEINT = interlaced_eff & status[5];   // O[5] HDMI Deinterlace: Weave / Bob (480i)

// =========================================================================
// Aspect ratio presented to the scaler
// -------------------------------------------------------------------------
// O[2:1]: Auto / 4:3 / 16:9. Auto with media loaded = the shown picture's VUI aspect
// (P5b, umd/aspect_vui.sv): the display aspect rounded to the nearer of 4:3 and 16:9.
// An unspecified SAR (no VUI, idc 0 / reserved) keeps the P4 rule: 16:9 (every UMD
// title measured is anamorphic 16:9). At idle, Auto follows the DISPLAY: a widescreen
// HDMI mode gets a full-width wave instead of a pillarboxed 4:3 window. W*2 >= H*3 <=>
// W/H >= 1.5, by shift-add; HDMI_WIDTH == 0 (no scaler) takes the 4:3 path. Registered;
// its inputs change only with the latched picture (the SPS), so VIDEO_ARX/ARY stay
// stable -- every change re-inits the scaler.
// =========================================================================
reg disp_wide_q = 1'b0;
always @(posedge clk_sys)
	disp_wide_q <= ({1'b0, HDMI_WIDTH, 1'b0} >=                        // W*2
	                {1'b0, HDMI_HEIGHT, 1'b0} + {2'b00, HDMI_HEIGHT})  // H*3
	               && (HDMI_WIDTH != 12'd0);
aspect_vui aspect_vui_inst (
	.clk        (clk_sys),
	.valid      (sh_valid),
	.aspect_idc (sh_ar_idc),
	.ext_sar_w  (sh_sar_w),
	.ext_sar_h  (sh_sar_h),
	.w_mbs      (sh_w),
	.hf_mbs     (sh_hf),
	.known      (vui_sar_known),
	.wide       (vui_wide)
);
wire idle_wide  = ~media_seen & disp_wide_q;
// P9: under a disc menu, 16:9 whatever the clip -- a menu is drawn in the PSP's 854 x 480 space
// (every disc), and the host pillarboxes a 4:3 clip under it (docs/p9.md M3, the first rig session)
wire auto_wide  = media_seen ? (host_menu | (vui_sar_known ? vui_wide : 1'b1)) : idle_wide;
wire ar_wide    = (status[2:1] == 2'd1) ? 1'b0 :
                  (status[2:1] == 2'd2) ? 1'b1 : auto_wide;
// Analog Aspect (O[10:9], docs/analog.md V8): the 480i raster's fit of a 16:9 picture to a 4:3
// CRT, done by the reader (0 Fit, 1 Letterbox, 2 Crop; a 720x480 picture only). Auto =
// Letterbox for a 16:9 picture (the shown picture's VUI, unknown = 16:9 as above), Fit for
// 4:3; Auto never selects Crop. While Letterbox or Crop is in effect HDMI shows the same
// raster: VIDEO_ARX/ARY are 4:3, so ascal does not stretch the corrected picture back.
wire       pic_wide  = vui_sar_known ? vui_wide : 1'b1;
// P9: under a disc menu, Fit: the reader's Letterbox / Crop move the video and not the plane --
// the HOST fits a menu instead (menu_aa: 1 Letterbox, the scene drawn into 720 x 360 at line 60;
// 2 Crop, its centre 640 x 480 onto the raster -- the video through the window either way) at 480i
// unless Analog Aspect is Fit: a menu is 16:9, so Auto letterboxes it; an explicit Crop crops it
// (the maintainer, 2026-10-03; docs/analog.md S7)
assign     menu_aa   = !interlaced_eff ? 2'd0 : (status[10:9] == 2'd1) ? 2'd0 : (status[10:9] == 2'd3) ? 2'd2 : 2'd1;
assign     menu_aa_on = host_menu && (menu_aa != 2'd0);
assign     aa_mode   = (!interlaced_eff || host_menu) ? 2'd0 :
                       (status[10:9] == 2'd0) ? (pic_wide ? 2'd1 : 2'd0) :
                       (status[10:9] == 2'd2) ? 2'd1 :
                       (status[10:9] == 2'd3) ? 2'd2 : 2'd0;
assign     aa_live   = media_seen && sh_valid && (aa_mode != 2'd0) && sh_w == 8'd45 && sh_hf == 8'd30;
// fj#71 Zoom (Aspect Ratio's fourth value; docs/zoom.md): a 720x480 4:3 picture's middle 360 lines
// shown at 16:9 (4 * 480 : 3 * 360 = 16 : 9). Otherwise Zoom is Auto (ar_wide above). zoom_ctl says
// when; it never coincides with aa_live (480i only).
zoom_ctl zoom_ctl_inst (
	.clk        (clk_sys),
	.rst_n      (reset_n),
	.sel        (status[2:1] == 2'd3),
	.il         (interlaced_eff),
	.media_seen (media_seen),
	.stopped    (pc_idle),            // the wave / the disc screen over the held picture: never cropped
	.host_menu  (host_menu),          // NOT host_ui: the control panel raises it too
	.sh_valid   (sh_valid),
	.pic_wide   (pic_wide),
	.sh_w       (sh_w),
	.sh_hf      (sh_hf),
	.vbl        (h_pos == 12'd0 && v_pos == 12'd500),   // sub_overlay's strobe (480p; Zoom is off at 480i)
	.v_pos      (v_pos),
	.zoom       (zoom),
	.cut        (zoom_cut)
);
assign VIDEO_ARX = (aa_live | menu_aa_on) ? 13'd4 : (ar_wide | zoom) ? 13'd16 : 13'd4;
assign VIDEO_ARY = (aa_live | menu_aa_on) ? 13'd3 : (ar_wide | zoom) ? 13'd9  : 13'd3;

// =========================================================================
// The clk_dec heartbeat (umd/dec_stub.sv): kept beside the front end as the sign of
// life that does not depend on it -- LED_USER blinks whether or not a title streams
// =========================================================================
wire dec_alive;
dec_stub dec_stub_inst (
	.clk_dec   (clk_dec),
	.clk_sys   (clk_sys),
	.rst_n     (reset_n),
	.dec_alive (dec_alive)
);


// =========================================================================
// DDR3: ram1 = the DPB client (behind umd/ddr_mux2.sv), ram2 = the display reader
// (read-only). Both on clk_mem.
// =========================================================================
assign DDRAM_CLK  = clk_mem;
assign DDRAM2_CLK = clk_mem;

// =========================================================================
// Unused framework interfaces
// =========================================================================
assign SD_SCK  = 1'b0;
assign SD_MOSI = 1'b0;
assign SD_CS   = 1'b1;
assign UART_RTS = 1'b1;
assign UART_TXD = 1'b1;
assign UART_DTR = 1'b1;
assign USER_OUT = 7'h7F;
// ADC_BUS: left undriven (high-Z), as the Template does when the ADC is unused.

// =========================================================================
// LEDs
// =========================================================================
assign LED_POWER = 2'b00;                       // framework controls it
assign LED_DISK  = {rd_active, sd_ack};         // {enable, value}: lit while blocks arrive
assign LED_USER  = dec_alive;                   // ~4.8 Hz: the clk_dec domain is alive

endmodule
