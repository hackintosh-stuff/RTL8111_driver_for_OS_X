#!/bin/sh
# build-noxcode.sh — Build RealtekRTL8111.kext using only the Command Line Tools
#
# Usage (run on macOS; neither Xcode.app nor sudo is required):
#   sh tools/build-noxcode.sh [source-root] [MacKernelSDK-root]
#   MACKERNELSDK=/path/to/MacKernelSDK sh tools/build-noxcode.sh
#
# Why xcodebuild is not used:
#   The target machine has only the Command Line Tools, and /usr/bin/xcodebuild is a stub.
#   Any invocation with -project fails with "requires Xcode". Building a kext only requires
#   clang, MacKernelSDK kernel headers, libkmod, and ld -kext, all of which are available in the CLT.
#
# Difference from MSI_X570/amd-iommu/tools/dual/build-rtl8111.sh:
#   That script first runs apply-rtl8111.py to inject experimental patches and adds
#   an org.maz1.AMDMapperProbe dependency to Info.plist. This script builds the upstream version,
#   keeps the source directory read-only, and introduces no experimental code. The output is a standard RealtekRTL8111.kext.
#
# Output: build-noxcode.XXXXXX/RealtekRTL8111.kext (a separate directory per build; old directories are retained)
#       The path to the latest build is written to latest-noxcode-build.txt
# Note: This script only builds; it does not deploy or touch /Library/Extensions or kernel caches.
set -eu

[ "$(uname -s)" = "Darwin" ] || { echo "This script can only run on macOS" >&2; exit 1; }

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SRC=${1:-$ROOT}
SRC=$(CDPATH= cd -- "$SRC" && pwd)
DRV="$SRC/RealtekRTL8111"
PROJ="$SRC/RealtekRTL8111.xcodeproj/project.pbxproj"
NAME=RealtekRTL8111

echo "== Environment =="
echo "source : $SRC"
xcrun clang++ --version | head -1
echo "sdk(CLT): $(xcrun --sdk macosx --show-sdk-version)"

# ---- Check source files and tools ----
[ -d "$DRV" ] || { echo "Source directory not found: $DRV" >&2; exit 1; }
# Match the PBXSourcesBuildPhase in project.pbxproj; avoid directory globs to prevent compiling unintended .c files.
SOURCES="RealtekRTL8111 RealtekRTL8111Setup RealtekRTL8111VTD RealtekRTL8111Hardware RealtekRTL8111Linux-804704 RealtekRxPool"
for name in $SOURCES; do
    [ -f "$DRV/$name.cpp" ] || { echo "Missing source file: $name.cpp" >&2; exit 1; }
done
for f in Info.plist RealtekRTL8111-V2-Prefix.pch gpl.txt APPLE_LICENSE; do
    [ -f "$DRV/$f" ] || { echo "Missing file: $f" >&2; exit 1; }
done
command -v c++filt >/dev/null 2>&1 || { echo "c++filt not found" >&2; exit 1; }

# ---- Version numbers: keep in sync with xcodeproj ----
CURVER=3.0.4
MKTVER=3.0.0
if [ -f "$PROJ" ]; then
    v=$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION = \([^;]*\);.*/\1/p' "$PROJ" | head -1)
    if [ -n "$v" ]; then CURVER=$v; fi
    v=$(sed -n 's/^[[:space:]]*MARKETING_VERSION = \([^;]*\);.*/\1/p' "$PROJ" | head -1)
    if [ -n "$v" ]; then MKTVER=$v; fi
fi
echo "version: $CURVER (marketing $MKTVER)"

# ---- Locate MacKernelSDK ----
SDK=${2:-${MACKERNELSDK:-}}
if [ -z "$SDK" ]; then
    if [ -d "$SRC/MacKernelSDK/Headers" ]; then
        SDK="$SRC/MacKernelSDK"
    else
        for cand in "$HOME"/rtl812x-src/RTL812xLucy-*/MacKernelSDK "$HOME"/MacKernelSDK "$HOME"/src/MacKernelSDK; do
            if [ -d "$cand/Headers" ]; then SDK=$cand; break; fi
        done
    fi
fi
[ -n "$SDK" ] || { echo "MacKernelSDK not found; specify it as the second argument or through MACKERNELSDK" >&2; exit 1; }
SDK=$(CDPATH= cd -- "$SDK" && pwd)
[ -d "$SDK/Headers/IOKit" ] || { echo "MacKernelSDK headers are incomplete: $SDK" >&2; exit 1; }
[ -f "$SDK/Library/universal/libkmodc++.a" ] || { echo "缺少 libkmodc++.a" >&2; exit 1; }
[ -f "$SDK/Library/x86_64/libkmod.a" ] || { echo "Missing libkmod.a (x86_64)" >&2; exit 1; }
echo "kernel SDK: $SDK"

# KernelSPI provides overlay headers for private IONetworkingFamily SPI restored by the Lucy project.
# It relies on <Availability.h> being included by the Lucy prefix header to resolve __exported.
# The original RTL8111 prefix header does not include that header. Testing confirmed that the
# IONetworkController.h included with MacKernelSDK already contains the __PRIVATE_SPI__ polled-mode declaration,
# so only MacKernelSDK headers are used by default. If overlay headers are required, explicitly set KERNELSPI,
# and place it after the SDK include path so SDK headers take precedence.
SPI_AFTER=
if [ -n "${KERNELSPI:-}" ]; then
    [ -d "$KERNELSPI/IOKit" ] || { echo "Invalid KERNELSPI directory: $KERNELSPI" >&2; exit 1; }
    SPI_AFTER="-I $KERNELSPI"
    echo "spi    : $KERNELSPI (explicitly enabled)"
else
    echo "spi    : (not used; MacKernelSDK headers are sufficient)"
