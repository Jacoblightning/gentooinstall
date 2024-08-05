#!/bin/bash

echo "Starting tests..."

echo "Confirming architecture..."
if [ $(uname -m) != 'x86_64' ]; then
    echo "This script only works on amd64"
    exit
fi

echo "Testing internet..."
if ping -c 3 1.1.1.1 > /dev/null 2>&1; then
    echo "Internet works"
else
    echo "Internet does not work. Please fix this and rerun the script"
    exit
fi

echo "Testing DNS..."

if ping -c 3 google.com;then #curl --location gentoo.org --output /dev/null > /dev/null 2>&1; then
    echo "DNS Works"
else
    echo "DNS does not work. Please fix this and rerun the script"
    exit
fi

echo "Starting Gentoo Install..."

echo "Please enter the path of the disk to install on. Options:"
lsblk -do PATH,SIZE -e7 -e 254
read -p "Is your device listed? (Y/N): " confirm
if [[ $confirm == [yY] || $confirm == [yY][eE][sS] ]]; then
    read -p "PLease enter the path of the device to install on: " installto
    if [ -e "$installto" ] && [ ! -f "$installto" ] && [ ! -d "$installto" ]; then echo; else
        echo "Device not found. Please re-run script."
        exit
    fi
    read -p "This device will be erased. Ok? (Y/N): " confirm
    if [[ $confirm == [yY] || $confirm == [yY][eE][sS] ]]; then
        echo "Great."
    else
        echo "Please re-run script to select another device."
        exit
    fi
else
    echo "Sorry, please plug in the device and re-run the script."
    exit 1
fi

if [[ "$installto" == *"nvme"* ]]; then
    drivepref="${installto}p"
else
    drivepref="${installto}"
fi

echo "Checking boot mode and creating filesystem..."
if [ -d /sys/firmware/efi ]; then
    echo "Booted in UEFI mode. Installing UEFI system."
    curl "https://raw.githubusercontent.com/Jacoblightning/gentooinstall/main/uefi_gpt.txt" | sfdisk --wipe always "$installto"
    mkfs.vfat -F 32 "${drivepref}1"
    mkdir --parents /mnt/gentoo/efi
else
    echo "Booted in BIOS mode. Installing BIOS system."
    curl "https://raw.githubusercontent.com/Jacoblightning/gentooinstall/main/bios_mbr.txt" | sfdisk --wipe always "$installto"
    mkfs.xfs "${drivepref}1"
    mkdir --parents /mnt/gentoo
fi

echo "Finalizing filesystem..."
mkfs.xfs "${drivepref}3"
mkswap "${drivepref}2"
swapon "${drivepref}2"

echo "Mounting system"
mount "${drivepref}3" /mnt/gentoo

cd /mnt/gentoo

echo "Correcting system clock..."
chronyd -q

clear

echo "First, Choose your init system."

PS3="Select your system: "

select initsystem in openrc systemd
do
    break
done

clear

echo "${initsystem}, great choice. Now select your System Type"

systypes=('server' 'desktop' 'server-hardened')
select systype in "${systypes[@]}"
do
    break
done

clear

mirrors=("gentoo.osuosl.org" "distfiles.gentoo.org")
gentoopart="/releases/amd64/autobuilds"
startpart="/current-stage3-amd64-"

declare -A systems

systems['openrc-desktop']="desktop-openrc"
systems['systemd-desktop']="desktop-systemd"
systems['openrc-server']="openrc"
systems['systemd-server']="systemd"
systems['openrc-server-hardened']="hardened-openrc"
systems['systemd-server-hardened']="hardened-systemd"

echo "Testing Mirrors..."

for mirror in "${mirrors[@]}"; do
    ping -c 3 "$mirror" && usemirror="$mirror" && break
done

if [ -z "$usemirror" ]; then
    echo "All mirrors were down. Please enter the url of a working mirror."
    read -p "Url: " usemirror
    
    echo "Checking mirror..."
    
    if ping -c 3 "$usemirror";then echo; else
        echo "Mirror failed. Install the rest yourself (Too far in to restart script.)"
    fi
fi

echo "Using mirror $usemirror"

sysindex="${initsystem}-${systype}"

url="https://${usemirror}${gentoopart}${startpart}${systems[$sysindex]}/"

echo "Finding newest version"

# Dumb magic
filename=$(curl $url | grep -oE '"stage3-amd64.*?.tar.xz"' | grep --color=none -oE "s.*z")

newest="${url}${filename}"

echo "Newest file is $newest"

wget "$newest"

echo "Preparing to verify integrity"

wget "${newest}.sha256"
wget "${newest}.DIGESTS"
wget "${newest}.asc"

echo "Checking file integrity"

if sha256sum --check "${filename}.sha256"; then
    echo "Sha256 passed."
else
    echo "Sha256 failed. Exiting"
    exit
fi

if cat "${filename}.DIGESTS" | grep --color=none $(openssl dgst -r -sha512 "$filename" | grep -o ".* "); then
    echo "Sha512 passed."
else
    echo "Sha512 failed. Exiting"
    exit
fi

if cat "${filename}.DIGESTS" | grep --color=none $(openssl dgst -r -blake2b512 "$filename" | grep -o ".* "); then
    echo "Blake passed."
else
    echo "Blake failed. Exiting"
    exit
fi

if [ -f /usr/share/openpgp-keys/gentoo-release.asc ];then
    gpg --import /usr/share/openpgp-keys/gentoo-release.asc
else
    wget -O - https://qa-reports.gentoo.org/output/service-keys.gpg | gpg --import
fi

if gpg --verify "$filename".DIGESTS; then
    echo "Digests are valid."
else
    echo "Invalid Digests. Exiting"
    exit
fi


if gpg --verify "$filename".sha256; then
    echo "sha256 is valid."
else
    echo "Invalid sha256. Exiting"
    exit
fi

if gpg --verify "${filename}.asc"; then
    echo "signature is valid!"
else
    echo "Invalid signature. Exiting"
    exit
fi

sleep 1

rm -v ${filename}.*

echo "Extracting filesystem..."
tar xpvf $filename --xattrs-include='*.*' --numeric-owner

echo "Setting Flags"
sed -i -e 's/COMMON_FLAGS="-O2 -pipe"/COMMON_FLAGS="-march=native -O2 -pipe"/g' etc/portage/make.conf

echo "Preparing to chroot..."
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/

if which arch-chroot; then
    croot=arch-chroot
else
    mount --types proc /proc /mnt/gentoo/proc
    mount --rbind /sys /mnt/gentoo/sys
    mount --make-rslave /mnt/gentoo/sys
    mount --rbind /dev /mnt/gentoo/dev
    mount --make-rslave /mnt/gentoo/dev
    mount --bind /run /mnt/gentoo/run
    mount --make-slave /mnt/gentoo/run 
    
    test -L /dev/shm && rm /dev/shm && mkdir /dev/shm
    mount --types tmpfs --options nosuid,nodev,noexec shm /dev/shm 
    
    chmod 1777 /dev/shm /run/shm
    
    croot=chroot
fi

echo "Downloading and moving new script"
wget "https://raw.githubusercontent.com/Jacoblightning/gentooinstall/main/finish_install.sh"

echo "Runnins finish_install script"
chroot /mnt/gentoo /bin/bash /finish_install.sh $installto

umount -l /mnt/gentoo/dev{/shm,/pts,} 
umount -R /mnt/gentoo 

echo "Gentoo is Installed!!!"
read -p "Press enter to reboot!!!"
reboot
