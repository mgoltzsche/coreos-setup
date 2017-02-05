#!/bin/sh

# Installs CoreOS on the current machine wiping all existing data.
# Useful to setup (Hetzner) server from within rescue system.

usage() {
	cat >&2 <<-EOF
		Usage: $0 [OPTIONS] HDD1 [HDD2 [SSHPUBLICKEY]]
		  OPTIONS:
		    -y		Suppresses confirmation prompt
		Examples:
		  $0 /dev/sda /dev/sdb 'ssh-rsa AAAAB...'
		  $0 /dev/sda '' 'ssh-rsa AAAAB...' # Without RAID1
		  $0 /dev/sda /dev/sdb # With key from user's authorized_key file
	EOF
}

# Destroys the partition table on the given device.
# Workaround for https://github.com/coreos/bugs/issues/152
destroyPartitionTablesAndExit() {
	echo 'Your devices contain old partition/RAID data that gets loaded by the kernel which then blocks partition reread.' >&2
	echo 'Destroying all partition tables ...' >&2
	for DEVICE in $@; do
		echo "Destroying partition table on device $DEVICE"
		dd if=/dev/zero of="$DEVICE" bs=512 count=1 conv=notrunc || exit 1
	done
	sleep 3
	echo 'Please restart the machine and run this script again' >&2
	partprobe
}

createCloudConfigFile() {
	cat > cloud-config.yml <<-EOF
		#cloud-config
		ssh_authorized_keys:
		  - $1
		coreos:
		  update:
		    reboot-strategy: reboot
		  locksmith:
		    window-start: Sat 04:00
		    window-length: 3h
	EOF
}

jsonEscape() {
	echo "$1" | sed ':a;N;$!ba;s/\n/\\n/g'
}

createIgnitionConfigFile() {
	CFG_HOSTNAME="$1"
	CFG_SSHPUBLICKEY="$2"
	# For CoreOS default disk layout see https://coreos.com/os/docs/latest/sdk-disk-partitions.html
	# For raid config see https://coreos.com/ignition/docs/latest/examples.html#create-a-raid-enabled-data-volume
	# For general ignite config see: https://coreos.com/ignition/docs/latest/configuration.html
	# This configuration does not prepare disks since this is done by this script already
	#  to be able to see partitioning succeed in rescue system and
	#  because ignite doesn't provide a proper documentation how to put sda into RAID1
	SYSTEMD_SSHD_SERVICE=$(cat <<-EOF
		[Unit]
		Description=OpenSSH server daemon

		[Service]
		Type=forking
		PIDFile=/var/run/sshd.pid
		ExecStart=/usr/sbin/sshd
		ExecReload=/bin/kill -HUP \$MAINPID
		KillMode=process
		Restart=on-failure
		RestartSec=30s

		[Install]
		WantedBy=multi-user.target
	EOF
	)
	SYSTEMD_SSHD_SOCKET=$(cat <<-EOF
		[Unit]
		Description=OpenSSH Server Socket
		Conflicts=sshd.service

		[Socket]
		ListenStream=22
		FreeBind=true
		Accept=yes

		[Install]
		WantedBy=sockets.target
	EOF
	)
	SYSTEMD=$(cat <<-EOF
		  "systemd": {
		    "units": [
		      {
		        "name": "sshd.socket",
		        "enable": true,
		        "contents": "$(jsonEscape "$SYSTEMD_SSHD_SOCKET")"
		      }
		    ]
		  },
	EOF
	)

	CREATEDATAFS=
	if [ "$3" = 'createdatafs' ]; then
		CREATEDATAFS=',"create": { "options": [ "-L", "DATA" ] }'
	fi

	cat > ignition.json <<-EOF
		{
		  "ignition": { "version": "2.0.0" },
		  "storage": {
		    "disks": [
		      {
		        "device": "/dev/sda",
		        "wipeTable": false,
		        "partitions": [
		          {
		            "label": "data.raid1.1",
		            "number": 10,
		            "size": 3221225472,
		            "start": 2639302656
		          }
		        ]
		      },
		      {
		        "device": "/dev/sdb",
		        "wipeTable": true,
		        "partitions": [{
		          "label": "data.raid1.2",
		          "number": 1,
		          "size": 3221225472,
		          "start": 0
		        }]
		      }
		    ],
		    "raid": [{
		      "devices": [
		        "/dev/disk/by-partlabel/data.raid1.1",
		        "/dev/disk/by-partlabel/data.raid1.2"
		      ],
		      "level": "raid1",
		      "name": "data"
		    }],
		    "filesystems": [{
		      "mount": {
		        "device": "/dev/md/data",
		        "format": "ext4"$CREATEDATAFS
		      }
		    }],
		    "files": [{
		      "filesystem": "root",
		      "path": "/etc/hostname",
		      "mode": 420,
		      "contents": { "source": "data:,$CFG_HOSTNAME" }
		    }]
		  },
		  "systemd": {
		    "units": [
		      {
		        "name": "var-data.mount",
		        "enable": true,
		        "contents": "[Mount]\nWhat=/dev/md/data\nWhere=/var/data\nType=ext4\n\n[Install]\nWantedBy=local-fs.target"
		      }
		    ]
		  },
		  "passwd": {
		    "users": [{
		      "name": "max",
		      "sshAuthorizedKeys": ["$CFG_SSHPUBLICKEY"],
		      "create": {
		        "groups": ["sudo"]
		      }
		    }]
		  }
		}
	EOF
}

