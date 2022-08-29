#!/bin/bash
MODEL=Z20_250_12
PATH_XILINX_SDK=/opt/Xilinx/SDK/2019.1
PATH_XILINX_VIVADO=/opt/Xilinx/Vivado/2020.1
RP_UBUNTU=redpitaya_ubuntu_04-oct-2021.tar.gz
SCHROOT_CONF_PATH=/etc/schroot/chroot.d/red-pitaya-ubuntu.conf

./settings.sh

export ENABLE_LICENSING=0
export CROSS_COMPILE=arm-linux-gnueabihf-
export ARCH=arm
export PATH=$PATH:$PATH_XILINX_VIVADO/bin
export PATH=$PATH:$PATH_XILINX_SDK/bin
export PATH=$PATH:$PATH_XILINX_SDK/gnu/aarch32/lin/gcc-arm-linux-gnueabi/bin/
ENABLE_PRODUCTION_TEST=0
GIT_COMMIT_SHORT=`git rev-parse --short HEAD`

schroot -c red-pitaya-ubuntu <<- EOL_CHROOT
make -f Makefile api CROSS_COMPILE="" REVISION=$GIT_COMMIT_SHORT MODEL=$MODEL ENABLE_PRODUCTION_TEST=$ENABLE_PRODUCTION_TEST
make -f Makefile scpi CROSS_COMPILE="" REVISION=$GIT_COMMIT_SHORT MODEL=$MODEL ENABLE_PRODUCTION_TEST=$ENABLE_PRODUCTION_TEST
EOL_CHROOT