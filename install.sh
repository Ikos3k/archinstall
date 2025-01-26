#!/bin/bash

DISK_DEVICE="/dev/sda"
BOOT_PARTITION="/dev/sda1"
SWAP_PARTITION="/dev/sda2"
ROOT_PARTITION="/dev/sda3"
EFI_RESPONSE="yes"
HOSTNAME="computer"
ROOT_PASSWORD=""
USER_NAME=""
USER_PASSWORD=""

lsblk -e7 -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT | while read -r line; do \
  disk=$(echo $line | awk "{print \$1}"); \
  if [[ "$disk" =~ ^sd[a-z]$ ]]; then \
    model=$(udevadm info --query=all --name=/dev/$disk | grep "ID_MODEL=" | cut -d "=" -f 2); \
    interface=$(udevadm info --query=all --name=/dev/$disk | grep "ID_BUS=" | cut -d "=" -f 2); \
    echo "$line $model $interface"; \
  else \
    echo "$line"; \
  fi; \
done

echo "Enter the disk device (e.g., /dev/sda):"
read user_input
DISK_DEVICE="${user_input:-$DISK_DEVICE}"

if [[ "$DISK_DEVICE" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]]; then
    BOOT_PARTITION="${DISK_DEVICE}p1"
    SWAP_PARTITION="${DISK_DEVICE}p2"
    ROOT_PARTITION="${DISK_DEVICE}p3"
else
    BOOT_PARTITION="${DISK_DEVICE}1"
    SWAP_PARTITION="${DISK_DEVICE}2"
    ROOT_PARTITION="${DISK_DEVICE}3"
fi

echo "Information for the specified disk device ($DISK_DEVICE):"
lsblk $DISK_DEVICE

echo "Enter the path to the boot partition (e.g., ${BOOT_PARTITION}):"
read user_input
BOOT_PARTITION="${user_input:-$BOOT_PARTITION}"

read -p "Do you want to create a swap partition? [Y/n] " SWAP_RESPONSE
case "$SWAP_RESPONSE" in
    [nN][oO]|[nN])
        SWAP_RESPONSE="no"
        if [[ "$DISK_DEVICE" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]]; then
            ROOT_PARTITION="${DISK_DEVICE}p2"
        else
            ROOT_PARTITION="${DISK_DEVICE}2"
        fi
        ;;
    *)
        SWAP_RESPONSE="yes"
        echo "Enter the path to the swap partition (e.g., ${SWAP_PARTITION}):"
        read user_input
        SWAP_PARTITION="${user_input:-$SWAP_PARTITION}"
        ;;
esac

echo "Enter the path to the root partition (e.g., ${ROOT_PARTITION}):"
read user_input
ROOT_PARTITION="${user_input:-$ROOT_PARTITION}"

read -p "Do you want to create an EFI boot partition? [Y/n] " EFI_RESPONSE
case "$EFI_RESPONSE" in
    [nN][oO]|[nN])
        EFI_RESPONSE="no"
        ;;
    *)
        if [ -d "/sys/firmware/efi" ]; then
            EFI_RESPONSE="yes"
            echo "System is in UEFI mode. Configuring for UEFI boot..."
            BOOT_FS="fat32"
            BOOT_DIR="/mnt/boot/efi"
        else
            echo "System is not in UEFI mode or UEFI not selected. Forcing legacy BIOS boot..."
            EFI_RESPONSE="no"
            BOOT_FS="ext4"
            BOOT_DIR="/mnt/boot"
        fi
        ;;
esac

echo "Enter the root password: "
read -s -p "Password: " ROOT_PASSWORD
echo ""
echo "Confirm the root password: "
read -s -p "Password: " ROOT_PASSWORD_CONFIRM
echo ""

while [ "$ROOT_PASSWORD" != "$ROOT_PASSWORD_CONFIRM" ]; do
    echo "Passwords do not match. Please try again."
    echo "Enter the root password: "
    read -s -p "Password: " ROOT_PASSWORD
    echo ""
    echo "Confirm the root password: "
    read -s -p "Password: " ROOT_PASSWORD_CONFIRM
    echo ""
