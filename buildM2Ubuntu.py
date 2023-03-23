import os
import re
import sys
import hashlib
import requests
import subprocess
from urllib.parse import urlparse
from pathlib import Path
from getpass import getpass

ZERO_KNOWN_MD5 = "ac581b250fda7a10d07ad11884a16834"
ZERO_KNOWN_MD5_UNZIPPED = "2c7ab85a893283e98c931e9511add182"
ZERO_IMAGE_URL = "https://dl.radxa.com/rock5/sw/images/others/zero.img.gz"
ZERO_IMAGE_FILENAME = os.path.basename(ZERO_IMAGE_URL)

BOOTLOADER_KNOWN_MD5 = "1b83982a5979008b4407552152732156"
BOOTLOADER_IMAGE_URL = "https://github.com/huazi-yg/rock5b/releases/download/rock5b/rkspi_loader.img"
BOOTLOADER_FILENAME = os.path.basename(BOOTLOADER_IMAGE_URL)

REQUIRED_PACKAGES = "curl docker.io python3 python3-pip netplan.io ufw"
PYTHON_PIP_PACKAGES = "mysql.connector pillow google google.api google.cloud"

REQUIRED_PACKAGES_PREINSTALL = "curl"

UBUNTU_IMAGE_URL = "https://github.com/radxa/debos-radxa/releases/download/20221031-1045/rock-5b-ubuntu-focal-server-arm64-20221031-1328-gpt.img.xz"
UBUNTU_IMAGE = os.path.basename(UBUNTU_IMAGE_URL)

DISK = "/dev/nvme0n1"
BOOTPART = "/dev/nvme0n1p1"
ROOTPART = "/dev/nvme0n1p2"
TARGET_DIRECTORY = "/mnt"

INET_INTERFACE = "enP4p65s0"
IPADDRESS = "10.10.0.11/24"
GATEWAY = "10.10.0.1"

custom_kernel = ""
kernel_headers = ""
kernel_libc_dev = ""


WORKDIR = os.path.join(os.path.expanduser("~"), "flash")

def confirm_overwrite(auto=False):
    if auto:
        return
    # ...

def get_inputs(accept_defaults=False):
    if not accept_defaults:
        global ZERO_IMAGE_URL, ZERO_KNOWN_MD5, ZERO_KNOWN_MD5_UNZIPPED
        global BOOTLOADER_IMAGE_URL, BOOTLOADER_KNOWN_MD5
        global REQUIRED_PACKAGES, PYTHON_PIP_PACKAGES
        global UBUNTU_IMAGE_URL, DISK, BOOTPART, ROOTPART, INET_INTERFACE
        global IPADDRESS, GATEWAY

        ZERO_IMAGE_URL = input(f"Radxa zero SPI image URL [default={ZERO_IMAGE_URL}]: ") or ZERO_IMAGE_URL
        ZERO_KNOWN_MD5 = input(f"Radxa zero SPI image MD5 (as downloaded) [default={ZERO_KNOWN_MD5}]: ") or ZERO_KNOWN_MD5
        ZERO_KNOWN_MD5_UNZIPPED = input(f"Radxa zero SPI image MD5 (decompressed) [default={ZERO_KNOWN_MD5_UNZIPPED}]: ") or ZERO_KNOWN_MD5_UNZIPPED
        BOOTLOADER_IMAGE_URL = input(f"Radxa SPI image URL [default={BOOTLOADER_IMAGE_URL}]: ") or BOOTLOADER_IMAGE_URL
        BOOTLOADER_KNOWN_MD5 = input(f"Radxa SPI image MD5 [default={BOOTLOADER_KNOWN_MD5}]: ") or BOOTLOADER_KNOWN_MD5
        REQUIRED_PACKAGES = input(f"Required packages [default={REQUIRED_PACKAGES}]: ") or REQUIRED_PACKAGES
        PYTHON_PIP_PACKAGES = input(f"Python packages [default={PYTHON_PIP_PACKAGES}]: ") or PYTHON_PIP_PACKAGES
        UBUNTU_IMAGE_URL = input(f"OS image URL [default={UBUNTU_IMAGE_URL}]: ") or UBUNTU_IMAGE_URL

        custom_kernel_response = input("Do you want to install a custom kernel? [y/N]: ")
        if custom_kernel_response.lower() == "y":
            custom_kernel = input("Enter the path or URL of the custom kernel package: ")
            kernel_headers = input("Enter the path or URL of the kernel headers package (optional): ")
            kernel_libc_dev = input("Enter the path or URL of the kernel libc-dev package (optional): ")
        else:
            custom_kernel = ""
            kernel_headers = ""
            kernel_libc_dev = ""

        DISK = input(f"Target device and partitions [default={DISK}]: ") or DISK
        BOOTPART = input(f"Boot partition [default={BOOTPART}]: ") or BOOTPART
        ROOTPART = input(f"Root partition [default={ROOTPART}]: ") or ROOTPART
        INET_INTERFACE = input(f"Internet interface [default={INET_INTERFACE}]: ") or INET_INTERFACE

        USE_DHCP = input("Do you want to use DHCP? (y/n): ")

        if USE_DHCP.lower() == "y":
            IPADDRESS = "dhcp"
            GATEWAY = "dhcp"
        else:
            while True:
                new_ipaddress = input(f"Enter an IP address in slash notation [default={IPADDRESS}]: ") or IPADDRESS
                if re.match(r"^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$", new_ipaddress):
                    IPADDRESS = new_ipaddress
                    break
                else:
                    print("Invalid IP format, re-enter")

            while True:
                new_gateway = input(f"Gateway IP address [default={GATEWAY}]: ") or GATEWAY
                if re.match(r"^([0-9]{1,3}\.){3}[0-9]{1,3}$", new_gateway):
                    GATEWAY = new_gateway
                    break
                else:
                    print("Invalid IP format, re-enter")

