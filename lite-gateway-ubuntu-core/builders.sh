#!/bin/bash

export SNAP=$(mktemp -d /tmp/lite.XXXXXX)

echo "deb http://archive.ubuntu.com/ubuntu/ xenial-updates main universe" | sudo tee -a /etc/apt/sources.list
echo "deb http://archive.ubuntu.com/ubuntu/ xenial-proposed main universe" | sudo tee -a /etc/apt/sources.list

sudo apt -q=2 update
sudo apt -q=2 install -y --no-install-recommends dosfstools snapcraft snapd squashfs-tools ubuntu-image pxz

set -ex

trap cleanup_exit INT TERM EXIT

cleanup_exit()
{
  cd ${WORKSPACE}
  sudo umount ${SNAP} || true
  sudo rm -rf ${SNAP} || true
  rm -f ubuntu-image_*
}

# sbin isn't in the PATH by default and prevent to find mkfs.vfat
export PATH="/usr/sbin:/sbin:$PATH"

tar xf snap.tar -C ${HOME}
for machine in ${MACHINES}; do
  wget -q https://git.linaro.org/ci/job/configs.git/blob_plain/HEAD:/lite-gateway-ubuntu-core/${machine}.json -O ${machine}.json
  cat ${machine}.json | snap sign -k madper-new > ${machine}.model
done

snap download ubuntu-image

sudo mount -o loop -t squashfs ubuntu-image_*.snap ${SNAP}
for machine in ${MACHINES}; do
  if [ "${machine}" == "hummingboard" ]; then
    git clone --depth 1 https://github.com/madper/hummingboard-kernel.git
    snapcraft --target-arch armhf snap hummingboard-kernel --output hummingboard-kernel.snap

    git clone --depth 1 https://github.com/madper/hummingboard-gadget.git
    snapcraft --target-arch armhf snap hummingboard-gadget --output hummingboard-gadget.snap

    ${SNAP}/command-ubuntu-image.wrapper -c beta \
      --extra-snaps hummingboard-kernel.snap \
      --extra-snaps hummingboard-gadget.snap \
      -o ubuntu-core-16-${machine}-lite.img ${machine}.model
  else
    ${SNAP}/command-ubuntu-image.wrapper -c beta \
      -o ubuntu-core-16-${machine}-lite.img ${machine}.model
  fi
done