# Write CoreOS image to disk. (See https://coreos.com/os/docs/latest/installing-to-disk.html)
# Usage: . DISK CLOUDCONFIGFILE
writeCoreOsImageToDisk() {
	echo "Installing CoreOS on $1 with ignition.json:" &&
	cat "$2" | sed -E 's/^/  /g' &&
	wget -O /tmp/coreos-install https://raw.githubusercontent.com/coreos/init/master/bin/coreos-install &&
	chmod +x /tmp/coreos-install &&
	/tmp/coreos-install -C beta -d "$1" -i "$2" # On error delete existing partitions, reboot and retry (See https://github.com/coreos/bugs/issues/152)
	STATUS=$?
	reloadPartitionTable "$1" && return $STATUS
}

simpleCoreOsInstall() {
	BASE_URL='https://stable.release.core-os.net/amd64-usr'
	VERSION_ID=$(wget --quiet -O - "$BASE_URL/current/version.txt" | grep -E '^COREOS_VERSION=' | grep -Eo '[0-9]+.*')
	IMAGE_URL="$BASE_URL/$VERSION_ID/coreos_production_image.bin.bz2"
	SIG_URL="$BASE_URL/$VERSION_ID/coreos_production_image.bin.bz2.sig"
	echo "Downloading and writing CoreOS $VERSION_ID image ..."
	dd if=/dev/zero of="$1" count=1024 2>/dev/null seek=$(($(blockdev --getsz "$1") - 1024)) && # Remove labels at disk end
	wget --no-verbose -O - "$IMAGE_URL" | bunzip2 --stdout >"$1"
	# TODO: verify with signature
}

diskSerialNumber() {
	hdparm -I "$1" 2>/dev/null | grep 'Serial Number:' | sed -E 's/\s*Serial Number:\s*//'
}

size2sectors() {
	SIZEINBYTES=$(numfmt --from=iec "$1") &&
	BYTESPERSECTOR=$(gdisk -l "$2" | grep -E '^Logical sector size: [0-9]+ bytes$' | grep -Eo '[0-9]+') &&
	SECTORS=$(expr "$SIZEINBYTES" / "$BYTESPERSECTOR") &&
	alignDiskSector "$2" "$SECTORS"
}

diskSectorAlignment() {
	(gdisk -l "$1" | grep -Eq 'aligned on [0-9]+-sector boundaries' || (echo "Cannot find disk $1 sector alignment" >&2; false)) &&
	gdisk -l "$1" | grep -Eo 'aligned on [0-9]+-sector boundaries' | grep -Eo '[0-9]+'
}

alignDiskSector() {
	SALIGN=$(diskSectorAlignment "$1") || return 1
	expr "$2" - $(expr "$2" % "$SALIGN")
	return 0
}

firstDiskSector() {
	expr 2 \* $(diskSectorAlignment "$1")
}

