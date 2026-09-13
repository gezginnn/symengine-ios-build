#!/bin/bash
# GMP + MPFR + SymEngine'i iOS için cross-compile edip
# tek bir SymEngine.xcframework üretir.
# Bu script SADECE macOS runner üzerinde (GitHub Actions içinde) çalışır.

set -e  # Herhangi bir komut hata verirse script hemen dursun

WORKDIR="$(pwd)/native_ios_build"
OUTPUT_DIR="$(pwd)/output"
GMP_VERSION="6.3.0"
MPFR_VERSION="4.2.1"
SYMENGINE_TAG="v0.14.0"

MIN_IOS_VERSION="13.0"

mkdir -p "$WORKDIR"
mkdir -p "$OUTPUT_DIR"
cd "$WORKDIR"

echo "===== 1) Kaynak kodları indiriliyor ====="
[ -f "gmp-${GMP_VERSION}.tar.xz" ] || curl -L --retry 5 --retry-delay 5 --connect-timeout 20 -o "gmp-${GMP_VERSION}.tar.xz" "https://ftp.gnu.org/gnu/gmp/gmp-${GMP_VERSION}.tar.xz"
[ -f "mpfr-${MPFR_VERSION}.tar.xz" ] || curl -L --retry 5 --retry-delay 5 --connect-timeout 20 -o "mpfr-${MPFR_VERSION}.tar.xz" "https://ftp.gnu.org/gnu/mpfr/mpfr-${MPFR_VERSION}.tar.xz"
[ -d "symengine" ] || git clone --depth 1 --branch "${SYMENGINE_TAG}" https://github.com/symengine/symengine.git

echo "===== 2) Ortak fonksiyon: bir mimari için GMP+MPFR derle ====="
build_gmp_mpfr_for_arch() {
    ARCH=$1        # arm64 | x86_64
    PLATFORM=$2    # iphoneos | iphonesimulator
    HOST=$3        # aarch64-apple-darwin | x86_64-apple-darwin

    SDK_PATH=$(xcrun --sdk ${PLATFORM} --show-sdk-path)
    PREFIX="${WORKDIR}/install/${PLATFORM}-${ARCH}"
    mkdir -p "${PREFIX}"

    export CC=$(xcrun -f clang)
    export CFLAGS="-arch ${ARCH} -isysroot ${SDK_PATH} -m${PLATFORM}-version-min=${MIN_IOS_VERSION}"
    export LDFLAGS="-arch ${ARCH} -isysroot ${SDK_PATH}"

    echo "----- GMP: ${PLATFORM}/${ARCH} -----"
    rm -rf "gmp-${GMP_VERSION}-${PLATFORM}-${ARCH}"
    mkdir "gmp-${GMP_VERSION}-${PLATFORM}-${ARCH}"
    tar -xf "gmp-${GMP_VERSION}.tar.xz" -C "gmp-${GMP_VERSION}-${PLATFORM}-${ARCH}" --strip-components=1
    (
        cd "gmp-${GMP_VERSION}-${PLATFORM}-${ARCH}"
        ./configure --host="${HOST}" --prefix="${PREFIX}" \
            --disable-shared --enable-static --disable-assembly
        make -j$(sysctl -n hw.ncpu)
        make install
    )

    echo "----- MPFR: ${PLATFORM}/${ARCH} -----"
    rm -rf "mpfr-${MPFR_VERSION}-${PLATFORM}-${ARCH}"
    mkdir "mpfr-${MPFR_VERSION}-${PLATFORM}-${ARCH}"
    tar -xf "mpfr-${MPFR_VERSION}.tar.xz" -C "mpfr-${MPFR_VERSION}-${PLATFORM}-${ARCH}" --strip-components=1
    (
        cd "mpfr-${MPFR_VERSION}-${PLATFORM}-${ARCH}"
        ./configure --host="${HOST}" --prefix="${PREFIX}" \
            --with-gmp="${PREFIX}" --disable-shared --enable-static
        make -j$(sysctl -n hw.ncpu)
        make install
    )

    echo "----- SymEngine: ${PLATFORM}/${ARCH} -----"
    BUILD_DIR="${WORKDIR}/symengine-build-${PLATFORM}-${ARCH}"
    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"
    (
        cd "${BUILD_DIR}"
        cmake "${WORKDIR}/symengine" \
            -DCMAKE_SYSTEM_NAME=iOS \
            -DCMAKE_OSX_SYSROOT="${SDK_PATH}" \
            -DCMAKE_OSX_ARCHITECTURES="${ARCH}" \
            -DCMAKE_OSX_DEPLOYMENT_TARGET="${MIN_IOS_VERSION}" \
            -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
            -DGMP_INCLUDE_DIR="${PREFIX}/include" \
            -DGMP_LIBRARY="${PREFIX}/lib/libgmp.a" \
            -DMPFR_INCLUDE_DIR="${PREFIX}/include" \
            -DMPFR_LIBRARIES="${PREFIX}/lib/libmpfr.a" \
            -DMPFR_INCLUDE_DIRS="${PREFIX}/include" \
            -DWITH_MPFR=yes \
            -DBUILD_SHARED_LIBS=no \
            -DBUILD_TESTS=no \
            -DBUILD_BENCHMARKS=no \
            -DCMAKE_FIND_ROOT_PATH="${PREFIX}" \
            -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
            -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH \
            -DCMAKE_BUILD_TYPE=Release
        cmake --build . --config Release -j$(sysctl -n hw.ncpu)
        cmake --install .
    )
}

