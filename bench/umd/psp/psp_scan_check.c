// psp_scan_check.c -- the PSP disc scanner's decisions (main/support/umd/umd_psp_logic.c) on
// scripted scan sequences. Each arm's expected actions are the rules of docs/psp_disc.md §3 applied
// to what the PSP was MEASURED to do (§2): leaving USB mode removes the file, entering it
// re-enumerates (new device / inode, maybe another usbN), a swap inside USB mode changes only the
// PVD's sectors (same inode, the previous disc's size). Not derived from the logic's code.
// Prints "FAIL [arm] ..." per miss and "PASS psp_scan_check" only when every arm held.
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "umd_psp_logic.h"

static int fails = 0, checks = 0;
static const char *arm = "";

static umd_psp_state S;
static umd_psp_view V;
static umd_psp_act A;

// discs: a PVD hash and the volume bytes; the file's size is the FAT's, built at USB start
#define NT_FP   0x11111111u
#define NT_SZ   1573552128ull
#define KR_FP   0x22222222u
#define KR_SZ   1617428480ull
#define GM_FP   0x33333333u
#define GM_SZ   1000000000ull

static void fresh(void) { umd_psp_init(&S); memset(&V, 0, sizeof(V)); }

// one scan. kind / fp / vol describe the disc in the drive NOW; size is the file's (stale after a swap)
static void scan(int present, int usb, uint64_t ino, uint64_t size, int kind, uint32_t fp, uint64_t vol)
{
	V.seq++;
	V.present = present; V.usb = usb; V.dev = 0x800 + usb; V.ino = ino; V.size = size;
	V.kind = kind; V.fp = fp; V.vol_bytes = vol;
	umd_psp_step(&S, &V, &A);
}

static void expect(int unmount, int mount, int usb, int msg, const char *what)
{
	checks++;
	if (A.unmount != unmount || A.mount != mount || (mount && A.usb != usb) || A.msg != msg) {
		fails++;
		printf("FAIL [%s] %s: got unmount %d mount %d usb %d msg %d, want %d %d %d %d\n",
		       arm, what, A.unmount, A.mount, A.usb, A.msg, unmount, mount, usb, msg);
	}
}
static void none(const char *what) { expect(0, 0, 0, 0, what); }
#define V_  UMD_PSP_K_VIDEO
#define G_  UMD_PSP_K_GAME
#define U_  UMD_PSP_K_UNREAD
#define E_  UMD_PSP_K_ERR
#define O_  UMD_PSP_K_OTHER

