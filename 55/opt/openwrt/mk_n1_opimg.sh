#!/bin/bash

WORK_DIR="${PWD}/tmp"
if [ ! -d ${WORK_DIR} ];then
	mkdir -p ${WORK_DIR}
fi

# 源镜像文件
##########################################################################
source make.env
# 盒子型号识别参数 
SOC=s905d
BOARD=n1

SUBVER=$1

# Armbian 源文件
LNX_IMG="/opt/imgs/Armbian_20.10_Aml-s9xxx_buster_${KERNEL_VERSION}.img"
# NEW UUID
NEWUUID="n"
# not used
# BOOT_TGZ="/opt/kernel/boot-${KERNEL_VERSION}.tar.gz"
# MODULES_TGZ="/opt/kernel/modules-${KERNEL_VERSION}.tar.gz"
###########################################################################

# Openwrt root 源文件
# +o OR + flag
if echo $KERNEL_VERSION | grep -E '*\+$';then
    SFE_FLAG=1
    FLOWOFFLOAD_FLAG=0
else
    SFE_FLAG=0
    FLOWOFFLOAD_FLAG=1
fi

OP_ROOT_TGZ="openwrt-armvirt-64-default-rootfs.tar.gz"
OPWRT_ROOTFS_GZ="${PWD}/${OP_ROOT_TGZ}"
if [ $SFE_FLAG -eq 1 ];then
    if [ -f "${PWD}/sfe/${OP_ROOT_TGZ}" ];then
        OPWRT_ROOTFS_GZ="${PWD}/sfe/${OP_ROOT_TGZ}"
    fi
elif [ ${FLOWOFFLOAD_FLAG} -eq 1 ];then
    if [ -f "${PWD}/flowoffload/${OP_ROOT_TGZ}" ];then
        OPWRT_ROOTFS_GZ="${PWD}/flowoffload/${OP_ROOT_TGZ}"
    fi
fi
echo "Use $OPWRT_ROOTFS_GZ as openwrt rootfs!"

# 目标镜像文件
TGT_IMG="${WORK_DIR}/N1-jcnf-mini-55+o.img"

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

# 补丁和脚本
###########################################################################
REGULATORY_DB="${PWD}/files/regulatory.db.tar.gz"
KMOD="${PWD}/files/kmod"
KMOD_BLACKLIST="${PWD}/files/kmod_blacklist"
MAC_SCRIPT1="${PWD}/files/fix_wifi_macaddr.sh"
MAC_SCRIPT2="${PWD}/files/find_macaddr.pl"
MAC_SCRIPT3="${PWD}/files/inc_macaddr.pl"
CPUSTAT_SCRIPT="${PWD}/files/cpustat"
CPUSTAT_SCRIPT_PY="${PWD}/files/cpustat.py"
CPUSTAT_PATCH="${PWD}/files/luci-admin-status-index-html.patch"
GETCPU_SCRIPT="${PWD}/files/getcpu"
TTYD="${PWD}/files/ttyd"
FLIPPY="${PWD}/files/flippy"
BANNER="${PWD}/files/banner"

# 20200314 add
FMW_HOME="${PWD}/files/firmware"
SMB4_PATCH="${PWD}/files/smb4.11_enable_smb1.patch"
SYSCTL_CUSTOM_CONF="${PWD}/files/99-custom.conf"

# 20200709 add
COREMARK="${PWD}/files/coremark.sh"

# 20200930 add
INST_SCRIPT="${PWD}/files/s905d/install-to-emmc.sh"
UPDATE_SCRIPT="${PWD}/files/s905d/update-to-emmc.sh"
SND_MOD="${PWD}/files/s905d/snd-meson-gx"
DAEMON_JSON="${PWD}/files/s905d/daemon.json"

