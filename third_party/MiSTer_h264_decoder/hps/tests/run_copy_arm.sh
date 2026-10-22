#!/usr/bin/env bash
# hps/tests/run_copy_arm.sh -- the store copy's NEON path against its scalar path, on the MiSTer
# (docs/uvc.md U2). The host tests score the scalar path against a model (tools/tests/test_hps_lib.py)
# but never run NEON: this builds tests/copy_equiv.c against the ARM library twice -- NEON, and
# -DH264RING_NO_NEON -- runs both on the rig and diffs their hashes, case by case.
#   hps/tests/run_copy_arm.sh          GREEN: identical on every case
#   hps/tests/run_copy_arm.sh --red    ... and each mutation of the NEON path below is caught
# The rig: $MISTER_HOST, else tools/.mister_host (root@<mister-ip>). Needs Docker (the hps image).
# Runs only copy_equiv in /tmp on the rig: nothing installed, the core untouched.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
hps=$(cd "$here/.." && pwd)
repo=$(cd "$hps/.." && pwd)
host=${MISTER_HOST:-$(cat "$repo/tools/.mister_host" 2>/dev/null || true)}
[ -n "$host" ] || { echo "no rig: set MISTER_HOST or tools/.mister_host"; exit 2; }
image=${HPS_DOCKER_IMAGE:-mister-h264-hps:gcc-arm-10.2}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
ARCH="-mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard"

build() {  # name src_tree extra_cflags -> $work/name (an ARM binary)
    local name=$1 tree=$2 extra=$3
    rm -f "$work/$name"
    docker run --rm -u "$(id -u):$(id -g)" -v "$tree:$tree" -v "$here:$here" -v "$work:$work" -w "$tree" "$image" sh -c "
        make -s BUILD=$work/lib-$name CROSS_COMPILE=arm-none-linux-gnueabihf- EXTRA_CFLAGS='$ARCH $extra' \
             $work/lib-$name/libh264ring.a >/dev/null &&
        arm-none-linux-gnueabihf-gcc -O2 $ARCH -std=c11 -Wall -Werror -Iinclude -static \
             -o $work/$name $here/copy_equiv.c $work/lib-$name/libh264ring.a"
    [ -x "$work/$name" ] || { echo "build $name: FAIL"; exit 1; }
}

run() {  # name -> $work/name.out (from the rig)
    scp -q "$work/$1" "$host:/tmp/copy_equiv_$1" 2>/dev/null
    ssh "$host" "/tmp/copy_equiv_$1; rm -f /tmp/copy_equiv_$1" >"$work/$1.out" 2>/dev/null
    grep -q '^cases [1-9]' "$work/$1.out" || { echo "run $1: no result"; cat "$work/$1.out"; exit 1; }
}

build scalar "$hps" "-DH264RING_NO_NEON"
build neon "$hps" ""
# a control: the NEON build really has a NEON loop (the macro, the flags), so the comparison means something
docker run --rm -v "$work:$work" "$image" sh -c "arm-none-linux-gnueabihf-objdump -d $work/neon | grep -q vrhadd" ||
    { echo "control: no vrhadd in the NEON build -- the NEON path was not compiled"; exit 1; }
run scalar
run neon
cases=$(sed -n 's/^cases //p' "$work/scalar.out")
if diff -q "$work/scalar.out" "$work/neon.out" >/dev/null; then
    echo "GREEN: PASS (NEON == scalar on the rig, $cases cases: four formats, frames and pairs, 14 widths, 8 heights)"
else
    diff "$work/scalar.out" "$work/neon.out" | head -20
    echo "GREEN: FAIL (NEON differs from scalar)"; exit 1
fi
[ "${1:-}" = --red ] || exit 0

# name ~ the exact text in lib/h264ring.c ~ its replacement (inside the NEON block only)
mutations=(
  "N1 the average truncates (vhadd)~                s = vrhadd_u8(s, vld1_u8(b + x));~                s = vhadd_u8(s, vld1_u8(b + x));"
  "N2 the division's +1 dropped~                y = vaddq_u16(vaddq_u16(y, vshrq_n_u16(y, 8)), vdupq_n_u16(1));~                y = vaddq_u16(y, vshrq_n_u16(y, 8));"
  "N3 the rounding's 127 dropped~                uint16x8_t y = vmlal_u8(vdupq_n_u16(127), s, k);~                uint16x8_t y = vmlal_u8(vdupq_n_u16(0), s, k);"
)
red_fail=0
for m in "${mutations[@]}"; do
    IFS='~' read -r name from to <<<"$m"
    tag=${name%% *}
    tree="$work/tree-$tag"
    mkdir -p "$tree"
    cp -r "$hps/include" "$hps/lib" "$hps/Makefile" "$tree/"
    python3 - "$tree/lib/h264ring.c" "$from" "$to" <<'EOF'
import sys
p, a, b = sys.argv[1:4]
s = open(p).read()
if s.count(a) != 1:
    sys.exit(f"mutation text found {s.count(a)} times: {a!r}")
open(p, 'w').write(s.replace(a, b))
EOF
    build "mut$tag" "$tree" ""
    run "mut$tag"
    if diff -q "$work/scalar.out" "$work/mut$tag.out" >/dev/null; then
        echo "RED $name: NOT caught"; red_fail=1
    else
        echo "RED $name: caught ($(diff "$work/scalar.out" "$work/mut$tag.out" | grep -c '^>') cases differ)"
    fi
done
[ $red_fail = 0 ] && echo "RED: PASS (${#mutations[@]} mutations of the NEON path)" || { echo "RED: FAIL"; exit 1; }
