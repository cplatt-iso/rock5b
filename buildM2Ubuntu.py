import os
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

def confirm_variables():
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

def update_packages(required_packages_preinstall, distro="focal-stable"):
    print("Caching sudo, default credentials are rock/rock")
    subprocess.run(["sudo", "-v"])

    print("Updating repositories and fixing broken radxa public key")
    subprocess.run(["wget", "-O", "-", f"apt.radxa.com/{distro}/public.key"], stdout=subprocess.PIPE)
    subprocess.run(["sudo", "apt-key", "add", "-"])
    subprocess.run(["sudo", "apt", "update", "-y"])

    print("Grabbing required packages")
    subprocess.run(["sudo", "apt", "install"] + required_packages_preinstall.split() + ["-y"])

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
    # ...

def install_os():
    # ...

def customize_os():
    # ...

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
