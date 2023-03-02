#!/bin/bash
ZERO_KNOWN_MD5="ac581b250fda7a10d07ad11884a16834"
ZERO_KNOWN_MD5_UNZIPPED="2c7ab85a893283e98c931e9511add182"
BOOTLOADER_KNOWN_MD5="46de85de37b8e670883e6f6a8bb95776"
REQUIRED_PACKAGES="curl"

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

	ZERO_MD5=`md5sum $WORKDIR/zero.img.gz`
	echo "downloaded: $ZERO_MD5 known: $ZERO_KNOWN_MD5"
	[ "$ZERO_MD5" == "$ZERO_KNOWN_MD5" ] || { echo "MD5 values do not match, halting"; exit 1; }
	echo "MD5 sum matched, unpacking and testing again"

	gzip -vd $WORKDIR/zero.img.gz
	ZERO_MD5_UNZIPPED=`md5sum $WORKDIR/zero.img`
	[ "$ZERO_MD5_UNZIPED" == "$ZERO_KNOWN_MD5_UNZIPPED" ] || { echo "MD5 values do not match, halting"; exit 1; }
	echo "MD5 matches, proceeding with bootloader"

	echo "Grabbing bootloader"
	wget -O $WORKDIR/rock-5b-spi-image-g49da44e116d.img https://dl.radxa.com/rock5/sw/images/loader/rock-5b/release/rock-5b-spi-image-g49da44e116d.img
	echo "Verifying MD5 sum"
	BOOTLOADER_MD5=`md5sum $WORKDIR/rock-5b-spi-image-g49da44e116d.img`
	[ "$BOOTLOADER_MD5" == "$BOOTLOADER_KNOWN_MD5" ] || { echo "MD5 values do not match, halting"; exit 1; }

	echo "MD5 verification successful, proceeding with flash"
}

update_packages
flash_spi
