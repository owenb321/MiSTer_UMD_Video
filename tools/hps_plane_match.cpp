// hps_plane_match.cpp -- B2's readback (docs/hps_host.md §6 "B2, the procedure", step 4):
// a subtitle plane the FABRIC wrote (sub_plane_wr.sv, until B3 removed it), dumped on the rig by the probe
// ("b2 dump", main/support/umd/umd_b2.cpp), against the plane B1's HPS decoder
// (main/support/umd/umd_sub.cpp) writes for the same unit. It proves the address map
// (core word W = HPS byte W * 8) and the byte order of hps_host.md §1 / §3.3 on silicon.
//
//   hps_plane_match LIST DUMP...        LIST: "path ux uy name" a line (hps_sub_check's format)
//   hps_plane_match --selftest LIST     the matcher's own RED: it must find a unit placed
//                                       into a blank dump under each transform, and only there
//
// For each unit of LIST: decode it with umd_sub into a zeroed plane, take its rectangle
// (clipped to 720 x 480), and compare it with each dump word for word under four readings
// of the dump: as is; the two pixels of each 64-bit word swapped; each 32-bit word
// byte-swapped; both. The plane is never cleared, so only the rectangle is compared, and an
// earlier unit's rectangle can match in part: every unit is scored and the best are listed.
//
// PASS: some unit's rectangle, with at least 64 non-transparent pixels, equals a dump word
// for word AS IS. A full match under another reading names the error outright.

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vector>
#include <string>
#include <algorithm>

#include "umd_sub.h"

#define W UMD_PLANE_W
#define H UMD_PLANE_H
#define NPIX (W * H)
#define MIN_NZ 64

static const char *xf_name[4] = {"as-is", "pair-swap", "byte-swap", "pair+byte"};

static uint32_t bswap(uint32_t v) { return __builtin_bswap32(v); }

// the dump's pixel (x, y) under reading k
static uint32_t rd(const uint32_t *d, int k, uint32_t x, uint32_t y)
{
	uint32_t v = d[y * W + ((k & 1) ? (x ^ 1) : x)];
	return (k & 2) ? bswap(v) : v;
}

static std::vector<uint8_t> load(const char *path)
{
	std::vector<uint8_t> b;
	FILE *f = fopen(path, "rb");
	if (!f) return b;
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	b.resize(n > 0 ? n : 0);
	if (n > 0 && fread(b.data(), 1, n, f) != (size_t)n) b.clear();
	fclose(f);
	return b;
}

struct unit_t { std::string path, name; uint32_t ux, uy; };

struct decoded_t {
	unit_t u;
	uint32_t x0, y0, x1, y1;    // the visible rectangle, [x0, x1) x [y0, y1)
	uint32_t nz;                // non-transparent pixels in it
	std::vector<uint32_t> plane;
};

static bool decode(const unit_t &u, decoded_t &o)
{
	std::vector<uint8_t> png = load(u.path.c_str());
	if (png.empty()) { fprintf(stderr, "cannot read %s\n", u.path.c_str()); return false; }
	o.u = u;
	o.plane.assign(NPIX, 0);
	umd_sub_result r;
	if (umd_sub_decode(png.data(), png.size(), u.ux, u.uy, o.plane.data(), &r, NULL, NULL))
		return false;
	o.x0 = std::min(u.ux, (uint32_t)W);
	o.y0 = std::min(u.uy, (uint32_t)H);
	o.x1 = std::min((uint64_t)u.ux + r.w, (uint64_t)W);
	o.y1 = std::min((uint64_t)u.uy + r.h, (uint64_t)H);
	o.nz = 0;
	for (uint32_t y = o.y0; y < o.y1; y++)
		for (uint32_t x = o.x0; x < o.x1; x++)
			o.nz += o.plane[y * W + x] != 0;
	return true;
}

// -> words of the rectangle that match under reading k; nzm: of those, the non-transparent
static uint32_t score(const decoded_t &u, const uint32_t *d, int k, uint32_t *nzm)
{
	uint32_t m = 0;
	*nzm = 0;
	for (uint32_t y = u.y0; y < u.y1; y++)
		for (uint32_t x = u.x0; x < u.x1; x++)
		{
			uint32_t v = u.plane[y * W + x];
			if (rd(d, k, x, y) == v) { m++; *nzm += v != 0; }
		}
	return m;
}

static std::vector<unit_t> read_list(const char *path)
{
	std::vector<unit_t> v;
	FILE *f = fopen(path, "r");
	if (!f) { fprintf(stderr, "cannot read %s\n", path); exit(2); }
	char p[1024], n[256];
	unsigned x, y;
	while (fscanf(f, "%1023s %u %u %255s", p, &x, &y, n) == 4) v.push_back({p, n, x, y});
	fclose(f);
	return v;
}

struct best_t { size_t ui; int k; uint32_t m, nzm; double frac; };

