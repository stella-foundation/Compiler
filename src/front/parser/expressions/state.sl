mod front.parser;
import "front/ast.sl";
import "front/log.sl";
import "front/token.sl";
import "std/mem.sl";
import "std/str.sl";

/// Represents the `Parser` data structure.

pub struct Parser {
	/// Stores the `toks` field (toks).
	pub toks: *front.token.TokenList,
	/// Stores the `idx` field (idx).
	pub idx: usize,
	/// Stores the `fname` field (fname).
	pub fname: []u8,
	/// Stores the `mod_path` field (mod path).
	pub mod_path: front.ast.ValList<[]u8>,
	/// Stores the `seen_non_import` field (seen non import).
	pub seen_non_import: bool,
	/// Stores the `parsing_generic_arg` field (parsing generic arg).
	pub parsing_generic_arg: bool,
	/// Stores the `generic_arg_nesting` field (generic arg nesting).
	pub generic_arg_nesting: u32,
	/// Stores the `allow_struct_init` field (allow struct init).
	pub allow_struct_init: bool,
	/// Stores the `in_match_pattern` field (in match pattern).
	pub in_match_pattern: bool,
	/// Stores the `parse_block_fn` field (parse block fn).
	pub parse_block_fn: fn(*mut Parser) -> *mut front.ast.Stmt,
	/// Stores the `parse_stmt_fn` field (parse stmt fn).
	pub parse_stmt_fn: fn(*mut Parser) -> *mut front.ast.Stmt
}

/// Executes `dummy_parse_block`.
pub fn dummy_parse_block(_p: *mut Parser) -> *mut front.ast.Stmt {
	return null;
}

/// Executes `init_parser` (init parser).
pub fn init_parser(
	toks: *front.token.TokenList,
	fname: []u8
) -> Parser {
	return {
		.toks = toks,
		.idx = 0,
		.fname = fname,
		.mod_path = { .data = null, .len = 0, .cap = 0 },
		.seen_non_import = false,
		.parsing_generic_arg = false,
		.generic_arg_nesting = 0,
		.allow_struct_init = true,
		.in_match_pattern = false,
		.parse_block_fn = dummy_parse_block,
		.parse_stmt_fn = dummy_parse_block
	};
}

/// Executes `is_attr_name_token`.
pub fn is_attr_name_token(k: front.token.TokenKind) -> bool {
	match k {
		.Ident | .KwTrue | .KwFalse | .KwNull | .KwMod | .KwImport | .KwPub
		| .KwExtern | .KwFn | .KwLet | .KwMut | .KwConst | .KwStruct | .KwUnion
		| .KwType | .KwEnum | .KwIf | .KwElse | .KwFor | .KwReturn | .KwBreak
		| .KwContinue | .KwDefer | .KwYield | .KwMatch | .KwAsm | .KwVolatile
		| .KwCast | .KwBitcast => return true,
		_ => return false
	}
}

/// Executes `make_binary`.
pub fn make_binary(
	op_tok: front.token.Token,
	lhs: *mut front.ast.Expr,
	rhs: *mut front.ast.Expr
) -> *mut front.ast.Expr {
	let e: *mut front.ast.Expr = front.ast.alloc_expr(front.ast.ExprKind.Binary, op_tok.loc);
	e.op = op_tok.op;
	e.op_variant = op_tok.variant;
	e.lhs = lhs;
	e.rhs = rhs;
	return e;
}

/// Executes `is_builtin_member` (is builtin member).
pub fn is_builtin_member(e: *front.ast.Expr, mod_out: *mut []u8, mem_out: *mut []u8) -> bool {
	if e == null || e.kind != front.ast.ExprKind.Member || e.lhs == null
		|| e.lhs.kind != front.ast.ExprKind.Ident || e.lhs.path.len != 1 {
		return false;
	}
	let m: []u8 = e.lhs.path.data[0];
	if std.str.eq(m, "@of") || std.str.eq(m, "@va") || std.str.eq(m, "@src")
		|| std.str.eq(m, "@syn") || std.str.eq(m, "@diag") {
		*mod_out = m;
		*mem_out = e.member;
		return true;
	}
	return false;
}
