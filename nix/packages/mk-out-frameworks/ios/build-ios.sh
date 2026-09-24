#!/usr/bin/env bash

set -e # exit immediately if a command exits with a non-zero status
set -u # treat unset variables as an error

# see: MobileVLCKit cocoapods

find ${DEPS} -maxdepth 1 -name "*.dylib" -type f | while read DYLIB; do
    echo "${DYLIB}"

    # create framework name: libavcodec.59.dylib -> Avcodec
    FRAMEWORK_NAME=$(basename $DYLIB .dylib | sed 's/\.[0-9]*$//' | sed 's/^lib//')
    FRAMEWORK_NAME="$(tr '[:lower:]' '[:upper:]' <<<${FRAMEWORK_NAME:0:1})${FRAMEWORK_NAME:1}"

    # framework dir
    FRAMEWORK_DIR="${OUTPUT_DIR}/${FRAMEWORK_NAME}.framework"

    if [ -d $FRAMEWORK_DIR ]; then
        # Duplicated framework because of versioned dylibs, just skip
        continue
    fi

    # determine archs
    ARCHS=$(lipo -archs "${DYLIB}")

    # determine lowest min os version across archs
    for ARCH in ${ARCHS}; do
        # determine min os version for the current arch
        ARCH_MIN_OS_VERSION=$(vtool -arch ${ARCH} -show-build "${DYLIB}" | grep minos | cut -d ' ' -f6)
        if [ -z "${ARCH_MIN_OS_VERSION}" ]; then
            ARCH_MIN_OS_VERSION=$(vtool -arch ${ARCH} -show-build "${DYLIB}" | grep version | cut -d ' ' -f4)
        fi

        # if not found throw an error
        if [ -z "${ARCH_MIN_OS_VERSION}" ]; then
            echo "Unable to find min os version for ${ARCH}"
            exit 1
        fi

        # if $MIN_OS_VERSION is null or greater than $ARCH_MIN_OS_VERSION replace it
        MIN_OS_VERSION=
        if [ -z "${MIN_OS_VERSION}" ] || (($(bc -l <<<"${MIN_OS_VERSION} > ${ARCH_MIN_OS_VERSION}"))); then
            MIN_OS_VERSION=${ARCH_MIN_OS_VERSION}
        fi
    done

    ORIGINAL_DYLIB="${DYLIB}"

    # copy dylib
    mkdir -p "${FRAMEWORK_DIR}"
    cp "${DYLIB}" "${FRAMEWORK_DIR}/${FRAMEWORK_NAME}"

    # replace DYLIB var
    DYLIB="${FRAMEWORK_DIR}/${FRAMEWORK_NAME}"

    # update dylib id
    NEW_ID="@rpath/${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}"
    install_name_tool \
        -id "${NEW_ID}" "${DYLIB}" \
        2>/dev/null

    # update dylib dep paths
    otool -l "${DYLIB}" |
        grep " name " |
        cut -d " " -f11 |
        tail -n +2 |
        grep "@rpath" |
        while read DEP; do
            DEP_NAME=$(basename $DEP .dylib | sed 's/\.[0-9]*$//' | sed 's/^lib//')
            DEP_NAME="$(tr '[:lower:]' '[:upper:]' <<<${DEP_NAME:0:1})${DEP_NAME:1}"

            NEW_DEP="@rpath/${DEP_NAME}.framework/${DEP_NAME}"

            install_name_tool \
                -change "${DEP}" "${NEW_DEP}" \
                "${DYLIB}" \
                2>/dev/null
        done

    # add Info.plist
    cp --no-preserve=mode ${INFO_PLIST_PATH} "${FRAMEWORK_DIR}/Info.plist"
    sed -i 's/${FRAMEWORK_NAME}/'${FRAMEWORK_NAME}'/g' "${FRAMEWORK_DIR}/Info.plist"
    sed -i 's/${SUPPORTED_PLATFORM}/'${SUPPORTED_PLATFORM}'/g' "${FRAMEWORK_DIR}/Info.plist"
    sed -i 's/${MIN_OS_VERSION}/'${MIN_OS_VERSION}'/g' "${FRAMEWORK_DIR}/Info.plist"
    plutil -convert binary1 "${FRAMEWORK_DIR}/Info.plist"

    # Mpv.framework needs headers and a module map to be importable as a Swift module
    if [ $FRAMEWORK_NAME == "Mpv" ]; then
        # copy headers
        mkdir -p "${FRAMEWORK_DIR}/Headers"
        cp --no-preserve=mode "${MPV_HEADERS_PATH}"/*.h "${FRAMEWORK_DIR}/Headers/"

        # generate the umbrella header (Mpv.h) re-exporting all of them
        for header_path in "${MPV_HEADERS_PATH}"/*.h; do
            header=$(basename "$header_path")
            echo "#import \"$header\"" >> "${FRAMEWORK_DIR}/Headers/Mpv.h"
        done

        # copy the module map to allow importing the framework as a named module
        mkdir -p "${FRAMEWORK_DIR}/Modules"
        cp --no-preserve=mode "${MPV_MODULE_MAP_PATH}" "${FRAMEWORK_DIR}/Modules/module.modulemap"
    fi
    # privacy manifest (required-reason APIs the library calls)
    if [ -f "${PRIVACY_MANIFESTS_DIR}/${FRAMEWORK_NAME}.xcprivacy" ]; then
        cp --no-preserve=mode "${PRIVACY_MANIFESTS_DIR}/${FRAMEWORK_NAME}.xcprivacy" "${FRAMEWORK_DIR}/PrivacyInfo.xcprivacy"
    fi

    # dSYM, named and laid out the way Xcode names a framework's dSYM
    DSYM="${DEPS}/dSYM/$(basename "${ORIGINAL_DYLIB}").dSYM"
    if [ ! -d "${DSYM}" ]; then
        echo "Error: no dSYM for ${ORIGINAL_DYLIB}" >&2
        exit 1
    fi
    mkdir -p "${DSYM_OUTPUT_DIR}"
    cp -R "${DSYM}" "${DSYM_OUTPUT_DIR}/${FRAMEWORK_NAME}.framework.dSYM"
    chmod -R u+w "${DSYM_OUTPUT_DIR}/${FRAMEWORK_NAME}.framework.dSYM"
    mv "${DSYM_OUTPUT_DIR}/${FRAMEWORK_NAME}.framework.dSYM/Contents/Resources/DWARF/"* \
        "${DSYM_OUTPUT_DIR}/${FRAMEWORK_NAME}.framework.dSYM/Contents/Resources/DWARF/${FRAMEWORK_NAME}"
done
