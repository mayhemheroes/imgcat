#!/usr/bin/env bash
#
# mayhem/build.sh — build imgcat's fuzz harness (in-process libFuzzer over the
# print_image()/load_image() decode+render path) AND the upstream functional test binary.
#
# Contract (see mayhem-repo-integration/mayhem/build.sh): build EVERYTHING here — the fuzzer,
# a standalone reproducer, and the project's own test binary (so mayhem/test.sh only RUNS it).
# The fuzzed code is compiled with $SANITIZER_FLAGS + $DEBUG_FLAGS (DWARF<4) AND SanitizerCoverage
# so libFuzzer/Mayhem see real edges; the test binary uses the project's NORMAL flags.
set -euo pipefail

# clang rejects an empty SOURCE_DATE_EPOCH.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# CImg is a git submodule pinned by the gitlink SHA. The CI checkout fetches it
# (submodules: recursive); a bare-clone build context has only the gitlink, so fetch it
# once here at image-build time. The air-gapped re-run finds it already present and
# stays offline (the fetch is pinned by the recorded submodule commit).
if [ ! -f CImg/CImg.h ]; then
  git submodule update --init --recursive
fi

# 1) Generate the project's config (config.mk, src/config.h, src/cimg_config.h with
#    cimg_use_png/cimg_use_jpeg). Idempotent; needs no network.
CC="$CC" CXX="$CXX" COMPILER="$CXX" ./configure

# 2) Build the upstream TEST binary with the project's NORMAL flags (independent, clean build)
#    so mayhem/test.sh is an honest oracle. `make imgcat` builds only the CLI (not the man page,
#    which needs pandoc). $COVERAGE_FLAGS is appended for optional source-coverage builds.
# NB: pass CFLAGS/CXXFLAGS through the ENVIRONMENT, not the make command line — a command-line
# override would kill the Makefile's target-specific `CXXFLAGS += -I./CImg` for load_image.o.
CFLAGS="$COVERAGE_FLAGS" CXXFLAGS="$COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" \
  make -j"$MAYHEM_JOBS" CC="$CC" CXX="$CXX" imgcat

PNG_JPEG_CFLAGS="$(pkg-config --cflags libpng libjpeg 2>/dev/null || true)"
PNG_JPEG_LIBS="$(pkg-config --libs libpng libjpeg 2>/dev/null || echo '-lpng -ljpeg')"
CIMG_INC="-I$SRC/CImg -I$SRC/src -Wno-char-subscripts $PNG_JPEG_CFLAGS"

# 3) Compile the fuzzed library objects (load_image.cc / print_image.c / rgbtree.c) with the
#    sanitizers + DWARF + coverage instrumentation. Two object sets: one WITH fuzzer coverage
#    (for the libFuzzer binary) and one WITHOUT (for the standalone reproducer, which links no
#    fuzzer runtime so it must not reference the SanCov trace callbacks).
OBJ=/tmp/imgcat-obj
rm -rf "$OBJ" && mkdir -p "$OBJ"

build_objs() {
  local suffix="$1" ; shift
  local extra="$*"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $extra -std=c++11 $CIMG_INC \
       -c "$SRC/src/load_image.cc" -o "$OBJ/load_image.$suffix.o"
  $CC  $SANITIZER_FLAGS $DEBUG_FLAGS $extra -std=c11 -I"$SRC/src" \
       -c "$SRC/src/print_image.c" -o "$OBJ/print_image.$suffix.o"
  $CC  $SANITIZER_FLAGS $DEBUG_FLAGS $extra -std=c11 -I"$SRC/src" \
       -c "$SRC/src/rgbtree.c" -o "$OBJ/rgbtree.$suffix.o"
}
build_objs fuzz -fsanitize=fuzzer-no-link
build_objs std

# Harness object: compile as C (keeps LLVMFuzzer* C linkage); link with clang++ for CImg's C++ runtime.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -std=c11 -I"$SRC/src" \
    -c "$SRC/mayhem/fuzz_imgcat.c" -o "$OBJ/fuzz_imgcat.fuzz.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -std=c11 -I"$SRC/src" \
    -c "$SRC/mayhem/fuzz_imgcat.c" -o "$OBJ/fuzz_imgcat.std.o"

# 4) Link the libFuzzer target.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
     "$OBJ/fuzz_imgcat.fuzz.o" \
     "$OBJ/load_image.fuzz.o" "$OBJ/print_image.fuzz.o" "$OBJ/rgbtree.fuzz.o" \
     $PNG_JPEG_LIBS -lz -lm -lpthread \
     -o /mayhem/imgcat-fuzz

# 5) Link the standalone reproducer (run-once, no libFuzzer runtime). Compile the standalone
#    driver as a C object so its LLVMFuzzerTestOneInput reference keeps C linkage.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS \
     "$OBJ/fuzz_imgcat.std.o" "$OBJ/standalone_main.o" \
     "$OBJ/load_image.std.o" "$OBJ/print_image.std.o" "$OBJ/rgbtree.std.o" \
     $PNG_JPEG_LIBS -lz -lm -lpthread \
     -o /mayhem/imgcat-standalone

echo "build.sh: built /mayhem/imgcat-fuzz (libFuzzer), /mayhem/imgcat-standalone, and the test binary $SRC/imgcat"
