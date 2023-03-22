#!/bin/bash
set -e

# This script attempts to automate the process of bootloader and os flashing for a Radxa Rock 5B SBC 
# configured with an 1TB M.2 NVME disk mounted to the underside M key slot.
# This script has been tested running from a 64GB micro SDCARD but should work on any booted ubuntu/debian shell.

# this script can be run with a -y switch to bypass user inputs and accept defaults for unattended use.

# Radxa bootloader zero image - prepares bootloader SPI for new image
ZERO_KNOWN_MD5="ac581b250fda7a10d07ad11884a16834"
ZERO_KNOWN_MD5_UNZIPPED="2c7ab85a893283e98c931e9511add182"
ZERO_IMAGE_URL="https://dl.radxa.com/rock5/sw/images/others/zero.img.gz"
ZERO_IMAGE_FILENAME=$(basename $ZERO_IMAGE_URL)

# Radxa SPI image
BOOTLOADER_KNOWN_MD5="1b83982a5979008b4407552152732156"
BOOTLOADER_IMAGE_URL="https://github.com/huazi-yg/rock5b/releases/download/rock5b/rkspi_loader.img"
BOOTLOADER_FILENAME=$(basename $BOOTLOADER_IMAGE_URL)

# This script will chroot to the target image once written and install the following packages in addition to update/upgrade
# Modify these packages to prepare your OS how you want it.
REQUIRED_PACKAGES="curl docker.io python3 python3-pip netplan.io ufw"
PYTHON_PIP_PACKAGES="mysql.connector pillow google google.api google.cloud"

# List of required packages for this script to function
REQUIRED_PACKAGES_PREINSTALL="curl"

# OS image URL
UBUNTU_IMAGE_URL="https://github.com/radxa/debos-radxa/releases/download/20221031-1045/rock-5b-ubuntu-focal-server-arm64-20221031-1328-gpt.img.xz"
UBUNTU_IMAGE=$(basename $UBUNTU_IMAGE_URL)

# target device and partitions
# NOTE: this is designed to work with the ubuntu radxa image with 2 partitions written to an NVME disk in the M.2 M key slot on the underside of the board.
DISK=/dev/nvme0n1
BOOTPART=/dev/nvme0n1p1
ROOTPART=/dev/nvme0n1p2
target_directory=/mnt

# internet interface (onboard 2.5 ethernet)
INET_INTERFACE="enP4p65s0"
IPADDRESS=10.10.0.11/24
GATEWAY=10.10.0.1

WORKDIR=$HOME/flash
[ -d $WORKDIR ] || mkdir $WORKDIR

function confirm_overwrite() {

    if [[ $1 == "-y" ]]; then
        return
    fi

    while true; do
        read -p "Warning: this script will destroy any data on $DISK. Are you sure you want to continue? (y/n): " CONFIRM
        if [[ $CONFIRM =~ ^[Yy]$ ]]; then
	    echo "Wiping partition table on $DISK"
    	    sudo dd if=/dev/zero of=$DISK bs=512 count=1
            break
        elif [[ $CONFIRM =~ ^[Nn]$ ]]; then
            exit 0
        else
            echo "Invalid input, please enter y or n."
        fi
    done
}

