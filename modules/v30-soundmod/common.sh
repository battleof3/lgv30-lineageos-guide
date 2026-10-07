# Shared by post-fs-data.sh and action.sh. Needs MODDIR.
umask 022
TARGET=/vendor/etc/mixer_paths_tavil.xml
WORK=/dev/v30_soundmod          # tmpfs: a bind mount sourced from /data would keep /data busy at shutdown
CONF=/data/adb/v30_soundmod.conf
LOG=/data/adb/v30_soundmod.log
BB=/data/adb/ksu/bin/busybox
SLOT=/sys/module/snd_soc_tfa98xx/parameters/lgv30_spk_slot   # kernel patch tfa-spk-slot.diff

log() { echo "$(date '+%F %T') $*" >> "$LOG"; echo "$*"; }

load_conf() {
	DUAL_SPEAKER=1; EAR_BOOST_DB=12; EAR_HPF_HZ=300; EAR_CHANNEL=R; ROTATION=1; SIDETONE=0
	[ -f "$CONF" ] || save_conf
	. "$CONF"
	case "$DUAL_SPEAKER" in 0|1) ;; *) DUAL_SPEAKER=1 ;; esac
	case "$SIDETONE" in 0|1) ;; *) SIDETONE=0 ;; esac
	case "$EAR_BOOST_DB" in [0-9]|1[0-6]) ;; *) EAR_BOOST_DB=12 ;; esac
	case "$EAR_HPF_HZ" in 0|[1-9][0-9][0-9]|1[0-9][0-9][0-9]) ;; *) EAR_HPF_HZ=300 ;; esac
	case "$EAR_CHANNEL" in L|R|MIX) ;; *) EAR_CHANNEL=R ;; esac
	case "$ROTATION" in 0|1) ;; *) ROTATION=1 ;; esac
	# Rotation-aware stereo needs the patched kernel: the speaker amp plays the right channel and the
	# earpiece the left, so the HAL's "Swap channel" at 270 degrees gives the mirrored layout.
	ROT_ACTIVE=0
	if [ "$ROTATION" = 1 ] && [ "$DUAL_SPEAKER" = 1 ] && [ -w "$SLOT" ]; then ROT_ACTIVE=1; EARCH=L; else EARCH=$EAR_CHANNEL; fi
}

save_conf() {
	cat > "$CONF" <<EOC
# V30 SoundMod settings (Action button cycles DUAL_SPEAKER/EAR_BOOST_DB).
DUAL_SPEAKER=$DUAL_SPEAKER
# Extra earpiece gain in dB while dual speaker is on (0-16). The original mod used 5. High values can
# clip loud music at high media volume.
EAR_BOOST_DB=$EAR_BOOST_DB
# Earpiece high-pass in Hz (0 = off, 100-1999): keeps bass the tiny earpiece cannot play out of it, which
# avoids distortion/clicks and leaves headroom for the boost. Not used with EAR_CHANNEL=MIX.
EAR_HPF_HZ=$EAR_HPF_HZ
# What the earpiece plays when ROTATION is off or unsupported: R or L (true stereo; the bottom speaker plays
# the other side) or MIX (L+R, original mod).
EAR_CHANNEL=$EAR_CHANNEL
# 1 = swap left/right when the phone is turned the other way (needs the patched kernel; reboot to change).
ROTATION=$ROTATION
# 1 = hear your own voice in the earpiece/headset during calls (original mod's sidetone level).
SIDETONE=$SIDETONE
EOC
}

is_mounted() { grep -q " $TARGET " /proc/mounts; }

# Keep an untouched copy of the ROM's file; taken before we ever mount over it.
save_stock() {
	mkdir -p "$WORK"
	if [ ! -f "$WORK/stock.xml" ]; then
		is_mounted && umount "$TARGET"
		cp "$TARGET" "$WORK/stock.xml"
	fi
}

# Build $WORK/mixer.xml from the stock copy; returns 1 (and logs why) unless every edit landed exactly.
build() {
	rm -f "$WORK/mixer.xml" "$WORK/counts"
	"$BB" awk -v dual="$DUAL_SPEAKER" -v boost="$EAR_BOOST_DB" -v earch="$EARCH" -v hpf="$EAR_HPF_HZ" -v sidetone="$SIDETONE" -v counts="$WORK/counts" \
		-f "$MODDIR/patch.awk" "$WORK/stock.xml" > "$WORK/mixer.xml" || { log "awk failed"; return 1; }
	if [ "$DUAL_SPEAKER" = 1 ]; then want="1 1 6"; else want="0 0 0"; fi
	if [ "$SIDETONE" = 1 ]; then want="$want 2"; else want="$want 0"; fi
	got=$(cat "$WORK/counts")
	[ "$got" = "$want" ] || { log "edit counts '$got' != expected '$want' (ROM mixer file changed?) - leaving stock audio"; return 1; }
	opened=$(grep -c '<path name="[^"]*">' "$WORK/mixer.xml"); closed=$(grep -c '</path>' "$WORK/mixer.xml")
	[ "$opened" = "$closed" ] || { log "path tags unbalanced ($opened/$closed) - leaving stock audio"; return 1; }
	return 0
}

# Mount the built file over the ROM's (or leave stock if everything is off).
apply() {
	is_mounted && umount "$TARGET"
	[ -w "$SLOT" ] && { [ "$ROT_ACTIVE" = 1 ] && echo 1 > "$SLOT" || echo 0 > "$SLOT"; }
	if [ "$DUAL_SPEAKER" = 0 ] && [ "$SIDETONE" = 0 ]; then log "all options off - stock mixer_paths"; return 0; fi
	build || return 1
	mv -f "$WORK/mixer.xml" "$WORK/active.xml"
	chmod 644 "$WORK/active.xml"
	chcon u:object_r:vendor_configs_file:s0 "$WORK/active.xml"
	mount --bind "$WORK/active.xml" "$TARGET" || { log "bind mount failed"; return 1; }
	log "applied: DUAL_SPEAKER=$DUAL_SPEAKER EAR_BOOST_DB=$EAR_BOOST_DB earpiece=$EARCH hpf=$EAR_HPF_HZ rotation=$ROT_ACTIVE SIDETONE=$SIDETONE"
}
