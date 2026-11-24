#!/bin/sh
set -eu

compiler=$1
work_dir=$2

mkdir -p "$work_dir"

# 1. Valid semantic analysis + const eval + import resolution
cat > "$work_dir/helper.sl" << 'EOF'
pub fn helper_val() -> i32 {
	return 7;
}
EOF

cat > "$work_dir/valid_sema.sl" << 'EOF'
import "./helper.sl";

const SIZE: usize = 2 + 3;

struct Pair {
	pub a: i32,
	pub b: i32,
}

enum Color: u8 {
	Red,
	Green,
}

const MyInt: type = i32;
const ConstInt: type = i32;

fn add(x: MyInt, y: ConstInt) -> MyInt {
	return x + y;
}

pub fn main() -> u8 {
	let arr: [SIZE]i32 = [1, 2, 3, 4, 5];
	let mut p: Pair = { .a = 10, .b = 20 };
	p.a = add(p.a, arr[0]);
	let c: Color = .Red;
	let raw: u8 = c cast u8;
	let ptr: *mut i32 = &p.b;
	*ptr = 30;
	for let mut i: usize = 0; i < SIZE; i += 1 {
		if i == 2 {
			continue;
		}
	}
	return raw;
}
EOF

"$compiler" "$work_dir/valid_sema.sl" --diag.color=never

# 2. Semantic error checks
expect_sema_err() {
	name=$1
	code=$2
	expected_diag=$3
	printf '%s\n' "$code" > "$work_dir/$name.sl"
	if "$compiler" "$work_dir/$name.sl" --diag.color=never > "$work_dir/$name.log" 2>&1; then
		echo "expected $name to fail sema" >&2
		exit 1
	fi
	grep -Fq "$expected_diag" "$work_dir/$name.log"
}

expect_sema_err "implicit_cast" 'fn f() -> void { let x: i64 = (1 cast i32); }' "E_TYPE_MISMATCH"
expect_sema_err "immutable_assign" 'fn f() -> void { let x: i32 = 1; x = 2; }' "E_IMMUTABLE_ASSIGNMENT"
expect_sema_err "non_bool_if" 'fn f() -> void { if 1 {} }' "E_TYPE_MISMATCH"
expect_sema_err "undef_var" 'fn f() -> i32 { return nope; }' "E_UNDEFINED_NAME"
expect_sema_err "undef_type" 'fn f() -> Missing { return 0; }' "E_UNDEFINED_TYPE"
expect_sema_err "dup_local" 'fn f() -> void { let x: i32 = 1; let x: i32 = 2; }' "E_DUPLICATE_DECLARATION"
expect_sema_err "break_outside" 'fn f() -> void { break; }' "E_INVALID_CONTROL_FLOW"
expect_sema_err "missing_return" 'fn f() -> i32 { let x: i32 = 1; }' "E_INVALID_CONTROL_FLOW"
expect_sema_err "missing_import" 'import "./does_not_exist.sl";' "E_SOURCE_NOT_FOUND"
expect_sema_err "bad_bitcast" 'fn f() -> void { let x: u8 = 1; let y: u32 = x bitcast u32; }' "E_TYPE_MISMATCH"
expect_sema_err "trait_missing_req" '
trait T {
	fn req(self: *Self) -> i32;
	fn def(self: *Self) -> i32 { return 1; }
}
struct S { pub x: i32 }
impl T for S {}
' "E_TRAIT_MISSING_METHOD"
expect_sema_err "trait_override_bad_sig" '
trait T {
	fn def(self: *Self) -> i32 { return 1; }
}
struct S { pub x: i32 }
impl T for S {
	fn def(self: *Self) -> u64 { return 2; }
}
' "E_TRAIT_SIGNATURE_MISMATCH"
