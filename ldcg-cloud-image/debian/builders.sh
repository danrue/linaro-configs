#!/bin/bash

export image_name=$(mktemp -u -p'debian-cloud-image' | sed -e 's+/+-+g')
export mountpoint=$(mktemp -d /tmp/${image_name}.XXXXXX)

echo "deb http://obs.linaro.org/ERP:/18.06/Debian_9 ./" | sudo tee /etc/apt/sources.list.d/erp-18.06.list

sudo apt-get -q=2 update
sudo apt-get -q=2 install -y --no-install-recommends cpio qemu-utils virtinst libvirt-clients

virt-host-validate

sudo virsh pool-list --all
sudo virsh net-list --all

set -ex

trap cleanup_exit INT TERM EXIT

cleanup_exit()
{
  cd ${WORKSPACE}
  sudo virsh vol-delete --pool default ${image_name}.img || true
  sudo virsh destroy ${image_name} || true
  sudo virsh undefine ${image_name} || true
  sudo umount ${mountpoint} || true
  sudo kpartx -dv ${image_name}.img || true
  sudo rm -rf ${mountpoint} || true
  sudo rm -f ${image_name}.img
}

wget -q https://git.linaro.org/ci/job/configs.git/blob_plain/HEAD:/ldcg-cloud-image/debian/preseed.cfg -O preseed.cfg

sudo virt-install \
  --name ${image_name} \
  --initrd-inject preseed.cfg \
  --extra-args "interface=auto noshell auto=true DEBIAN_FRONTEND=text" \
  --disk=pool=default,size=2.0,format=raw \
  --network=network=default, \
  --memory 2048 \
  --location http://deb.debian.org/debian/dists/stable/main/installer-arm64/ \
  --noreboot

set +ex
while [ true ]; do
  sleep 1
  vm_running=$(sudo virsh list --name --state-running | grep "^${image_name}" | wc -l)
  [ "${vm_running}" -eq "0" ] && break
done
set -ex

sudo virsh list --all

mkdir -p out
cp preseed.cfg out/debian-stretch-arm64-preseed.cfg

sudo cp -a /var/lib/libvirt/images/${image_name}.img .

sudo virsh vol-download --pool default --vol ${image_name}.img --file ${image_name}.img

for device in $(sudo kpartx -avs ${image_name}.img | cut -d' ' -f3); do
  partition=$(echo ${device} | cut -d'p' -f3)
  [ "${partition}" = "2" ] && sudo mount /dev/mapper/${device} ${mountpoint}
done

cp -a ${mountpoint}/boot/*-arm64 out/

sudo qemu-img convert -c -O qcow2 ${image_name}.img out/debian-erp-cloud-image.qcow2
sudo chown -R buildslave:buildslave out