lastDiskSector() {
	SALIGN=$(diskSectorAlignment "$1") &&
	LASTSECTOR=$(totalDiskSectors "$1") || return 1
	expr $(alignDiskSector "$1" "$LASTSECTOR") - $(expr 2 \* $SALIGN)
}

totalDiskSectors() {
	(gdisk -l "$1" | grep -Eq "^Disk $1: [0-9]+ sectors" || (echo "Cannot find disk $1 sector count" >&2; false)) &&
	gdisk -l "$1" | grep -Eo "^Disk $1: [0-9]+ sectors" | sed -E 's/^.* ([0-9]+) sectors$/\1/'
}

firstPartitionSector() {
	(sgdisk "$1" -i="$2" | grep -Eq '^First sector: [0-9]+' || (echo "Cannot read partition $2 from $1" >&2; false)) &&
	sgdisk "$1" -i="$2" | grep -Eo '^First sector: [0-9]+' | grep -Eo '[0-9]+'
}

partitionSectors() {
	(sgdisk "$1" -i="$2" | grep -Eq '^Partition size: [0-9]+ sectors' || (echo "Cannot read partition $2 size from $1" >&2; false)) &&
	sgdisk "$1" -i="$2" | grep -Eo '^Partition size: [0-9]+ sectors' | grep -Eo '[0-9]+'
}

partitionGUID() {
	sgdisk "$1" -i="$2" | grep -E '^Partition unique GUID: .*' | grep -Eio '[a-z0-9\-]+$'
}

reloadPartitionTable() {
	for DEVICE in $@; do
		udevadm settle
		for try in 0 1 2 4; do
			sleep "$try"  # Give the device a bit more time on each attempt.
			blockdev --rereadpt "$DEVICE" && unset try && break ||
			echo "Failed to reread partitions on $DEVICE" >&2
		done
		if [ ! -z "$try" ]; then
			cat >&2 <<-EOF
				TROUBLESHOOTING:
				  Unmount all partitions!
				  If partition table could still not be reread restart the machine
				  to let the kernel free the partition table.
				  If the problem remains and you accept the loss of all data on $DEVICE
				  destroy the old partition table with this call:
				    dd if=/dev/zero of=$DEVICE bs=512 count=1 conv=notrunc
				    sgdisk -Z $DEVICE
				  => partprobe $DEVICE should yield no error.
			EOF
			return 1
		fi
	done
}

# Copies the GPT partition table of device A to device B and
# generates new GUIDs for device B.
# Useful to migrate an existing system to RAID.
# See http://ram.kossboss.com/clone-partition-tables-gpt-mbr-sfdisk-sgdisk/
copyGptPartitionTable() {
	SRCDEV="$1"
	DESTDEV="$2"
	echo "Copying partition table from $SRCDEV to $DESTDEV ..."
	#MBR partition cloning: sfdisk -d "$SRCDEV" | sed -E 's/Id=\s*[a-z0-9]+/Id=fd/g' | sfdisk "$DESTDEV" && # Copy partition table from HDD1 to HDD2 while changing partition type to "Linux raid autodetect" (hex: fd)
	sgdisk "$DESTDEV" -Z # Destroy/zap partition table
	sgdisk "$SRCDEV" -R="$DESTDEV" && # Copy partition table
	sgdisk "$DESTDEV" -Gg && # Assign new GUIDs and convert MBR to GPT
	reloadPartitionTable "$DESTDEV" # Reload partitions
}