echo "===== 3) Dört mimari için derle: cihaz (arm64) + simülatör (arm64, x86_64) ====="
build_gmp_mpfr_for_arch "arm64"  "iphoneos"          "aarch64-apple-darwin"
build_gmp_mpfr_for_arch "arm64"  "iphonesimulator"   "aarch64-apple-darwin"
build_gmp_mpfr_for_arch "x86_64" "iphonesimulator"   "x86_64-apple-darwin"

echo "===== 4) Simülatör mimarilerini (arm64+x86_64) tek 'fat' kütüphanede birleştir ====="
SIM_UNIVERSAL="${WORKDIR}/install/iphonesimulator-universal"
mkdir -p "${SIM_UNIVERSAL}/lib" "${SIM_UNIVERSAL}/include"
cp -R "${WORKDIR}/install/iphonesimulator-arm64/include/." "${SIM_UNIVERSAL}/include/"

for LIB in libgmp.a libmpfr.a libsymengine.a; do
    lipo -create \
        "${WORKDIR}/install/iphonesimulator-arm64/lib/${LIB}" \
        "${WORKDIR}/install/iphonesimulator-x86_64/lib/${LIB}" \
        -output "${SIM_UNIVERSAL}/lib/${LIB}"
done

echo "===== 5) Cihaz + Simülatör için üç kütüphaneyi (gmp, mpfr, symengine) birleştirip xcframework paketle ====="
mkdir -p "${WORKDIR}/combined/iphoneos" "${WORKDIR}/combined/iphonesimulator"

libtool -static -o "${WORKDIR}/combined/iphoneos/libSymEngineAll.a" \
    "${WORKDIR}/install/iphoneos-arm64/lib/libgmp.a" \
    "${WORKDIR}/install/iphoneos-arm64/lib/libmpfr.a" \
    "${WORKDIR}/install/iphoneos-arm64/lib/libsymengine.a"

libtool -static -o "${WORKDIR}/combined/iphonesimulator/libSymEngineAll.a" \
    "${SIM_UNIVERSAL}/lib/libgmp.a" \
    "${SIM_UNIVERSAL}/lib/libmpfr.a" \
    "${SIM_UNIVERSAL}/lib/libsymengine.a"

rm -rf "${OUTPUT_DIR}/SymEngine.xcframework"
xcodebuild -create-xcframework \
    -library "${WORKDIR}/combined/iphoneos/libSymEngineAll.a" \
    -headers "${WORKDIR}/install/iphoneos-arm64/include" \
    -library "${WORKDIR}/combined/iphonesimulator/libSymEngineAll.a" \
    -headers "${SIM_UNIVERSAL}/include" \
    -output "${OUTPUT_DIR}/SymEngine.xcframework"

echo "===== TAMAMLANDI: ${OUTPUT_DIR}/SymEngine.xcframework ====="
ls -la "${OUTPUT_DIR}/SymEngine.xcframework"