#!/bin/sh
# Compiles the probe tools into .build/probes (or the directory given), and dumps
# CoreBrightness's strings and disassembly there for refs.py.
#
#   tools/probes/build.sh [outdir]
#
# These are throwaway research tools, not part of the app. Most of them change the real
# logo, so quit LogoLight before using them (see README.md).
set -eu

SRC="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$SRC/../../.build/probes}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

for file in "$SRC"/*.swift; do
    name="$(basename "$file" .swift)"
    echo "==> $name"
    swiftc -O -suppress-warnings "$file" -o "$OUT/$name"
done
cp "$SRC/refs.py" "$OUT/"

LIB=/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness
echo "==> Dumping $LIB"
dyld_info -disassemble "$LIB" > "$OUT/cb.asm" 2>&1
dyld_info -section __TEXT __cstring "$LIB" > "$OUT/cstrings.txt" 2>&1
for seg in __DATA_CONST __AUTH_CONST __DATA; do
    dyld_info -section "$seg" __cfstring "$LIB" 2>/dev/null || true
done > "$OUT/cfstrings.txt"

echo "==> Tools and dumps are in $OUT"
