#!/bin/sh
set -eu

build_dir=${1:-build}
ctest --test-dir "$build_dir" --output-on-failure
