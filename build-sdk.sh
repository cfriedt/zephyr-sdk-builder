#!/usr/bin/env bash
# Copyright (c) 2022 Meta
#
# SPDX-License-Identifier: Apache-2.0
#
# Zephyr SDK Builder for RPM-based systems
#
# Transposed from upstream
# See https://github.com/zephyrproject-rtos/sdk-ng/blob/main/.github/workflows/ci.yml

set -e
#set -x

# Constants

RUNNER_OS="$(uname -s)"
GH="https://github.com/"
USR="zephyrproject-rtos"
PRJ="sdk-ng"
MATRIX_ARCHIVES="tar.gz" # 1 type of tarball is fine
TAR="tar"

ALL_HOSTS=(\
    linux-x86_64 \
    linux-aarch64 \
    macos-x86_64 \
    macos-aarch64 \
    windows-x86_64 \
)
ALL_TARGETS=(\
    aarch64-zephyr-elf arc64-zephyr-elf arc-zephyr-elf arm-zephyr-eabi \
    mips-zephyr-elf nios2-zephyr-elf riscv64-zephyr-elf sparc-zephyr-elf \
    x86_64-zephyr-elf xtensa-espressif_esp32s2_zephyr-elf \
    xtensa-espressif_esp32_zephyr-elf xtensa-intel_apl_adsp_zephyr-elf \
    xtensa-intel_bdw_adsp_zephyr-elf xtensa-intel_byt_adsp_zephyr-elf \
    xtensa-intel_s1000_zephyr-elf xtensa-nxp_imx8m_adsp_zephyr-elf \
    xtensa-nxp_imx_adsp_zephyr-elf xtensa-sample_controller_zephyr-elf \
)

# Default Variables

DEFAULT_SDK_NG_PATCH_DIR="$PWD"
DEFAULT_SDK_VERSION="0.15.2"
DEFAULT_PYTHON_VERSION="python3.8"
DEFAULT_RUNNER_TEMP="$HOME/build-zephyr-sdk"
DEFAULT_POKY_DOWNLOADS="${DEFAULT_RUNNER_TEMP}/poky-downloads"
DEFAULT_NO_DEPS=0
DEFAULT_DRY_RUN=0
DEFAULT_COMMANDS=""
DEFAULT_PROXY=""
DEFAULT_YES=""

# Initialized Variables

SDK_NG_PATCH_DIR="$DEFAULT_SDK_NG_PATCH_DIR"
SDK_VERSION="$DEFAULT_SDK_VERSION"
PYTHON_VERSION="$DEFAULT_PYTHON_VERSION"
RUNNER_TEMP="$DEFAULT_RUNNER_TEMP"
export POKY_DOWNLOADS="$DEFAULT_POKY_DOWNLOADS"

MATRIX_HOSTS=""
MATRIX_TARGETS=""

NO_DEPS=$DEFAULT_NO_DEPS
DRY_RUN=$DEFAULT_DRY_RUN

COMMANDS="$DEFAULT_COMMANDS"
PROXY="$DEFAULT_PROXY"
YES="$DEFAULT_YES"

SDK_GIT_REF="v$SDK_VERSION"

export WORKSPACE="$RUNNER_TEMP/workspace"
export GITHUB_WORKSPACE="$RUNNER_TEMP/$PRJ"

export CT_NG=$WORKSPACE/crosstool-ng/bin/ct-ng
export CT_PREFIX="${WORKSPACE}/output"


# Functions

install_dependencies() {
    # Transposed from upstream Dockerfile / Ubuntu packages
    #
    # See https://github.com/zephyrproject-rtos/docker-sdk-build/blob/master/Dockerfile

    # skipped some environment manipulation.. might be relevant

    # The package sets are based on Yocto & crosstool-ng docs/references
    # notable differences:
    # g++ (apt) -> gcc-c++ (dnf)
    # libncurses5-dev (apt) -> ncurses-devel (dnf)
    # python3-dev (apt) -> platform-python-devel (dnf)
    # libtool-bin (apt) -> libtool (dnf)
    # xz-utils (apt) -> xz (dnf)
    # libstdc++6 (apt) -> libstdc++ libstdc++-static (dnf)
    # build-essential (apt) -> make automake gcc gcc-c++ kernel-devel (dnf)
    # python (apt) -> python3 (dnf)
    # debianutils (apt) -> "" (dnf)
    # iputils-ping (apt) -> iputils (dnf)
    sudo dnf install ${YES} \
        gcc gcc-c++ gperf bison flex texinfo help2man make ncurses-devel \
        platform-python-devel autoconf automake libtool libtool gawk wget bzip2 \
        xz unzip patch libstdc++ diffstat make automake gcc gcc-c++ kernel-devel chrpath \
        socat cpio python3 python3 python3-pip python3-pexpect \
        python3-setuptools  iputils ca-certificates \
        ninja-build

    # notable differences:
    # p7zip-full (apt) -> p7zip p7zip-plugins (dnf)
    sudo dnf install ${YES} makeself tree curl p7zip p7zip-plugins

    # skip installation of awscli

    sudo dnf install ${YES} meson

    sudo dnf install ${YES} git

    # needed to build host tools (required by Yocto)
    sudo dnf install ${YES} rpcgen

    # needed by this script (and upstream CI)
    sudo dnf install ${YES} jq
}

