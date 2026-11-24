#!/bin/sh
set -eu

compiler=$1
work_dir=$2

mkdir -p "$work_dir"

cat > "$work_dir/prog.sl" << 'EOF'
struct Pair {
	pub a: i32,
	pub b: i32,
}

const BASE: i32 = 10;

fn sum_pair(p: Pair) -> i32 {
	return p.a + p.b;
}

pub fn main() -> u8 {
	let mut p: Pair = { .a = BASE, .b = 12 };
	let mut acc: i32 = sum_pair(p);
	for let mut i: i32 = 0; i < 4; i += 1 {
		if i == 2 {
			continue;
		}
		acc += i;
	}
	// acc = 10 + 12 + 0 + 1 + 3 = 26
	let ptr: *mut i32 = &p.a;
	*ptr = acc;
	return p.a cast u8;
}
EOF

# 1. Emit LLVM IR
"$compiler" "$work_dir/prog.sl" --emit.ir "--build.output=$work_dir/prog.ll"
grep -Fq 'define ' "$work_dir/prog.ll"
grep -Fq 'st$main()' "$work_dir/prog.ll"

# 2. Emit object file
"$compiler" "$work_dir/prog.sl" --build.compile-only "--build.output=$work_dir/prog.o"
test -s "$work_dir/prog.o"

# 3. Compile and link executable, then run and verify exit code 26
"$compiler" "$work_dir/prog.sl" "--build.output=$work_dir/prog_bin"
set +e
"$work_dir/prog_bin"
rc=$?
set -e
if [ "$rc" -ne 26 ]; then
	echo "expected exit code 26, got $rc" >&2
	exit 1
fi

# 4. Default trait methods with optional override
cat > "$work_dir/trait_default.sl" << 'EOF'
trait Counter {
	fn base(self: *Self) -> i32;
	fn bonus(self: *Self) -> i32 {
		return self.base() + 5;
	}
}

struct A {
	pub v: i32
}

struct B {
	pub v: i32
}

impl Counter for A {
	fn base(self: *Self) -> i32 {
		return self.v;
	}
}

impl Counter for B {
	fn base(self: *Self) -> i32 {
		return self.v;
	}
	fn bonus(self: *Self) -> i32 {
		return self.base() + 20;
	}
}

struct Box<T> {
	pub item: T
}

impl<T> Counter for Box<T> {
	fn base(self: *Self) -> i32 {
		return 3;
	}
}

pub fn main() -> u8 {
	let a: A = { .v = 10 };
	let b: B = { .v = 10 };
	let bx: Box<i32> = { .item = 99 };
	// a.bonus() = 15, b.bonus() = 30, bx.bonus() = 8 -> 53
	return (a.bonus() + b.bonus() + bx.bonus()) cast u8;
}
EOF

"$compiler" "$work_dir/trait_default.sl" "--build.output=$work_dir/trait_default_bin"
set +e
"$work_dir/trait_default_bin"
rc=$?
set -e
if [ "$rc" -ne 53 ]; then
	echo "expected exit code 53, got $rc" >&2
	exit 1
fi
