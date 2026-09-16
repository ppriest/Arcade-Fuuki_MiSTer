// ymfm reference for sim/opl4_replay_tb: the same MAME OPL4 writes, the
// same pacing, the same window. ymfm is MAME's YMF278B engine and the source
// the OPL4 RTL was translated from, so its output is what the RTL must match.
//
// Build: fetch ymfm.h, ymfm_opl.{h,cpp}, ymfm_pcm.{h,cpp}, ymfm_adpcm.{h,cpp},
// ymfm_fm.{h,ipp} from github.com/aaronsgiles/ymfm/src into one directory,
// change their private:/protected: to public: (the trace reads channel
// state), then
//     clang++ -std=c++17 -O2 -o ymfm_replay ymfm_replay.cpp ymfm_opl.cpp ymfm_pcm.cpp ymfm_adpcm.cpp
// Run:
//     ymfm_replay sim/opl4_replay_tb/writes.hex debug/hw/asurabld_wave.bin 2380 2470 pcm.raw mix.raw
// writes trace_ymfm.txt ("n ch env tl pos sample") and regs_ymfm.txt in the CWD.
//
// Pacing mirrors the bench: each port write costs 307 clk; frames are
// 1433730 clk; a sample tick is 768 * 21875 / 8624 clk. Before fast_to only
// the writes advance time; from fast_to each frame's writes go at its start.
#include "ymfm_opl.h"
#include <cstdio>
#include <cstdlib>
#include <vector>

struct iface : ymfm::ymfm_interface {
	std::vector<uint8_t> rom;
	uint8_t ymfm_external_read(ymfm::access_class t, uint32_t a) override {
		return (t == ymfm::ACCESS_PCM && a < rom.size()) ? rom[a] : 0;
	}
};

struct chip : ymfm::ymf278b {
	using ymfm::ymf278b::ymf278b;
	FILE *trace = nullptr; long trace_n = 0;
	// one sample: the full DO2 mix, and the PCM term alone as the bench sees it
	void step(int16_t &pl, int16_t &pr, int16_t &ml, int16_t &mr) {
		static const int16_t sc[8] = { 0x7fa, 0x5a4, 0x3fd, 0x2d2, 0x1fe, 0x169, 0xff, 0 };
		int32_t pcm_l = sc[m_pcm.regs().mix_pcm_l()], pcm_r = sc[m_pcm.regs().mix_pcm_r()];
		int32_t fm_l = sc[m_pcm.regs().mix_fm_l()], fm_r = sc[m_pcm.regs().mix_fm_r()];
		m_fm_pos += 21;
		if (m_fm_pos >= 171) { m_fm.clock(fm_engine::ALL_CHANNELS); m_fm_pos -= 171; }
		m_fm.clock(fm_engine::ALL_CHANNELS);
		m_pcm.clock(ymfm::pcm_engine::ALL_CHANNELS);
		if (trace && trace_n < 30000) {
			for (int ch = 0; ch < 24; ch++) {
				auto &c = *m_pcm.m_channel[ch];
				if (c.m_env_attenuation > 0x200) continue;
				fprintf(trace, "%ld %d %d %d %u %d\n", trace_n, ch, c.m_env_attenuation, c.m_total_level >> 8, c.m_curpos, c.fetch_sample());
			}
		}
		if (trace) trace_n++;
		fm_engine::output_data fo; m_fm.output(fo.clear(), 0, 32767, fm_engine::ALL_CHANNELS);
		ymfm::pcm_engine::output_data po; m_pcm.output(po.clear(), ymfm::pcm_engine::ALL_CHANNELS);
		auto c16 = [](int32_t v) { return int16_t(v > 32767 ? 32767 : v < -32768 ? -32768 : v); };
		pl = c16((po.data[0] * pcm_l) >> 11);
		pr = c16((po.data[1] * pcm_r) >> 11);
		ml = c16((fo.data[0] * fm_l + po.data[0] * pcm_l) >> 11);
		mr = c16((fo.data[1] * fm_r + po.data[1] * pcm_r) >> 11);
	}
};

int main(int argc, char **argv) {
	if (argc != 7) { fprintf(stderr, "usage: replay writes.hex wave.bin fast_to end pcm.raw mix.raw\n"); return 1; }
	iface io;
	FILE *f = fopen(argv[2], "rb"); if (!f) return 2;
	io.rom.resize(4194304); io.rom.resize(fread(io.rom.data(), 1, io.rom.size(), f)); fclose(f);
	chip c(io); c.reset();
	int fast_to = atoi(argv[3]), end_fr = atoi(argv[4]);
	FILE *op = fopen(argv[5], "wb"), *om = fopen(argv[6], "wb");
	FILE *w = fopen(argv[1], "r"); if (!w) return 3;

	const double TICK = 768.0 * 21875.0 / 8624.0, FRAME = 1433730.0;
	double t = 40.0, next_tick = TICK;          // the bench's reset takes 40 clk
	bool rec = false; long samples = 0; int cur = 0; double frame_t0 = 0;
	auto run_to = [&](double until) {
		while (next_tick <= until) {
			int16_t pl, pr, ml, mr; c.step(pl, pr, ml, mr);
			if (rec) { fwrite(&pl, 2, 1, op); fwrite(&pr, 2, 1, op); fwrite(&ml, 2, 1, om); fwrite(&mr, 2, 1, om); samples++; }
			next_tick += TICK;
		}
		t = until;
	};
	unsigned fr, port, val;
	while (fscanf(w, "%x %x %x", &fr, &port, &val) == 3) {
		if ((int)fr >= end_fr) break;
		if ((int)fr >= fast_to && !rec) { rec = true; cur = fast_to; frame_t0 = t; c.trace = fopen("trace_ymfm.txt", "w"); printf("ymfm env_counter at recording start: %u\n", c.m_pcm.m_env_counter); FILE *rg = fopen("regs_ymfm.txt", "w"); for (int i = 0; i < 256; i++) fprintf(rg, "%02x %02x\n", i, c.m_pcm.m_regs.m_regdata[i]); fclose(rg); }
		if (rec) while (cur < (int)fr) { run_to(frame_t0 + FRAME); frame_t0 += FRAME; cur++; }
		c.write(port, uint8_t(val));
		run_to(t + 307.0);
	}
	while (rec && cur < end_fr) { run_to(frame_t0 + FRAME); frame_t0 += FRAME; cur++; }
	fclose(op); fclose(om); fclose(w);
	printf("ymfm: %ld samples recorded\n", samples);
	return 0;
}
