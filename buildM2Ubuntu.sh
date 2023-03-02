#!/bin/bash
ZERO_KNOWN_MD5="ac581b250fda7a10d07ad11884a16834"
ZERO_KNOWN_MD5_UNZIPPED="2c7ab85a893283e98c931e9511add182"
BOOTLOADER_KNOWN_MD5="46de85de37b8e670883e6f6a8bb95776"
REQUIRED_PACKAGES="curl"
UBUNTU_IMAGE_URL="https://github.com/radxa/debos-radxa/releases/download/20221031-1045/rock-5b-ubuntu-focal-server-arm64-20221031-1328-gpt.img.xz"
UBUNTU_IMAGE="rock-5b-ubuntu-focal-server-arm64-20221031-1328-gpt.img.xz"

WORKDIR=$HOME/flash
[ -d $WORKDIR ] || mkdir $WORKDIR

function update_packages() {
	echo "Caching sudo, default credentials are rock/rock"
	sudo -v

	echo "Updating repositories and fixing broken radxa public key"
	export DISTRO=focal-stable
	wget -O - apt.radxa.com/$DISTRO/public.key | sudo apt-key add -
	sudo apt update -y
	echo "Grabbing required packages"
	sudo apt install $REQUIRED_PACKAGES -y
}

function flash_spi() {
	echo "Grabbing bootload zero fill file (reset SPI)"
	wget -O $WORKDIR/zero.img.gz https://dl.radxa.com/rock5/sw/images/others/zero.img.gz

	ZERO_MD5=$(md5sum "$WORKDIR/zero.img.gz" | awk '{print $1}')
	echo "$ZERO_MD5" | od -c
	echo "$ZERO_KNOWN_MD5" | od -c
	[ "$ZERO_MD5" == "$ZERO_KNOWN_MD5" ] || { echo "MD5 values do not match, halting"; exit 1; }
	echo "MD5 sum matched, unpacking and testing again"

	gzip -vd $WORKDIR/zero.img.gz
	ZERO_MD5_UNZIPPED=$(md5sum "$WORKDIR/zero.img" |  awk '{print $1}')
	echo "$ZERO_MD5_UNZIPPED" | od -c
	echo "$ZERO_KNOWN_MD5_UNZIPPED" | od -c
	[ "$ZERO_MD5_UNZIPPED" == "$ZERO_KNOWN_MD5_UNZIPPED" ] || { echo "MD5 values do not match, halting"; exit 1; }
	echo "MD5 matches, proceeding with bootloader"

	echo "Grabbing bootloader"
	wget -O $WORKDIR/rock-5b-spi-image-g49da44e116d.img https://dl.radxa.com/rock5/sw/images/loader/rock-5b/release/rock-5b-spi-image-g49da44e116d.img
	echo "Verifying MD5 sum"
	BOOTLOADER_MD5=$(md5sum "$WORKDIR/rock-5b-spi-image-g49da44e116d.img" |  awk '{print $1}')
	echo "$BOOTLOADER_MD5" | od -c
	echo "$BOOTLOADER_KNOWN_MD5" | od -c
	[ "$BOOTLOADER_MD5" == "$BOOTLOADER_KNOWN_MD5" ] || { echo "MD5 values do not match, halting"; exit 1; }

	echo "MD5 verification successful, proceeding with flash"

	echo "Checking for flash block device"
	[ -b /dev/mtdblock0 ] || { echo "No flash block device found, halting"; exit 1; }
	echo "Found: /dev/mtdblock0, flashing zero.img (this takes approximately 193 seconds)..."
	sudo dd if=$WORKDIR/zero.img of=/dev/mtdblock0
	BLOCK_MD5=$(sudo md5sum "/dev/mtdblock0" | awk '{print $1}')
	echo "Validating md5"
	echo "$BLOCK_MD5" | od -c
	echo "$ZERO_MD5_UNZIPPED" | od -c
	[ "$BLOCK_MD5" == "$ZERO_MD5_UNZIPPED" ] || { echo "MD5 of zero.img differs from /dev/mdtblock0, exiting"; exit 1; }

	echo "MD5 validated, flashing m.2 enabled bootloader (this also takes approximately 193 seconds)..."
	sudo dd if=$WORKDIR/rock-5b-spi-image-g49da44e116d.img of=/dev/mtdblock0
	sync
	SPI_BLOCK_MD5=$(sudo md5sum "/dev/mtdblock0" | awk '{print $1}')
	echo "$SPI_BLOCK_MD5" | od -c
	echo "$BOOTLOADER_KNOWN_MD5" | od -c
	[ "$SPI_BLOCK_MD5" == "$BOOTLOADER_KNOWN_MD5" ] || { echo "MD5 $WORKDIR/rock-5b-spi-image-g49da44e116d.img differs from /dev/mtdblock0, exiting"; exit 1; }

	echo "Flash complete.  This device should now boot from a bootable M.2 PCIE drive"
}

function install_os() {
	echo "Installing operating system"
	echo "Checking for M.2 block device"
	[ -b /dev/nvme0n1 ] || { echo "Unable to locate /dev/nvme0n1, exiting"l exit 1; }
	echo "Found /dev/nvme0n1"
	sudo fdisk -l /dev/nvme0n1

	echo "Nice, downloading operating system"
	wget -O $WORKDIR/$UBUNTU_IMAGE $UBUNTU_IMAGE_URL
	echo "Super, writing operating system to disk"
	sudo xzcat $WORKDIR/$UBUNTU_IMAGE | dd of=/dev/nvme0n1 bs=1M status=progress

	echo "Congratulations, the OS is written to disk"
}

#update_packages
#flash_spi
install_os