def confirm_variables(auto):
    if not auto:
        print("Please confirm the following values:")
        print(f"Zero SPI image URL: {ZERO_IMAGE_URL}")
        print(f"Zero SPI image MD5 (as downloaded): {ZERO_KNOWN_MD5}")
        print(f"Zero SPI image MD5 (decompressed): {ZERO_KNOWN_MD5_UNZIPPED}")
        print(f"Bootloader SPI image URL: {BOOTLOADER_IMAGE_URL}")
        print(f"Bootloader SPI image MD5: {BOOTLOADER_KNOWN_MD5}")
        print(f"Required packages: {REQUIRED_PACKAGES}")
        print(f"Python packages: {PYTHON_PIP_PACKAGES}")
        print(f"Ubuntu OS image URL: {UBUNTU_IMAGE_URL}")
        print(f"Target device and partitions: {DISK}")
        print(f"Boot partition: {BOOTPART}")
        print(f"Root partition: {ROOTPART}")
        print(f"Internet interface: {INET_INTERFACE}")
        print(f"IP address: {IPADDRESS}")
        print(f"Gateway: {GATEWAY}")
        print(f"Custom kernel: {custom_kernel}")
        print(f"Kernel headers: {kernel_headers}")
        print(f"Kernel libc-dev: {kernel_libc_dev}")
        confirm_response = input("Are these values correct? (y/n): ")
        return confirm_response.lower() == 'y'
    else:
        pass

def update_packages():
    print("Updating repositories and fixing broken radxa public key")
    distro = "focal-stable"
    subprocess.run(["wget", "-O", "-", f"apt.radxa.com/{distro}/public.key"], capture_output=True, check=True)
    subprocess.run(["apt-key", "add", "-"], capture_output=True, check=True)
    subprocess.run(["apt", "update", "-y"], capture_output=True, check=True)
    print("Grabbing required packages")
    subprocess.run(["apt", "install"] + REQUIRED_PACKAGES_PREINSTALL.split() + ["-y"], capture_output=True, check=True)

def download_file(url, save_path):
    response = requests.get(url, stream=True)
    response.raise_for_status()
    with open(save_path, 'wb') as f:
        for chunk in response.iter_content(chunk_size=8192):
            f.write(chunk)
    return save_path

def md5sum(file_path):
    hash_md5 = hashlib.md5()
    with open(file_path, "rb") as f:
        for chunk in iter(lambda: f.read(4096), b""):
            hash_md5.update(chunk)
    return hash_md5.hexdigest()

