#
# Copyright (C) 2026 OpenWrt.org
#

# LaCie CloudBox, stock U-Boot, Nexus disk layout. Do not replace U-Boot.
#
# saved_entry 0 boots partition 4, saved_entry 1 boots partition 5.
# The kernel is the file /boot/uImage on that partition.
# Partition 3 holds /ubootenv (boot_count and saved_entry).
# Partition 2 holds /rescue/uImage. An upgrade does not write it.
# Partitions 6, 7 and 8, and the SPI NOR, are left alone.
#
# U-Boot reads the flags with ext2get and writes boot_count back with
# ext2set. Those commands are not in the strings dump. The file on a
# stock disk is small and contains the names boot_count and saved_entry,
# so this treats it as key=value records separated by newlines or NULs
# and replaces only the named value.

CLOUDBOX_NV_PART=3
CLOUDBOX_SLOT_A=4
CLOUDBOX_SLOT_B=5

cloudbox_file_has_nul() {
	local raw stripped

	raw=$(wc -c < "$1")
	stripped=$(tr -d '\000' < "$1" | wc -c)
	[ "$raw" -ne "$stripped" ]
}

cloudbox_ubootenv_get() {
	local file="$1"
	local key="$2"
	local line val

	[ -f "$file" ] || return 1
	val=$(tr '\000' '\n' < "$file" | while IFS= read -r line; do
		line=$(printf '%s' "$line" | tr -d '\r')
		if [ "${line%%=*}" = "$key" ] && [ "$line" != "$key" ]; then
			printf '%s\n' "${line#*=}"
			break
		fi
	done)
	[ -n "$val" ] || return 1
	printf '%s' "$val"
}

cloudbox_ubootenv_edit() {
	local file="$1"
	local key="$2"
	local value="$3"
	local line found=0

	while IFS= read -r line || [ -n "$line" ]; do
		line=$(printf '%s' "$line" | tr -d '\r')
		if [ "${line%%=*}" = "$key" ] && [ "$line" != "$key" ]; then
			printf '%s=%s\n' "$key" "$value"
			found=1
		else
			printf '%s\n' "$line"
		fi
	done < "$file"
	[ "$found" -eq 1 ] || printf '%s=%s\n' "$key" "$value"
}

cloudbox_ubootenv_set() {
	local file="$1"
	local key="$2"
	local value="$3"
	local dir tmp

	dir=$(dirname "$file")
	tmp="$dir/.ubootenv.new"

	if [ ! -f "$file" ]; then
		printf '%s=%s\n' "$key" "$value" > "$tmp"
		mv "$tmp" "$file"
		return 0
	fi

	if cloudbox_file_has_nul "$file"; then
		tr '\000' '\n' < "$file" > "$tmp.in"
		cloudbox_ubootenv_edit "$tmp.in" "$key" "$value" > "$tmp.out"
		tr '\n' '\000' < "$tmp.out" > "$tmp"
		rm -f "$tmp.in" "$tmp.out"
	else
		cloudbox_ubootenv_edit "$file" "$key" "$value" > "$tmp"
	fi
	mv "$tmp" "$file"
}

cloudbox_ubootenv_set_flags() {
	local file="$1"
	local entry="$2"
	local dir tmp

	dir=$(dirname "$file")
	tmp="$dir/.ubootenv.new"
	if [ ! -f "$file" ]; then
		printf 'boot_count=0\nsaved_entry=%s\n' "$entry" > "$tmp"
		mv "$tmp" "$file"
		return 0
	fi

	if cloudbox_file_has_nul "$file"; then
		tr '\000' '\n' < "$file" > "$tmp.in"
		cloudbox_ubootenv_edit "$tmp.in" saved_entry "$entry" > "$tmp.mid"
		cloudbox_ubootenv_edit "$tmp.mid" boot_count 0 > "$tmp.out"
		tr '\n' '\000' < "$tmp.out" > "$tmp"
		rm -f "$tmp.in" "$tmp.mid" "$tmp.out"
	else
		cloudbox_ubootenv_edit "$file" saved_entry "$entry" > "$tmp.mid"
		cloudbox_ubootenv_edit "$tmp.mid" boot_count 0 > "$tmp"
		rm -f "$tmp.mid"
	fi
	mv "$tmp" "$file"
}