int main(void)
{
	// [appear] the PSP enters USB mode with a video disc: mounted once its PVD is read
	arm = "appear";
	fresh();
	scan(1, 0, 100, NT_SZ, U_, 0, 0);            none("present, PVD not read yet");
	scan(1, 0, 100, NT_SZ, E_, 0, 0);            none("the PVD read failed");
	scan(1, 0, 100, NT_SZ, V_, NT_FP, NT_SZ);    expect(0, 1, 0, 0, "the video disc read");
	scan(1, 0, 100, NT_SZ, V_, NT_FP, NT_SZ);    none("the same disc, scanned again");
	fresh();
	scan(1, 3, 100, NT_SZ, V_, NT_FP, NT_SZ);    expect(0, 1, 3, 0, "found on usb3");
	fresh();
	scan(1, 0, 100, NT_SZ, O_, 0x44444444u, NT_SZ); expect(0, 1, 0, 0, "another system id: mounted, the core judges");

	// [vanish] USB mode left / unplugged: our disc unmounted at once; nothing else touched
	arm = "vanish";
	fresh();
	scan(1, 0, 100, NT_SZ, V_, NT_FP, NT_SZ);    expect(0, 1, 0, 0, "mounted");
	scan(0, 0, 0, 0, U_, 0, 0);                  expect(1, 0, 0, 0, "the file is gone");
	scan(0, 0, 0, 0, U_, 0, 0);                  none("still gone");
	scan(1, 0, 101, NT_SZ, V_, NT_FP, NT_SZ);    expect(0, 1, 0, 0, "USB mode entered again: the same disc mounted again");
	fresh();
	umd_psp_mounted(&S, 1, 0, 0);                 // a library ISO
	scan(0, 0, 0, 0, U_, 0, 0);                  none("no PSP, a library ISO: untouched");

	// [reenum] USB mode re-entered between two scans: another inode / usbN, the old fd is dead
	arm = "reenum";
	fresh();
	scan(1, 0, 100, NT_SZ, V_, NT_FP, NT_SZ);    expect(0, 1, 0, 0, "mounted on usb0");
	scan(1, 1, 200, NT_SZ, V_, NT_FP, NT_SZ);    expect(1, 1, 1, 0, "back as usb1: unmounted, mounted at the new path");
	scan(1, 1, 300, KR_SZ, U_, 0, 0);            expect(1, 0, 0, 0, "a new inode, PVD unread: the old fd unmounted now");
	scan(1, 1, 300, KR_SZ, V_, KR_FP, KR_SZ);    expect(0, 1, 1, 0, "then mounted once read");

	// [swap] the disc changed inside USB mode: same inode, the FAT's old size, a new PVD
	arm = "swap";
	fresh();
	scan(1, 0, 100, KR_SZ, V_, KR_FP, KR_SZ);    expect(0, 1, 0, 0, "Kranks mounted");
	scan(1, 0, 100, KR_SZ, E_, 0, 0);            none("the drive busy across the swap");
	scan(1, 0, 100, KR_SZ, V_, NT_FP, NT_SZ);    expect(1, 0, 0, UMD_PSP_MSG_REENTER, "National Treasure (smaller): unmounted, told to re-enter all the same");
	scan(1, 0, 100, KR_SZ, V_, NT_FP, NT_SZ);    none("told once, not mounted");
	scan(1, 0, 100, KR_SZ, V_, KR_FP, KR_SZ);    expect(0, 0, 0, UMD_PSP_MSG_REENTER, "swapped back to Kranks: still a stale FAT, told for this disc");
	scan(1, 0, 101, KR_SZ, V_, KR_FP, KR_SZ);    expect(0, 1, 0, 0, "USB mode re-entered between scans (a new inode): mounted");
	fresh();
	scan(1, 0, 100, NT_SZ, V_, NT_FP, NT_SZ);    expect(0, 1, 0, 0, "National Treasure mounted");
	scan(1, 0, 100, NT_SZ, V_, KR_FP, KR_SZ);    expect(1, 0, 0, UMD_PSP_MSG_REENTER, "Kranks (bigger than the file): unmounted, told to re-enter");
	scan(1, 0, 100, NT_SZ, V_, KR_FP, KR_SZ);    none("told once");
	scan(0, 0, 0, 0, U_, 0, 0);                  none("USB mode left");
	scan(1, 0, 101, KR_SZ, V_, KR_FP, KR_SZ);    expect(0, 1, 0, 0, "entered again: its own FAT, mounted");
	fresh();
	scan(1, 0, 100, KR_SZ, V_, KR_FP, KR_SZ);    expect(0, 1, 0, 0, "fresh FAT: mounted");

	// [first] a Main started after a swap it never saw: the file far from the PVD's size is stale
	arm = "first";
	fresh();
	scan(1, 0, 100, NT_SZ, U_, 0, 0);            none("unread");
	scan(1, 0, 100, NT_SZ, V_, KR_FP, KR_SZ);    expect(0, 0, 0, UMD_PSP_MSG_REENTER, "Kranks under National Treasure's FAT: told to re-enter");
	scan(1, 0, 101, KR_SZ, V_, KR_FP, KR_SZ);    expect(0, 1, 0, 0, "re-entered: mounted");
	fresh();
	scan(1, 0, 100, KR_SZ, V_, NT_FP, NT_SZ);    expect(0, 0, 0, UMD_PSP_MSG_REENTER, "a smaller disc under a bigger FAT: the same rule");
	fresh();
	scan(1, 0, 100, NT_SZ - 2048, V_, NT_FP, NT_SZ); expect(0, 1, 0, 0, "a FAT one sector short of the PVD (4 library dumps): mounted");
	fresh();
	scan(1, 0, 100, NT_SZ, V_, NT_FP, NT_SZ);    expect(0, 1, 0, 0, "mounted");
	scan(1, 0, 101, NT_SZ - 4096000, V_, NT_FP, NT_SZ); expect(1, 1, 0, 0, "re-enumerated, a short FAT: only the first view is judged by size");

	// [game] a game disc: never mounted, one message per disc
	arm = "game";
	fresh();
	scan(1, 0, 100, GM_SZ, G_, GM_FP, GM_SZ);    expect(0, 0, 0, UMD_PSP_MSG_GAME, "a game disc");
	scan(1, 0, 100, GM_SZ, G_, GM_FP, GM_SZ);    none("told once");
	scan(0, 0, 0, 0, U_, 0, 0);                  none("USB mode left");
	scan(1, 0, 101, GM_SZ, G_, GM_FP, GM_SZ);    expect(0, 0, 0, UMD_PSP_MSG_GAME, "entered again: told again");
	fresh();
	scan(1, 0, 100, NT_SZ, V_, NT_FP, NT_SZ);    expect(0, 1, 0, 0, "a video disc mounted");
	scan(1, 0, 100, NT_SZ, G_, GM_FP, GM_SZ);    expect(1, 0, 0, UMD_PSP_MSG_GAME, "swapped to a game: unmounted, told");

	// [foreign] the user's own image is never pre-empted -- until a deliberate act on the PSP
	arm = "foreign";
	fresh();
	umd_psp_mounted(&S, 1, 0, 0);                 // an MGL loaded a library ISO, the PSP already attached
	scan(1, 0, 100, NT_SZ, V_, NT_FP, NT_SZ);    none("the first view is no edge: the library ISO kept");
	scan(0, 0, 0, 0, U_, 0, 0);                  none("USB mode left");
	scan(1, 0, 101, NT_SZ, V_, NT_FP, NT_SZ);    expect(0, 1, 0, 0, "entered again: an edge, it wins");
	fresh();
	scan(1, 0, 100, KR_SZ, U_, 0, 0);            none("present, unread");
	umd_psp_mounted(&S, 1, 0, 0);                 // the user picks a library ISO meanwhile
	scan(1, 0, 100, KR_SZ, V_, KR_FP, KR_SZ);    none("read now: the library ISO kept");
	scan(1, 0, 100, KR_SZ, V_, KR_FP, KR_SZ);    none("still kept");
	scan(1, 0, 100, KR_SZ, V_, NT_FP, NT_SZ);    expect(0, 0, 0, UMD_PSP_MSG_REENTER, "a disc swapped on the PSP: told to re-enter, the library ISO kept");
	scan(1, 0, 101, NT_SZ, V_, NT_FP, NT_SZ);    expect(0, 1, 0, 0, "re-entered: an edge, it wins");
	fresh();
	scan(1, 0, 100, NT_SZ, V_, NT_FP, NT_SZ);    expect(0, 1, 0, 0, "mounted");
	umd_psp_mounted(&S, 1, 0, 0);                 // the user picks a library ISO over it
	scan(0, 0, 0, 0, U_, 0, 0);                  none("the PSP leaves USB mode: the library ISO untouched");

	// [suppress] the user unmounted the PSP's disc from the OSD: not mounted again until an edge
	arm = "suppress";
	fresh();
	scan(1, 0, 100, NT_SZ, V_, NT_FP, NT_SZ);    expect(0, 1, 0, 0, "mounted");
	umd_psp_mounted(&S, 0, 0, 1);                 // the OSD's unmount
	scan(1, 0, 100, NT_SZ, V_, NT_FP, NT_SZ);    none("not mounted again");
	scan(1, 0, 100, NT_SZ, V_, NT_FP, NT_SZ);    none("still not");
	scan(0, 0, 0, 0, U_, 0, 0);                  none("USB mode left");
	scan(1, 0, 101, NT_SZ, V_, NT_FP, NT_SZ);    expect(0, 1, 0, 0, "entered again: mounted");
	fresh();
	umd_psp_mounted(&S, 1, 0, 0);                 // a library ISO
	scan(1, 0, 100, NT_SZ, V_, NT_FP, NT_SZ);    none("the library ISO kept");
	umd_psp_mounted(&S, 0, 0, 1);                 // the user unmounts it
	scan(1, 0, 100, NT_SZ, V_, NT_FP, NT_SZ);    none("the slot the user emptied stays empty");
	scan(1, 0, 101, NT_SZ, V_, NT_FP, NT_SZ);    expect(0, 1, 0, 0, "USB mode re-entered: mounted");

	// [adopt] an MGL's / the OSD's mount of the PSP's file is watched like ours
	arm = "adopt";
	fresh();
	umd_psp_mounted(&S, 1, 1, 0);                 // the stock MGL, before any scan
	scan(1, 0, 100, NT_SZ, V_, NT_FP, NT_SZ);    none("the MGL's mount adopted: no second mount");
	scan(1, 0, 100, NT_SZ, V_, KR_FP, NT_SZ);    expect(1, 0, 0, UMD_PSP_MSG_REENTER, "a disc swapped in: unmounted, told to re-enter");
	fresh();
	umd_psp_mounted(&S, 1, 1, 0);
	scan(1, 0, 100, NT_SZ, V_, NT_FP, NT_SZ);    none("adopted");
	scan(0, 0, 0, 0, U_, 0, 0);                  expect(1, 0, 0, 0, "USB mode left: unmounted");
	fresh();
	scan(1, 0, 100, NT_SZ, V_, NT_FP, NT_SZ);    expect(0, 1, 0, 0, "mounted");
	umd_psp_mounted(&S, 1, 1, 0);                 // the OSD picks the same file again
	scan(1, 0, 100, NT_SZ, V_, NT_FP, NT_SZ);    none("the same disc: nothing");
	fresh();
	umd_psp_mounted(&S, 1, 1, 0);                 // an MGL of the PSP's path, a game disc in it
	scan(1, 0, 100, GM_SZ, G_, GM_FP, GM_SZ);    expect(1, 0, 0, UMD_PSP_MSG_GAME, "an adopted game disc: unmounted, told");
	fresh();
	umd_psp_mounted(&S, 1, 1, 0);                 // an MGL of the PSP's path after a swap Main never saw
	scan(1, 0, 100, NT_SZ, V_, KR_FP, KR_SZ);    expect(1, 0, 0, UMD_PSP_MSG_REENTER, "adopted on a stale FAT: unmounted, told");

	// [failed] our mount did not open: not retried every scan; an edge retries
	arm = "failed";
	fresh();
	scan(1, 0, 100, NT_SZ, V_, NT_FP, NT_SZ);    expect(0, 1, 0, 0, "mounted");
	umd_psp_self_failed(&S);
	scan(1, 0, 100, NT_SZ, V_, NT_FP, NT_SZ);    none("not retried");
	scan(1, 2, 200, NT_SZ, V_, NT_FP, NT_SZ);    expect(0, 1, 2, 0, "re-enumerated: retried");

	// [path] which mounted paths are the PSP's file
	arm = "path";
	{
		static const struct { const char *p; int want; } T[] = {
			{ "/media/usb0/UMD9660.ISO", 0 }, { "/media/usb7/umd9660.iso", 7 },
			{ "/media/usb3/Umd9660.Iso", 3 }, { "/media/usb8/UMD9660.ISO", -1 },
			{ "/media/usb0/games/UMD9660.ISO", -1 }, { "/media/fat/games/UMD/UMD9660.ISO", -1 },
			{ "/media/usb0/UMD9660.ISO.bak", -1 }, { "/media/usb0/Akira.iso", -1 },
			{ "/media/usb10/UMD9660.ISO", -1 }, { "", -1 }, { NULL, -1 },
		};
		for (unsigned i = 0; i < sizeof(T) / sizeof(T[0]); i++) {
			checks++;
			int got = umd_psp_path_usb(T[i].p);
			if (got != T[i].want) { fails++; printf("FAIL [path] %s: %d, want %d\n", T[i].p ? T[i].p : "(null)", got, T[i].want); }
		}
	}

	printf("psp_scan_check: %d checks, %d failed\n", checks, fails);
	if (fails) return 1;
	printf("PASS psp_scan_check\n");
	return 0;
}
