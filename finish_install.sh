#!/bin/bash

source /etc/profile 

runningon=$1

if [[ "$runningon" == *"nvme"* ]]; then
    drivepref="${runningon}p"
else
    drivepref="${runningon}"
fi

echo "Creating boot directories"
if [ -d /sys/firmware/efi ]; then
    mkdir /efi 
    mount "${drivepref}1" /efi
else
    mount "${drivepref}1" /boot
fi

echo "Syncing repos"
emerge-webrsync

echo "Installing mirrorselect tool"
emerge --verbose --oneshot app-portage/mirrorselect

read -p "Press enter to select your mirrors"
mirrorselect -i -o >> /etc/portage/make.conf

echo "Re-syncing mirrors"
emerge --sync

read -p "Select a profile if you want. Press enter to view the list: "
eselect profile list | less
read -p "Select a profile or 0 to keep it as is: " prof

if [ $prof != '0' ]; then
    eselect profile set $prof
fi

read -p "Would you like binary packages? (Y/N): " confirm
if [[ $confirm == [yY] || $confirm == [yY][eE][sS] ]]; then
    mkdir --parents /etc/portage/binrepos.conf
    echo "[binhost]" > /etc/portage/binrepos.conf/gentoobinhost.conf
    echo "priority = 9999" >> /etc/portage/binrepos.conf/gentoobinhost.conf
    
    echo "Calculating current version"
    version=$(curl "https://distfiles.gentoo.org/releases/amd64/binpackages/" | grep -oE '[0-9]{2,}\.[0-9]+' | sed 1q)
    
    read -p "Would you like hardened binary packages? (Y/N): " confirm
    if [[ $confirm == [yY] || $confirm == [yY][eE][sS] ]]; then
        echo "sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/${version}/x86-64_hardened/" >> /etc/portage/binrepos.conf/gentoobinhost.conf
    else
        echo "sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/${version}/x86-64/" >> /etc/portage/binrepos.conf/gentoobinhost.conf
    fi
    
    echo -e '\n\n# Appending getbinpkg to the list of values within the FEATURES variable' >> /etc/portage/make.conf
    echo 'FEATURES="${FEATURES} getbinpkg"' >> /etc/portage/make.conf
    echo "# Require signatures" >> /etc/portage/make.conf
    echo 'FEATURES="${FEATURES} binpkg-request-signature"' >> /etc/portage/make.conf
    
    echo "Recompiling keyring... Please wait"
    getuto
fi


echo "Configuring CPU flags"
emerge --oneshot app-portage/cpuid2cpuflags
echo "*/* $(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags

read -p "Enter your video cards separated by a space." vidcards

echo "VIDEO_CARDS='${vidcards}'" >> /etc/portage/make.conf

echo "Setting up licenses"

echo -e "\n\n# Overrides the profile's ACCEPT_LICENSE default value" >> /etc/portage/make.conf
echo 'ACCEPT_LICENSE="-* @FREE @BINARY-REDISTRIBUTABLE"' >> /etc/portage/make.conf

mkdir --parents /etc/portage/package.license

echo "app-arch/unrar unRAR" > /etc/portage/package.license/kernel
echo "sys-kernel/linux-firmware linux-fw-redistributable" >> /etc/portage/package.license/kernel
echo "sys-firmware/intel-microcode intel-ucode" >> /etc/portage/package.license/kernel

echo "Performing system update"

emerge --verbose --update --deep --newuse @world

echo "Removing old packages"

echo "Please check this list and answer yes or no accordingly."
emerge --ask --depclean

if which systemctl; then
    echo "Systemd users, this script ends here. Please continue to manually finish from https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Base#Optional:_Using_systemd_as_the_system_and_service_manager"
    echo "gl"; exit
fi

echo "Generating locales"
locale-gen

echo "Spawning shell so you can set your timezone as specified in https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Base#Timezone"
echo "Type exit when done"
bash

echo "Setting new timezone config"
emerge --config sys-libs/timezone-data

echo 'LC_COLLATE="C.UTF-8"' >> /etc/env.d/02locale
echo 'LANG="en_US.UTF-8"' >> /etc/env.d/02locale

env-update && source /etc/profile 

echo "Installing additional firmware"

emerge sys-kernel/linux-firmware
emerge sys-firmware/sof-firmware
if lscpu | grep -i intel > /dev/null; then
    emerge sys-firmware/intel-microcode
fi

echo "Installing the kernel (binary)"
echo "sys-kernel/installkernel dracut" >> /etc/portage/package.use/installkernel

emerge sys-kernel/gentoo-kernel-bin

echo "Creating fstab"
if [ -d /sys/firmware/efi ]; then
    echo "${drivepref}1 /efi vfat defaults 0 2" > /etc/fstab
else
    echo "${drivepref}1 /boot xfs defaults 0 2" > /etc/fstab
fi
echo "${drivepref}2 none swap sw 0 0
${drivepref}3 / xfs defaults,noatime 0 1

/dev/cdrom /mnt/cdrom auto noauto,user 0 0" >> /etc/fstab

read -p "Enter your new hostname: " hname
echo "$hname" > /etc/hostname

echo "Configuring network"
emerge net-misc/dhcpcd
rc-update add dhcpcd default 
rc-service dhcpcd start

echo "127.0.0.1 ${hname} localhost ${hname}.local" >> /etc/hosts

clear
echo "Please set the root password"
passwd

echo "Installing additional tools..."
emerge app-admin/sysklogd sys-fs/xfsprogs sys-fs/e2fsprogs sys-fs/dosfstools sys-process/cronie sys-block/io-scheduler-udev-rules sys-apps/mlocate app-shells/bash-completion net-misc/chrony net-wireless/iw net-wireless/wpa_supplicant
rc-update add cronie default
rc-update add sysklogd default
rc-update add chronyd default

echo "Installing the bootloader..."
if [ -d /sys/firmware/efi ]; then
    echo 'GRUB_PLATFORMS="efi-64"' >> /etc/portage/make.conf
fi
emerge --verbose sys-boot/grub
if [ -d /sys/firmware/efi ]; then
    grub-install --efi-directory=/efi
else
    grub-install $runningon
fi
grub-mkconfig -o /boot/grub/grub.cfg