cloudbox_find_disk() {
	local b name mnt found

	mnt=/tmp/cloudbox-probe
	mkdir -p "$mnt"
	for b in /sys/block/sd*; do
		[ -d "$b" ] || continue
		name=$(basename "$b")
		[ -b "/dev/${name}${CLOUDBOX_NV_PART}" ] || continue
		[ -b "/dev/${name}${CLOUDBOX_SLOT_A}" ] || continue
		[ -b "/dev/${name}${CLOUDBOX_SLOT_B}" ] || continue
		mount -o ro "/dev/${name}${CLOUDBOX_NV_PART}" "$mnt" 2>/dev/null || \
			mount -o ro -t ext4 "/dev/${name}${CLOUDBOX_NV_PART}" "$mnt" 2>/dev/null || \
			continue
		if [ -f "$mnt/ubootenv" ]; then
			found="/dev/$name"
		fi
		umount "$mnt" || return 1
		if [ -n "$found" ]; then
			echo "$found"
			return 0
		fi
	done
	return 1
}

cloudbox_mount() {
	local dev="$1"
	local mnt="$2"

	mkdir -p "$mnt"
	mount "$dev" "$mnt" 2>/dev/null || mount -t ext4 "$dev" "$mnt"
}

cloudbox_image_board_dir() {
	tar tf "$1" 2>/dev/null | sed -n 's/^\(sysupgrade-.*\)\/kernel$/\1/p' | head -n 1
}

cloudbox_check_image() {
	local board_dir root_ok

	board_dir=$(cloudbox_image_board_dir "$1")
	[ -n "$board_dir" ] || {
		echo "sysupgrade image has no kernel" >&2
		return 1
	}
	root_ok=$(tar tf "$1" 2>/dev/null | grep -c "^${board_dir}/root$")
	[ "$root_ok" -eq 1 ] || {
		echo "sysupgrade image has no root archive" >&2
		return 1
	}
	return 0
}

cloudbox_fail() {
	echo "$@" >&2
	[ -n "$CLOUDBOX_ROOT_MNT" ] && umount "$CLOUDBOX_ROOT_MNT" 2>/dev/null
	[ -n "$CLOUDBOX_NV_MNT" ] && umount "$CLOUDBOX_NV_MNT" 2>/dev/null
	CLOUDBOX_ROOT_MNT=
	CLOUDBOX_NV_MNT=
	return 1
}

