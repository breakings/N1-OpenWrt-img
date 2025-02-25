#!/bin/bash

SKIP1=68
BOOT=160
ROOT1=960
SKIP2=162
ROOT2=960

TARGET_SHARED_FSTYPE=f2fs
BACKUP_IMG="/root/bootloader_backup.img"
FDTFILE="meson-g12a-x96-max.dtb"
UBOOT_OVERLOAD="u-boot-x96max.bin"

KERNEL_VERSION=$(uname -r)
# 判断内核版本是否 >= 5.10
K_VER=$(echo "$KERNEL_VERSION" | cut -d '.' -f1)
K_MAJ=$(echo "$KERNEL_VERSION" | cut -d '.' -f2)

if [ $K_VER -eq 5 ];then
	if [ $K_MAJ -ge 10 ];then
		K510=1
	else
		K510=0
	fi
elif [ $K_VER -gt 5 ];then
	K510=1
else
	K510=0
fi

BOOT_LABEL="EMMC_BOOT"

hasdrives=$(lsblk | grep -oE '(mmcblk[0-9])' | sort | uniq)
if [ "$hasdrives" = "" ]
then
	echo "本系统中未找到任何 EMMC 或 SD 设备!!! "
	exit 1
fi

avail=$(lsblk | grep -oE '(mmcblk[0-9]|sda[0-9])' | sort | uniq)
if [ "$avail" = "" ]
then
	echo "本系统未找到任何可用的磁盘设备!!!"
	exit 1
fi

runfrom=$(lsblk | grep -e '/$' | grep -oE '(mmcblk[0-9]|sda[0-9])')
if [ "$runfrom" = "" ]
then
	echo " 未找到根文件系统!!! "
	exit 1
fi

emmc=$(echo $avail | sed "s/$runfrom//" | sed "s/sd[a-z][0-9]//g" | sed "s/ //g")
if [ "$emmc" = "" ]
then
	echo " 没找到空闲的EMMC设备，或是系统已经运行在EMMC设备上了!!!"
	exit 1
fi

if [ "$runfrom" = "$avail" ]
then
	echo " 你的系统已经运行在 EMMC 设备上了!!! "
	exit 1
fi

if [ $runfrom = $emmc ]
then
	echo " 你的系统已经运行在 EMMC 设备上了!!! "
	exit 1
fi

if [ "$(echo $emmc | grep mmcblk)" = "" ]
then
	echo " 你的系统上好象没有任何 EMMC 设备!!! "
	exit 1
fi

# EMMC DEVICE NAME
EMMC_NAME="$emmc"
EMMC_DEVPATH="/dev/$EMMC_NAME"
echo $EMMC_DEVPATH
EMMC_SIZE=$(lsblk -l -b -o NAME,SIZE | grep ${EMMC_NAME} | sort | uniq | head -n1 | awk '{print $2}')
echo "$EMMC_NAME : $EMMC_SIZE bytes"

ROOT_NAME=$(lsblk -l -o NAME,MAJ:MIN,MOUNTPOINT | grep -e '/$' | awk '{print $1}')
echo "ROOTFS: $ROOT_NAME"

BOOT_NAME=$(lsblk -l -o NAME,MAJ:MIN,MOUNTPOINT | grep -e '/boot$' | awk '{print $1}')
echo "BOOT: $BOOT_NAME"

echo "接下来的步骤将会覆盖 EMMC 的原始数据， 请确认是否要继续!"
echo -ne "选择 y 开始安装到 EMMC， 请择 n 则退出 y/n [n]\b\b"
read yn
case $yn in 
	y|Y) yn='y';;
	*)   yn='n';;
esac

if [ "$yn" == "n" ];then
	echo "再见!"
	exit 0
fi

echo 

U_BOOT_EXT=0
MAINLINE_UBOOT=""
ANDROID_UBOOT=""
FLASH_MAINLINE_UBOOT=0
cat <<EOF
-------------------
请选择 Amlogic S905X2 盒子型号: 
1. X96-Max
2. X96-Max-rmii (这是 2G内存/100M 网卡用的)

0. 其它
-------------------
EOF
echo -ne "请选择: "
read boxtype
case $boxtype in 
        1) FDTFILE="meson-g12a-x96-max.dtb"
           MAINLINE_UBOOT="/lib/u-boot/x96max-u-boot.bin.sd.bin"
           ;;
        2) FDTFILE="meson-g12a-x96-max-rmii.dtb"
           MAINLINE_UBOOT="/lib/u-boot/x96max-u-boot.bin.sd.bin"
           ;;
	0) cat <<EOF