function get_inputs() {

    if [[ $1 == "-y" ]]; then
        return
    fi

    read -p "Radxa zero SPI image URL [default=$ZERO_IMAGE_URL]: " NEW_ZERO_IMAGE_URL
    ZERO_IMAGE_URL=${NEW_ZERO_IMAGE_URL:-$ZERO_IMAGE_URL}

    read -p "Radxa zero SPI image MD5 (as downloaded) [default=$ZERO_KNOWN_MD5]: " NEW_ZERO_KNOWN_MD5
    ZERO_KNOWN_MD5=${NEW_ZERO_KNOWN_MD5:-$ZERO_KNOWN_MD5}

    read -p "Radxa zero SPI image MD5 (decompressed)  [default=$ZERO_KNOWN_MD5_UNZIPPED]: " NEW_ZERO_KNOWN_MD5_UNZIPPED
    ZERO_KNOWN_MD5_UNZIPPED=${NEW_ZERO_KNOWN_MD5_UNZIPPED:-$ZERO_KNOWN_MD5_UNZIPPED}

    read -p "Radxa SPI image URL [default=$BOOTLOADER_IMAGE_URL]: " NEW_BOOTLOADER_IMAGE_URL
    BOOTLOADER_IMAGE_URL=${NEW_BOOTLOADER_IMAGE_URL:-$BOOTLOADER_IMAGE_URL}

    read -p "Radxa SPI image MD5 [default=$BOOTLOADER_KNOWN_MD5]: " NEW_BOOTLOADER_KNOWN_MD5
    BOOTLOADER_KNOWN_MD5=${NEW_BOOTLOADER_KNOWN_MD5:-$BOOTLOADER_KNOWN_MD5}

    read -p "Required packages [default=$REQUIRED_PACKAGES]: " NEW_REQUIRED_PACKAGES
    REQUIRED_PACKAGES=${NEW_REQUIRED_PACKAGES:-$REQUIRED_PACKAGES}

    read -p "Python packages [default=$PYTHON_PIP_PACKAGES]: " NEW_PYTHON_PIP_PACKAGES
    PYTHON_PIP_PACKAGES=${NEW_PYTHON_PIP_PACKAGES:-$PYTHON_PIP_PACKAGES}

    read -p "OS image URL [default=$UBUNTU_IMAGE_URL]: " NEW_UBUNTU_IMAGE_URL
    UBUNTU_IMAGE_URL=${NEW_UBUNTU_IMAGE_URL:-$UBUNTU_IMAGE_URL}

    echo "Do you want to install a custom kernel? [y/N]: "
    read custom_kernel_response
	if [[ "$custom_kernel_response" =~ ^[Yy]$ ]]; then
 		echo "Enter the path or URL of the custom kernel package:"
  		read custom_kernel

  		echo "Enter the path or URL of the kernel headers package (optional):"
 		read kernel_headers

  		echo "Enter the path or URL of the kernel libc-dev package (optional):"
  		read kernel_libc_dev
	else
  		custom_kernel=""
  		kernel_headers=""
  		kernel_libc_dev=""
	fi

    read -p "Target device and partitions [default=$DISK]: " NEW_DISK
    DISK=${NEW_DISK:-$DISK}

    read -p "Boot partition [default=$BOOTPART]: " NEW_BOOTPART
    BOOTPART=${NEW_BOOTPART:-$BOOTPART}

    read -p "Root partition [default=$ROOTPART]: " NEW_ROOTPART
    ROOTPART=${NEW_ROOTPART:-$ROOTPART}

    read -p "Internet interface [default=$INET_INTERFACE]: " NEW_INET_INTERFACE
    INET_INTERFACE=${NEW_INET_INTERFACE:-$INET_INTERFACE}

    # autoassign filename variables
    ZERO_IMAGE_FILENAME=$(basename $ZERO_IMAGE_URL)
    BOOTLOADER_FILENAME=$(basename $BOOTLOADER_IMAGE_URL)
    UBUNTU_IMAGE=$(basename $UBUNTU_IMAGE_URL)

    # get IP address and gateway information
    read -p "Do you want to use DHCP? (y/n): " USE_DHCP

    if [[ $USE_DHCP =~ ^[Yy]$ ]]; then
       # use DHCP
       IPADDRESS="dhcp"
       GATEWAY="dhcp"
    else
       # get and validate IP
       ip_regex="^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$"
       while true; do
           read -p "Enter an IP address in slash notation [defualt=$IPADDRESS]: " NEW_IPADDRESS
             if [[ $NEW_IPADDRESS =~ $ip_regex ]]; then
		IPADDRESS=${NEW_IPADDRESS:-$IPADDRESS}
                break
             else
                echo "Invalid IP format, re-enter"
             fi
       done

    # get and validate GATEWAY
    gw_regex="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
    while true; do
         read -p "Gateway IP address [default=$GATEWAY]: " NEW_GATEWAY
         if [[ $NEW_GATEWAY =~ $gw_regex ]]; then
	     GATEWAY=${NEW_GATEWAY:-$GATEWAY}
             break
         else
             echo "Invalid IP format, re-enter"
         fi
    done
    fi
}

