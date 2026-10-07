# Applies the SoundMod edits to mixer_paths_tavil.xml.
# Vars: dual (0/1), boost (earpiece dB over 0 dB, 0-16), earch (L, R or MIX: what the earpiece plays),
#       hpf (earpiece high-pass in Hz, 0 = off), sidetone (0/1), counts (file for edit counts).
function setval(s, v) { sub(/value="[^"]*"/, "value=\"" v "\"", s); return s }
# WCD934x IIR coefficient: Q28 fixed point, 30-bit two's complement (top two bits reserved).
function q28(c,   v) { v = int(c * 268435456); if (v < 0) v += 1073741824; return v }
# RBJ high-pass biquad at 48 kHz into C[0..4] = b0 b1 b2 a1 a2, normalised to a0 = 1.
function hpf_biquad(f, q, C,   w, cw, al, a0) {
	w = 2 * PI * f / 48000; cw = cos(w); al = sin(w) / (2 * q); a0 = 1 + al
	C[0] = (1 + cw) / 2 / a0; C[1] = -(1 + cw) / a0; C[2] = C[0]; C[3] = -2 * cw / a0; C[4] = (1 - al) / a0
}
function print_band(n, C,   i) {
	for (i = 0; i < 5; i++)
		print "        <ctl name=\"IIR1 Band" n "\" id=\"" i "\" value=\"" q28(C[i]) "\" />"
	print "        <ctl name=\"IIR1 Enable Band" n "\" value=\"1\" />"
}
BEGIN { PI = atan2(0, -1) }
{
	line = $0
	if (match(line, /<path name="[^"]*">/))
		cur = substr(line, RSTART + 12, RLENGTH - 14)

	if (dual) {
		# New path: earpiece amp on (+6 dB PA gain, as "handset").
		if (cur == "speaker" && index(line, "<path name=\"speaker\">")) {
			print "    <path name=\"dual-speaker-ear\">"
			print "        <ctl name=\"SLIM RX0 MUX\" value=\"AIF1_PB\" />"
			print "        <ctl name=\"CDC_IF RX0 MUX\" value=\"SLIM RX0\" />"
			if (earch == "MIX") {
				# Original mod: one-channel slimbus, the DSP downmixes L+R.
				print "        <ctl name=\"SLIM_0_RX Channels\" value=\"One\" />"
				print "        <ctl name=\"RX INT0_1 MIX1 INP0\" value=\"RX0\" />"
			} else {
				# Both channels into IIR1 (input 0 = left, 1 = right); the unused one sits at 0 (-84 dB)
				# but must stay connected or the slimbus RX port overflows and the earpiece goes silent.
				# The patched kernel swaps the two input levels on rotation. Played level is 83 (-1 dB,
				# filter headroom), which also differs from the reset level (84) so audio_route always
				# rewrites both after a swap.
				print "        <ctl name=\"SLIM RX1 MUX\" value=\"AIF1_PB\" />"
				print "        <ctl name=\"CDC_IF RX1 MUX\" value=\"SLIM RX1\" />"
				print "        <ctl name=\"SLIM_0_RX Channels\" value=\"Two\" />"
				print "        <ctl name=\"IIR1 INP0 MUX\" value=\"RX0\" />"
				print "        <ctl name=\"IIR1 INP1 MUX\" value=\"RX1\" />"
				print "        <ctl name=\"IIR1 INP0 Volume\" value=\"" (earch == "L" ? 83 : 0) "\" />"
				print "        <ctl name=\"IIR1 INP1 Volume\" value=\"" (earch == "L" ? 0 : 83) "\" />"
				# Earpiece high-pass: 4th-order Butterworth (two biquads); the rest pass through.
				unity[0] = 1; unity[1] = 0; unity[2] = 0; unity[3] = 0; unity[4] = 0
				if (hpf > 0) { hpf_biquad(hpf, 0.54119610, B); print_band(1, B); hpf_biquad(hpf, 1.30656296, B); print_band(2, B) }
				else { print_band(1, unity); print_band(2, unity) }
				print_band(3, unity); print_band(4, unity); print_band(5, unity)
				print "        <ctl name=\"RX INT0_1 MIX1 INP0\" value=\"IIR1\" />"
			}
			print "        <ctl name=\"RX INT0 DEM MUX\" value=\"CLSH_DSM_OUT\" />"
			print "        <ctl name=\"EAR PA Gain\" value=\"G_6_DB\" />"
			print "    </path>"
			print ""
			d3++
		}
		# Speaker device turns the earpiece on; RX0 Digital Volume is the earpiece's digital gain (84 = 0 dB;
		# +1 makes up for the IIR input's -1 dB).
		if (cur == "speaker" && index(line, "\"RX0 Digital Volume\"")) {
			print "        <path name=\"dual-speaker-ear\" />"
			line = setval(line, 84 + boost + (earch == "MIX" ? 0 : 1)); d4++
		}
		# Media front ends: also feed the earpiece backend (SLIMBUS_0_RX) next to the speaker amp (TERT_MI2S_RX).
		if ((cur == "deep-buffer-playback speaker" || cur == "low-latency-playback speaker" || \
		     cur == "compress-offload-playback speaker" || cur == "compress-offload-playback2 speaker" || \
		     cur == "audio-ull-playback speaker" || cur == "mmap-playback speaker") && \
		    match(line, /"TERT_MI2S_RX Audio Mixer MultiMedia[0-9]+"/)) {
			print line
			sub(/TERT_MI2S_RX Audio Mixer/, "SLIMBUS_0_RX Audio Mixer", line); d5++
		}
	}
	if (sidetone && (cur == "sidetone-headphones" || cur == "sidetone-handset") && index(line, "\"IIR0 INP0 Volume\"")) {
		line = setval(line, 54); st++
	}

	print line
	if (index(line, "</path>")) cur = ""
}
END { print (d3+0), (d4+0), (d5+0), (st+0) > counts }
