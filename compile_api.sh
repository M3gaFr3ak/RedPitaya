#!/bin/bash
./opt/Xilinx/Vivado/2020.1/settings64.sh
MODEL=Z20_250

export CROSS_COMPILE=arm-linux-gnueabihf-

schroot -v -c red-pitaya-ubuntu <<- EOL_CHROOT
make api MODEL=$MODEL
make scpi MODEL=$MODEL
EOL_CHROOT