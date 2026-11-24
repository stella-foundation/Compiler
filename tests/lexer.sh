#!/bin/sh
set -eu

compiler=$1
work_dir=$2

mkdir -p "$work_dir"

# 1. Comprehensive valid token stream test
cat > "$work_dir/valid.sl" << 'EOF'
mod test.lex;
import "std/io.sl";

// line comment
#my_flag
@of @va @src @syn @diag

fn demo(a: u64, b: f64) -> void {
	let x: u64 = 42 + 0xDEAD_BEEF + 0b1010_0101;
	let y: f64 = 3.14 + 1.5e-2 + 0x1.8p3 + 2.0f + 1.0~ + 1.0f~;
	let s: []u8 = "hi\n\t\x41";
	let cs: *u8 = c"nul\0";
	let ch: u8 = '\x7f';
	a += 1; a +%= 2; a +|= 3;
	a -= 1; a -%= 2; a -|= 3;
	a *= 1; a *%= 2; a *|= 3;
	a /= 1; a %= 2; a &= 3; a |= 4; a ^= 5; a <<= 1; a >>= 1;
	let cmp: bool = (a == b) || (a != b) && (a <= b) && (a >= b) && (a < b) && (a > b);
	let sl: []u8 = s[0..2];
	match x {
		1 => {}
		_ => {}
	}
	// variadic dots
	let z: bool = !true || false && null == null;
	...
}
EOF

"$compiler" "$work_dir/valid.sl" --emit.tokens > "$work_dir/valid.tokens"

grep -Fq '1:1 mod' "$work_dir/valid.tokens"
grep -Fq '5:1 define-ref text=my_flag' "$work_dir/valid.tokens"
grep -Fq '6:1 builtin-module text=of' "$work_dir/valid.tokens"
grep -Fq '6:19 builtin-module text=diag' "$work_dir/valid.tokens"
grep -Fq '9:15 int text=42 val=42' "$work_dir/valid.tokens"
grep -Fq '9:20 int text=0xDEAD_BEEF val=3735928559' "$work_dir/valid.tokens"
grep -Fq '9:34 int text=0b1010_0101 val=165' "$work_dir/valid.tokens"
grep -Fq '10:15 float text=3.14' "$work_dir/valid.tokens"
grep -Fq '10:22 float text=1.5e-2' "$work_dir/valid.tokens"
grep -Fq '10:31 float text=0x1.8p3' "$work_dir/valid.tokens"
grep -Fq '10:41 float text=2.0f' "$work_dir/valid.tokens"
grep -Fq '10:48 float text=1.0~' "$work_dir/valid.tokens"
grep -Fq '10:55 float text=1.0f~' "$work_dir/valid.tokens"
grep -Fq '11:16 string text="hi' "$work_dir/valid.tokens"
grep -Fq '12:16 string cstr=true' "$work_dir/valid.tokens"
grep -Fq '13:15 char val=127' "$work_dir/valid.tokens"
grep -Fq '14:4 operator base=+ var=normal assign=true text=+=' "$work_dir/valid.tokens"
grep -Fq '14:12 operator base=+ var=wrap assign=true text=+%=' "$work_dir/valid.tokens"
grep -Fq '14:21 operator base=+ var=sat assign=true text=+|=' "$work_dir/valid.tokens"
grep -Fq '15:12 operator base=- var=wrap assign=true text=-%=' "$work_dir/valid.tokens"
grep -Fq '16:21 operator base=* var=sat assign=true text=*|=' "$work_dir/valid.tokens"
grep -Fa '17:44 operator base=<< var=normal assign=true text=<<=' "$work_dir/valid.tokens"
grep -Fa '17:53 operator base=>> var=normal assign=true text=>>=' "$work_dir/valid.tokens"
grep -Fa '19:20 ..' "$work_dir/valid.tokens"
grep -Fa '21:5 =>' "$work_dir/valid.tokens"
grep -Fa '26:2 ...' "$work_dir/valid.tokens"
grep -Fa 'eof' "$work_dir/valid.tokens"

# 2. Lexical error cases
expect_lex_err() {
	name=$1
	code=$2
	expected_diag=$3
	printf '%s\n' "$code" > "$work_dir/$name.sl"
	if "$compiler" "$work_dir/$name.sl" > "$work_dir/$name.log" 2>&1; then
		echo "expected $name to fail lexing" >&2
		exit 1
	fi
	grep -Fq "$expected_diag" "$work_dir/$name.log"
}

expect_lex_err "bare_at" "@" "E_LEX_INVALID_CHARACTER"
expect_lex_err "unknown_builtin" "@nope" "E_LEX_INVALID_CHARACTER"
expect_lex_err "bad_hex" "0x" "E_LEX_INVALID_NUMBER"
expect_lex_err "bad_bin" "0b" "E_LEX_INVALID_NUMBER"
expect_lex_err "bad_sep" "1__2" "E_LEX_INVALID_NUMBER"
expect_lex_err "trailing_sep" "1_" "E_LEX_INVALID_NUMBER"
expect_lex_err "dup_tilde" "1.0~~" "E_LEX_INVALID_NUMBER"
expect_lex_err "int_overflow" "99999999999999999999999" "E_LEX_INVALID_NUMBER"
expect_lex_err "unterm_str" '"abc' "E_LEX_UNTERMINATED_STRING"
expect_lex_err "empty_char" "''" "E_LEX_UNTERMINATED_CHAR"
expect_lex_err "unterm_char" "'a" "E_LEX_UNTERMINATED_CHAR"
expect_lex_err "bad_char" '$' "E_LEX_INVALID_CHARACTER"