# 20201006 add
FORCE_REBOOT="${PWD}/files/s905d/reboot"
# 20201017 add
BAL_ETH_IRQ="${PWD}/files/balethirq.pl"
# 20201026 add
FIX_CPU_FREQ="${PWD}/files/fixcpufreq.pl"
SYSFIXTIME_PATCH="${PWD}/files/sysfixtime.patch"

# 20201128 add
SSL_CNF_PATCH="${PWD}/files/openssl_engine.patch"

# 20201212 add
BAL_CONFIG="${PWD}/files/s905d/balance_irq"
CPUFREQ_INIT="${PWD}/files/s905d/cpufreq"

# 20210302 modify
FIP_HOME="${PWD}/files/meson_btld/with_fip/s905d"
UBOOT_WITH_FIP="${FIP_HOME}/n1-u-boot.bin.sd.bin"
UBOOT_WITHOUT_FIP="u-boot-n1.bin"

# 20210208 add
WIRELESS_CONFIG="${PWD}/files/s905d/wireless"

# 20210307 add
SS_LIB="${PWD}/files/ss-glibc/lib-glibc.tar.xz"
SS_BIN="${PWD}/files/ss-glibc/ss-bin-glibc.tar.xz"
JQ="${PWD}/files/jq"
###########################################################################

# 检查环境
if [ ! -f "$LNX_IMG" ];then
	echo "Armbian镜像: ${LNX_IMG} 不存在, 请检查!"
	exit 1
fi

if [ ! -f "$OPWRT_ROOTFS_GZ" ];then
	echo "Openwrt镜像: ${OPWRT_ROOTFS_GZ} 不存在, 请检查!"
	exit 1
fi

if mkfs.btrfs -V >/dev/null;then
	echo "check mkfs.btrfs ok"
else
	echo "mkfs.btrfs 程序不存在，请安装 btrfsprogs"
	exit 1
fi

if uuidgen>/dev/null;then
	echo "check uuidgen ok"
else
	echo "uuidgen 程序不存在，请安装 uuid-runtime"
	exit 1
fi

if losetup -V >/dev/null;then
	echo "check losetup ok"
else
	echo "losetup 程序不存在，请安装 mount"
	exit 1
fi

if lsblk --version >/dev/null 2>&1;then
	echo "check lsblk ok"
else
	echo "lsblk 程序不存在，请安装 util-linux"
	exit 1
fi

# work dir
cd $WORK_DIR
TEMP_DIR=$(mktemp -p $WORK_DIR)
rm -rf $TEMP_DIR
mkdir -p $TEMP_DIR
echo $TEMP_DIR

# temp dir
cd $TEMP_DIR
LINUX_BOOT=armbian_boot
LINUX_ROOT=armbian_root
mkdir $LINUX_BOOT $LINUX_ROOT

# mount & tar xf
echo "挂载 Armbian 镜像 ... "
sudo losetup -D
sudo losetup -f -P $LNX_IMG
BLK_DEV=$(sudo losetup | grep "$LNX_IMG" | head -n 1 | gawk '{print $1}')
sudo mount -o ro ${BLK_DEV}p1 $LINUX_BOOT
sudo mount -o ro ${BLK_DEV}p2 $LINUX_ROOT

# 创建空白镜像文件
echo "创建空白的目标镜像文件 ..."
SKIP_MB=4
BOOT_MB=256
ROOTFS_MB=640
SIZE=$((SKIP_MB + BOOT_MB + ROOTFS_MB))
echo $SIZE

dd if=/dev/zero of=$TGT_IMG bs=1M count=$SIZE
sudo losetup -f -P $TGT_IMG
TGT_DEV=$(sudo losetup | grep "$TGT_IMG" | gawk '{print $1}')

echo "创建磁盘分区和文件系统 ..."
sudo parted -s $TGT_DEV mklabel msdos 2>/dev/null
BEGIN=$((SKIP_MB * 1024 * 1024))
END=$(( BOOT_MB * 1024 * 1024 + BEGIN -1))
sudo parted -s $TGT_DEV mkpart primary fat32 ${BEGIN}b ${END}b 2>/dev/null
if [ $? -ne 0 ];then
    echo "创建 boot 分区失败!"
    losetup -D
    exit 1