prepareSecondaryHdd() {
	reloadPartitionTable "$HDD2" &&
	FIRSTDISKSECTOR=$(firstDiskSector "$HDD2") &&
	DATASECTORS=$(partitionSectors "$HDD1" 10) &&
	HDD2DATAEND=$(lastDiskSector "$HDD2") &&
	HDD2DATASTART=$(expr $HDD2DATAEND - $DATASECTORS) &&
	HDD2FIRSTEND=$(expr $HDD2DATASTART - 1) &&
	set -x &&
	sgdisk "$HDD2" -ZGg -a=$SECTORALIGNMENT && # Clear HDD2's partition table (retry on error)
	sgdisk "$HDD2" -n=1:$FIRSTDISKSECTOR:$HDD2FIRSTEND -t=1:8300 -c=1:simpledata && # Add 1st (fill) partition on HDD2
	sgdisk "$HDD2" -n=2:$HDD2DATASTART:$HDD2DATAEND -t=2:fd00 -c=2:raid.data.1 && # Add data RAID partition on HDD2
	sgdisk "$HDD2" -v && # Verify
	reloadPartitionTable "$HDD2" &&

	# Destroy old data on HDD2 partitions in 1st sector
	for PARTITION in $(ls "$HDD2"* | grep -E "$HDD2"'[0-9]+$'); do
		echo "partition $PARTITION: $(sfdisk -s $PARTITION | numfmt --to=iec-i --suffix=B --padding=7)"
		mdadm --zero-superblock "$PARTITION" # Remove possible old RAID information
	done
}

createRaid1Array() {
	echo 'Creating RAID1 array ...' &&
	mount /dev/disk/by-label/ROOT /mnt &&
	#mkdir -p /mnt/etc/mdadm &&
	mdadm --create /dev/md/data --level=1 --raid-disks=2 /dev/disk/by-label/raid.data.1 /dev/disk/by-label/raid.data.2 && # Create degraded RAID1 array
	mkfs.ext4 -I 128 -L DATA /dev/md/data && # Format with ext4
	# Use this to rebuild RAID: mdadm --add /dev/md/data /dev/disk/by-label/raid.data.2 && # Add 2nd partition to RAID1 array
	# TODO: write COMPLETE config to disk
#	mdadm --examine --scan >> /mnt/etc/mdadm/mdadm.conf && # Write mdadm.conf with current state to restart with this preferences
	cat /proc/mdstat
	STATUS=$?

	umount /mnt &&
	[ $STATUS -eq 0 ]
}

injectFile() {
	mount "$1" /mnt &&
	echo "$3" > /mnt"$2"
	STATUS=$?
	umount /mnt && return $STATUS
}

stopRaidArrays() {
	# Stop eventually running RAID devices so that partition tables can be
	# changed and reloaded without the need of a reboot.
	RAIDRUNNING=
	for MDDEVICE in $(ls /dev/md 2>/dev/null); do
		echo "Stopping RAID device /dev/md/$MDDEVICE ..."
		mdadm --stop "/dev/md/$MDDEVICE" || return 1
		RAIDRUNNING=true
	done
	[ -z "$RAIDRUNNING" ] || sleep 7
}

stopRaidAndWipeDisk() {
	echo "Wiping disk $1 ..."
	mount | grep -Eo '^/dev/[^ ]+ on [^ ]+' | grep -Eo '[^ ]+$' | xargs -n1 umount 2>/dev/null
	stopRaidArrays || return 1
	# Wipe superblock on all partitions if available so that CoreOS
	# ignition setup doesn't get confused by existing RAID partition
	for PARTITION in $(ls /dev); do
		if echo "/dev/$PARTITION" | grep -Eq "^$1[0-9]+$"; then
			echo "  Wiping superblock of /dev/$PARTITION ..."
			# Delete raid if there was one
			mdadm --zero-superblock "/dev/$PARTITION" 2>&1 | sed -E 's/^/  /g'
			# Overwrite 1st sector to make sure old partition/RAID information
			# is destroyed
			dd if=/dev/zero of="/dev/$PARTITION" bs=512 count=1 conv=notrunc 2>&1 | sed -E 's/^/  /g'
		fi
	done
	echo "  Wiping partition table on $1 ..."
	dd if=/dev/zero of="$1" bs=512 count=1 conv=notrunc 2>&1 | sed -E 's/^/  /g'
}