platform_do_upgrade_cloudbox() {
	local image="$1"
	local board_dir disk entry new_part new_entry dev mnt magic f

	board_dir=$(cloudbox_image_board_dir "$image")
	[ -n "$board_dir" ] || {
		cloudbox_fail "sysupgrade image has no kernel"
		return 1
	}

	disk=$(cloudbox_find_disk) || {
		cloudbox_fail "no disk with a Nexus /ubootenv on partition ${CLOUDBOX_NV_PART}"
		return 1
	}

	CLOUDBOX_NV_MNT=/tmp/cloudbox-nv
	cloudbox_mount "${disk}${CLOUDBOX_NV_PART}" "$CLOUDBOX_NV_MNT" || {
		cloudbox_fail "cannot mount ${disk}${CLOUDBOX_NV_PART}"
		return 1
	}

	entry=$(cloudbox_ubootenv_get "$CLOUDBOX_NV_MNT/ubootenv" saved_entry) || {
		cloudbox_fail "saved_entry is missing from /ubootenv"
		return 1
	}
	case "$entry" in
	0)
		new_part=$CLOUDBOX_SLOT_B
		new_entry=1
		;;
	1)
		new_part=$CLOUDBOX_SLOT_A
		new_entry=0
		;;
	*)
		cloudbox_fail "saved_entry must be 0 or 1, not '$entry'"
		return 1
		;;
	esac

	dev="${disk}${new_part}"
	echo "installing to ${dev} (saved_entry ${entry} -> ${new_entry})"
	if grep -q "^${dev} " /proc/mounts; then
		umount "$dev" || {
			cloudbox_fail "${dev} is mounted"
			return 1
		}
	fi

	CLOUDBOX_ROOT_MNT=/tmp/cloudbox-root
	cloudbox_mount "$dev" "$CLOUDBOX_ROOT_MNT" || {
		cloudbox_fail "cannot mount ${dev}; it must already be ext2 or ext3"
		return 1
	}

	mnt="$CLOUDBOX_ROOT_MNT"
	for f in "$mnt"/* "$mnt"/.[!.]* "$mnt"/..?*; do
		[ -e "$f" ] || continue
		[ "$(basename "$f")" = "lost+found" ] && continue
		rm -rf "$f" || {
			cloudbox_fail "cannot clear ${dev}"
			return 1
		}
	done

	tar -xOf "$image" "$board_dir/root" | tar -xz -C "$mnt" || {
		cloudbox_fail "cannot extract root archive onto ${dev}"
		return 1
	}
	[ -x "$mnt/sbin/init" ] || [ -L "$mnt/sbin/init" ] || {
		cloudbox_fail "extracted root has no /sbin/init"
		return 1
	}

	mkdir -p "$mnt/boot"
	tar -xOf "$image" "$board_dir/kernel" > "$mnt/boot/uImage" || {
		cloudbox_fail "cannot extract kernel onto ${dev}"
		return 1
	}
	magic=$(dd if="$mnt/boot/uImage" bs=4 count=1 2>/dev/null | hexdump -v -e '1/1 "%02x"')
	[ "$magic" = "27051956" ] || {
		cloudbox_fail "kernel is not a uImage"
		return 1
	}
	sync

	cloudbox_ubootenv_set_flags "$CLOUDBOX_NV_MNT/ubootenv" "$new_entry" || {
		cloudbox_fail "cannot write /ubootenv"
		return 1
	}
	sync
	umount "$CLOUDBOX_NV_MNT" || echo "nv partition stayed mounted" >&2
	CLOUDBOX_NV_MNT=
}

platform_copy_config_cloudbox() {
	[ -n "$CLOUDBOX_ROOT_MNT" ] || return 0
	[ -f "$UPGRADE_BACKUP" ] || return 0
	cp -f "$UPGRADE_BACKUP" "$CLOUDBOX_ROOT_MNT/$BACKUP_FILE"
	sync
}

cloudbox_clear_boot_count() {
	local disk mnt cur owned=0 mp

	disk=$(cloudbox_find_disk) || return 1
	mp=$(awk -v dev="${disk}${CLOUDBOX_NV_PART}" '$1 == dev { print $2; exit }' /proc/mounts)
	if [ -n "$mp" ]; then
		mnt="$mp"
	else
		mnt=/tmp/cloudbox-nv
		cloudbox_mount "${disk}${CLOUDBOX_NV_PART}" "$mnt" || return 1
		owned=1
	fi

	cur=$(cloudbox_ubootenv_get "$mnt/ubootenv" boot_count) || {
		[ "$owned" -eq 1 ] && umount "$mnt"
		return 1
	}
	if [ "$cur" != "0" ]; then
		cloudbox_ubootenv_set "$mnt/ubootenv" boot_count 0 || {
			[ "$owned" -eq 1 ] && umount "$mnt"
			return 1
		}
		sync
		echo "cloudbox: boot_count reset to 0"
	fi
	[ "$owned" -eq 1 ] && umount "$mnt"
	return 0
}
