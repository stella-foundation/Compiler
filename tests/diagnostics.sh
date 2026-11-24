#!/bin/sh
set -eu

compiler=$1
work_dir=$2

mkdir -p "$work_dir"

# 1. Missing input
if "$compiler" > "$work_dir/missing.log" 2>&1; then
	echo "expected missing input to fail" >&2
	exit 1
fi
grep -Fq 'E_CLI_MISSING_INPUT' "$work_dir/missing.log"

# 2. Invalid option
if "$compiler" --unknown.flag > "$work_dir/bad_opt.log" 2>&1; then
	echo "expected unknown option to fail" >&2
	exit 1
fi
grep -Fq 'E_CLI_INVALID_OPTION' "$work_dir/bad_opt.log"

# 3. Human diagnostic with source snippet & underline
printf 'let x: u8 = @nope;\n' > "$work_dir/human.sl"
if "$compiler" "$work_dir/human.sl" --diag.color=never > "$work_dir/human.log" 2>&1; then
	echo "expected human.sl to fail" >&2
	exit 1
fi
grep -Fq 'error[E_LEX_INVALID_CHARACTER]:' "$work_dir/human.log"
grep -Fq ' --> ' "$work_dir/human.log"
grep -Fq 'let x: u8 = @nope;' "$work_dir/human.log"
grep -Fq '^~~~~' "$work_dir/human.log"

# 4. JSON diagnostic format
if "$compiler" "$work_dir/human.sl" --diag.format=json > "$work_dir/json.log" 2>&1; then
	echo "expected human.sl with json format to fail" >&2
	exit 1
fi
grep -Fq '"severity":"error"' "$work_dir/json.log"
grep -Fq '"code":"E_LEX_INVALID_CHARACTER"' "$work_dir/json.log"
grep -Fq '"phase":"lexer"' "$work_dir/json.log"

# 5. --diag.warn-error promotes unknown escape warning to error
printf 'let s: []u8 = "\\q";\n' > "$work_dir/warn.sl"
"$compiler" "$work_dir/warn.sl" --diag.color=never > "$work_dir/warn_ok.log" 2>&1
grep -Fq 'warning[W_GENERAL]: unknown escape' "$work_dir/warn_ok.log"

if "$compiler" "$work_dir/warn.sl" --diag.warn-error --diag.color=never > "$work_dir/warn_err.log" 2>&1; then
	echo "expected --diag.warn-error to fail on warning" >&2
	exit 1
fi
grep -Fq 'error[W_GENERAL]: unknown escape' "$work_dir/warn_err.log"
