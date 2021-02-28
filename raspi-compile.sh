#!/bin/bash

export MAKEFLAGS="-j$(nproc) KBUILD_DEBARCH=arm64 TARGET_LIST=arm64 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-"
unset CONFIG_DEBUG_INFO && make $MAKEFLAGS bindeb-pkg

exit 0