fi

# ---- Build directory: create a new one each time; preserve previous outputs ----
W=$(mktemp -d "$ROOT/build-noxcode.XXXXXX")
KEXT="$W/$NAME.kext"
BIN="$KEXT/Contents/MacOS/$NAME"
mkdir -p "$W/objects" "$KEXT/Contents/MacOS" "$KEXT/Contents/Resources"
echo "work   : $W"

# ---- kmod_info ----
# xcodebuild runs CreateKModInfo.perl to generate a translation unit containing kmod_info. When bypassing Xcode,
# this translation unit must be provided manually; otherwise, the binary lacks _kmod_info and the kext will be rejected.
KMOD="$W/kmod-info.cpp"
cat > "$KMOD" <<'KMOD_EOF'
#include <mach/kmod.h>
#include <libkern/OSKextLib.h>

extern "C" {
extern kern_return_t _start(kmod_info_t *, void *);
extern kern_return_t _stop(kmod_info_t *, void *);

KMOD_EXPLICIT_DECL(com.insanelymac.RealtekRTL8111, "@VERSION@", _start, _stop);

__attribute__((visibility("hidden"))) kmod_start_func_t *_realmain = nullptr;
__attribute__((visibility("hidden"))) kmod_stop_func_t  *_antimain = nullptr;
__attribute__((visibility("hidden"))) int _kext_apple_cc = __APPLE_CC__;
}
KMOD_EOF
sed "s/@VERSION@/$CURVER/" "$KMOD" > "$KMOD.tmp"
mv "$KMOD.tmp" "$KMOD"

# ---- Compiler flags ----
# Match the kernel development configuration in xcodeproj (x86_64 / C++17 / no exceptions or RTTI).
# The -include prefix header is required: it defines __PRIVATE_SPI__ and includes all kernel/IOKit headers.
# -O0 follows the conservative choice in the workspace CLT build scripts to avoid optimizer-amplified kernel-mode undefined behavior.
CFLAGS="-arch x86_64 -mkernel -fapple-kext -mno-red-zone \
 -nostdinc++ -std=gnu++17 -O0 \
 -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -D__APPLE_KEXT__ \
 -fno-builtin -fno-common -fno-exceptions -fno-rtti \
 -fstack-protector -fno-threadsafe-statics \
 -Wno-unused-parameter -Wno-unused-function"

compile() {
    echo "  CC $(basename "$1")"
    # shellcheck disable=SC2086
    xcrun clang++ $CFLAGS \
        -I "$SDK/Headers" $SPI_AFTER -I "$DRV" \
        -include "$DRV/RealtekRTL8111-V2-Prefix.pch" \
        -c "$1" -o "$2"
}

echo "== Compilation =="
for name in $SOURCES; do
    compile "$DRV/$name.cpp" "$W/objects/$name.o"
done
compile "$KMOD" "$W/objects/kmod-info.o"

echo "== Linking =="
# -kext 允许未定义符号（由内核加载时解析），所以后面必须单独检查驱动内部符号。
# shellcheck disable=SC2086
xcrun ld -kext -arch x86_64 "$W"/objects/*.o \
    "$SDK/Library/universal/libkmodc++.a" \
    "$SDK/Library/x86_64/libkmod.a" \
    -o "$BIN"

echo "== Bundle validation =="
nm "$BIN" > "$W/symbols.txt"
for sym in ' _kmod_info$' ' __start$' ' __stop$'; do
    grep -q "$sym" "$W/symbols.txt" || { echo "Missing symbol: $sym" >&2; exit 1; }
done
FT=$(otool -h "$BIN" | awk 'NR>1{print $5}' | tail -1)
[ "$FT" = "11" ] || { echo "filetype=$FT; expected 11 (MH_KEXT_BUNDLE)" >&2; exit 1; }
echo "  MH_KEXT_BUNDLE OK"
if nm -u "$BIN" | c++filt | grep -E 'rtl8168_|RTL8111::|RealtekRxPool::' > "$W/unresolved.txt"; then
    echo "Unresolved driver-internal symbols (a source file may be missing):" >&2
    cat "$W/unresolved.txt" >&2
    exit 1
fi
echo "  All driver-internal symbols are defined: OK"

echo "== Info.plist =="
# The source Info.plist is an Xcode template containing build variables; a manual build must expand them,
# or CFBundleIdentifier and version values will remain literal strings, preventing the kext from matching and loading correctly.
sed -e 's/\${EXECUTABLE_NAME}/RealtekRTL8111/g' \
    -e 's/\${PRODUCT_NAME:rfc1034identifier}/RealtekRTL8111/g' \
    -e 's/\${PRODUCT_NAME}/RealtekRTL8111/g' \
    -e 's/\$MODULE_VERSION/'"$CURVER"'/g' \
    -e 's/\$MARKETING_VERSION/'"$MKTVER"'/g' \
    "$DRV/Info.plist" > "$KEXT/Contents/Info.plist"
plutil -lint "$KEXT/Contents/Info.plist"
if grep -E '\$\{|\$MODULE_VERSION|\$MARKETING_VERSION' "$KEXT/Contents/Info.plist" >/dev/null; then
    echo "Info.plist still contains unexpanded Xcode variables" >&2
    exit 1
fi
cp "$DRV/gpl.txt" "$DRV/APPLE_LICENSE" "$KEXT/Contents/Resources/"

echo "== Signing (ad hoc) =="
codesign --force --sign - --timestamp=none "$KEXT"
codesign --verify --strict "$KEXT"

printf '%s\n' "$KEXT" > "$ROOT/latest-noxcode-build.txt"
echo
echo "BUILD OK: $KEXT (RealtekRTL8111 $CURVER)"
echo "The build has not been deployed; /Library/Extensions and kernel caches were not modified."
