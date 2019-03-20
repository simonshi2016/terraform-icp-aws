#!/bin/bash
mount_point=$1
data_disk=$2

sudo mkdir -p ${mount_point}
sudo parted -s -a optimal ${data_disk} mklabel gpt -- mkpart primary ext4 1 -1

sudo partprobe

sudo mkfs.ext4 ${data_disk}1
echo "${data_disk}1  ${mount_point}   ext4  defaults   0 0" | sudo tee -a /etc/fstab

sudo mount -a