fi
BEGIN=$((END + 1))
END=$((ROOTFS_MB * 1024 * 1024 + BEGIN -1))
sudo parted -s $TGT_DEV mkpart primary btrfs ${BEGIN}b 100% 2>/dev/null
if [ $? -ne 0 ];then
    echo "创建 rootfs 分区失败!"
    losetup -D
    exit 1
fi
sudo parted -s $TGT_DEV print 2>/dev/null

# 格式化文件系统
sudo mkfs.vfat -n BOOT ${TGT_DEV}p1
ROOTFS_UUID="443c1545-cd60-402f-9630-4794fc242a01"
if [ "$NEWUUID" == "y" ]; then
	ROOTFS_UUID=$(uuidgen) 
fi
echo "ROOTFS_UUID = $ROOTFS_UUID"
sudo mkfs.btrfs -U ${ROOTFS_UUID} -L ROOTFS -m single ${TGT_DEV}p2

echo "挂载目标设备 ..."
TGT_BOOT=${TEMP_DIR}/tgt_boot
TGT_ROOT=${TEMP_DIR}/tgt_root
mkdir $TGT_BOOT $TGT_ROOT
sudo mount -t vfat ${TGT_DEV}p1 $TGT_BOOT
sudo mount -t btrfs -o compress=zstd ${TGT_DEV}p2 $TGT_ROOT

# extract boot
echo "boot 文件解包 ... "
cd $TEMP_DIR/$LINUX_BOOT 
#if [ -f "${BOOT_TGZ}" ];then
#	( cd $TGT_BOOT; tar xvzf "${BOOT_TGZ}" )
#else
	sudo tar cf - . | (cd $TGT_BOOT;sudo  tar xf - )
#fi