请输入 dtb 文件名, 例如: $FDTFILE
自定义的dtb文件有可能无法工作，请慎重选择！
EOF
	   echo -ne "dtb 文件名(不要包含路径): "
           read CUST_FDTFILE
	   FDTFILE=$CUST_FDTFILE
	   ;;
       *) echo "输入错误，退出!"
	  exit 1
	  ;;
esac

if [  ! -f "/boot/dtb/amlogic/${FDTFILE}" ];then
       echo "/boot/dtb/amlogic/${FDTFILE} 不存在！"
       exit 1
fi

# backup old bootloader
if [ ! -f ${BACKUP_IMG} ];then
	echo -n "备份原始 bootloader -> ${BACKUP_IMG} ... "
	dd if=/dev/$EMMC_NAME of=${BACKUP_IMG} bs=1M count=4 conv=fsync
	echo "完成"
	echo
fi

# swapoff -a
swapoff -a

# umount all other mount points
MOUNTS=$(lsblk -l -o MOUNTPOINT)
for mnt in $MOUNTS;do
	if [ "$mnt" == "MOUNTPOINT" ];then
		continue
	fi
	if [ "$mnt" == "" ];then
		continue
	fi
	if [ "$mnt" == "/" ];then
		continue
	fi
	if [ "$mnt" == "/boot" ];then
		continue
	fi
	if [ "$mnt" == "[SWAP]" ];then
		echo "swapoff -a"
		swapoff -a
		continue
	fi
	if echo $mnt | grep $EMMC_NAME;then
		echo "umount -f $mnt"
		umount -f $mnt
		if [ $? -ne 0 ];then
			echo "$mnt 不能被卸载, 安装过程中止"
			exit 1
		fi
	fi
done

# Delete old partition if exists
p=$(lsblk -l | grep -e "${EMMC_NAME}p" | wc -l)
echo "EMMC 上共有 $p 个旧的分区会被删除"
>/tmp/fdisk.script
while [ $p -ge 1 ];do
	echo "d" >> /tmp/fdisk.script
	if [ $p -gt 1 ];then
		echo "$p" >> /tmp/fdisk.script
	fi
	p=$((p-1))
done

# Create new partition
DST_TOTAL_MB=$((EMMC_SIZE/1024/1024))

start1=$(( SKIP1 * 2048 ))
end1=$(( start1 + (BOOT * 2048) - 1 ))

start2=$(( end1 + 1 ))
end2=$(( start2 + (ROOT1 * 2048) -1 ))

start3=$(( (SKIP2 * 2048) + end2 + 1 ))
end3=$(( start3 + (ROOT2 * 2048) -1 ))

start4=$((end3 + 1 ))
end4=$(( DST_TOTAL_MB * 2048 -1 ))

cat >> /tmp/fdisk.script <<EOF
n
p
1
$start1
$end1
n
p
2
$start2
$end2
n
p
3
$start3
$end3
n
p
$start4
$end4
t
1
c
t
2
83
t
3
83
t
4
83
w
EOF

fdisk /dev/$EMMC_NAME < /tmp/fdisk.script
if [ $? -ne 0 ];then
	echo "fdisk 分区失败, 将会还原已备份的bootloader , 然后退出"
	dd if=${BACKUP_IMG} of=/dev/$EMMC_NAME conv=fsync
	exit 1
fi
echo "分区完成"
echo

# write some zero data to part begin
seek=$((start1 / 2048))
dd if=/dev/zero of=/dev/${EMMC_NAME} bs=1M count=1 seek=$seek conv=fsync

seek=$((start2 / 2048))
dd if=/dev/zero of=/dev/${EMMC_NAME} bs=1M count=1 seek=$seek conv=fsync

seek=$((start3 / 2048))
dd if=/dev/zero of=/dev/${EMMC_NAME} bs=1M count=1 seek=$seek conv=fsync

seek=$((start4 / 2048))
dd if=/dev/zero of=/dev/${EMMC_NAME} bs=1M count=1 seek=$seek conv=fsync

if [ "$MAINLINE_UBOOT" != "" ];then
    if [ -f "$MAINLINE_UBOOT" ];then
	cat <<EOF
