#!/bin/bash

# Init script to use ramdisk used in bootrr testing
INITRAMFS_RAMDISK=$(cat <<EOF
#!/bin/sh

HOME=/root
PATH=/sbin:/bin:/usr/sbin:/usr/bin
PS1="linaro-test [rc=\$(echo \\\$?)]# "
export HOME PS1 PATH

do_mount_fs() {
	grep -q "\$1" /proc/filesystems || return
	test -d "\$2" || mkdir -p "\$2"
	mount -t "\$1" "\$1" "\$2"
}

do_mknod() {
	test -e "\$1" || mknod "\$1" "\$2" "\$3" "\$4"
}

mkdir -p /proc
mount -t proc proc /proc

do_mount_fs sysfs /sys
do_mount_fs debugfs /sys/kernel/debug
do_mount_fs devtmpfs /dev
do_mount_fs devpts /dev/pts
do_mount_fs tmpfs /dev/shm

mkdir -p /run
mkdir -p /var/run

/sbin/udevd --daemon
/bin/udevadm trigger

do_mknod /dev/console c 5 1
do_mknod /dev/null c 1 3
do_mknod /dev/zero c 1 5

echo -n 'BOOT TIME: '
cat /proc/uptime

if \$(grep -q bootrr-auto /proc/cmdline); then
	for TEST in \$(tr "\0" "\n" < /proc/device-tree/compatible); do
		if [ -x "/usr/bin/\${TEST}" ]; then
			/usr/bin/\${TEST}
		fi
	done

	echo ~~~~~~~~~~~~~~~~~~~~~
fi

exec sh </dev/console >/dev/console 2>/dev/console
EOF
)

# Init script to mount rootfs mainly used in functional testing
INITRAMFS_ROOTFS=$(cat <<EOF
#!/bin/sh

HOME=/root
PATH=/sbin:/bin:/usr/sbin:/usr/bin
export HOME PATH

do_mount_fs() {
	grep -qa "\$1" /proc/filesystems || return
	test -d "\$2" || mkdir -p "\$2"
	mount -t "\$1" "\$1" "\$2"
}

do_mknod() {
	test -e "\$1" || mknod "\$1" "\$2" "\$3" "\$4"
}

rescue_shell() {
	echo "Failed to mount rootfs (__ROOTFS_PARTITION__), executing rescue shell..."
	export PS1="linaro-test [rc=\$(echo \\\$?)]# "
	exec sh </dev/console >/dev/console 2>/dev/console
}

mkdir -p /proc
mount -t proc proc /proc

do_mount_fs sysfs /sys
do_mount_fs devtmpfs /dev

mkdir -p /run
mkdir -p /var/run
/sbin/udevd --daemon
/bin/udevadm trigger

do_mknod /dev/console c 5 1
do_mknod /dev/null c 1 3
do_mknod /dev/zero c 1 5

if [ ! -b "__ROOTFS_PARTITION__" ]; then
	echo "Waiting for root device __ROOTFS_PARTITION__ ..."
	while [ ! -b "__ROOTFS_PARTITION__" ]; do
		sleep 1s
	done;
fi

mkdir -p /rootfs
mount -o ro __ROOTFS_PARTITION__ /rootfs || rescue_shell

umount /proc
umount /sys
umount /dev

echo "All done. Switching to real root."
exec switch_root /rootfs /sbin/init
EOF
)

set -x

wget_error() {
	wget -c $1 -P out/
	retcode=$?
	if [ $retcode -ne 0 ]; then
		exit $retcode
	fi
}

function copy_tarball_to_rootfs() {
	tarball_file=$1
	target_file=$2
	target_file_type=$3

	if [[ $target_file_type = *"cpio archive"* ]]; then
		mkdir -p out/tarball
		tar -xvf $tarball_file -C out/tarball
		cd out/tarball
		find . | cpio -oA -H newc -F ../../$target_file
		cd ../../
		rm -rf out/tarball
	else
		required_size=$(${GZ} -l $tarball_file | tail -1 | awk '{print $2}')
		required_size=$(( $required_size / 1024 ))

		sudo e2fsck -y $target_file
		block_count=$(sudo dumpe2fs -h $target_file | grep "Block count" | awk '{print $3}')
		block_size=$(sudo dumpe2fs -h $target_file | grep "Block size" | awk '{print $3}')
		current_size=$(( $block_size * $block_count / 1024 ))

		final_size=$(( $current_size + $required_size + 32768 ))
		sudo resize2fs -p $target_file "$final_size"K

		mkdir -p out/rootfs_mount
		sudo mount -o loop $target_file out/rootfs_mount
		sudo tar -xvf $tarball_file -C out/rootfs_mount
		sudo umount out/rootfs_mount
		rm -rf out/rootfs_mount
	fi
}

