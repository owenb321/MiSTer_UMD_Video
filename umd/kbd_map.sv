// ============================================================================
// umd/kbd_map.sv -- keyboard / TV-remote transport control (P6b3; docs/transport.md S4)
// ============================================================================
// HARVESTED from MiSTer_DVD dvd/kbd_map.sv (docs/harvest.md): the decode structure, the
// press-edge-only rule and the key choices' reasons are its; the bindings are UMD's.
//
// Decodes the framework's ps2_key stream into a VIRTUAL JOYSTICK VECTOR with the bit
// layout of hps_io's joystick_0[24:0] (D-pad = [3:0], the J1 CONF_STR buttons from [4]),
// which emu ORs into the buttons' press edges. tools/mister.py parses the decode table
// below (the `if (ps2_key[8]) begin ... end else begin ... end` shape and the
// `8'hXX: hit[N]` lines) to name the keys the harness can press: keep that shape.
//
// WHY, when MiSTer already maps keys to buttons (MiSTer_DVD issue #35): Main's "Define
// buttons" refuses to bind Enter or Esc for a keyboard, and HDMI-CEC remote presses reach
// the core ONLY as keyboard events (Main never runs them through the joystick mapping).
// Reading the scancode here bypasses Main's mapper; the choices follow CEC's fixed table
// first, then DVD-remote / VLC convention.
//
// EVERY OUTPUT BIT IS A ONE-CYCLE PULSE ON THE PRESS. Break events are ignored and no level
// is held, so a lost release is a non-event and a stuck key is impossible. Tap-repeating IR
// remotes send ~9 taps a second for a hold: nothing here may be a hold path (FF / REW,
// P6b4, count presses: docs/transport.md S4).
//
// P6b6 (docs/transport.md D10 and "The keyboard carries every action too"): EVERY action has
// a default key, so a FLIRC (it learns any IR remote in its firmware and types keys), a 2.4 GHz
// media remote, a dock's receiver or a keyboard reaches all of it with nothing configured.
// The bits are the J1 list's (B1 = bit 4: Play/Pause, Pause, Stop, Prev Chapter, Next Chapter,
// Audio, Display, UMD Menu, Subtitle, Go To, Control Panel), then bit 15, A-B Repeat, keyboard-only
// (the panel's item reaches it too; docs/ab_repeat.md: it was the dropped Frame Step's, on `.`).
// MiSTer_DVD's keys are kept wherever the action is the same; every code is below 256 and in
// Main's PS/2 table (Main never passes a keycode of 256 or more to a core). P6b6 extends the table with the
// PSP's full map (Audio, Display, the panel) when CONF_STR grows, in one change.
//
// NEVER BIND (all verified against Main by MiSTer_DVD): F12 (07) and KEY_MENU (the OSD
// toggle), KEY_PAUSE (E1: no break code), NumLock / ScrollLock (Main's keyboard-emulation
// toggles), Alt / Meta. The arrow and page keys differ from numpad digits ONLY by the E0
// prefix, which is why ps2_key[8] is part of the decode key.
// ============================================================================

`default_nettype none

module kbd_map (
    input  wire        clk,        // clk_sys
    input  wire        rst_n,

    // hps_io "ps2 alternative interface": {toggle, pressed, extended, code}.
    // Bit 10 flips on every new key event; bit 9 is make/break; bit 8 is E0.
    input  wire [10:0] ps2_key,

    // One-cycle pulse per PRESS, in joystick_0[24:0] bit order.
    output reg  [24:0] joy
);

    // ---- scancode -> bit (combinational); several keys may share a bit --------------
    reg [24:0] hit;
    always @(*) begin
        hit = 25'd0;
        if (ps2_key[8]) begin
            // ---- E0-extended ----
            case (ps2_key[7:0])
            8'h75: hit[3]  = 1'b1;   // Up          -> D-pad Up      (CEC; Go To's value, slow motion)
            8'h72: hit[2]  = 1'b1;   // Down        -> D-pad Down    (CEC)
            8'h6B: hit[1]  = 1'b1;   // Left        -> D-pad Left    (CEC; REW)
            8'h74: hit[0]  = 1'b1;   // Right       -> D-pad Right   (CEC; FF, frame advance paused)
            8'h7D: hit[7]  = 1'b1;   // Page Up     -> B4  Prev Chapter (CEC)
            8'h7A: hit[8]  = 1'b1;   // Page Down   -> B5  Next Chapter (CEC)
            8'h5A: hit[5]  = 1'b1;   // KP-Enter    -> B2  Select
            default: ;
            endcase
        end else begin
            // ---- plain set-2 ----
            case (ps2_key[7:0])
            8'h29: hit[4]  = 1'b1;   // Space       -> B1  Play/Pause (CEC Play/Pause)
            8'h5A: hit[5]  = 1'b1;   // Enter       -> B2  Select, Go To's confirm (CEC OK)
            8'h15: hit[6]  = 1'b1;   // Q           -> B3  Stop
            8'h76: hit[6]  = 1'b1;   // Esc         -> B3  Stop      (CEC Stop, the dock's Exit)
            8'h4D: hit[7]  = 1'b1;   // P           -> B4  Prev Chapter
            8'h31: hit[8]  = 1'b1;   // N           -> B5  Next Chapter
            8'h1C: hit[9]  = 1'b1;   // A           -> B6  Audio
            8'h04: hit[9]  = 1'b1;   // F3          -> B6  Audio     (CEC Green)
            8'h23: hit[10] = 1'b1;   // D           -> B7  Display
            8'h3A: hit[11] = 1'b1;   // M           -> B8  UMD Menu  (P9)
            8'h05: hit[11] = 1'b1;   // F1          -> B8  UMD Menu  (CEC Blue)
            8'h1B: hit[12] = 1'b1;   // S           -> B9  Subtitle  (P7)
            8'h0C: hit[12] = 1'b1;   // F4          -> B9  Subtitle  (CEC Yellow)
            8'h34: hit[13] = 1'b1;   // G           -> B10 Go To     (P6c)
            8'h06: hit[13] = 1'b1;   // F2          -> B10 Go To     (CEC Red)
            8'h4B: hit[14] = 1'b1;   // L           -> B11 Control Panel (P6d; Repeat's key until then)
            8'h2B: hit[0]  = 1'b1;   // F           -> D-pad Right   (FF)
            8'h0D: hit[0]  = 1'b1;   // Tab         -> D-pad Right   (CEC Fast Forward)
            8'h2D: hit[1]  = 1'b1;   // R           -> D-pad Left    (REW)
            8'h66: hit[1]  = 1'b1;   // Backspace   -> D-pad Left    (CEC Rewind)
            8'h32: hit[15] = 1'b1;   // B           -> A-B Repeat    (keyboard / panel only, no J1 button)
            default: ;
            endcase
        end
    end

    // ---- the event's edge -> a one-cycle pulse -----------------------------------------
    // Registered, not combinational off ps2_key: that word stays put for thousands of
    // cycles between events, so a combinational "pulse" would be a level.
    reg ps2_tgl_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            joy       <= 25'd0;
            ps2_tgl_q <= 1'b0;
        end else begin
            joy       <= 25'd0;
            ps2_tgl_q <= ps2_key[10];
            // a new key event (the toggle flipped), PRESSED (break events ignored)
            if ((ps2_key[10] ^ ps2_tgl_q) && ps2_key[9]) joy <= hit;
        end
    end

endmodule

`default_nettype wire