function confirm_variables() {


    echo "The following variables will be used:"
    echo "ZERO_IMAGE_URL=$ZERO_IMAGE_URL"
    echo "BOOTLOADER_IMAGE_URL=$BOOTLOADER_IMAGE_URL"
    echo "REQUIRED_PACKAGES=$REQUIRED_PACKAGES"
    echo "PYTHON_PIP_PACKAGES=$PYTHON_PIP_PACKAGES"
    echo "UBUNTU_IMAGE_URL=$UBUNTU_IMAGE_URL"
    echo "DISK=$DISK"
    echo "BOOTPART=$BOOTPART"
    echo "ROOTPART=$ROOTPART"
    echo "INET_INTERFACE=$INET_INTERFACE"
    
    
    if [[ $1 == "-y" ]]; then
	sleep 5
        return
    fi

    while true; do
        read -p "Do you want to proceed? (y/n): " CONFIRM
        if [[ $CONFIRM =~ ^[Yy]$ ]]; then
            break
        elif [[ $CONFIRM =~ ^[Nn]$ ]]; then
            exit 0
        else
            echo "Invalid input, please enter y or n."
        fi
    done
}


function update_packages() {
	echo "Caching sudo, default credentials are rock/rock"
	sudo -v

	echo "Updating repositories and fixing broken radxa public key"
	export DISTRO=focal-stable
	wget -O - apt.radxa.com/$DISTRO/public.key | sudo apt-key add -
	sudo apt update -y
	echo "Grabbing required packages"
	sudo apt install $REQUIRED_PACKAGES_PREINSTALL -y
}

function flash_spi() {
	echo "Grabbing bootload zero fill file (reset SPI)"
	wget -O $WORKDIR/$ZERO_IMAGE_FILENAME $ZERO_IMAGE_URL

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
	wget -O $WORKDIR/$BOOTLOADER_FILENAME $BOOTLOADER_IMAGE_URL
	echo "Verifying MD5 sum"
	BOOTLOADER_MD5=$(md5sum "$WORKDIR/$BOOTLOADER_FILENAME" |  awk '{print $1}')
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
	sudo dd if=$WORKDIR/$BOOTLOADER_FILENAME of=/dev/mtdblock0
	sync
	SPI_BLOCK_MD5=$(sudo md5sum "/dev/mtdblock0" | awk '{print $1}')
	echo "$SPI_BLOCK_MD5" | od -c
	echo "$BOOTLOADER_KNOWN_MD5" | od -c
	[ "$SPI_BLOCK_MD5" == "$BOOTLOADER_KNOWN_MD5" ] || { echo "MD5 $WORKDIR/$BOOTLOADER_FILENAME differs from /dev/mtdblock0, exiting"; exit 1; }

	echo "Flash complete.  This device should now boot from a bootable M.2 PCIE drive"
}

function install_os() {
	echo "Installing operating system"
	echo "Checking for M.2 block device"
	[ -b $DISK ] || { echo "Unable to locate $DISK, exiting"; exit 1; }
	echo "Found $DISK"
	sudo fdisk -l $DISK

	echo "Nice, downloading operating system"
	wget -O $WORKDIR/$UBUNTU_IMAGE $UBUNTU_IMAGE_URL
	echo "Super, writing operating system to disk"
	sudo xzcat $WORKDIR/$UBUNTU_IMAGE | sudo dd of=$DISK bs=1M status=progress

	echo "Fixing partitions to 100% of usable space"
sudo gdisk $DISK <<EOF
x
e
w
Y	
Y
EOF
sudo parted $DISK --script -- resizepart 2 100%
sudo e2fsck -f $ROOTPART
sudo resize2fs $ROOTPART
echo "Drive fixed up, finished installing OS"
}