def flash_spi():
    print("Grabbing bootloader zero fill file (recommended prior to SPI reflash)")
    subprocess.run(["wget", "-O", f"{WORKDIR}/{ZERO_IMAGE_FILENAME}", ZERO_IMAGE_URL], check=True)

    zero_md5 = subprocess.run(["md5sum", f"{WORKDIR}/zero.img.gz"], capture_output=True, check=True, text=True).stdout.split()[0]
    if zero_md5 != ZERO_KNOWN_MD5:
        print("MD5 values do not match, halting")
        exit(1)

    print("MD5 sum matched, unpacking and testing again")
    subprocess.run(["gzip", "-vd", f"{WORKDIR}/zero.img.gz"], check=True)

    zero_md5_unzipped = subprocess.run(["md5sum", f"{WORKDIR}/zero.img"], capture_output=True, check=True, text=True).stdout.split()[0]
    if zero_md5_unzipped != ZERO_KNOWN_MD5_UNZIPPED:
        print("MD5 values do not match, halting")
        exit(1)

    print("MD5 matches, proceeding with bootloader")
    subprocess.run(["wget", "-O", f"{WORKDIR}/{BOOTLOADER_FILENAME}", BOOTLOADER_IMAGE_URL], check=True)

    bootloader_md5 = subprocess.run(["md5sum", f"{WORKDIR}/{BOOTLOADER_FILENAME}"], capture_output=True, check=True, text=True).stdout.split()[0]
    if bootloader_md5 != BOOTLOADER_KNOWN_MD5:
        print("MD5 values do not match, halting")
        exit(1)

    print("MD5 verification successful, proceeding with flash")
    if not os.path.exists("/dev/mtdblock0"):
        print("No flash block device found, halting")
        exit(1)

    print("Found: /dev/mtdblock0, flashing zero.img (this takes approximately 193 seconds)...")
    subprocess.run(["dd", f"if={WORKDIR}/zero.img", "of=/dev/mtdblock0"], check=True)

    block_md5 = subprocess.run(["md5sum", "/dev/mtdblock0"], capture_output=True, check=True, text=True).stdout.split()[0]
    if block_md5 != zero_md5_unzipped:
        print("MD5 of zero.img differs from /dev/mdtblock0, exiting")
        exit(1)

    print("MD5 validated, flashing m.2 enabled bootloader (this also takes approximately 193 seconds)...")
    subprocess.run(["dd", f"if={WORKDIR}/{BOOTLOADER_FILENAME}", "of=/dev/mtdblock0"], check=True)

    subprocess.run(["sync"], check=True)

    spi_block_md5 = subprocess.run(["md5sum", "/dev/mtdblock0"], capture_output=True, check=True, text=True).stdout.split()[0]
    if spi_block_md5 != BOOTLOADER_KNOWN_MD5:
        print("MD5 of bootloader differs from /dev/mtdblock0, exiting")
        exit(1)

    print("Flash complete. This device should now boot from a bootable M.2 PCIE drive")

def install_os():
    print("Installing operating system")
    print("Checking for M.2 block device")
    if not os.path.exists(DISK):
        print(f"Unable to locate {DISK}, exiting")
        exit(1)

    print(f"Found {DISK}")
    subprocess.run(["fdisk", "-l", DISK], check=True)

    print("Nice, downloading operating system")
    subprocess.run(["wget", "-O", f"{WORKDIR}/{UBUNTU_IMAGE}", UBUNTU_IMAGE_URL], check=True)

    print("Super, writing operating system to disk")
    with subprocess.Popen(["xzcat", f"{WORKDIR}/{UBUNTU_IMAGE}"], stdout=subprocess.PIPE) as xzcat_process:
        subprocess.run(["dd", f"of={DISK}", "bs=1M", "status=progress"], stdin=xzcat_process.stdout, check=True)

    print("Fixing partitions to 100% of usable space")
    gdisk_commands = "x\ne\nw\nY\nY\n"
    subprocess.run(["gdisk", DISK], input=gdisk_commands, text=True, check=True)

    subprocess.run(["parted", DISK, "--script", "--", "resizepart", "2", "100%"], check=True)
    subprocess.run(["e2fsck", "-f", ROOTPART], check=True)
    subprocess.run(["resize2fs", ROOTPART], check=True)

    print("Drive fixed up, finished installing OS")

