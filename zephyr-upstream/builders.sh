#!/bin/bash

sudo apt-get -q=2 update
sudo apt-get -q=2 -y install git ninja-build g++ g++-multilib gperf python3-ply \
    python3-yaml gcc-arm-none-eabi python-requests rsync device-tree-compiler \
    python3-pip python3-setuptools python3-wheel

set -ex

# pip as shipped by distro may be not up to date enough to support some
# quirky PyPI packages, specifically cmake was caught like that.
sudo pip3 install --upgrade pip

# Distro package is too old for Zephyr
sudo pip3 install pyelftools pykwalify
# Pre-installed CMake is too old for the latest Zephyr
# Recent recommendation to users is to install it via PyPI, let'd do the same
sudo pip3 install cmake
#cmake_version=3.9.5
#wget -q https://cmake.org/files/v3.9/cmake-${cmake_version}-Linux-x86_64.tar.gz
#tar xf cmake-${cmake_version}-Linux-x86_64.tar.gz
#cp -a cmake-${cmake_version}-Linux-x86_64/bin/* /usr/local/bin/
#cp -a cmake-${cmake_version}-Linux-x86_64/share/* /usr/local/share/
#rm -rf cmake-${cmake_version}-Linux-x86_64
#cmake -version

sudo pip3 install west
west --version

git clone -b ${BRANCH} https://github.com/zephyrproject-rtos/zephyr.git
west init -l zephyr/
west update

cd zephyr
git clean -fdx
if [ -n "${GIT_COMMIT}" ]; then
  git checkout ${GIT_COMMIT}
fi
echo "GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD)" > ${WORKSPACE}/env_var_parameters

head -5 Makefile

# Toolchains are pre-installed and come from:
# https://armkeil.blob.core.windows.net/developer/Files/downloads/gnu-rm/7-2018q2/gcc-arm-none-eabi-7-2018-q2-update-linux.tar.bz2
# https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v0.10.1/zephyr-sdk-0.10.1-setup.run
# To install Zephyr SDK: ./zephyr-sdk-0.10.1-setup.run --quiet --nox11 -- <<< "${HOME}/srv/toolchain/zephyr-sdk-0.10.1"

export GNUARMEMB_TOOLCHAIN_PATH="${HOME}/srv/toolchain/gcc-arm-none-eabi-7-2018-q2-update"
# We building with the gnuarmemb toolchain, we need ZEPHYR_SDK_INSTALL_DIR to find things like conf
export ZEPHYR_SDK_INSTALL_DIR="${HOME}/srv/toolchain/zephyr-sdk-0.10.1"

# Set build environment variables
export LANG=C.UTF-8
ZEPHYR_BASE=${WORKSPACE}/zephyr
PATH=${ZEPHYR_BASE}/scripts:${PATH}
OUTDIR=${HOME}/srv/zephyr/${BRANCH}/${ZEPHYR_TOOLCHAIN_VARIANT}/${PLATFORM}
export LANG ZEPHYR_BASE PATH
CCACHE_DIR="${HOME}/srv/ccache-zephyr/${BRANCH}"
CCACHE_UNIFY=1
CCACHE_SLOPPINESS=file_macro,include_file_mtime,time_macros
USE_CCACHE=1
export CCACHE_DIR CCACHE_UNIFY CCACHE_SLOPPINESS USE_CCACHE
env |grep '^ZEPHYR'
mkdir -p "${CCACHE_DIR}"
rm -rf ${OUTDIR}

echo ""
echo "########################################################################"
echo "    sanitycheck"
echo "########################################################################"

time ${ZEPHYR_BASE}/scripts/sanitycheck \
  --platform ${PLATFORM} \
  --inline-logs \
  --build-only \
  --outdir ${OUTDIR} \
  --enable-slow \
  -x=USE_CCACHE=${USE_CCACHE}

cd ${ZEPHYR_BASE}
# OUTDIR is already per-platform, but it may get contaminated with unrelated
# builds e.g. due to bugs in sanitycheck script. It however stores builds in
# per-platform named subdirs under its --outdir (${OUTDIR} in our case), so
# we use ${OUTDIR}/${PLATFORM} paths below.
find ${OUTDIR}/${PLATFORM} -type f -name '.config' -exec rename 's/.config/zephyr.config/' {} +
rsync -avm \
  --include=zephyr.bin \
  --include=zephyr.config \
  --include=zephyr.elf \
  --include='*/' \
  --exclude='*' \
  ${OUTDIR}/${PLATFORM} ${WORKSPACE}/out/
find ${OUTDIR}/${PLATFORM} -type f -name 'zephyr.config' -delete
# If there are support files, ship them.
BOARD_CONFIG=$(find "${ZEPHYR_BASE}/boards/" -type f -name "${PLATFORM}_defconfig")
BOARD_DIR=$(dirname ${BOARD_CONFIG})
test -d "${BOARD_DIR}/support" && rsync -avm "${BOARD_DIR}/support" "${WORKSPACE}/out/${PLATFORM}"

cd ${WORKSPACE}/
echo "=== contents of ${WORKSPACE}/out/ ==="
find out
echo "=== end of contents of ${WORKSPACE}/out/ ==="

CCACHE_DIR=${CCACHE_DIR} ccache -M 30G
CCACHE_DIR=${CCACHE_DIR} ccache -s
