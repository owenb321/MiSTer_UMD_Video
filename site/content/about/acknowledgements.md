# Acknowledgements

- **MiSTer_DVD**, the sibling project this core's framework, build gates, process and
  much of its plumbing come from.
- **The MiSTer-devel framework** and its documentation, and **Main_MiSTer**, the MiSTer's
  Main program, which the UMD Main is built from (GPL-3.0-or-later).
- **libpng**, which decodes the disc menus' images in the UMD Main, and against which the core's
  own subtitle decoder is checked; it is the copy already on every
  MiSTer.
- **ffmpeg**, whose H.264 and ATRAC3plus decoders are the reference oracles the fabric
  decoders are checked against. The decoders are used to verify, never copied.
- **Maxim Poliakovski**, whose reverse-engineered ATRAC3plus decoder in ffmpeg is the only
  description of the format. Its tables (the Huffman codebooks, quantiser steps, noise
  table and filter bank) are carried in this core, with credit, under the GPL.
- **The JM reference decoder** (ITU-T H.264 reference software) for syntax-element traces.
- **The ITU-T H.264.1 conformance bitstreams**, which test the decoder on everything the
  specification allows, not only what UMD discs happen to use.
- **The PSP homebrew community**, whose reverse engineering of the PSMF, CLPI and RCO
  formats is the only documentation of them.
- **ARK-5** (PSP-Arkfive) and the **PRO CFW** team, whose custom firmware shares a PSP's UMD
  over USB: the only way a real UMD reaches a MiSTer ([Playing a real UMD](../getting-started/psp-disc.md)).
- Agostini et al., *Design and FPGA Prototyping of a H.264/AVC Main Profile Decoder for
  HDTV* (2007), and Petrovsky et al., *Pipeline processing in real-time of CABAC decoder
  based on FPGA* (ICSES 2012), for the architectures this core's decoder is sized against.
