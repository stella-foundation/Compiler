#!/bin/sh
set -eu

compiler=$1
work_dir=$2
src_dir=$3

mkdir -p "$work_dir"

# 1. Comprehensive AST dump test
cat > "$work_dir/ast_test.sl" << 'EOF'
mod demo.app;
import "std/io.sl";

#[layout(8, 4)]
pub struct Point<T> {
	pub x: T,
	pub y: T,
}

union Value {
	i: i64,
	f: f64,
}

enum Msg: u8 {
	Quit,
	Write(i32),
	Move { x: i32, y: i32 },
}

const Id: type = u64;

trait Printable {
	fn show(self: *Self) -> void;
}

impl Printable for Point<i32> {
	pub fn show(self: *Self) -> void {}
}

if #debug {
	const MODE: u8 = 1;
} else {
	const MODE: u8 = 0;
}

#[abi("C")]
extern fn puts(s: *u8) -> i32;

pub fn compute(mut a: i32, b: i32) -> i32 {
	let mut acc: i32 = a + b * 2;
	acc +%= 1;
	let sl: []u8 = "hello"[0..2];
	let bits: u8 = (a cast u8)[3:0];
	defer { acc = 0; }
	if acc > 0 {
		for let mut i: i32 = 0; i < 3; i += 1 {
			if i == 1 { continue; }
			if i == 2 { break; }
		}
	} else {
		unreachable;
	}
	let msg: Msg = .Move { x: 1, y: 2 };
	match msg {
		.Quit => return 0,
		.Write(v) | .Move { x: v, y: _ } => return v,
	}
}
EOF

"$compiler" "$work_dir/ast_test.sl" --emit.ast > "$work_dir/ast_test.out"

grep -Fq 'Module(demo.app, decls=10)' "$work_dir/ast_test.out"
grep -Fq 'Import(path=std/io.sl)' "$work_dir/ast_test.out"
grep -Fq 'Struct(name=Point, fields=2)' "$work_dir/ast_test.out"
grep -Fq 'Union(name=Value, fields=2)' "$work_dir/ast_test.out"
grep -Fq 'Enum(name=Msg, members=3)' "$work_dir/ast_test.out"
grep -Fq 'TypeBinding(name=Id, target=u64)' "$work_dir/ast_test.out"
grep -Fq 'Trait(name=Printable, methods=1)' "$work_dir/ast_test.out"
grep -Fq 'Impl(trait=Printable, methods=1)' "$work_dir/ast_test.out"
grep -Fq 'Conditional(arms=2)' "$work_dir/ast_test.out"
grep -Fq 'Fn(name=puts, params=1, ret=i32)' "$work_dir/ast_test.out"
grep -Fq 'Fn(name=compute, params=2, ret=i32)' "$work_dir/ast_test.out"
grep -Fq 'Binary(+%)' "$work_dir/ast_test.out"
grep -Fq 'Slice' "$work_dir/ast_test.out"
grep -Fq 'Index(bit_range=true)' "$work_dir/ast_test.out"
grep -Fq 'Defer' "$work_dir/ast_test.out"
grep -Fq 'Match(arms=2)' "$work_dir/ast_test.out"

# 2. Self-parsing: all compiler .sl sources must parse without error
for f in \
	"$src_dir/main.sl" \
	"$src_dir/driver/cli.sl" \
	"$src_dir/front/log.sl" \
	"$src_dir/front/token.sl" \
	"$src_dir/front/lexer.sl" \
	"$src_dir/front/ast.sl" \
	"$src_dir/front/parser/expressions.sl" \
	"$src_dir/front/parser/statements.sl" \
	"$src_dir/front/parser/module.sl"
do
	"$compiler" "$f" --emit.ast > /dev/null
done

# 3. Syntax error recovery: report errors on bad decls and still parse later valid decls
cat > "$work_dir/recover.sl" << 'EOF'
fn bad( -> void {}
struct Broken { x: }
fn good() -> void {
	let x: i32 = ;
	return;
}
EOF

if "$compiler" "$work_dir/recover.sl" --diag.color=never > "$work_dir/recover.log" 2>&1; then
	echo "expected recover.sl to fail parsing" >&2
	exit 1
fi
grep -Fq 'E_PARSE_EXPECTED_TOKEN' "$work_dir/recover.log"
# Ensure multiple errors were reported (recovery continued past first error)
err_count=$(grep -c 'E_PARSE_EXPECTED_TOKEN' "$work_dir/recover.log")
if [ "$err_count" -lt 2 ]; then
	echo "expected >= 2 parse errors from recovery, got $err_count" >&2
	exit 1
fi

# 4. `const Name: type = Target;` parses as TypeBinding and `type Name = Target;` is rejected
cat > "$work_dir/const_type.sl" << 'EOF'
pub const c_int: type = i32;
EOF
"$compiler" "$work_dir/const_type.sl" --emit.ast > "$work_dir/const_type.out"
grep -Fq 'TypeBinding(name=c_int, target=i32)' "$work_dir/const_type.out"

cat > "$work_dir/bad_type_decl.sl" << 'EOF'
type Foo = i32;
EOF
if "$compiler" "$work_dir/bad_type_decl.sl" --emit.ast > /dev/null 2>&1; then
	echo "expected top-level 'type Foo = i32;' to fail parsing" >&2
	exit 1
fi
