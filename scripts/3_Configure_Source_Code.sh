#!/bin/bash
printf "\n\n------------------------------ FINAL PREBUILD CONFIGURATION ---------------------------------\n";

set -e

# Setup Script Variables
srcdir=$1;
CI_PROJECT_DIR=${CI_PROJECT_DIR:-$(realpath $(dirname $0)/../)}
_COMMON_REPO='https://gitlab.com/librewolf-community/browser/common.git';
_COMMON_COMMIT='5bce5285fa7046e6987ec3e5a8931ac17ca6c7c0'
_COMMON_DIR="${CI_PROJECT_DIR}"/common
_PATCHES_DIR="${_COMMON_DIR}"/patches
_MOZBUILD=$srcdir/../mozbuild

mkdir -p ${_MOZBUILD}

# Copy Source Code Changes to Source Code
printf "\nCopying branding and source code changes to firefox source code\n";
git clone $_COMMON_REPO ${_COMMON_DIR}
cd ${_COMMON_DIR}
git checkout ${_COMMON_COMMIT}
cd ..
cp -r ${_COMMON_DIR}/source_files/* $srcdir/;

cd $srcdir

cat >${CI_PROJECT_DIR}/mozconfig <<END
ac_add_options --enable-application=browser
mk_add_options MOZ_OBJDIR=${srcdir}/firefox-${pkgver}/obj

# to build on ubuntu and pick up clang
ac_add_options NODEJS=/usr/lib/nodejs-mozilla/bin/node

# This supposedly speeds up compilation (We test through dogfooding anyway)
ac_add_options --disable-tests
ac_add_options --disable-debug

ac_add_options --prefix=/usr
ac_add_options --enable-release
ac_add_options --enable-hardening
ac_add_options --enable-rust-simd

# Branding
ac_add_options --enable-update-channel=release
ac_add_options --with-app-name=librewolf
ac_add_options --with-app-basename=LibreWolf
ac_add_options --with-branding=browser/branding/librewolf
ac_add_options --with-distribution-id=io.gitlab.librewolf-community
ac_add_options --with-unsigned-addon-scopes=app,system
ac_add_options --allow-addon-sideload
export MOZ_REQUIRE_SIGNING=0

# System libraries
# ac_add_options --with-system-nspr
# ac_add_options --with-system-nss

# Features
ac_add_options --enable-alsa
ac_add_options --enable-jack
ac_add_options --disable-crashreporter
ac_add_options --disable-updater
ac_add_options --disable-tests

# Disables crash reporting, telemetry and other data gathering tools
mk_add_options MOZ_CRASHREPORTER=0
mk_add_options MOZ_DATA_REPORTING=0
mk_add_options MOZ_SERVICES_HEALTHREPORT=0
mk_add_options MOZ_TELEMETRY_REPORTING=0

# options for ci / weaker build systems
# mk_add_options MOZ_MAKE_FLAGS="-j4"
# ac_add_options --enable-linker=gold
END

# allow setting limited resource usage via ENV / CI:

if [[ ! -z ${CORES_TO_USE} ]]; then
  echo "mk_add_options MOZ_MAKE_FLAGS=\"-j${CORES_TO_USE}\"" >> ${CI_PROJECT_DIR}/mozconfig
fi

if [[ $CARCH == 'aarch64' ]]; then
    cat >>${CI_PROJECT_DIR}/mozconfig <<END
# taken from manjaro build:
ac_add_options --enable-optimize="-g0 -O2"

export CC='clang-10'
export CXX='clang++-10'
export AR=llvm-ar-10
export NM=llvm-nm-10
export RANLIB=llvm-ranlib-10
END

  export MOZ_DEBUG_FLAGS=" "
  export CFLAGS+=" -g0"
  export CXXFLAGS+=" -g0"
  export RUSTFLAGS="-Cdebuginfo=0"

  export LDFLAGS+=" -Wl,--no-keep-memory -Wl"
  patch -Np1 -i ${_PATCHES_DIR}/arm.patch
  wget https://raw.githubusercontent.com/archlinuxarm/PKGBUILDs/master/extra/firefox/build-arm-libopus.patch -O ${_PATCHES_DIR}/build-arm-libopus.patch
  patch -Np1 -i ${_PATCHES_DIR}/build-arm-libopus.patch

else
    cat >>${CI_PROJECT_DIR}/mozconfig <<END
# ubuntu seems to recommend this
ac_add_options --disable-elf-hack

export CC='clang-11'
export CXX='clang++-11'
export AR=llvm-ar-11
export NM=llvm-nm-11
export RANLIB=llvm-ranlib-11

# probably not needed, enabled by default?
ac_add_options --enable-optimize

# unavailable option when (on ubuntu at least(?)) building on aarch64
ac_add_options NASM=/usr/lib/nasm-mozilla/bin/nasm
END

fi

# hopefully the magic sauce that makes things build on 16.04 and later on work "everywhere":
patch -Np1 -i "${CI_PROJECT_DIR}/deb_patches/armhf-reduce-linker-memory-use.patch"
patch -Np1 -i "${CI_PROJECT_DIR}/deb_patches/fix-armhf-webrtc-build.patch"
patch -Np1 -i "${CI_PROJECT_DIR}/deb_patches/webrtc-fix-compiler-flags-for-armhf.patch"
patch -Np1 -i "${CI_PROJECT_DIR}/deb_patches/reduce-rust-debuginfo.patch"
patch -Np1 -i "${CI_PROJECT_DIR}/deb_patches/relax-cargo-dep.patch"
patch -Np1 -i "${CI_PROJECT_DIR}/deb_patches/use-system-icupkg.patch"
patch -Np1 -i "${CI_PROJECT_DIR}/deb_patches/sandbox-update-arm-syscall-numbers.patch"

# Remove some pre-installed addons that might be questionable
patch -Np1 -i ${_PATCHES_DIR}/remove_addons.patch

# Disable (some) megabar functionality
# Adapted from https://github.com/WesleyBranton/userChrome.css-Customizations
patch -Np1 -i ${_PATCHES_DIR}/megabar.patch

# remove mozilla vpn ads
patch -Np1 -i ${_PATCHES_DIR}/mozilla-vpn-ad.patch

# Debian patch to enable global menubar
if [[ ! -z "${GLOBAL_MENUBAR}" ]];then
  patch -Np1 -i ${_PATCHES_DIR}/unity-menubar.patch
fi

# Disabling Pocket
printf "\nDisabling Pocket\n";
# sed -i 's/"pocket"/# "pocket"/g' browser/components/moz.build
# this one only to remove an annoying error message:
# sed -i 's#SaveToPocket.init();#// SaveToPocket.init();#g' browser/components/BrowserGlue.jsm
patch -Np1 -i "${_PATCHES_DIR}/sed-patches/disable-pocket.patch"

# More patches
patch -Np1 -i "${_PATCHES_DIR}/context-menu.patch"

patch -Np1 -i "${_PATCHES_DIR}/browser-confvars.patch"
patch -Np1 -i "${_PATCHES_DIR}/urlbarprovider-interventions.patch"

# Remove Internal Plugin Certificates
# _cert_sed='s#if (aCert.organizationalUnit == "Mozilla [[:alpha:]]\+") {\n'
# _cert_sed+='[[:blank:]]\+return AddonManager\.SIGNEDSTATE_[[:upper:]]\+;\n'
# _cert_sed+='[[:blank:]]\+}#'
# _cert_sed+='// NOTE: removed#g'
# sed -z "$_cert_sed" -i toolkit/mozapps/extensions/internal/XPIInstall.jsm
patch -Np1 -i "${_PATCHES_DIR}/sed-patches/remove-internal-plugin-certs.patch"

# allow SearchEngines option in non-ESR builds
# sed -i 's#"enterprise_only": true,#"enterprise_only": false,#g' browser/components/enterprisepolicies/schemas/policies-schema.json
patch -Np1 -i "${_PATCHES_DIR}/sed-patches/allow-searchengines-non-esr.patch"

# stop some undesired requests (https://gitlab.com/librewolf-community/browser/common/-/issues/10)
# _settings_services_sed='s#firefox.settings.services.mozilla.com#f.s.s.m.c.qjz9zk#g'
# sed "$_settings_services_sed" -i browser/components/newtab/data/content/activity-stream.bundle.js
# sed "$_settings_services_sed" -i modules/libpref/init/all.js
# sed "$_settings_services_sed" -i services/settings/Utils.jsm
# sed "$_settings_services_sed" -i toolkit/components/search/SearchUtils.jsm
patch -Np1 -i "${_PATCHES_DIR}/sed-patches/stop-undesired-requests.patch"

rm -rf common
