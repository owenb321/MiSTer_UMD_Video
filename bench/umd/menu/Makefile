# bench/umd/menu/Makefile -- the menu engine (main/support/umd/menu/) built for the PC (P9 M1).
# The engine's sources stay a straight overlay on stock Main; the PC build glue lives here.
SRC   := ../../../main/support/umd/menu
OUT   ?= ../../../.sim/menu
CFLAGS := -std=c99 -O2 -g -Wall -Wextra -Werror -I$(SRC)
LIBS  := -lz

ENGINE := $(SRC)/rco.c $(SRC)/vsmx.c $(SRC)/menu.c $(SRC)/vag.c
HDRS   := $(SRC)/rco.h $(SRC)/rco_attrs.h $(SRC)/vsmx.h $(SRC)/menu.h $(SRC)/vag.h

all: $(OUT)/menu_dump $(OUT)/menu_run $(OUT)/menu_tree $(OUT)/iso_dump $(OUT)/pl_dump $(OUT)/host_menu_check $(OUT)/menu_host_check $(OUT)/vag_dump $(OUT)/scale_check

$(OUT)/menu_dump: menu_dump.c $(SRC)/rco.c $(SRC)/rco.h $(SRC)/rco_attrs.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ menu_dump.c $(SRC)/rco.c $(LIBS)

$(OUT)/vag_dump: vag_dump.c $(SRC)/rco.c $(SRC)/rco.h $(SRC)/rco_attrs.h $(SRC)/vag.c $(SRC)/vag.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ vag_dump.c $(SRC)/rco.c $(SRC)/vag.c $(LIBS)

$(OUT)/menu_tree: menu_tree.c $(SRC)/rco.c $(SRC)/rco.h $(SRC)/rco_attrs.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ menu_tree.c $(SRC)/rco.c $(LIBS)

$(OUT)/iso_dump: iso_dump.c $(SRC)/umd_iso.c $(SRC)/umd_iso.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -D_FILE_OFFSET_BITS=64 -D_POSIX_C_SOURCE=200809L -o $@ iso_dump.c $(SRC)/umd_iso.c $(LIBS)

$(OUT)/pl_dump: pl_dump.c $(SRC)/umd_iso.c $(SRC)/umd_iso.h $(SRC)/umd_playlist.c $(SRC)/umd_playlist.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -D_FILE_OFFSET_BITS=64 -D_POSIX_C_SOURCE=200809L -o $@ pl_dump.c $(SRC)/umd_iso.c $(SRC)/umd_playlist.c $(LIBS)

# the Main's P9 host-row logic (main/support/umd/, beside umd_host_logic)
HSRC ?= $(SRC)/..
$(OUT)/host_menu_check: host_menu_check.c $(HSRC)/umd_menu_logic.c $(HSRC)/umd_menu_logic.h $(HSRC)/umd_host_proto.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -I$(HSRC) -o $@ host_menu_check.c $(HSRC)/umd_menu_logic.c

# the integration: the engine, the menu host, the logic, the image reader, against a core model
$(OUT)/menu_host_check: menu_host_check.c img_decode.c img_decode.h $(ENGINE) $(HDRS) $(SRC)/umd_iso.c $(SRC)/umd_playlist.c $(HSRC)/umd_menu_host.c $(HSRC)/umd_menu_host.h $(HSRC)/umd_menu_logic.c $(HSRC)/umd_menu_logic.h $(HSRC)/umd_menu_run.c $(HSRC)/umd_menu_run.h $(HSRC)/umd_panel.c $(HSRC)/umd_panel.h $(HSRC)/umd_panel_art.c $(HSRC)/umd_disc_screen.c $(HSRC)/umd_disc_screen.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -D_FILE_OFFSET_BITS=64 -D_POSIX_C_SOURCE=200809L -I$(HSRC) -o $@ menu_host_check.c img_decode.c $(ENGINE) $(SRC)/umd_iso.c $(SRC)/umd_playlist.c $(HSRC)/umd_menu_host.c $(HSRC)/umd_menu_logic.c $(HSRC)/umd_menu_run.c $(HSRC)/umd_panel.c $(HSRC)/umd_panel_art.c $(HSRC)/umd_disc_screen.c -lpng -ljpeg $(LIBS) -lm

# M4h: the canvas's stretch (menu.c menu_scale) against its definition
$(OUT)/scale_check: scale_check.c $(ENGINE) $(HDRS)
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ scale_check.c $(ENGINE) $(LIBS) -lm

$(OUT)/menu_run: menu_run.c img_decode.c img_decode.h $(ENGINE) $(HDRS)
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ menu_run.c img_decode.c $(ENGINE) -lpng -ljpeg $(LIBS) -lm

clean:
	rm -rf $(OUT)
.PHONY: all clean