function create_ramdisk_from_folder() {
	ramdisk_name=$1
	ramdisk_folder=$2
	ramdisk="$ramdisk_name.cpio"

	cd $ramdisk_folder
	find . | cpio -ov -H newc > "../../out/$ramdisk"
	${GZ} "../../out/$ramdisk"
	ramdisk=$ramdisk.gz
	echo "$ramdisk"
	cd ../
}

function overlay_ramdisk_from_git() {
	git_repo=$1
	git_branch=$2

	# clone git repo and get revision details
	project_name="$(basename "$git_repo" .git)"
	project_folder="$project_name"
	project_ramdisk_folder="$(realpath $project_folder)/rootfs"
	git clone -b "$git_branch" --depth 1 "$git_repo" "$project_folder"
	cd "$project_folder"
	DESTDIR="$project_ramdisk_folder" prefix="/usr" make install 2>&1 > /dev/null
	project_name="$project_name-$(git rev-parse --short HEAD)"

	# created the overlayed ramdisk involves the creation of new ramdisk from folder and
	# concat both into a single file
	project_ramdisk_overlay=$(create_ramdisk_from_folder $project_name $project_ramdisk_folder)
	cd ../

	overlayed_ramdisk_file="$(basename $ramdisk_file)+$(basename $project_ramdisk_overlay)"
	cat "$ramdisk_file" "out/$project_ramdisk_overlay" > "out/$overlayed_ramdisk_file"
	echo "$overlayed_ramdisk_file"
	rm -rf "$project_folder"
}

function overlay_ramdisk_from_file() {
	file_name=$1
	file_cpio="out/$2.cpio"

	echo $file_name | cpio -ov -H newc > $file_cpio
	${GZ} $file_cpio
	file_cpio=$file_cpio.gz

	overlayed_ramdisk_file="$(basename $ramdisk_file)+$(basename $file_cpio)"
	cat "$ramdisk_file" "$file_cpio" > "out/$overlayed_ramdisk_file"
	echo "$overlayed_ramdisk_file"
}

# Set default tools to use
if [ -z "${GZ}" ]; then
	export GZ=gzip
fi

# Set per MACHINE configuration
case "${MACHINE}" in
	dragonboard410c)
		KERNEL_DT_URL=${KERNEL_DT_URL_dragonboard410c}
		if [ ! -z "${RAMDISK_URL_dragonboard410c}" ]; then
			RAMDISK_URL=${RAMDISK_URL_dragonboard410c}
		fi
		if [ ! -z "${ROOTFS_URL_dragonboard410c}" ]; then
			ROOTFS_URL=${ROOTFS_URL_dragonboard410c}
		fi
		FIRMWARE_URL=${FIRMWARE_URL_dragonboard410c}
		BOOTIMG_PAGESIZE=2048
		BOOTIMG_BASE=0x80000000
		RAMDISK_BASE=0x84000000
		ROOTFS_PARTITION=/dev/mmcblk0p10
		SERIAL_CONSOLE=ttyMSM0
		;;
	dragonboard820c)
		KERNEL_DT_URL=${KERNEL_DT_URL_dragonboard820c}
		if [ ! -z "${RAMDISK_URL_dragonboard820c}" ]; then
			RAMDISK_URL=${RAMDISK_URL_dragonboard820c}
		fi
		if [ ! -z "${ROOTFS_URL_dragonboard820c}" ]; then
			ROOTFS_URL=${ROOTFS_URL_dragonboard820c}
		fi
		FIRMWARE_URL=${FIRMWARE_URL_dragonboard820c}
		BOOTIMG_PAGESIZE=4096
		BOOTIMG_BASE=0x80000000
		RAMDISK_BASE=0x84000000
		ROOTFS_PARTITION=/dev/sda1
		SERIAL_CONSOLE=ttyMSM0
		;;
	sdm845_mtp)
		KERNEL_DT_URL=${KERNEL_DT_URL_sdm845_mtp}
		if [ ! -z "${RAMDISK_URL_sdm845_mtp}" ]; then
			RAMDISK_URL=${RAMDISK_URL_sdm845_mtp}
		fi
		if [ ! -z "${ROOTFS_URL_sdm845_mtp}" ]; then
			ROOTFS_URL=${ROOTFS_URL_sdm845_mtp}
		fi
		FIRMWARE_URL=${FIRMWARE_URL_sdm845_mtp}
		BOOTIMG_PAGESIZE=2048
		BOOTIMG_BASE=0x80000000
		RAMDISK_BASE=0x84000000
		ROOTFS_PARTITION=/dev/sda8 # XXX: using Android userdata since we don't have Linux parttable
		SERIAL_CONSOLE=ttyMSM0
		;;
	*)
		echo "Currently MACHINE: ${MACHINE} isn't supported"
		exit 1
		;;
