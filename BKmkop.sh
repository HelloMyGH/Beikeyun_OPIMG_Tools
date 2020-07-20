#!/bin/bash
#
red="\033[31m"
green="\033[32m"
white="\033[0m"

out_dir="./out"
openwrt_dir="./openwrt"
BOOTLOADER_IMG="$PWD/armbian/beikeyun/others/btld-rk3328.bin"
rootfs_dir="/media/rootfs"
loop=
SKIP_MB=16
BOOT_MB=128

echo  -e "\n贝壳云Openwrt镜像制作工具"
#检测root权限
if [ $UID -ne 0 ];then
echo -e "$red \n 错误：请使用root用户或sudo执行此脚本！$white" && exit
fi


#清理重建目录
if [ -d $out_dir ]; then
    sudo rm -rf $out_dir
fi

mkdir -p $out_dir/openwrt
sudo mkdir -p $rootfs_dir

# 解压openwrt固件
cd $openwrt_dir
if [ -f *ext4-factory.img.gz ]; then
    gzip -d *ext4-factory.img.gz
elif [ -f *root.ext4.gz ]; then
    gzip -d *root.ext4.gz
elif [ -f *rootfs.tar.gz ] || [ -f *ext4-factory.img ] || [ -f *root.ext4 ]; then
    [ ]
else
    echo -e "$red \n openwrt目录下不存在固件或固件类型不受支持! $white" && exit
fi

# 挂载openwrt固件
if [ -f *rootfs.tar.gz ]; then
    sudo tar -xzf *rootfs.tar.gz -C ../$out_dir/openwrt
elif [ -f *ext4-factory.img ]; then
    loop=$(sudo losetup -P -f --show *ext4-factory.img)
    if ! sudo mount -o rw ${loop}p2 $rootfs_dir; then
        echo -e "$red \n 挂载OpenWrt镜像失败! $white" && exit
    fi
elif [ -f *root.ext4 ]; then
    sudo mount -o loop *root.ext4 $rootfs_dir
fi

# 拷贝openwrt rootfs
echo -e "$green \n 提取OpenWrt ROOTFS... $white"
cd ../$out_dir
if df -h | grep $rootfs_dir > /dev/null 2>&1; then
    sudo cp -r $rootfs_dir/* openwrt/ && sync
    sudo umount $rootfs_dir
    [ $loop ] && sudo losetup -d $loop
fi

sudo cp -r ../armbian/beikeyun/rootfs/* openwrt/ && sync

# 制作可启动镜像
echo && read -p "请输入ROOTFS分区大小(单位MB)，默认256M: " rootfssize
[ $rootfssize ] || rootfssize=256

openwrtsize=$(sudo du -hs openwrt | cut -d "M" -f 1)
[ $rootfssize -lt $openwrtsize ] && \
    echo -e "$red \n ROOTFS分区最少需要 $openwrtsize MB! $white" && \
    exit

echo -e "$green \n 生成空镜像(.img)... $white"

fallocate -l ${rootfssize}MB "$(date +%Y-%m-%d)-openwrt-beikeyun-auto-generate.img"


# 格式化镜像
echo -e "$green \n 格式化... $white"
loop=$(sudo losetup -P -f --show *.img)
[ ! $loop ] && \
    echo -e "$red \n 格式化失败! $white" && \
    exit

    #MBR引导
sudo parted -s $loop  mklabel msdos> /dev/null 2>&1
    #创建BOOT分区
START=$((SKIP_MB * 1024 * 1024))
END=$((BOOT_MB * 1024 * 1024 + START -1))
sudo parted $loop mkpart primary ext4 ${START}b ${END}b >/dev/null 2>&1
    #创建ROOTFS分区
START=$((END + 1))
END=$((rootfssize * 1024 * 1024 + START -1))
sudo parted $loop mkpart primary btrfs ${START}b 100%
sudo parted $loop print

# mk boot filesystem (ext4)
BOOT_UUID=$(uuid)
sudo mkfs.ext4 -U ${BOOT_UUID} -L EMMC_BOOT ${loop}p1
echo "BOOT UUID IS $BOOT_UUID"
# mk root filesystem (btrfs)
ROOTFS_UUID=$(uuid)
sudo mkfs.btrfs -U ${ROOTFS_UUID} -L EMMC_ROOTFS1 ${loop}p2
echo "ROOTFS UUID IS $ROOTFS_UUID"

echo "parted ok"

# write bootloader
echo $PWD
sudo dd if=${BOOTLOADER_IMG} of=${loop} bs=1 count=446
sudo dd if=${BOOTLOADER_IMG} of=${loop} bs=512 skip=1 seek=1
sudo sync

    #设定分区目录挂载路径
boot_dir=/media/$BOOT_UUID
rootfs_dir=/media/$ROOTFS_UUID
    #删除重建目录
sudo rm -rf $boot_dir $rootfs_dir
sudo mkdir $boot_dir $rootfs_dir
    #挂载分区到新建目录
sudo mount -t ext4 ${loop}p1 $boot_dir
sudo mount -t btrfs -o compress=zstd ${loop}p2 $rootfs_dir
    #写入UUID 到fstab
    sudo echo "UUID=$BOOT_UUID / btrfs compress=zstd 0 1">openwrt/etc/fstab
    sudo echo "UUID=$ROOTFS_UUID /boot ext4 noatime,errors=remount-ro 0 2">openwrt/etc/fstab
    sudo echo "tmpfs /tmp tmpfs defaults,nosuid 0 0">>openwrt/etc/fstab

# 拷贝文件到启动镜像
cd ../
    #创建armbianEnv.txt
    sudo rm -rf armbian/beikeyun/boot/armbianEnv.txt
    sudo touch armbian/beikeyun/boot/armbianEnv.txt
    #写入UUID到armbianEnv
sudo cat > armbian/beikeyun/boot/armbianEnv.txt <<EOF
verbosity=7
overlay_prefix=rockchip
rootdev=/dev/mmcblk0p2
rootfstype=btrfs
rootflags=compress=zstd
extraargs=usbcore.autosuspend=-1
extraboardargs=
fdtfile=rk3328-beikeyun.dtb
EOF
    sudo cp -r armbian/beikeyun/boot /media/$BOOT_UUID
    sudo chown -R root:root $out_dir/openwrt/
    sudo mv $out_dir/openwrt/* /media/$ROOTFS_UUID




# 取消挂载
if df -h | grep $rootfs_dir > /dev/null 2>&1 ; then
    sudo umount /media/$BOOT_UUID /media/$ROOTFS_UUID
fi

[ $loopp1 ] && sudo losetup -d $loop

# 清理残余
sudo rm -rf $boot_dir
sudo rm -rf $rootfs_dir
sudo rm -rf $out_dir/openwrt
echo -e "$green \n 制作成功, 输出文件夹 --> $out_dir $white"