done

echo "Enter the user name:"
read -p "username: " USER_NAME

echo "Enter the user password: "
read -s -p "Password: " USER_PASSWORD
echo ""
echo "Confirm the user password: "
read -s -p "Password: " USER_PASSWORD_CONFIRM
echo ""

while [ "$USER_PASSWORD" != "$USER_PASSWORD_CONFIRM" ]; do
    echo "Passwords do not match. Please try again."
    echo "Enter the user password: "
    read -s -p "Password: " USER_PASSWORD
    echo ""
    echo "Confirm the user password: "
    read -s -p "Password: " USER_PASSWORD_CONFIRM
    echo ""
done

echo "Enter the hostname:"
read user_input
HOSTNAME="${user_input:-$HOSTNAME}"

echo "Formatting the partitions..."
if [ "$EFI_RESPONSE" = "yes" ]; then
    mkfs.fat -F 32 $BOOT_PARTITION
else
    mkfs.ext4 $BOOT_PARTITION
fi
if [ "$SWAP_RESPONSE" = "yes" ]; then
    mkswap $SWAP_PARTITION
fi
mkfs.ext4 $ROOT_PARTITION

umount -A --recursive /mnt

echo "Mounting the file systems..."
mount $ROOT_PARTITION /mnt
mkdir /mnt/boot
if [ "$EFI_RESPONSE" = "yes" ]; then
    mkdir -p /mnt/boot/efi
    mount $BOOT_PARTITION /mnt/boot/efi
else
    mount $BOOT_PARTITION /mnt/boot
fi
if [ "$SWAP_RESPONSE" = "yes" ]; then
    swapon $SWAP_PARTITION
fi

echo "Installing base system..."
pacstrap /mnt base linux linux-firmware base-devel grub
if [ "$EFI_RESPONSE" = "yes" ]; then
    pacstrap /mnt efibootmgr
fi

echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab #genfstab -L

echo "Chrooting into the new system..."

arch-chroot /mnt /bin/bash -c '
echo "Installing additional packages..."
pacman -S --noconfirm networkmanager nano wget

echo "Setting timezone..."
ln -sf /usr/share/zoneinfo/Europe/Warsaw /etc/localtime
hwclock --systohc

echo "Setting locale..."
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" >> /etc/locale.conf

echo "Enabling NetworkManager..."
systemctl enable NetworkManager

pacman -S --noconfirm noto-fonts ly xorg-server xorg-xinit xorg-xrandr xorg-xset xorg-xrdb xorg-xauth i3-wm i3status i3lock i3bar dmenu xterm

systemctl enable ly

echo "Setting hostname..."
echo "'$HOSTNAME'" > /etc/hostname

echo "Setting root password..."
echo "root:'$ROOT_PASSWORD'" | chpasswd

echo "Creating new user..."
useradd -m -G wheel -s /bin/bash "'$USER_NAME'"
echo "'$USER_NAME':'$USER_PASSWORD'" | chpasswd

echo "Adding user to sudoers..."
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

echo "Installing GRUB..."
if [ "'$EFI_RESPONSE'" = "yes" ]; then
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
else
  grub-install --target=i386-pc "'$DISK_DEVICE'" # --grub-setup=/bin/true
fi
grub-mkconfig -o /boot/grub/grub.cfg

echo "Hostname set to:"
cat /etc/hostname

echo "Created users:"
getent passwd | grep -E "^(root|'$USER_NAME')"

exit
'

echo "Unmounting the file systems..."
if [ "$EFI_RESPONSE" = "yes" ]; then
    umount /mnt/boot/efi
else
    umount /mnt/boot
fi
umount /mnt

if [ "$SWAP_RESPONSE" = "yes" ]; then
    echo "Disabling swap..."
    swapoff $SWAP_PARTITION
fi

echo "Installation complete!"
echo "Please reboot your system."