esac

# Validate required parameters
if [ -z "${KERNEL_IMAGE_URL}" ]; then
	echo "ERROR: KERNEL_IMAGE_URL is empty"
	exit 1
fi
if [ -z "${RAMDISK_URL}" ]; then
	echo "ERROR: RAMDISK_URL is empty"
	exit 1
fi
if [ -z "${ROOTFS_URL}" ]; then
	echo "ERROR: RAMDISK_URL is empty"
	exit 1
fi

# Build information
mkdir -p out
cat > out/HEADER.textile << EOF

h4. QCOM Landing Team - $BUILD_DISPLAY_NAME

Build description:
* Build URL: "$BUILD_URL":$BUILD_URL
* Kernel image URL: $KERNEL_IMAGE_URL
* Kernel dt URL: $KERNEL_DT_URL
* kernel modules URL: $KERNEL_MODULES_URL
* Ramdisk URL: $RAMDISK_URL
* RootFS URL: $ROOTFS_URL
* Firmware URL: $FIRMWARE_URL
EOF

# Ramdisk/RootFS image, modules populate
wget_error ${RAMDISK_URL}
ramdisk_file=out/$(basename ${RAMDISK_URL})
ramdisk_file_type=$(file $ramdisk_file)

wget_error ${ROOTFS_URL}
rootfs_file=out/$(basename ${ROOTFS_URL})
rootfs_file_type=$(file $rootfs_file)

if [[ ! -z "${KERNEL_MODULES_URL}" ]]; then
	wget_error ${KERNEL_MODULES_URL}
	modules_file="out/$(basename ${KERNEL_MODULES_URL})"

	# XXX: Compress modules to gzip for use copy_tarball_to_rootfs
	# generic code to calculate size in ext4 filesystem
	modules_file_type=$(file $modules_file)
	if [[ $modules_file_type = *"XZ compressed data"* ]]; then
		xz -d $modules_file
		modules_file="out/$(basename ${KERNEL_MODULES_URL} .xz)"
		${GZ} $modules_file
		modules_file=$modules_file.gz
	elif [[ $modules_file_type = *"bzip2 compressed data"* ]]; then
		bzip2 -d $modules_file
		modules_file="out/$(basename ${KERNEL_MODULES_URL} .bz2)"
		${GZ} $modules_file
		modules_file=$modules_file.gz
	fi
fi
if [[ ! -z "${FIRMWARE_URL}" ]]; then
	wget_error ${FIRMWARE_URL}
	firmware_file="out/$(basename ${FIRMWARE_URL} .bz2)"
fi

rootfs_comp=''
if [[ $rootfs_file_type = *"gzip compressed data"* ]]; then
	${GZ} -d $rootfs_file
	rootfs_file=out/$(basename ${ROOTFS_URL} .gz)
	rootfs_file_type=$(file $rootfs_file)
	rootfs_comp='gz'
fi
if [[ $ramdisk_file_type = *"gzip compressed data"* ]]; then
	${GZ} -d $ramdisk_file
	ramdisk_file=out/$(basename ${RAMDISK_URL} .gz)
	ramdisk_file_type=$(file $ramdisk_file)
	ramdisk_comp='gz'
fi

if [[ $rootfs_file_type = *"Android sparse image"* ]]; then
	rootfs_file_ext4=out/$(basename ${rootfs_file} .img).ext4
	simg2img $rootfs_file $rootfs_file_ext4
	rootfs_file=$rootfs_file_ext4
elif [[ $rootfs_file_type = *"ext4 filesystem data"* ]]; then
	rootfs_file=$rootfs_file
else
	echo "ERROR: ROOTFS_IMAGE type isn't supported: $rootfs_file_type"
	exit 1
fi

if [[ ! -z "$modules_file" ]]; then
	copy_tarball_to_rootfs "$modules_file" "$ramdisk_file" "$ramdisk_file_type"
	copy_tarball_to_rootfs "$modules_file" "$rootfs_file" "$rootfs_file_type"
fi

