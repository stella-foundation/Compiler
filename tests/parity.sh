#!/bin/sh
set -eu

self_compiler=$1
ref_compiler=$2
work_dir=$3
self_src=$4
stdlib_src=$5

mkdir -p "$work_dir"

# 1. Execution parity between C++ reference stellac and self-hosted stellac
cat > "$work_dir/parity.sl" << 'EOF'
struct Acc {
	pub sum: i32,
	pub count: i32,
}

fn step(a: *mut Acc, delta: i32) -> void {
	a.sum += delta;
	a.count += 1;
}

pub fn main() -> u8 {
	let mut acc: Acc = { .sum = 0, .count = 0 };
	for let mut i: i32 = 1; i <= 5; i += 1 {
		step(&acc, i);
	}
	// sum = 15, count = 5 => 20
	return (acc.sum + acc.count) cast u8;
}
EOF

"$ref_compiler" "$work_dir/parity.sl" "--build.output=$work_dir/ref_bin"
"$self_compiler" "$work_dir/parity.sl" "--build.output=$work_dir/self_bin"

set +e
"$work_dir/ref_bin"
ref_rc=$?
"$work_dir/self_bin"
self_rc=$?
set -e

if [ "$ref_rc" -ne "$self_rc" ]; then
	echo "parity mismatch: ref=$ref_rc self=$self_rc" >&2
	exit 1
fi

# 2. Frontend/parser parity across all self-hosted compiler and Standard Library sources
find "$self_src" -name "*.sl" | while IFS= read -r f; do
	"$self_compiler" "$f" --emit.ast > /dev/null
done

find "$stdlib_src" -name "*.sl" | while IFS= read -r f; do
	"$self_compiler" "$f" --emit.ast > /dev/null
done