setupPartitions() {
	# Setup data partition mirrored on HDD2
	# See https://www.howtoforge.com/software-raid1-grub-boot-debian-etch
	# and http://serverfault.com/questions/682145/coreos-on-software-raid-with-ext4-filesystem
	mdadm --help >/dev/null || apt-get install -y --force-yes mdadm || exit 1

	HDD1="$1"
	HDD2="$2"
	echo 'Preparing partitions ...'
	DATA_PARTITION_SIZE='1.5T'
	SECTORALIGNMENT=$(diskSectorAlignment "$HDD1") &&
	DATASECTORS=$(size2sectors "$DATA_PARTITION_SIZE" "$HDD1") &&
	HDD1DATAEND=$(lastDiskSector "$HDD1") &&
	HDD1DATASTART=$(expr $HDD1DATAEND - $DATASECTORS) &&
	ROOTSTART=$(firstPartitionSector "$HDD1" 9) &&
	ROOTEND=$(expr $HDD1DATASTART - 1) &&
	ROOTGUID=$(partitionGUID "$HDD1" 9) &&
	NEWHDD1GUID=$(cat /proc/sys/kernel/random/uuid) &&
	(
	set -x &&
	# Prepare 1st disk
	sgdisk "$HDD1" -U=$NEWHDD1GUID && # Generate new disk GUID to disable CoreOS' 1st boot setup
	sgdisk "$HDD1" -S=9 && # Increase HDD1 partition table (has image size until now)
	sgdisk "$HDD1" -d=9 -n=9:$ROOTSTART:$ROOTEND -t=9:8300 -c=9:ROOT -u=9:$ROOTGUID && # Replace CoreOS' root partition with bigger one
	sgdisk "$HDD1" -n=10:$HDD1DATASTART:$HDD1DATAEND -t=10:fd00 -c=10:raid.data.2 && # Add data RAID partition on HDD1
	sgdisk "$HDD1" -v # Verify
	) &&
	reloadPartitionTable "$HDD1" &&
	e2fsck -f "$HDD1"9 && # Check file system (must be run before resize)
	resize2fs "$HDD1"9 && # Resize ext file system within partition
#	prepareSecondaryHdd &&
#	reloadPartitionTable "$HDD2" &&
	lsblk
#	createRaid1Array
}

CONFIRMED=
if [ "$1" = '-y' ]; then
	CONFIRMED='y'
	shift
fi
set -e
	: ${HDD1:="$1"}
	: ${HDD2:="$2"}
	: ${SSH_PUBLIC_KEY:="$3"}
	: ${SSH_PUBLIC_KEY:=$(cat ~/.ssh/authorized_keys | sed -E '/^#|^\s*$/d' | tail -1)} # Use last public key in authorized_keys file as default
[ $(id -u) -eq 0 ] || (echo 'Must be run as root' >&2; false) || exit 1
[ "$HDD1" -a -e "$HDD1" ] && [ -z "$HDD2" -o -e "$HDD2" ] || (usage; false) || exit 1
[ "$SSH_PUBLIC_KEY" ] || (echo 'Missing SSHPUBLICKEY!' >&2; usage; false) || exit 1
cat <<-EOF
	CoreOS installation on
	  $HDD1 ($(diskSerialNumber $HDD1))
	  $HDD2 ($(diskSerialNumber $HDD2))
EOF
[ "$CONFIRMED" = 'y' ] || read -p "Do you want all data wiped from your disks and install CoreOS? [y|N] (Add -y to skip this prompt)" CONFIRMED
[ "$CONFIRMED" = 'y' ] || exit 1

# Install requirements
(gawk --help 2>/dev/null >/dev/null || apt-get install -y --force-yes gawk || (echo 'gawk missing' >&2; false)) && # gawk required by coreos-install

# Make sure datafs is only created if it doesn't exist
CREATEDATAFS=
if [ ! -b '/dev/md/data' ]; then
	CREATEDATAFS=createdatafs
fi

# Install CoreOS
stopRaidAndWipeDisk $HDD1 &&
reloadPartitionTable $HDD1 $HDD2 &&
createIgnitionConfigFile myhost "$SSH_PUBLIC_KEY" $CREATEDATAFS &&
writeCoreOsImageToDisk "$HDD1" ignition.json || exit 1

#if [ "$HDD2" ]; then
#	setupPartitions "$HDD1" "$HDD2" || exit 1
#fi

#injectFile "$HDD1"9 /home/core/.ssh/authorized_keys "$SSH_PUBLIC_KEY" &&
#injectFile "$HDD1"9 /etc/hostname myhost &&

echo 'Reboot and login using your public key with ssh core@hostname'

# TODO: Mirror all partitions including boot sector

