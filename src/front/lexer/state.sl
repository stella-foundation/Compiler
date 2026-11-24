mod front.lexer;
import "front/ast.sl";
import "front/log.sl";
import "front/token.sl";
import "std/mem.sl";
import "std/str.sl";

/// Represents the `Lexer` data structure.

pub struct Lexer {
	src: []u8,
	fname: []u8,
	pos: usize,
	line: i32,
	col: i32,
	emit_diagnostics: bool,
	out: *mut front.token.TokenList
}

/// Executes `init_lexer` (init lexer).
pub fn init_lexer(
	source: []u8,
	fname: []u8,
	emit_diagnostics: bool,
	out: *mut front.token.TokenList
) -> Lexer {
	return {
		.src = source,
		.fname = fname,
		.pos = 0,
		.line = 1,
		.col = 1,
		.emit_diagnostics = emit_diagnostics,
		.out = out
	};
}

/// Executes `is_ident_start`.
pub fn is_ident_start(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

/// Executes `is_ident_cont`.
pub fn is_ident_cont(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

/// Executes `span_len`.
pub fn span_len(pos: usize, start_pos: usize) -> i32 {
	if pos > start_pos {
		return (pos - start_pos) cast i32;
	}
	return 1;
}

/// Executes `is_digit`.
pub fn is_digit(c: u8) -> bool {
	return c >= '0' && c <= '9';
}

/// Executes `is_xdigit`.
pub fn is_xdigit(c: u8) -> bool {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

/// Executes `is_bin_digit`.
pub fn is_bin_digit(c: u8) -> bool {
	return c == '0' || c == '1';
}

/// Executes `hex_val`.
pub fn hex_val(c: u8) -> u8 {
	if c >= '0' && c <= '9' {
		return c - '0';
	}
	if c >= 'a' && c <= 'f' {
		return c - 'a' + 10;
	}
	return c - 'A' + 10;
}

/// Executes `kw_lookup`.
pub fn kw_lookup(s: []u8) -> front.token.TokenKind {
	match s.len {
		2 => {
			if std.str.eq(s, "fn") {
				return front.token.TokenKind.KwFn;
			}
			if std.str.eq(s, "if") {
				return front.token.TokenKind.KwIf;
			}
		}
		3 => {
			if std.str.eq(s, "mod") {
				return front.token.TokenKind.KwMod;
			}
			if std.str.eq(s, "pub") {
				return front.token.TokenKind.KwPub;
			}
			if std.str.eq(s, "let") {
				return front.token.TokenKind.KwLet;
			}
			if std.str.eq(s, "mut") {
				return front.token.TokenKind.KwMut;
			}
			if std.str.eq(s, "for") {
				return front.token.TokenKind.KwFor;
			}
			if std.str.eq(s, "asm") {
				return front.token.TokenKind.KwAsm;
			}
		}
		4 => {
			if std.str.eq(s, "Self") {
				return front.token.TokenKind.KwSelf;
			}
			if std.str.eq(s, "else") {
				return front.token.TokenKind.KwElse;
			}
			if std.str.eq(s, "true") {
				return front.token.TokenKind.KwTrue;
			}
			if std.str.eq(s, "null") {
				return front.token.TokenKind.KwNull;
			}
			if std.str.eq(s, "enum") {
				return front.token.TokenKind.KwEnum;
			}
			if std.str.eq(s, "impl") {
				return front.token.TokenKind.KwImpl;
			}
			if std.str.eq(s, "cast") {
				return front.token.TokenKind.KwCast;
			}
			if std.str.eq(s, "type") {
				return front.token.TokenKind.KwType;
			}
		}
		5 => {
			if std.str.eq(s, "macro") {
				return front.token.TokenKind.KwMacro;
			}
			if std.str.eq(s, "const") {
				return front.token.TokenKind.KwConst;
			}
			if std.str.eq(s, "trait") {
				return front.token.TokenKind.KwTrait;
			}
			if std.str.eq(s, "match") {
				return front.token.TokenKind.KwMatch;
			}
			if std.str.eq(s, "break") {
				return front.token.TokenKind.KwBreak;
			}
			if std.str.eq(s, "defer") {
				return front.token.TokenKind.KwDefer;
			}
			if std.str.eq(s, "yield") {
				return front.token.TokenKind.KwYield;
			}
			if std.str.eq(s, "false") {
				return front.token.TokenKind.KwFalse;
			}
			if std.str.eq(s, "union") {
				return front.token.TokenKind.KwUnion;
			}
		}
		6 => {
			if std.str.eq(s, "import") {
				return front.token.TokenKind.KwImport;
			}
			if std.str.eq(s, "extern") {
				return front.token.TokenKind.KwExtern;
			}
			if std.str.eq(s, "static") {
				return front.token.TokenKind.KwStatic;
			}
			if std.str.eq(s, "struct") {
				return front.token.TokenKind.KwStruct;
			}
			if std.str.eq(s, "return") {
				return front.token.TokenKind.KwReturn;
			}
		}
		7 => {
			if std.str.eq(s, "bitcast") {
				return front.token.TokenKind.KwBitcast;
			}
		}
		8 => {
			if std.str.eq(s, "continue") {
				return front.token.TokenKind.KwContinue;
			}
			if std.str.eq(s, "volatile") {
				return front.token.TokenKind.KwVolatile;
			}
		}
		11 => {
			if std.str.eq(s, "unreachable") {
				return front.token.TokenKind.KwUnreachable;
			}
		}
		12 => {
			if std.str.eq(s, "thread_local") {
				return front.token.TokenKind.KwThreadLocal;
			}
		}
		_ => {}
	}
	return front.token.TokenKind.Ident;
}

/// Executes `lex_escape`.
pub fn lex_escape(c: u8, out: *mut u32) -> bool {
	match c {
		'n' => {
			*out = '\n' cast u32;
			return true;
		}
		't' => {
			*out = '\t' cast u32;
			return true;
		}
		'r' => {
			*out = '\r' cast u32;
			return true;
		}
		'\\' => {
			*out = '\\' cast u32;
			return true;
		}
		'\'' => {
			*out = '\'' cast u32;
			return true;
		}
		'"' => {
			*out = '"' cast u32;
			return true;
		}
		'0' => {
			*out = 0;
			return true;
		}
		'a' => {
			*out = 7;
			return true;
		}
		'b' => {
			*out = 8;
			return true;
		}
		'f' => {
			*out = 12;
			return true;
		}
		'v' => {
			*out = 11;
			return true;
		}
		_ => return false
	}
}