----------------------------------------------------------------------
发现了可用的主线 bootloader (Mainline u-boot), 可以刷入 EMMC
好处是: 千兆网卡正常、HDMI颜色正常、启动速度快、且兼容所有版本的linux内核
坏处是：刷入后如果要还原成安卓固件的话，必须先还原安卓的 bootloader
        或者只能用短接法刷回安卓固件
----------------------------------------------------------------------
EOF
        while :;do
            read -p "请仔细阅读上述说明，然后选择是否把主线 bootloader 刷入 EMMC ?  y/n " yn
	    case $yn in 
		    y|Y) FLASH_MAINLINE_UBOOT=1
			 break
			 ;;
		    n|N) FLASH_MAINLINE_UBOOT=0
			 break
			 ;;
	    esac
	done
    fi
fi

if [ $FLASH_MAINLINE_UBOOT -eq 1 ];then
    echo "************************************************************************"
    echo "写入新的 bootloader ..."

    echo "dd if=${MAINLINE_UBOOT} of=/dev/${EMMC_NAME} conv=fsync bs=1 count=444"
    dd if=${MAINLINE_UBOOT} of="/dev/${EMMC_NAME}" conv=fsync bs=1 count=444

    echo "dd if=${MAINLINE_UBOOT} of=/dev/${EMMC_NAME} conv=fsync bs=512 skip=1 seek=1"
    dd if=${MAINLINE_UBOOT} of="/dev/${EMMC_NAME}" conv=fsync bs=512 skip=1 seek=1

    MD5SUM=$(md5sum ${MAINLINE_UBOOT} | awk '{print $1}')

    sync
    echo "完成"
    echo "************************************************************************"
    echo 
elif [ "$ANDROID_UBOOT" != "" ];then
    if [ -f "$ANDROID_UBOOT" ];then
        echo "************************************************************************"
        echo "写入新的 bootloader ..."

         echo "dd if=${ANDROID_UBOOT} of=/dev/${EMMC_NAME} conv=fsync bs=1 count=444"
         dd if=${ANDROID_UBOOT} of="/dev/${EMMC_NAME}" conv=fsync bs=1 count=444

         echo "dd if=${ANDROID_UBOOT} of=/dev/${EMMC_NAME} conv=fsync bs=512 skip=1 seek=1"
         dd if=${ANDROID_UBOOT} of="/dev/${EMMC_NAME}" conv=fsync bs=512 skip=1 seek=1

         sync
	 echo "完成"
	 echo "************************************************************************"
	 echo 
    fi
fi

# fix wifi macaddr
if [ -x /usr/bin/fix_wifi_macaddr.sh ];then
    /usr/bin/fix_wifi_macaddr.sh
fi

# mkfs
echo "开始创建文件系统 ... "
echo "创建boot文件系统 ... "
mkfs.fat -n EMMC_BOOT -F 32 /dev/${EMMC_NAME}p1
mkdir -p /mnt/${EMMC_NAME}p1
sleep 2
umount -f /mnt/${EMMC_NAME}p1 2>/dev/null

echo "创建 rootfs1 文件系统 ... "
ROOTFS1_UUID=$(/usr/bin/uuidgen)
mkfs.btrfs -f -U ${ROOTFS1_UUID} -L EMMC_ROOTFS1 -m single /dev/${EMMC_NAME}p2
mkdir -p /mnt/${EMMC_NAME}p2
sleep 2
umount -f /mnt/${EMMC_NAME}p2 2>/dev/null

echo "创建 rootfs2 文件系统 ... "
ROOTFS2_UUID=$(/usr/bin/uuidgen)
mkfs.btrfs -f -U ${ROOTFS2_UUID} -L EMMC_ROOTFS2 -m single /dev/${EMMC_NAME}p3
mkdir -p /mnt/${EMMC_NAME}p3
sleep 2
umount -f /mnt/${EMMC_NAME}p3 2>/dev/null