def customize_os():
    print("Mounting chroot environment")
    subprocess.run(["mount", ROOTPART, "/mnt"], check=True)
    subprocess.run(["mount", BOOTPART, "/mnt/boot"], check=True)
    subprocess.run(["mount", "--bind", "/dev", "/mnt/dev"], check=True)
    subprocess.run(["mount", "--bind", "/dev/pts", "/mnt/dev/pts"], check=True)
    subprocess.run(["mount", "--bind", "/proc", "/mnt/proc"], check=True)
    subprocess.run(["mount", "--bind", "/sys", "/mnt/sys"], check=True)

    print("Chrooting to configure target operating system")
    chroot_script = f"""\
export DISTRO=focal-stable
wget -O - apt.radxa.com/$DISTRO/public.key | apt-key add -
apt update -y
apt upgrade -y
apt install {REQUIRED_PACKAGES} -y
python3 -m pip install {PYTHON_PIP_PACKAGES}
if [ "{{IPADDRESS}}" = "dhcp" ]; then
  cat <<EOB > /etc/netplan/01-dhcp.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    {{INET_INTERFACE}}:
      dhcp4: yes
EOB
else
  cat <<EOB > /etc/netplan/01-static-ip.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    {INET_INTERFACE}:
      addresses:
        - {IPADDRESS}
      gateway4: {GATEWAY}
EOB
fi
systemctl enable docker.service
mkdir /mnt/boot
cp -av /boot/* /mnt/boot/
sed -i '/\\/boot/s|.*|{BOOTPART} /boot ext4 defaults 0 2|' /etc/fstab
"""
    subprocess.run(["chroot", "/mnt", "/bin/bash"], input=chroot_script, text=True, check=True)

    print("Reformatting boot partition to ext4")
    print("NOTE: this is a hack until images are fixed")
    subprocess.run(["umount", "/mnt/boot"], check=True)
    subprocess.run(["mkfs.ext4", "-F", BOOTPART], check=True)
    subprocess.run(["mount", BOOTPART, "/mnt/boot"], check=True)
    subprocess.run(["cp", "-av", "/mnt/mnt/boot/*", "/mnt/boot"], check=True)

    # Add your logic for handling the kernel_package, kernel_headers, and kernel_libc_dev variables
    # similar to the bash script

    # Handle kernel_package
    if kernel_package:
        kernel_package_basename = os.path.basename(kernel_package)
        subprocess.run(["cp", kernel_package, f"/mnt/{kernel_package_basename}"], check=True)
        subprocess.run(["chroot", "/mnt", "/bin/bash", "-c", f"dpkg -i /{kernel_package_basename}"], check=True)
        subprocess.run(["rm", f"/mnt/{kernel_package_basename}"], check=True)

    # Handle kernel_headers
    if kernel_headers:
        kernel_headers_basename = os.path.basename(kernel_headers)
        subprocess.run(["cp", kernel_headers, f"/mnt/{kernel_headers_basename}"], check=True)
        subprocess.run(["chroot", "/mnt", "/bin/bash", "-c", f"dpkg -i /{kernel_headers_basename}"], check=True)
        subprocess.run(["rm", f"/mnt/{kernel_headers_basename}"], check=True)

    if kernel_libc_dev:
        kernel_libc_dev_basename = os.path.basename(kernel_libc_dev)
        subprocess.run(["cp", kernel_libc_dev, f"/mnt/{kernel_libc_dev_basename}"], check=True)
        subprocess.run(["chroot", "/mnt", "/bin/bash", "-c", f"dpkg -i /{kernel_libc_dev_basename}"], check=True)
        subprocess.run(["rm", f"/mnt/{kernel_libc_dev_basename}"], check=True)

def main():
    auto = '-y' in sys.argv

    confirm_overwrite(auto)
    get_inputs(auto)
    confirm_variables(auto)

    update_packages()
    flash_spi()
    install_os()
    customize_os()

if __name__ == '__main__':
    main()