// -> the full matches, every reading; prints the best units of one dump
static int match_dump(const char *dname, const uint32_t *d, const std::vector<decoded_t> &us,
                      int *full_asis, int quiet)
{
	std::vector<best_t> all;
	int full[4] = {0, 0, 0, 0};
	for (size_t i = 0; i < us.size(); i++)
	{
		const decoded_t &u = us[i];
		if (u.nz < MIN_NZ) continue;
		uint32_t area = (u.x1 - u.x0) * (u.y1 - u.y0);
		for (int k = 0; k < 4; k++)
		{
			uint32_t nzm, m = score(u, d, k, &nzm);
			if (m == area) full[k]++;
			all.push_back({i, k, m, nzm, (double)nzm / u.nz});
		}
	}
	std::sort(all.begin(), all.end(), [](const best_t &a, const best_t &b) {
		return a.frac != b.frac ? a.frac > b.frac : a.k < b.k;
	});
	if (!quiet)
	{
		printf("%s: full matches as-is %d, pair-swap %d, byte-swap %d, pair+byte %d\n",
		       dname, full[0], full[1], full[2], full[3]);
		for (size_t j = 0; j < all.size() && j < 5; j++)
		{
			const best_t &b = all[j];
			const decoded_t &u = us[b.ui];
			printf("  %-28s %-9s at %u,%u %ux%u: %u of %u non-transparent pixels (%.1f %%)%s\n",
			       u.u.name.c_str(), xf_name[b.k], u.u.ux, u.u.uy, u.x1 - u.x0, u.y1 - u.y0,
			       b.nzm, u.nz, 100.0 * b.frac,
			       b.m == (u.x1 - u.x0) * (u.y1 - u.y0) ? "  FULL" : "");
		}
	}
	*full_asis = full[0];
	return full[0] + full[1] + full[2] + full[3];
}

static int selftest(const std::vector<decoded_t> &us)
{
	// the first unit with enough pixels, placed into a blank dump under each reading
	size_t pick = us.size();
	for (size_t i = 0; i < us.size(); i++)
		if (us[i].nz >= MIN_NZ) { pick = i; break; }
	if (pick == us.size()) { printf("FAIL selftest: no unit with %d pixels\n", MIN_NZ); return 1; }
	const decoded_t &u = us[pick];
	int bad = 0;
	for (int k = 0; k < 4; k++)
	{
		std::vector<uint32_t> d(NPIX, 0);
		for (uint32_t y = u.y0; y < u.y1; y++)
			for (uint32_t x = u.x0; x < u.x1; x++)
			{
				// the inverse of rd(): store so that reading k gives the plane back
				uint32_t v = u.plane[y * W + x];
				d[y * W + ((k & 1) ? (x ^ 1) : x)] = (k & 2) ? bswap(v) : v;
			}
		int asis, any = match_dump("selftest", d.data(), us, &asis, 1);
		// the unit itself must match under k, and as-is only when k is as-is
		uint32_t nzm, m = score(u, d.data(), k, &nzm);
		bool self = m == (u.x1 - u.x0) * (u.y1 - u.y0);
		bool asis_ok = (k == 0) ? asis > 0 : asis == 0;
		printf("  selftest %-9s: unit %s found %s, as-is matches %d (want %s), any %d\n",
		       xf_name[k], u.u.name.c_str(), self ? "yes" : "NO", asis, k ? "0" : ">0", any);
		bad += !self || !asis_ok;
	}
	if (bad) { printf("FAIL selftest\n"); return 1; }
	printf("PASS selftest\n");
	return 0;
}

int main(int argc, char **argv)
{
	bool st = argc == 3 && !strcmp(argv[1], "--selftest");
	if (argc < 3 || (argv[1][0] == '-' && !st))
	{
		fprintf(stderr, "usage: hps_plane_match LIST DUMP... | --selftest LIST\n");
		return 2;
	}
	std::vector<unit_t> list = read_list(argv[st ? 2 : 1]);
	std::vector<decoded_t> us;
	for (const unit_t &u : list)
	{
		decoded_t o;
		if (decode(u, o)) us.push_back(std::move(o));
	}
	printf("hps_plane_match: %zu units, %zu decoded\n", list.size(), us.size());
	if (st) return selftest(us);

	int pass = 0;
	for (int a = 2; a < argc; a++)
	{
		std::vector<uint8_t> b = load(argv[a]);
		if (b.size() < (size_t)NPIX * 4) { printf("FAIL %s: %zu bytes, want %d\n", argv[a], b.size(), NPIX * 4); return 1; }
		std::vector<uint32_t> d(NPIX);
		memcpy(d.data(), b.data(), (size_t)NPIX * 4);    // the dump is the A9's little-endian words
		int asis;
		match_dump(argv[a], d.data(), us, &asis, 0);
		pass += asis > 0;
	}
	if (pass) { printf("PASS hps_plane_match\n"); return 0; }
	printf("FAIL hps_plane_match: no unit matched a dump word for word as is\n");
	return 1;
}