echo "openwrt 根文件系统解包 ... "
(
  cd $TGT_ROOT && \
	  sudo tar xzf $OPWRT_ROOTFS_GZ && \
	  sudo rm -rf ./lib/firmware/* ./lib/modules/* && \
	  sudo mkdir -p .reserved boot rom proc sys run
)

echo "Armbian 根文件系统解包 ... "
cd $TEMP_DIR/$LINUX_ROOT && \
	sudo tar cf - ./etc/armbian* ./etc/default/armbian* ./etc/default/cpufreq* ./lib/init ./lib/lsb ./lib/firmware ./usr/lib/armbian | (cd ${TGT_ROOT}; sudo tar xf -)

echo "内核模块解包 ... "
cd $TEMP_DIR/$LINUX_ROOT
#if [ -f "${MODULES_TGZ}" ];then
#	(cd ${TGT_ROOT}/lib/modules; tar xvzf "${MODULES_TGZ}")
#else
	sudo tar cf - ./lib/modules | ( cd ${TGT_ROOT}; sudo tar xf - )
#fi

while :;do
	lsblk -l -o NAME,PATH,UUID 
	BOOT_UUID=$(lsblk -l -o NAME,PATH,UUID | grep "${TGT_DEV}p1" | awk '{print $3}')
	#ROOTFS_UUID=$(lsblk -l -o NAME,PATH,UUID | grep "${TGT_DEV}p2" | awk '{print $3}')
	echo "BOOT_UUID is $BOOT_UUID"
	echo "ROOTFS_UUID is $ROOTFS_UUID"
	if [ "$ROOTFS_UUID" != "" ];then
		break
	fi
	sleep 1
done

echo "修改引导分区相关配置 ... "
# modify boot
cd $TGT_BOOT
sudo rm -f uEnv.ini
sudo tee uEnv.txt >/dev/null  <<EOF
LINUX=/zImage
INITRD=/uInitrd

# 下列 dtb，用到哪个就把哪个的#删除，其它的则加上 # 在行首

# 用于 Phicomm N1
FDT=/dtb/amlogic/meson-gxl-s905d-phicomm-n1.dtb

# 用于 Phicomm N1 (thresh)
#FDT=/dtb/amlogic/meson-gxl-s905d-phicomm-n1-thresh.dtb

APPEND=root=UUID=${ROOTFS_UUID} rootfstype=btrfs rootflags=compress=zstd console=ttyAML0,115200n8 console=tty0 no_console_suspend consoleblank=0 fsck.fix=yes fsck.repair=yes net.ifnames=0 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory swapaccount=1
EOF

# 替换dtb文件
[ "$REPLACE_DTB" == "y" ] && [ -f "$DTB_FILE" ] && sudo cp "$DTB_FILE" ./dtb/amlogic/

echo "uEnv.txt --->"
cat uEnv.txt

# 5.10以后的内核，需要增加u-boot重载
if [ $K510 -eq 1 ];then
	sudo cp -fv ${UBOOT_WITHOUT_FIP} u-boot.ext
fi

echo "修改根文件系统相关配置 ... "

# modify root
sudo chmod -R 777 $TGT_ROOT
cd $TGT_ROOT
( [ -f "$SS_LIB" ] &&  cd lib && sudo tar xvJf "$SS_LIB" )
if [ -f "$SS_BIN" ];then
    (
        cd usr/bin
        sudo mkdir -p ss-bin-musl && sudo mv -f ss-server ss-redir ss-local ss-tunnel ss-bin-musl/ 2>/dev/null
       	sudo tar xvJf "$SS_BIN"
    )
fi
if [ -f "$JQ" ] && [ ! -f "./usr/bin/jq" ];then
	sudo cp -v ${JQ} ./usr/bin
fi

if [ -d "${FIP_HOME}" ];then
       sudo mkdir -p lib/u-boot
       sudo cp -v "${FIP_HOME}"/../*.sh lib/u-boot/
       sudo cp -v "${FIP_HOME}"/*.sd.bin lib/u-boot/ 
fi

[ -f $INST_SCRIPT ] && sudo cp $INST_SCRIPT root/
# [ -f $UPDATE_SCRIPT ] && cp $UPDATE_SCRIPT root/
[ -f $MAC_SCRIPT1 ] && sudo cp $MAC_SCRIPT1 usr/bin/
[ -f $MAC_SCRIPT2 ] && sudo cp $MAC_SCRIPT2 usr/bin/
[ -f $MAC_SCRIPT3 ] && sudo cp $MAC_SCRIPT3 usr/bin/
[ -f $DAEMON_JSON ] && sudo mkdir -p "etc/docker" && sudo cp $DAEMON_JSON "etc/docker/daemon.json"
[ -f $FORCE_REBOOT ] && sudo cp $FORCE_REBOOT usr/sbin/
[ -f $COREMARK ] && [ -f "etc/coremark.sh" ] && sudo cp -f $COREMARK "etc/coremark.sh" && sudo chmod 755 "etc/coremark.sh"
if [ -x usr/bin/perl ];then
	[ -f $CPUSTAT_SCRIPT ] && sudo cp $CPUSTAT_SCRIPT usr/bin/
	[ -f $GETCPU_SCRIPT ] && sudo cp $GETCPU_SCRIPT bin/
else
	[ -f $CPUSTAT_SCRIPT_PY ] && sudo cp $CPUSTAT_SCRIPT_PY usr/bin/cpustat
fi
[ -f $TTYD ] && sudo cp $TTYD etc/init.d/
[ -f $FLIPPY ] && sudo cp $FLIPPY usr/sbin/
if [ -f $BANNER ];then
    sudo cp -f $BANNER etc/banner
    sudo echo " Base on OpenWrt ${OPENWRT_VER} by lean & lienol" >> etc/banner
    sudo echo " Kernel 5.4.105-mingxiaoyu-55+o " >> etc/banner
    TODAY=$(date +%Y-%m-%d)
    sudo echo " Packaged by ${WHOAMI} on ${TODAY}" >> etc/banner
    sudo echo " SOC: ${SOC}	BOARD: ${BOARD}" >> etc/banner
    sudo echo >> etc/banner
fi

if [ -f $BAL_ETH_IRQ ];then
    sudo cp -v $BAL_ETH_IRQ usr/sbin
    sudo chmod 755 usr/sbin/balethirq.pl
    sudo sed -e "/exit/i\/usr/sbin/balethirq.pl" -i etc/rc.local
    [ -f ${BAL_CONFIG} ] && sudo cp -v ${BAL_CONFIG} etc/config/
fi
[ -f $CPUFREQ_INIT ] && sudo cp -v $CPUFREQ_INIT etc/init.d/ && sudo chmod 755 etc/init.d/cpufreq
[ -f $WIRELESS_CONFIG ] && sudo cp -v $WIRELESS_CONFIG etc/config/

if [ -f $FIX_CPU_FREQ ];then
    sudo cp -v $FIX_CPU_FREQ usr/sbin
    sudo chmod 755 usr/sbin/fixcpufreq.pl
fi
if [ -f $SYSFIXTIME_PATCH ];then
    sudo patch -p1 < $SYSFIXTIME_PATCH
fi
if [ -f $SSL_CNF_PATCH ];then
    sudo patch -p1 < $SSL_CNF_PATCH
fi

[ -d ${FMW_HOME} ] && sudo cp -a ${FMW_HOME}/* lib/firmware/
[ -f ${SYSCTL_CUSTOM_CONF} ] && sudo cp ${SYSCTL_CUSTOM_CONF} etc/sysctl.d/
[ -d boot ] || sudo mkdir -p boot
[ -d overlay ] || sudo mkdir -p overlay
[ -d rom ] || sudo mkdir -p rom
[ -d sys ] || sudo mkdir -p sys
[ -d proc ] || sudo mkdir -p proc
[ -d run ] || sudo mkdir -p run
sudo sed -e 's/ttyAMA0/ttyAML0/' -i ./etc/inittab
sudo sed -e 's/ttyS0/tty0/' -i ./etc/inittab
sudo sed -e 's/\/opt/\/etc/' -i ./etc/config/qbittorrent
sudo sed -e "s/#PermitRootLogin prohibit-password/PermitRootLogin yes/" -i ./etc/ssh/sshd_config 2>/dev/null
sss=$(date +%s)
ddd=$((sss/86400))
sudo sed -e "s/:0:0:99999:7:::/:${ddd}:0:99999:7:::/" -i ./etc/shadow
sudo sed -e 's/root::/root:$1$NA6OM0Li$99nh752vw4oe7A.gkm2xk1:/' -i ./etc/shadow

# for collectd
#[ -f ./etc/ppp/options-opkg ] && sudo mv ./etc/ppp/options-opkg ./etc/ppp/options

# for cifsd
[ -f ./etc/init.d/cifsd ] && sudo rm -f ./etc/rc.d/S98samba4
# for smbd
[ -f ./etc/init.d/smbd ] && sudo rm -f ./etc/rc.d/S98samba4
# for ksmbd
[ -f ./etc/init.d/ksmbd ] && sudo rm -f ./etc/rc.d/S98samba4 && sudo sed -e 's/modprobe ksmbd/sleep 1 \&\& modprobe ksmbd/' -i ./etc/init.d/ksmbd
# for samba4 enable smbv1 protocol
[ -f ./etc/config/samba4 ] && \
	sudo sed -e 's/services/nas/g' -i ./usr/lib/lua/luci/controller/samba4.lua && \
	[ -f ${SMB4_PATCH} ] && \
	sudo patch -p1 < ${SMB4_PATCH}
# for nfs server
if [ -f ./etc/init.d/nfsd ];then
    sudo echo "/mnt/mmcblk2p4 *(rw,sync,no_root_squash,insecure,no_subtree_check)" > ./etc/exports
sudo tee  ./etc/config/nfs <<EOF
config share
	option clients '*'
	option enabled '1'
	option options 'rw,sync,no_root_squash,insecure,no_subtree_check'
	option path '/mnt/mmcblk2p4'
EOF
fi

sudo chmod 755 ./etc/init.d/*

sudo sed -e "s/START=25/START=99/" -i ./etc/init.d/dockerd 2>/dev/null
sudo sed -e "s/START=90/START=99/" -i ./etc/init.d/dockerd 2>/dev/null
sudo sed -e "s/option wan_mode 'false'/option wan_mode 'true'/" -i ./etc/config/dockerman 2>/dev/null
sudo mv -f ./etc/rc.d/S??dockerd ./etc/rc.d/S99dockerd 2>/dev/null
sudo rm -f ./etc/rc.d/S80nginx 2>/dev/null

sudo tee  ./etc/fstab >/dev/null  <<EOF
UUID=${ROOTFS_UUID} / btrfs compress=zstd 0 1
LABEL=BOOT /boot vfat defaults 0 2
#tmpfs /tmp tmpfs defaults,nosuid 0 0
EOF
echo "/etc/fstab --->"
cat ./etc/fstab

sudo tee  ./etc/config/fstab >/dev/null  <<EOF
config global
        option anon_swap '0'
        option auto_swap '0'
        option anon_mount '0'
        option auto_mount '1'
        option delay_root '5'
        option check_fs '0'

config mount
        option target '/overlay'
        option uuid '${ROOTFS_UUID}'
        option enabled '1'
        option enabled_fsck '1'
	option options 'compress=zstd'
	option fstype 'btrfs'

config mount
        option target '/boot'
        option label 'BOOT'
        option enabled '1'
        option enabled_fsck '1'
	option fstype 'vfat'
EOF
echo "/etc/config/fstab --->"
cat ./etc/config/fstab

sudo mkdir -p ./etc/modprobe.d
sudo bash -c 'cat > ./etc/modprobe.d/99-local.conf <<EOF
blacklist snd_soc_meson_aiu_i2s
alias brnf br_netfilter
alias pwm pwm_meson
alias wifi brcmfmac
EOF'

# echo br_netfilter > ./etc/modules.d/br_netfilter
sudo echo pwm_meson > ./etc/modules.d/pwm_meson
sudo echo panfrost > ./etc/modules.d/panfrost
#echo meson_gxbb_wdt > ./etc/modules.d/watchdog

mkdir ./etc/modules.d.remove
mod_blacklist=$(cat ${KMOD_BLACKLIST})
for mod in $mod_blacklist ;do
	sudo mv -f ./etc/modules.d/${mod} ./etc/modules.d.remove/ 2>/dev/null
done

# 在高版本内核下， wifi模块目前问题太多，禁用
if [ $K510 -eq 1 ];then
    sudo mv -f ./etc/modules.d/brcm*  ./etc/modules.d.remove/ 2>/dev/null
fi

# 默认禁用sfe
sudo sed -e 's/option enabled '1'/option enabled '0'/' -i ./etc/config/sfe

[ -f ./etc/modules.d/usb-net-asix-ax88179 ] || sudo echo "ax88179_178a" > ./etc/modules.d/usb-net-asix-ax88179
# +版内核，优先启用v2驱动, +o内核则启用v1驱动
if echo $KERNEL_VERSION | grep -E '*\+$' ;then
	sudo echo "r8152_v2" > ./etc/modules.d/usb-net-rtl8152
	#echo "r8152" > ./etc/modules.d/usb-net-rtl8152
else
	sudo echo "r8152" > ./etc/modules.d/usb-net-rtl8152
fi
[ -f ./etc/config/shairport-sync ] && [ -f ${SND_MOD} ] && cp ${SND_MOD} ./etc/modules.d/
sudo echo "r8188eu" > ./etc/modules.d/rtl8188eu

sudo rm -f ./etc/rc.d/S*dockerd

# 写入版本信息
sudo tee  ./etc/flippy-openwrt-release >/dev/null  <<EOF
SOC=${SOC}
BOARD=${BOARD}
KERNEL_VERSION=${KERNEL_VERSION}
K510=${K510}
SFE_FLAG=${SFE_FLAG}
FLOWOFFLOAD_FLAG=${FLOWOFFLOAD_FLAG}
EOF

if [ $K510 -eq 1 ];then
    sudo tee   ./etc/flippy-openwrt-release  >/dev/null <<EOF
UBOOT_OVERLOAD=${UBOOT_WITHOUT_FIP}
EOF
fi

cd $TGT_ROOT/lib/modules/${KERNEL_VERSION}/
sudo rm -f build source
find . -name '*.ko' -exec ln -sf {} . \;
sudo rm -f ntfs.ko

cd $TGT_ROOT/sbin
if [ ! -x kmod ];then
	cp $KMOD .
fi
sudo ln -sf kmod depmod
sudo ln -sf kmod insmod
sudo ln -sf kmod lsmod
sudo ln -sf kmod modinfo
sudo ln -sf kmod modprobe
sudo ln -sf kmod rmmod
sudo ln -sf /usr/bin/ntfs-3g mount.ntfs

cd $TGT_ROOT/lib/firmware
sudo mv *.hcd brcm/ 2>/dev/null
if [ -f "$REGULATORY_DB" ];then
	sudo tar xzf "$REGULATORY_DB"
fi

cd brcm
source $TGT_ROOT/usr/lib/armbian/armbian-common

# gtking/gtking pro 采用 bcm4356 wifi/bluetooth 模块
get_random_mac
sudo sed -e "s/macaddr=00:90:4c:1a:10:01/macaddr=${MACADDR}/" "brcmfmac4356-sdio.txt" > "brcmfmac4356-sdio.azw,gtking.txt"

# Phicomm N1 采用 bcm43455 wifi/bluetooth 模块
get_random_mac
sed -e "s/macaddr=b8:27:eb:74:f2:6c/macaddr=${MACADDR}/" "brcmfmac43455-sdio.txt" > "brcmfmac43455-sdio.phicomm,n1.txt"

# HK1 Box 和 H96 Max X3 采用 bcm54339 wifi/bluetooth 模块
get_random_mac
sudo sed -e "s/macaddr=00:90:4c:c5:12:38/macaddr=${MACADDR}/" "brcmfmac4339-sdio.ZP.txt" > "brcmfmac4339-sdio.amlogic,sm1.txt"

sudo rm -f ${TGT_ROOT}/etc/bench.log
sudo tee ${TGT_ROOT}/etc/crontabs/root >/dev/null <<EOF
37 5 * * * /etc/coremark.sh
EOF

[ -f $CPUSTAT_PATCH ] && \
cd $TGT_ROOT/usr/lib/lua/luci/view/admin_status && \
sudo patch -p0 < ${CPUSTAT_PATCH}

# clean temp_dir
cd $TEMP_DIR
sudo umount -f $LINUX_BOOT $LINUX_ROOT $TGT_BOOT $TGT_ROOT 

# 写入完整的 u-boot 到 镜像文件
if [ -f ${UBOOT_WITH_FIP} ];then
    sudo dd if=${UBOOT_WITH_FIP}  of=${TGT_DEV} conv=fsync,notrunc bs=512 skip=1 seek=1
    sudo dd if=${UBOOT_WITH_FIP}  of=${TGT_DEV} conv=fsync,notrunc bs=1 count=444
fi

(sudo  losetup -D && cd $WORK_DIR && sudo rm -rf $TEMP_DIR && sudo losetup -D)
sync
echo
echo "镜像打包已完成，再见!"