# 写入 boot 
#if [ $K510 -eq 0 ] || [ $FLASH_MAINLINE_UBOOT -eq 1 ];then  # kernel version < 5.10 or flash_mainline_uboot = 1
# 新版本都可以写入 EMMC，不再需要 usb或tf卡启动
if true;then  
	# mount and copy
	max_try=10
	echo "等待 boot 文件系统挂载 ... "
	i=1
	while [ $i -le $max_try ]; do
		mount -t vfat /dev/${EMMC_NAME}p1 /mnt/${EMMC_NAME}p1 2>/dev/null
		sleep 2
		mnt=$(lsblk -l -o MOUNTPOINT | grep /mnt/${EMMC_NAME}p1)
		if [ "$mnt" == "" ];then
			if [ $i -lt $max_try ];then
				echo "未挂载成功， 重试 ..."
				i=$((i+1))
			else
				echo "不能挂载  boot 文件系统，放弃!"
				exit 1
			fi
		else
			echo "挂载成功"
			echo -n "复制 boot ..."
			cd /mnt/${EMMC_NAME}p1
			rm -rf /boot/'System Volume Information/'
			(cd /boot && tar cf - .) | tar mxf -
			sync
			echo "done"
			echo -n "Write uEnv.txt ... "
			cat > uEnv.txt <<EOF
LINUX=/zImage
INITRD=/uInitrd

FDT=/dtb/amlogic/${FDTFILE}

APPEND=root=UUID=${ROOTFS1_UUID} rootfstype=btrfs rootflags=compress=zstd console=ttyAML0,115200n8 console=tty0 no_console_suspend consoleblank=0 fsck.fix=yes fsck.repair=yes net.ifnames=0 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory swapaccount=1
EOF

			rm -f s905_autoscript* aml_autoscript*
			if [ $U_BOOT_EXT -eq 1 ];then
				if [ -f ${UBOOT_OVERLOAD} ];then
					cp -f -v ${UBOOT_OVERLOAD} u-boot.emmc
				else
					cp -f -v u-boot.sd u-boot.emmc
				fi
			fi
			mv -f boot-emmc.ini boot.ini
			mv -f boot-emmc.cmd boot.cmd
			mv -f boot-emmc.scr boot.scr
			sync
			echo "完成."
			cd /
			umount -f /mnt/${EMMC_NAME}p1
			break
		fi
	done
	echo "完成"
	echo 
else  # kernel version >=5.10
	echo "由于内核版本 >= 5.10， 因此只能用sd卡或u盘启动， 正在修改boot配置文件 ... "
	mv /boot/uEnv.txt /boot/uEnv.sd
	cat > /boot/uEnv.txt <<EOF
LINUX=/zImage
INITRD=/uInitrd

FDT=/dtb/amlogic/${FDTFILE}

APPEND=root=UUID=${ROOTFS1_UUID} rootfstype=btrfs rootflags=compress=zstd console=ttyAML0,115200n8 console=tty0 no_console_suspend consoleblank=0 fsck.fix=yes fsck.repair=yes net.ifnames=0 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory swapaccount=1
EOF
	sync
	echo "完成"
	echo 
fi

echo "等待 rootfs 文件系统挂载 ... "
i=1
max_try=10
while [ $i -le $max_try ]; do
	mount -t btrfs -o compress=zstd /dev/${EMMC_NAME}p2 /mnt/${EMMC_NAME}p2 2>/dev/null
	sleep 2
	mnt=$(lsblk -l -o MOUNTPOINT | grep /mnt/${EMMC_NAME}p2)
	if [ "$mnt" == "" ];then
		if [ $i -lt $max_try ];then
			echo "未挂载成功， 重试 ..."
			i=$((i+1))
		else
			echo "不能挂载 rootfs 文件系统, 放弃!"
			exit 1
		fi
	else
		echo "挂载成功"
		echo -n "创建文件夹 ... "
		cd /mnt/${EMMC_NAME}p2
		mkdir -p bin boot dev etc lib opt mnt overlay proc rom root run sbin sys tmp usr www
		ln -sf lib/ lib64
		ln -sf tmp/ var
		echo "完成"
		
		COPY_SRC="root etc bin sbin lib opt usr www"
		echo "复制数据 ... "
		for src in $COPY_SRC;do
			echo -n "复制 $src ... "
			(cd / && tar cf - $src) | tar xmf -
			sync
			echo "完成"
		done
		rm -rf opt/docker && ln -sf /mnt/${EMMC_NAME}p4/docker/ opt/docker
		rm -rf usr/bin/AdGuardHome && ln -sf /mnt/${EMMC_NAME}p4/AdGuardHome usr/bin/AdGuardHome
		echo "复制完成"
		
		echo -n "编辑配置文件 ... "
		cd /mnt/${EMMC_NAME}p2/root
		rm -f install-to-emmc.sh update-to-emmc.sh
		cd /mnt/${EMMC_NAME}p2/etc/rc.d
		ln -sf ../init.d/dockerd S99dockerd
		cd /mnt/${EMMC_NAME}p2/etc
		cat > fstab <<EOF