function customize_os() {
echo "Mounting chroot envionment"
sudo mount $ROOTPART /mnt
sudo mount $BOOTPART /mnt/boot
sudo mount --bind /dev /mnt/dev
sudo mount --bind /dev/pts /mnt/dev/pts
sudo mount --bind /proc /mnt/proc
sudo mount --bind /sys /mnt/sys

echo "Chrooting to configure target operating system"
sudo chroot /mnt /bin/bash <<EOF
export DISTRO=focal-stable
wget -O - apt.radxa.com/$DISTRO/public.key | sudo apt-key add -
sudo apt update -y
sudo apt upgrade -y
sudo apt install $REQUIRED_PACKAGES -y
python3 -m pip install $PYTHON_PIP_PACKAGES

if [ "$IPADDRESS" = "dhcp" ]; then
  cat <<EOB > /etc/netplan/01-dhcp.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    $INET_INTERFACE:
      dhcp4: yes
EOB
else
  cat <<EOB > /etc/netplan/01-static-ip.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    $INET_INTERFACE:
      addresses:
        - $IPADDRESS
      gateway4: $GATEWAY
EOB
fi

systemctl enable docker.service
mkdir /mnt/boot
cp -av /boot/* /mnt/boot/
sed -i '/\/boot/s|.*|$BOOTPART /boot ext4 defaults 0 2|' /etc/fstab
EOF

echo "reformatting boot partition to ext4"
echo "NOTE: this is a hack until images are fixed"
sudo umount /mnt/boot
sudo mkfs.ext4 -F $BOOTPART
sudo mount $BOOTPART /mnt/boot
sudo cp -av /mnt/mnt/boot/* /mnt/boot

if [[ -n "$kernel_package" ]]; then
    cp "$kernel_package" "${target_directory}/mnt/$(basename "$kernel_package")"
    chroot "$target_directory" /bin/bash -c "dpkg -i /mnt/$(basename "$kernel_package")"
    rm "${target_directory}/mnt/$(basename "$kernel_package")"
fi

if [[ -n "$kernel_headers" ]]; then
    cp "$kernel_headers" "${target_directory}/mnt/$(basename "$kernel_headers")"
    chroot "$target_directory" /bin/bash -c "dpkg -i /mnt/$(basename "$kernel_headers")"
    rm "${target_directory}/mnt/$(basename "$kernel_headers")"
fi

if [[ -n "$kernel_libc_dev" ]]; then
    cp "$kernel_libc_dev" "${target_directory}/mnt/$(basename "$kernel_libc_dev")"
    chroot "$target_directory" /bin/bash -c "dpkg -i /mnt/$(basename "$kernel_libc_dev")"
    rm "${target_directory}/mnt/$(basename "$kernel_libc_dev")"
fi

}

function clean() {
echo "unmounting chroot"
sudo umount /mnt/dev/pts
sudo umount /mnt/dev
sudo umount /mnt/proc
sudo umount /mnt/sys
sudo umount /mnt/boot
sudo umount /mnt
rm -Rf $WORKDIR

echo "target operating system updated, shut the board down, remove the SDCARD, and reboot"
if [ "$IPADDRESS" = "dhcp" ]; then
  echo "your system will be accessible via DHCP assigned IP"
else
  echo "your system will be accessible via SSH on IP: [ $IPADDRESS ]"
fi
echo "default credentials - user: rock password: rock"
}

get_inputs
confirm_variables
confirm_overwrite
update_packages
flash_spi
install_os
customize_os
clean

