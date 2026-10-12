// umd/png/png_pkg.sv -- the PNG decoder's verdict codes (docs/png_decode.md §4)
//
// err: 0 = the image is good; anything else is fatal and the image must not be shown
// (pixels already emitted are the consumer's to discard -- the decoder streams). Each
// DEFLATE code is one of zlib's messages, so a verdict can be checked against zlib
// case by case (tools/png_golden.py ZMSG; its E / W tables MUST equal these).
// warn: bits for what libpng treats as benign -- the image is shown.

package png_pkg;

    localparam logic [4:0]
        E_OK       = 5'd0,
        E_SIG      = 5'd1,   // not the PNG signature
        E_CRC      = 5'd2,   // a critical chunk's CRC-32 (IEND too: stricter than libpng)
        E_IHDR     = 5'd3,   // IHDR length / field / type-depth combination
        E_SIZE     = 5'd4,   // past our bound: row bytes > 8192 or a dimension > 65535
        E_CRITICAL = 5'd5,   // an unknown critical chunk, or a type byte that is not a letter
        E_ORDER    = 5'd6,   // chunk structure / order (length < 2^31, IHDR first and once, PLTE before IDAT, IDAT before IEND)
        E_PLTE     = 5'd7,   // PLTE length not 3n, 0 entries, > 256 entries, or twice
        E_TRUNC    = 5'd8,   // the input ended (in_last) before IEND
        E_ZCHECK   = 5'd9,   // "incorrect header check"
        E_ZMETHOD  = 5'd10,  // "unknown compression method"
        E_ZWINDOW  = 5'd11,  // "invalid window size"
        E_ZDICT    = 5'd12,  // "need dictionary" (PNG forbids a preset dictionary)
        E_BTYPE    = 5'd13,  // "invalid block type"
        E_STORED   = 5'd14,  // "invalid stored block lengths"
        E_NSYMS    = 5'd15,  // "too many length or distance symbols"
        E_CLSET    = 5'd16,  // "invalid code lengths set"
        E_REPEAT   = 5'd17,  // "invalid bit length repeat"
        E_NOEOB    = 5'd18,  // "invalid code -- missing end-of-block"
        E_LITSET   = 5'd19,  // "invalid literal/lengths set"
        E_DISTSET  = 5'd20,  // "invalid distances set"
        E_LITCODE  = 5'd21,  // "invalid literal/length code"
        E_DISTCODE = 5'd22,  // "invalid distance code"
        E_FAR      = 5'd23,  // "invalid distance too far back"
        E_ADLER    = 5'd24,  // "incorrect data check"
        E_ZSHORT   = 5'd25,  // the IDAT data ended inside the zlib stream
        E_FILTER   = 5'd26,  // a filter type > 4
        E_SHORT    = 5'd27;  // the zlib stream ended before the last row (libpng: benign)

    localparam int W_ANC_CRC    = 0;  // an ancillary chunk's CRC: the chunk is discarded
    localparam int W_ZEXTRA     = 1;  // bytes after the zlib stream inside IDAT
    localparam int W_LONG       = 2;  // inflated bytes past the last row
    localparam int W_AFTER_IEND = 3;  // bytes after IEND before in_last
    localparam int W_IGNORED    = 4;  // an ancillary chunk / PLTE in grey ignored as invalid
    localparam int W_INDEX      = 5;  // a palette index past PLTE (drawn opaque black)

    localparam logic [19:0] MAX_ROW_BYTES = 20'd8192;   // the previous-row buffer (docs/png_decode.md §3)

endpackage