UUID=${ROOTFS1_UUID} / btrfs compress=zstd 0 1
LABEL=${BOOT_LABEL} /boot vfat defaults 0 2
#tmpfs /tmp tmpfs defaults,nosuid 0 0
EOF

        if [ $FLASH_MAINLINE_UBOOT -eq 1 ];then
            echo "MAINLINE_UBOOT=${MAINLINE_UBOOT}" >> flippy-openwrt-release
            echo "MAINLINE_UBOOT_MD5SUM=${MD5SUM}" >> flippy-openwrt-release
        fi		
		
		cd /mnt/${EMMC_NAME}p2/etc/config
		cat > fstab <<EOF
config global
	option anon_swap '0'
	option anon_mount '1'
	option auto_swap '0'
	option auto_mount '1'
	option delay_root '5'
	option check_fs '0'

config mount
	option target '/overlay'
	option uuid '${ROOTFS1_UUID}'
	option enabled '1'
	option enabled_fsck '1'
        option fstype 'btrfs'
        option options 'compress=zstd'

config mount
	option target '/boot'
	option label '${BOOT_LABEL}'
	option enabled '1'
	option enabled_fsck '0'
        option fstype 'vfat'
		
EOF
		cd /
		umount -f /mnt/${EMMC_NAME}p2
		break
	fi
done
echo "完成"
echo 

echo "创建共享文件系统 ... "
cat <<EOF
请选择共享文件系统的类型：
------------------------------------------
1. ext4 (默认的选项，适合一般用途)

2. btrfs (对 ssd/mmc 有一定优化，
          可延长 ssd/mmc 使用寿命，
          具有众多现代文件系统特性, 
          但速度稍慢)

3. f2fs  (对 ssd/mmc 有专门的优化，
          读写速度快，
          且可延长 ssd/mmc 使用寿命，
          但空间利用率稍低, 
          且兼容性稍差)

4. xfs   (非常优秀的文件系统，ext4的替代品)
------------------------------------------
EOF
echo -ne "[1]\b\b"
read sel
case $sel in 
        2) TARGET_SHARED_FSTYPE=btrfs;;
	3) TARGET_SHARED_FSTYPE=f2fs;;
	4) TARGET_SHARED_FSTYPE=xfs;;
	*) TARGET_SHARED_FSTYPE=ext4;;
esac

mkdir -p /mnt/${EMMC_NAME}p4
case $TARGET_SHARED_FSTYPE in
	xfs) mkfs.xfs -f -L EMMC_SHARED /dev/${EMMC_NAME}p4
	     mount -t xfs /dev/${EMMC_NAME}p4 /mnt/${EMMC_NAME}p4
	     ;;
      btrfs) mkfs.btrfs -f -L EMMC_SHARED -m single /dev/${EMMC_NAME}p4
	     mount -t btrfs /dev/${EMMC_NAME}p4 /mnt/${EMMC_NAME}p4
	     ;;
       f2fs) mkfs.f2fs -f -l EMMC_SHARED /dev/${EMMC_NAME}p4
	     mount -t f2fs /dev/${EMMC_NAME}p4 /mnt/${EMMC_NAME}p4
	     ;;
	  *) mkfs.ext4 -F -L EMMC_SHARED  /dev/${EMMC_NAME}p4
	     mount -t ext4 /dev/${EMMC_NAME}p4 /mnt/${EMMC_NAME}p4
	     ;;
esac
mkdir -p /mnt/${EMMC_NAME}p4/docker /mnt/${EMMC_NAME}p4/AdGuardHome
echo "完成"
echo

sync

echo "注意：原版 bootloader 已导出到 ${BACKUP_IMG} , 请注意下载并保存!"
#if [ $K510 -eq 1 ];then
#	mv /root/install-to-emmc.sh /root/install-to-emmc.sh.done
#	echo "所有步骤均已完成， 请重启系统，注意: 5.10内核只支持SD卡(或U盘)启动，因此请不要拔掉启动介质!"
#else
	echo "所有步骤均已完成!"
	echo "猴属性者： 请输入 reboot 命令重启动，然后迅速拔掉 SD卡或U盘 ！"
	echo "龟属性者： 请输入 poweroff 命令关机，拔除 SD卡或U盘 之后再开机 !"
	echo "神属性者： 可以直接拔电！"
#fi
exit 0