clean() {
    # Clean up working directories
    shopt -s dotglob
    sudo rm -rf ${GITHUB_WORKSPACE}/*
    sudo rm -rf ${WORKSPACE}/*
    shopt -u dotglob
}

set_up_build_environment() {
    # Install common dependencies
    # notable differences:
    # libboost-dev (apt) -> boost-devel (dnf)
    # libboost-regex-dev (apt) -> boost-regex (dnf)
    # libncurses5-dev (apt) -> ncurses-devel (dnf)
    # libtool-bin (apt) -> libtool (dnf)
    # libtool-doc (apt) -> libtool (dnf)
    sudo dnf install ${YES} \
        autoconf automake bison flex gettext \
        help2man boost-devel boost-regex \
        ncurses-devel libtool libtool \
        pkg-config texinfo zip

    # Install dependencies for cross compilation
    # TBD (focus on x86_64 package for now)

    # e.g. set_up_buildenvironment_macOS
}

check_out_source_code() {
    # Clones sdk-ng ($PRJ) into $GITHUB_WORKSPACE
    mkdir -p $RUNNER_TEMP
    pushd $RUNNER_TEMP

    rm -Rf "$PRJ"

    # git "shallow" cloning is different when cloning from a a commit hash vs a branch
    if git_ref_is_sha "$SDK_GIT_REF"; then
        mkdir -p "$PRJ"
        pushd "$PRJ"
        git init .
        git remote add origin "$GH/$USR/$PRJ"
        git fetch --tags --depth 1 origin "$SDK_GIT_REF"
        git checkout FETCH_HEAD
        git submodule update --init --recursive --depth=1
    else
        git clone --depth 1 --recursive -b "$SDK_GIT_REF" "$GH/$USR/$PRJ" "$PRJ"
    fi

    popd

    pushd ${GITHUB_WORKSPACE}
    POKY_BASE="$GITHUB_WORKSPACE/meta-zephyr-sdk"
    # Check out Poky
    ${POKY_BASE}/scripts/meta-zephyr-sdk-clone.sh
    popd
}

patch_sdk_ng_components() {
    local PATCHES=""

    pushd $RUNNER_TEMP/sdk-ng

    # can be extended for components under $WORKSPACE/sdk-ng
    for i in crosstool-ng poky; do
        pushd $i

        PATCHES="$(ls $SDK_NG_PATCH_DIR/$SDK_VERSION/[0-9]*-${i}*.patch)"
        if [ "$PATCHES" != "" ]; then
            for j in $PATCHES; do
                git apply $j
            done
        fi

        popd
    done

    popd
}

generate_version_file() {
    pushd ${GITHUB_WORKSPACE}

    VERSION=$(git describe --tags --match 'v*')
    echo "${VERSION:1}" > version

    popd
}

generate_matrix() {
    if [ "${build_host_all}" == "y" ]; then
        build_host_linux_x86_64="y"
        build_host_linux_aarch64="y"
        build_host_macos_x86_64="y"
        build_host_macos_aarch64="y"
        build_host_windows_x86_64="y"
    fi

    if [ "${build_target_all}" == "y" ]; then
        build_target_aarch64_zephyr_elf="y"
        build_target_arc64_zephyr_elf="y"
        build_target_arc_zephyr_elf="y"
        build_target_arm_zephyr_eabi="y"
        build_target_mips_zephyr_elf="y"
        build_target_nios2_zephyr_elf="y"
        build_target_riscv64_zephyr_elf="y"
        build_target_sparc_zephyr_elf="y"
        build_target_x86_64_zephyr_elf="y"
        build_target_xtensa_espressif_esp32_zephyr_elf="y"
        build_target_xtensa_espressif_esp32s2_zephyr_elf="y"
        build_target_xtensa_intel_apl_adsp_zephyr_elf="y"
        build_target_xtensa_intel_bdw_adsp_zephyr_elf="y"
        build_target_xtensa_intel_byt_adsp_zephyr_elf="y"
        build_target_xtensa_intel_s1000_zephyr_elf="y"
        build_target_xtensa_nxp_imx_adsp_zephyr_elf="y"
        build_target_xtensa_nxp_imx8m_adsp_zephyr_elf="y"
        build_target_xtensa_sample_controller_zephyr_elf="y"
    fi

    # Generate host list
    MATRIX_HOSTS='['
    if [ "${build_host_linux_x86_64}" == "y" ]; then
        MATRIX_HOSTS+='{
            "name": "linux-x86_64",
            "runner": "zephyr_runner",
            "container": "ghcr.io/zephyrproject-rtos/sdk-build:v1.2.3",
            "archive": "tar.gz"
        },'
    fi
    if [ "${build_host_linux_aarch64}" == "y" ]; then
        MATRIX_HOSTS+='{
            "name": "linux-aarch64",
            "runner": "zephyr_runner",
            "container": "ghcr.io/zephyrproject-rtos/sdk-build:v1.2.3",
            "archive": "tar.gz"
        },'
    fi
    if [ "${build_host_macos_x86_64}" == "y" ]; then
        MATRIX_HOSTS+='{
            "name": "macos-x86_64",
            "runner": "zephyr_runner-macos-x86_64",
            "container": "",
            "archive": "tar.gz"
        },'
    fi
    if [ "${build_host_macos_aarch64}" == "y" ]; then
        MATRIX_HOSTS+='{
            "name": "macos-aarch64",
            "runner": "zephyr_runner-macos-x86_64",
            "container": "",
            "archive": "tar.gz"
        },'
    fi
    if [ "${build_host_windows_x86_64}" == "y" ]; then
        MATRIX_HOSTS+='{
            "name": "windows-x86_64",
            "runner": "zephyr_runner",
            "container": "ghcr.io/zephyrproject-rtos/sdk-build:v1.2.3",
            "archive": "zip"
        },'
    fi
    MATRIX_HOSTS+=']'

    # Generate target list
    MATRIX_TARGETS='['
    [ "${build_target_aarch64_zephyr_elf}" == "y" ]                   && MATRIX_TARGETS+='"aarch64-zephyr-elf",'
    [ "${build_target_arc64_zephyr_elf}" == "y" ]                     && MATRIX_TARGETS+='"arc64-zephyr-elf",'
    [ "${build_target_arc_zephyr_elf}" == "y" ]                       && MATRIX_TARGETS+='"arc-zephyr-elf",'
    [ "${build_target_arm_zephyr_eabi}" == "y" ]                      && MATRIX_TARGETS+='"arm-zephyr-eabi",'
    [ "${build_target_mips_zephyr_elf}" == "y" ]                      && MATRIX_TARGETS+='"mips-zephyr-elf",'
    [ "${build_target_nios2_zephyr_elf}" == "y" ]                     && MATRIX_TARGETS+='"nios2-zephyr-elf",'
    [ "${build_target_riscv64_zephyr_elf}" == "y" ]                   && MATRIX_TARGETS+='"riscv64-zephyr-elf",'
    [ "${build_target_sparc_zephyr_elf}" == "y" ]                     && MATRIX_TARGETS+='"sparc-zephyr-elf",'
    [ "${build_target_x86_64_zephyr_elf}" == "y" ]                    && MATRIX_TARGETS+='"x86_64-zephyr-elf",'
    [ "${build_target_xtensa_espressif_esp32_zephyr_elf}" == "y" ]    && MATRIX_TARGETS+='"xtensa-espressif_esp32_zephyr-elf",'
    [ "${build_target_xtensa_espressif_esp32s2_zephyr_elf}" == "y" ]  && MATRIX_TARGETS+='"xtensa-espressif_esp32s2_zephyr-elf",'
    [ "${build_target_xtensa_intel_apl_adsp_zephyr_elf}" == "y" ]     && MATRIX_TARGETS+='"xtensa-intel_apl_adsp_zephyr-elf",'
    [ "${build_target_xtensa_intel_bdw_adsp_zephyr_elf}" == "y" ]     && MATRIX_TARGETS+='"xtensa-intel_bdw_adsp_zephyr-elf",'
    [ "${build_target_xtensa_intel_byt_adsp_zephyr_elf}" == "y" ]     && MATRIX_TARGETS+='"xtensa-intel_byt_adsp_zephyr-elf",'
    [ "${build_target_xtensa_intel_s1000_zephyr_elf}" == "y" ]        && MATRIX_TARGETS+='"xtensa-intel_s1000_zephyr-elf",'
    [ "${build_target_xtensa_nxp_imx_adsp_zephyr_elf}" == "y" ]       && MATRIX_TARGETS+='"xtensa-nxp_imx_adsp_zephyr-elf",'
    [ "${build_target_xtensa_nxp_imx8m_adsp_zephyr_elf}" == "y" ]     && MATRIX_TARGETS+='"xtensa-nxp_imx8m_adsp_zephyr-elf",'
    [ "${build_target_xtensa_sample_controller_zephyr_elf}" == "y" ]  && MATRIX_TARGETS+='"xtensa-sample_controller_zephyr-elf",'
    MATRIX_TARGETS+=']'

    # Generate test environment list
    MATRIX_TESTENVS='['
    if [ "${build_host_linux_x86_64}" == "y" ]; then
        MATRIX_TESTENVS+='{
            "name": "ubuntu-20.04-x86_64",
            "runner": "ubuntu-20.04",
            "container": "",
            "bundle-host": "linux-x86_64",
            "bundle-archive": "tar.gz"
        },'
    fi
    if [ "${build_host_macos_x86_64}" == "y" ]; then
        MATRIX_TESTENVS+='{
            "name": "macos-11-x86_64",
            "runner": "macos-11",
            "container": "",
            "bundle-host": "macos-x86_64",
            "bundle-archive": "tar.gz"
        },'
    fi
    if [ "${build_host_windows_x86_64}" == "y" ]; then
        MATRIX_TESTENVS+='{
            "name": "windows-2019-x86_64",
            "runner": "windows-2019-8c",
            "container": "",
            "bundle-host": "windows-x86_64",
            "bundle-archive": "zip"
        },'
    fi
    MATRIX_TESTENVS+=']'

    # Escape control characters because GitHub Actions
    MATRIX_HOSTS="${MATRIX_HOSTS//'%'/''}"
    MATRIX_HOSTS="${MATRIX_HOSTS//$'\n'/''}"
    MATRIX_HOSTS="${MATRIX_HOSTS//$'\r'/''}"
    MATRIX_TARGETS="${MATRIX_TARGETS//'%'/''}"
    MATRIX_TARGETS="${MATRIX_TARGETS//$'\n'/''}"
    MATRIX_TARGETS="${MATRIX_TARGETS//$'\r'/''}"
    MATRIX_TESTENVS="${MATRIX_TESTENVS//'%'/''}"
    MATRIX_TESTENVS="${MATRIX_TESTENVS//$'\n'/''}"
    MATRIX_TESTENVS="${MATRIX_TESTENVS//$'\r'/''}"

    # Remove trailing comma
    MATRIX_HOSTS=$(echo "${MATRIX_HOSTS}" | sed -zr 's/,([^,]*$)/\1/')
    MATRIX_TARGETS=$(echo "${MATRIX_TARGETS}" | sed -zr 's/,([^,]*$)/\1/')
    MATRIX_TESTENVS=$(echo "${MATRIX_TESTENVS}" | sed -zr 's/,([^,]*$)/\1/')

    # Prepare configuration report
    mkdir -p ${RUNNER_TEMP}
    CONFIG_REPORT=${RUNNER_TEMP}/config-report.txt
    echo "Hosts:" > ${CONFIG_REPORT}
    echo "$(echo "${MATRIX_HOSTS}" | jq)" >> ${CONFIG_REPORT}
    echo "" >> ${CONFIG_REPORT}
    echo "Targets:" >> ${CONFIG_REPORT}
    echo "$(echo "${MATRIX_TARGETS}" | jq)" >> ${CONFIG_REPORT}
    echo "" >> ${CONFIG_REPORT}
    echo "Test Environments:" >> ${CONFIG_REPORT}
    echo "$(echo "${MATRIX_TESTENVS}" | jq)" >> ${CONFIG_REPORT}
}

build_crosstool_ng() {
    # Create build directory
    mkdir -p ${WORKSPACE}/crosstool-ng-build
    pushd ${WORKSPACE}/crosstool-ng-build

    # Bootstrap crosstool-ng
    pushd ${GITHUB_WORKSPACE}/crosstool-ng
    ./bootstrap
    popd

    # Build and install crosstool-ng
    ${GITHUB_WORKSPACE}/crosstool-ng/configure --prefix=${WORKSPACE}/crosstool-ng
    make
    make install

    # Clean up build directory to reduce disk usage
    popd
    rm -rf ${WORKSPACE}/crosstool-ng-build

    # copied to the top of the file so steps can be skipped easier
    export CT_NG=$WORKSPACE/crosstool-ng/bin/ct-ng
}

test_ct_ng() {
    $CT_NG version
}

download_cached_source_files() {
    local matrix_host_name="$1"
    local matrix_target="$2"

    #SRC_CACHE_BASE="s3://cache-sdk/crosstool-ng-sources"
    #SRC_CACHE_DIR="${matrix_host_name}/${matrix_target}"
    #SRC_CACHE_URI="${SRC_CACHE_BASE}/${SRC_CACHE_DIR}"
    # Download cached source files
    mkdir -p ${WORKSPACE}/sources
    pushd ${WORKSPACE}/sources
    #aws s3 sync ${SRC_CACHE_URI} .
    popd

    # Export environment variables
    #echo "SRC_CACHE_URI=${SRC_CACHE_URI}" >> $GITHUB_ENV
    #export SRC_CACHE_URI=${SRC_CACHE_URI}
}

build_toolchain() {
    local matrix_host_name="$1"
    local matrix_target="$2"
    local matrix_host_archive="$3"

    # Set output path
    # copied to the top of the file so steps can be skipped easier
    export CT_PREFIX="${WORKSPACE}/output"

    # Create build directory
    mkdir -p ${WORKSPACE}/build
    pushd ${WORKSPACE}/build
    # Load default target configurations
    cp ${GITHUB_WORKSPACE}/configs/${matrix_target}.config \
        .config

    # Set version information
    cat <<EOF >> .config
CT_SHOW_CT_VERSION=n
CT_TOOLCHAIN_PKGVERSION="${BUNDLE_NAME} $(<${RUNNER_TEMP}/version)"
CT_TOOLCHAIN_BUGURL="${BUG_URL}"
EOF

    # Set environment configuration
    cat <<EOF >> .config
CT_LOCAL_TARBALLS_DIR="${WORKSPACE}/sources"
CT_LOCAL_PATCH_DIR="${GITHUB_WORKSPACE}/patches-arc64"
CT_OVERLAY_LOCATION="${GITHUB_WORKSPACE}/overlays"
EOF

    # Set logging configurations
    cat <<EOF >> .config
CT_LOG_PROGRESS_BAR=n
CT_LOG_EXTRA=y
CT_LOG_LEVEL_MAX="EXTRA"
EOF

    # Set Canadian cross compilation configurations
    if [ "${matrix_host_name}" == "linux-aarch64" ]; then
        # Building for linux-aarch64 on linux-x86_64
        cat <<EOF >> .config
CT_CANADIAN=y
CT_HOST="aarch64-linux-gnu"
EOF
    elif [ "${matrix_host_name}" == "macos-aarch64" ]; then
        # Building for macos-aarch64 on macos-x86_64
        cat <<EOF >> .config
CT_CANADIAN=y
CT_HOST="aarch64-apple-darwin"
EOF
    elif [ "${matrix_host_name}" == "windows-x86_64" ]; then
        # Building for windows-x86_64 on linux-x86_64
        cat <<EOF >> .config
CT_CANADIAN=y
CT_HOST="x86_64-w64-mingw32"
EOF
    fi

    # Configure GDB Python scripting support
    cat <<EOF >> .config
CT_GDB_CROSS_PYTHON=y
CT_GDB_CROSS_PYTHON_VARIANT=y
EOF

    if [ "${matrix_host_name}" == "linux-aarch64" ]; then
        # Clone crosskit-aarch64-linux-libpython cross compilation kit
        git clone \
        https://github.com/stephanosio/crosskit-aarch64-linux-libpython.git \
        ${WORKSPACE}/crosskit-aarch64-linux-libpython
        # Use Python 3.8.0
        export LIBPYTHON_KIT_ROOT=${WORKSPACE}/crosskit-aarch64-linux-libpython/python-3.8.0
        # Set Python configuration resolver for GDB
        cat <<EOF >> .config
CT_GDB_CROSS_PYTHON_BINARY="${LIBPYTHON_KIT_ROOT}/bin/python"
EOF
    elif [ "${matrix_host_name}" == "macos-aarch64" ]; then
        # Clone crosskit-aarch64-darwin-libpython cross compilation kit
        git clone \
        https://github.com/stephanosio/crosskit-aarch64-darwin-libpython.git \
        ${WORKSPACE}/crosskit-aarch64-darwin-libpython
        # Use Python 3.8.12
        export LIBPYTHON_KIT_ROOT=${WORKSPACE}/crosskit-aarch64-darwin-libpython/python-3.8.12
        # Set Python configuration resolver for GDB
        cat <<EOF >> .config
CT_GDB_CROSS_PYTHON_BINARY="${LIBPYTHON_KIT_ROOT}/bin/python"
EOF
    elif [ "${matrix_host_name}" == "windows-x86_64" ]; then
        # Clone crosskit-mingw-w64-libpython cross compilation kit
        git clone \
        https://github.com/stephanosio/crosskit-mingw-w64-libpython.git \
        ${WORKSPACE}/crosskit-mingw-w64-libpython
        # Use Python 3.8.3
        export LIBPYTHON_KIT_ROOT=${WORKSPACE}/crosskit-mingw-w64-libpython/python-3.8.3
        # Set Python configuration resolver for GDB
        cat <<EOF >> .config
CT_GDB_CROSS_PYTHON_BINARY="${LIBPYTHON_KIT_ROOT}/bin/python"
EOF
    else
        # Use Python 3.8 for non-Canadian Linux and macOS builds
        cat <<EOF >> .config
CT_GDB_CROSS_PYTHON_BINARY="$PYTHON_VERSION"
EOF
    fi

    # Allow building as root on Linux to avoid all sorts of container
    # permission issues with the GitHub Actions.
    if [ "$RUNNER_OS" == "Linux" ]; then
        cat <<EOF >> .config
CT_EXPERIMENTAL=y
CT_ALLOW_BUILD_AS_ROOT=y
CT_ALLOW_BUILD_AS_ROOT_SURE=y
EOF
    fi

    # Merge configurations
    ${CT_NG} savedefconfig DEFCONFIG=build.config
    ${CT_NG} distclean
    ${CT_NG} defconfig DEFCONFIG=build.config

    # Build toolchain
    ${CT_NG} build

    # Resolve output directory path
    if [ "${matrix_host_name}" == "linux-aarch64" ]; then
        OUTPUT_BASE="${WORKSPACE}/output"
        OUTPUT_DIR="HOST-aarch64-linux-gnu"
    elif [ "${matrix_host_name}" == "macos-aarch64" ]; then
        OUTPUT_BASE="${WORKSPACE}/output"
        OUTPUT_DIR="HOST-aarch64-apple-darwin"
    elif [ "${matrix_host_name}" == "windows-x86_64" ]; then
        OUTPUT_BASE="${WORKSPACE}/output"
        OUTPUT_DIR="HOST-x86_64-w64-mingw32"
    else
        OUTPUT_BASE="${WORKSPACE}"
        OUTPUT_DIR="output"
    fi

    # Remove unneeded files from output directory
    pushd ${OUTPUT_BASE}/${OUTPUT_DIR}/${matrix_target}
    rm -rf newlib-nano
    rm -f build.log.bz2
    popd

    # Grant write permission for owner
    chmod -R u+w ${OUTPUT_BASE}/${OUTPUT_DIR}

    # Rename Canadian cross-compiled toolchain output directory to
    # "output" for consistency
    if [ "${OUTPUT_DIR}" != "output" ]; then
        mv ${OUTPUT_BASE}/${OUTPUT_DIR} ${OUTPUT_BASE}/output
        OUTPUT_DIR="output"
    fi

    # Create archive
    ARCHIVE_NAME=toolchain_${matrix_host_name}_${matrix_target}
    ARCHIVE_FILE=${ARCHIVE_NAME}.${matrix_host_archive}
    if [ "${matrix_host_archive}" == "tar.gz" ]; then
        ${TAR} -zcvf ${ARCHIVE_FILE} \
                --owner=0 --group=0 -C ${OUTPUT_BASE}/${OUTPUT_DIR} ${matrix_target}
    elif [ "${matrix_host_archive}" == "zip" ]; then
        pushd ${OUTPUT_BASE}/${OUTPUT_DIR}
        zip -r ${GITHUB_WORKSPACE}/${ARCHIVE_FILE} \
                ${matrix_target}
        popd
    fi

    # Compute checksum
    md5sum ${ARCHIVE_FILE} >> md5.sum
    sha256sum ${ARCHIVE_FILE} >> sha256.sum

    popd
}

build_linux_host_tools() {
    local matrix_host_name="$1"

    if [ "$matrix_host_name" != "linux-x86_64" ]; then
        # The build currently relies on host tools being built in their own native
        # execution environments. GitHub Actions is able to spawn jobs to run under
        # linux-x86_64, linux-aarch64, macos-x86_64, macos-aarch64, windows-x86_64
        # It's unclear whether we can do anything like that internally.
        return
    fi

    # Download cached source files
    mkdir -p ${POKY_DOWNLOADS}
    #pushd ${POKY_DOWNLOADS}
    #aws s3 sync ${SRC_CACHE_URI} .
    #popd

    pushd "$GITHUB_WORKSPACE"

    # Export environment variables
    #echo "SRC_CACHE_URI=${SRC_CACHE_URI}" >> $GITHUB_ENV
    #echo "POKY_DOWNLOADS=${POKY_DOWNLOADS}" >> $GITHUB_ENV
    POKY_BASE="$GITHUB_WORKSPACE/meta-zephyr-sdk"
    export META_DOWNLOADS="${POKY_DOWNLOADS}"

    # Check out Poky
    #${POKY_BASE}/scripts/meta-zephyr-sdk-clone.sh
    ### ^^^ this is done in check_out_source_code

    # Patch Poky sanity configuration to allow building as root
    sed -i '/^INHERIT/ s/./#&/' poky/meta/conf/sanity.conf

    # Build meta-zephyr-sdk
    ${POKY_BASE}/scripts/meta-zephyr-sdk-build.sh tools

    # Prepare artifact for upload
    ARTIFACT_ROOT="${POKY_BASE}/scripts/toolchains"
    ARTIFACT=(${ARTIFACT_ROOT}/*hosttools*.sh)
    ARTIFACT=${ARTIFACT[0]}
    ARTIFACT=$(basename ${ARTIFACT})
    ARCHIVE_NAME=hosttools_${matrix_host_name}
    ARCHIVE_FILE=hosttools_${matrix_host_name}.tar.xz

    XZ_OPT="-T0" \
    ${TAR} -Jcvf ${ARCHIVE_FILE} --owner=0 --group=0 \
            -C ${ARTIFACT_ROOT} ${ARTIFACT}

    # Compute checksum
    md5sum ${ARCHIVE_FILE} >> md5.sum
    sha256sum ${ARCHIVE_FILE} >> sha256.sum

    popd
}

usage() {
    local progname="$(basename $0)"

    >&2 echo "usage:"
    >&2 echo "$progname [options..] [commands...]"
    >&2 echo ""
    >&2 echo "Many options can be specified additively times. To list all"
    >&2 echo "arguments supported by a specific option, use e.g."
    >&2 echo "'--target list'."
    >&2 echo ""
    >&2 echo "options:"
    >&2 echo "<-a|--patch-dir> dir            patch sdk-ng from 'dir'"
    >&2 echo "                                Default: $DEFAULT_SDK_NG_PATCH_DIR"
    >&2 echo "<-d|--dry-run>                  Do not do anything. Just print steps"
    >&2 echo "<-h|--help>                     Print usage information"
    >&2 echo "<-k|--sdk-version>    version   Build Zephyr SDK 'version'"
    >&2 echo "                                Default: $DEFAULT_SDK_VERSION"
    >&2 echo "<-l|--poky-downloads> dir       Save Poky (Yocto) downloads in 'dir'"
    >&2 echo "                                Default: $DEFAULT_POKY_DOWNLOADS"
    >&2 echo "<-m|--temp>           dir       Use 'dir' as the temporary directory"
    >&2 echo "                                Default: $DEFAULT_RUNNER_TEMP"
    >&2 echo "<-n|--no-deps>                  Do not install dependencies"
    >&2 echo "<-p|--python-version> version   Use the specified python version"
    >&2 echo "                                Default: $DEFAULT_PYTHON_VERSION"
    >&2 echo "<-s|--host>           host      Build the SDK for 'host'"
    >&2 echo "                                Default: all"
    >&2 echo "<-t|--target>         target    Build a toolchain for 'target'"
    >&2 echo "                                Default: all"
    >&2 echo "<-x|--proxy>          proxy     Use 'proxy' as the proxy"
    >&2 echo "                                Default: $DEFAULT_PROXY"
    >&2 echo "<-y|--yes>                      Automatically answer 'yes' when prompted"
    >&2 echo "                                Default: $DEFAULT_YES"
    >&2 echo ""
    >&2 echo "commands (the default is to execute all commands):"
    >&2 echo "deps                  install RPM dependencies via dnf"
    >&2 echo "clean                 clean the temp directory"
    >&2 echo "prepare               check out and patch sources"
    >&2 echo "manifest              generate the build matrix"
    >&2 echo "build                 build all targets specified via the build matrix"
    >&2 echo "hosttools             build host tools"
    >&2 echo ""
    >&2 echo "#################################################################"
    >&2 echo "# NOTE: the build process uses wget. If you use a proxy, please"
    >&2 echo "# ensure that the relevant parameters are included in /etc/wgetrc"
    >&2 echo "# or ~/.wgetrc"
    >&2 echo "#################################################################"
}

parse_args() {
    local tmp

    while [ $# -ge 1 ]; do
        case "$1" in
        -a | --sdk-ng-patch-dir)
            SDK_NG_PATCH_DIR="$2"
            shift
            ;;
        -d | --dry-run)
            DRY_RUN=1
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        -k | --sdk-version)
            SDK_VERSION="$2"
            shift
            ;;
        -l | --poky-downloads)
            POKY_DOWNLOADS="$2"
            shift
            ;;
        -m | --temp)
            RUNNER_TEMP="$2"
            shift
            ;;
        -n | --no-deps)
            NO_DEPS=1
            ;;
        -p | --python-version)
            case "$2" in
            python3.6)
                PYTHON_VERSION="$2"
                shift
                ;;
            list)
                echo $DEFAULT_PYTHON_VERSION
                exit 0
                ;;
            *)
                >&2 echo "Unsupported python version: $2"
                usage
                exit 1
                ;;
            esac
            ;;
        -s | --host)
            case "$2" in
            list)
                for i in ${ALL_HOSTS[@]}; do
                    echo $i
                done
                exit 0
                ;;
            all | linux-x86_64 | linux-aarch64 | macos-x86_64 | macos-aarch64 | windows-x86_64)
                tmp="$(echo "${2}" | sed -e 's/-/_/g')"
                eval export build_host_${tmp}=y
                hosts+=" $2"
                shift
                ;;
            *)
                >&2 echo "Unsupported host: $2"
                usage
                exit 1
                ;;
            esac
            ;;
        -t | --target)
            case "$2" in
            list)
                for i in ${ALL_TARGETS[@]}; do
                    echo $i
                done
                exit 0
                ;;
            all | aarch64-zephyr-elf | arc64-zephyr-elf | arc-zephyr-elf | arm-zephyr-eabi | \
            mips-zephyr-elf | nios2-zephyr-elf | riscv64-zephyr-elf | sparc-zephyr-elf | \
            x86_64-zephyr-elf | xtensa-espressif_esp32s2_zephyr-elf | \
            xtensa-espressif_esp32_zephyr-elf | xtensa-intel_apl_adsp_zephyr-elf | \
            xtensa-intel_bdw_adsp_zephyr-elf | xtensa-intel_byt_adsp_zephyr-elf | \
            xtensa-intel_s1000_zephyr-elf | xtensa-nxp_imx8m_adsp_zephyr-elf | \
            xtensa-nxp_imx_adsp_zephyr-elf | xtensa-sample_controller_zephyr-elf)
                tmp="$(echo "${2}" | sed -e 's/-/_/g')"
                eval export build_target_${tmp}=y
                targets+=" $2"
                shift
                ;;
            *)
                >&2 echo "Unsupported target: $2"
                usage
                exit 1
                ;;
            esac
            ;;
        -x | --proxy)
            PROXY="$2"
            shift
            ;;
        -y | --yes)
            YES="-y"
            ;;
        --)
            # all subsequent arguments are positional
            shift
            # break out of while loop
            break
            ;;
        -*)
            >&2 echo "Unrecognized option: $2"
            usage
            exit 1
            ;;
        *)
            # only positional arguments are left
            # break out of while loop
            break
            ;;
        esac
        shift
    done

    if [ "$hosts" = "" ]; then
        export build_host_all=y
    fi

    if [ "$targets" = "" ]; then
        export build_target_all=y
    fi

    SDK_GIT_REF="v$SDK_VERSION"

    WORKSPACE="$RUNNER_TEMP/workspace"
    GITHUB_WORKSPACE="$RUNNER_TEMP/$PRJ"

    CT_NG=$WORKSPACE/crosstool-ng/bin/ct-ng
    CT_PREFIX="${WORKSPACE}/output"

    COMMANDS="$@"
}

git_ref_is_sha() {
    local ref="$1"

    if [ ${#ref} -ne 40 ]; then
        return 1
    fi

    if [[ ! "$ref" =~ [a-z0-9]{40} ]]; then
        return 0
    fi

    return 1
}

main() {
    # ~modeled around Portage / ebuild phases
    # https://wiki.gentoo.org/wiki/Stepping_through_ebuilds
    # See also
    # https://dev.gentoo.org/~zmedico/portage/doc/man/ebuild.5.html

    parse_args "$@"

    local cmds="$COMMANDS"
    if [ "$cmds" = "" ]; then
        cmds="deps clean prepare manifest build hosttools"
    fi

    # deps
    if [[ $cmds =~ .*deps.* ]]; then
        if [ $DRY_RUN -gt 0 ]; then
            echo "deps"
        else
            if [ $NO_DEPS -eq 0 ]; then
                install_dependencies
                set_up_build_environment
            fi
        fi
    fi

    # clean
    if [[ $cmds =~ .*clean.* ]]; then
        if [ $DRY_RUN -gt 0 ]; then
            echo "clean"
        else
            clean
        fi
    fi

    # prepare
    if [[ $cmds =~ .*prepare.* ]]; then
        if [ $DRY_RUN -gt 0 ]; then
            echo "prepare"
        else
            check_out_source_code
            patch_sdk_ng_components
        fi
    fi

    # manifest
    if [[ $cmds =~ .*manifest.* ]]; then
        if [ $DRY_RUN -gt 0 ]; then
            echo "manifest"
        else
            generate_matrix
            generate_version_file
        fi
    fi

    # build
    if [[ $cmds =~ .*build.* ]]; then
        if [ $DRY_RUN -gt 0 ]; then
            echo "build"
        else
            build_crosstool_ng
            test_ct_ng
            for matrix_host_name in $(echo ${MATRIX_HOSTS} | jq -r '.[].name'); do
                for matrix_target in $(echo ${MATRIX_TARGETS} | jq -r '.[]'); do
                    for matrix_host_archive in $MATRIX_ARCHIVES; do
                        OLDPATH=$PATH
                        export PATH=$WORKSPACE/build/.build/$matrix_target/buildtools/bin:$OLDPATH
                        download_cached_source_files "$matrix_host_name" "$matrix_target"
                        build_toolchain "$matrix_host_name" "$matrix_target" "$matrix_host_archive"
                        export PATH=$OLDPATH
                    done
                done
            done
        fi
    fi

    # hosttools
    if [[ $cmds =~ .*hosttools.* ]]; then
        if [ $DRY_RUN -gt 0 ]; then
            echo "hosttools"
        else
            for matrix_host_name in $(echo ${MATRIX_HOSTS} | jq -r '.[].name'); do
                build_linux_host_tools "$matrix_host_name"
            done
        fi
    fi
}

main "$@"