if [[ ! -z "${firmware_file}" ]]; then
	copy_tarball_to_rootfs "$firmware_file" "$ramdisk_file" "$ramdisk_file_type"
	copy_tarball_to_rootfs "$firmware_file" "$rootfs_file" "$rootfs_file_type"
fi

if [[ $rootfs_file_type = *"Android sparse image"* ]]; then
	rootfs_file_img=out/$(basename $rootfs_file .ext4).img
	img2simg $rootfs_file $rootfs_file_img
	rm $rootfs_file
	rootfs_file=$rootfs_file_img
fi


if [[ $ramdisk_comp = "gz" ]]; then
	${GZ} $ramdisk_file
	ramdisk_file="$ramdisk_file".gz
	ramdisk_file_type=$(file $ramdisk_file)
	ramdisk_comp=""
fi
if [[ $rootfs_comp = "gz" ]]; then
	${GZ} $rootfs_file
	rootfs_file="$rootfs_file".gz
	rootfs_file_type=$(file $rootfs_file)
	rootfs_comp=""
fi

# Compress kernel image if isn't
wget_error ${KERNEL_IMAGE_URL}
kernel_file=out/$(basename ${KERNEL_IMAGE_URL})
kernel_file_type=$(file $kernel_file)
if [[ ! $kernel_file_type = *"gzip compressed data"* ]]; then
	${GZ} -kf $kernel_file
	kernel_file=$kernel_file.gz
fi

# Making android boot img
dt_mkbootimg_arg=""
if [[ ! -z "${KERNEL_DT_URL}" ]]; then
	wget_error ${KERNEL_DT_URL}
	dt_mkbootimg_arg="--dt out/$(basename ${KERNEL_DT_URL})"
fi

# Overlay ramdisk to install tools, artifacts, etc
if [[ ! -z "${BOOTRR_GIT_REPO}" ]]; then
	overlayed_ramdisk_file="out/$(overlay_ramdisk_from_git "${BOOTRR_GIT_REPO}" "${BOOTRR_GIT_BRANCH}")"
	ramdisk_file=$overlayed_ramdisk_file
fi

# Create boot image (bootrr), overlay the init script to setup the ramdisk
init_file=init
echo "${INITRAMFS_RAMDISK}" > ./$init_file
chmod +x ./$init_file
overlayed_ramdisk_file="out/$(overlay_ramdisk_from_file "$init_file" "init_ramdisk")"
rm -f $init_file

boot_file=boot-${KERNEL_FLAVOR}-${KERNEL_VERSION}-${BUILD_NUMBER}-${MACHINE}.img
skales-mkbootimg \
	--kernel $kernel_file \
	--ramdisk $overlayed_ramdisk_file \
	--output out/$boot_file \
	$dt_mkbootimg_arg \
	--pagesize "${BOOTIMG_PAGESIZE}" \
	--base "${BOOTIMG_BASE}" \
	--ramdisk_base "${RAMDISK_BASE}" \
	--cmdline "root=/dev/ram0 init=/init rw console=tty0 console=${SERIAL_CONSOLE},115200n8"

# Create boot image (functional), sdm845-mtp requires an initramfs to mount the rootfs and then
# exec switch_rootfs, use the same method in other boards too
boot_rootfs_file=boot-rootfs-${KERNEL_FLAVOR}-${KERNEL_VERSION}-${BUILD_NUMBER}-${MACHINE}.img
init_file=init
echo "${INITRAMFS_ROOTFS}" | sed -e "s|__ROOTFS_PARTITION__|${ROOTFS_PARTITION}|g" > ./$init_file
chmod +x ./$init_file
overlayed_ramdisk_file="out/$(overlay_ramdisk_from_file "$init_file" "init_rootfs")"
rm -f $init_file

skales-mkbootimg \
	--kernel $kernel_file \
	--ramdisk $overlayed_ramdisk_file \
	--output out/$boot_rootfs_file \
	$dt_mkbootimg_arg \
	--pagesize "${BOOTIMG_PAGESIZE}" \
	--base "${BOOTIMG_BASE}" \
	--ramdisk_base "${RAMDISK_BASE}" \
	--cmdline "root=/dev/ram0 init=/init rw console=tty0 console=${SERIAL_CONSOLE},115200n8"

echo BOOT_FILE=$boot_file >> builders_out_parameters
echo BOOT_ROOTFS_FILE=$boot_rootfs_file >> builders_out_parameters
echo ROOTFS_FILE="$(basename $rootfs_file)" >> builders_out_parameters

ls -l out/
