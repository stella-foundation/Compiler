mod front.token;
import "front/log.sl";
import "std/mem.sl";

/// Enumerates `Op` variants.
pub enum Op: u8 {
	// Arithmetic
	Add,
	Sub,
	Mul,
	Div,
	Mod,
	// Bitwise
	BitAnd,
	BitOr,
	BitXor,
	Shl,
	Shr,
	// Comparison
	Eq,
	Ne,
	Lt,
	Le,
	Gt,
	Ge,
	// Logical
	LogicalAnd,
	LogicalOr
}

/// Enumerates `OpVariant` variants.
pub enum OpVariant: u8 {
	Normal,
	Wrap,
	Sat
}

/// Executes `op_text` (op text).
pub fn op_text(o: Op, variant: OpVariant) -> []u8 {
	match o {
		.Add => {
			match variant {
				.Wrap => return "+%",
				.Sat => return "+|",
				.Normal => return "+"
			}
		}
		.Sub => {
			match variant {
				.Wrap => return "-%",
				.Sat => return "-|",
				.Normal => return "-"
			}
		}
		.Mul => {
			match variant {
				.Wrap => return "*%",
				.Sat => return "*|",
				.Normal => return "*"
			}
		}
		.Div => return "/",
		.Mod => return "%",
		.BitAnd => return "&",
		.BitOr => return "|",
		.BitXor => return "^",
		.Shl => return "<<",
		.Shr => return ">>",
		.Eq => return "==",
		.Ne => return "!=",
		.Lt => return "<",
		.Le => return "<=",
		.Gt => return ">",
		.Ge => return ">=",
		.LogicalAnd => return "&&",
		.LogicalOr => return "||"
	}
}

/// Enumerates `TokenKind` variants.
pub enum TokenKind: u8 {
	// Special
	Eof,
	Unknown,

	// Literals
	IntLit,
	FloatLit,
	StringLit,
	CharLit,

	// Identifiers / compile-time defines
	Ident,
	DefineRef,
	BuiltinModuleRef,

	// Constants
	KwTrue,
	KwFalse,
	KwNull,

	// Declaration keywords
	KwMod,
	KwImport,
	KwPub,
	KwExtern,
	KwFn,
	KwMacro,
	KwLet,
	KwMut,
	KwConst,
	KwThreadLocal,
	KwStatic,
	KwStruct,
	KwUnion,
	KwType,
	KwEnum,
	KwTrait,
	KwImpl,
	KwSelf,

	// Control flow keywords
	KwIf,
	KwElse,
	KwFor,
	KwReturn,
	KwUnreachable,
	KwBreak,
	KwContinue,
	KwDefer,
	KwYield,
	KwMatch,

	// Inline asm
	KwAsm,
	KwVolatile,

	// Cast operators
	KwCast,
	KwBitcast,

	// Punctuation
	LParen,
	RParen,
	LBrace,
	RBrace,
	LBracket,
	RBracket,
	Comma,
	Semicolon,
	Colon,
	Question,
	Dot,
	Tilde,
	Bang,
	Operator,
	Assign,
	Arrow,
	FatArrow,
	DotDot,
	DotDotDot,
	Hash
}

/// Represents the `Token` data structure.
pub struct Token {
	/// Stores the `kind` field (kind).
	pub kind: TokenKind,
	/// Stores the `op` field (op).
	pub op: Op,
	/// Stores the `variant` field (variant).
	pub variant: OpVariant,
	/// Stores the `compound_assignment` field (compound assignment).
	pub compound_assignment: bool,
	/// Stores the `is_cstring` field (is cstring).
	pub is_cstring: bool,
	/// Stores the `owns_text` field (owns text).
	pub owns_text: bool,
	/// Stores the `loc` field (loc).
	pub loc: front.log.SourceLoc,
	/// Stores the `text` field (text).
	pub text: []u8,
	/// Stores the `int_val` field (int val).
	pub int_val: u64,
	/// Stores the `flt_val` field (flt val).
	pub flt_val: f64,
	/// Stores the `char_val` field (char val).
	pub char_val: u32
}

/// Executes `make_token` (make token).
pub fn make_token(kind: TokenKind, loc: front.log.SourceLoc) -> Token {
	return {
		.kind = kind,
		.op = Op.Add,
		.variant = OpVariant.Normal,
		.compound_assignment = false,
		.is_cstring = false,
		.owns_text = false,
		.loc = loc,
		.text = "",
		.int_val = 0,
		.flt_val = 0.0,
		.char_val = 0
	};
}

/// Executes `is_keyword` (is keyword).
pub fn is_keyword(k: TokenKind) -> bool {
	let v: u8 = k cast u8;
	return v >= (TokenKind.KwTrue cast u8) && v <= (TokenKind.KwBitcast cast u8);
}

/// Executes `token_kind_name` (token kind name).
pub fn token_kind_name(k: TokenKind) -> []u8 {
	match k {
		.Eof => return "eof",
		.Unknown => return "unknown",
		.IntLit => return "int",
		.FloatLit => return "float",
		.StringLit => return "string",
		.CharLit => return "char",
		.Ident => return "ident",
		.DefineRef => return "define-ref",
		.BuiltinModuleRef => return "builtin-module",
		.KwTrue => return "true",
		.KwFalse => return "false",
		.KwNull => return "null",
		.KwMod => return "mod",
		.KwImport => return "import",
		.KwPub => return "pub",
		.KwExtern => return "extern",
		.KwFn => return "fn",
		.KwMacro => return "macro",
		.KwLet => return "let",
		.KwMut => return "mut",
		.KwConst => return "const",
		.KwThreadLocal => return "thread_local",
		.KwStatic => return "static",
		.KwStruct => return "struct",
		.KwUnion => return "union",
		.KwType => return "type",
		.KwEnum => return "enum",
		.KwTrait => return "trait",
		.KwImpl => return "impl",
		.KwSelf => return "Self",
		.KwIf => return "if",
		.KwElse => return "else",
		.KwFor => return "for",
		.KwReturn => return "return",
		.KwUnreachable => return "unreachable",
		.KwBreak => return "break",
		.KwContinue => return "continue",
		.KwDefer => return "defer",
		.KwYield => return "yield",
		.KwMatch => return "match",
		.KwAsm => return "asm",
		.KwVolatile => return "volatile",
		.KwCast => return "cast",
		.KwBitcast => return "bitcast",
		.LParen => return "(",
		.RParen => return ")",
		.LBrace => return "{",
		.RBrace => return "}",
		.LBracket => return "[",
		.RBracket => return "]",
		.Comma => return ",",
		.Semicolon => return ";",
		.Colon => return ":",
		.Question => return "?",
		.Dot => return ".",
		.Tilde => return "~",
		.Bang => return "!",
		.Operator => return "operator",
		.Assign => return "=",
		.Arrow => return "->",
		.FatArrow => return "=>",
		.DotDot => return "..",
		.DotDotDot => return "...",
		.Hash => return "#"
	}
}

/// Represents the `TokenList` data structure.
pub struct TokenList {
	/// Stores the `data` field (data).
	pub data: *mut Token,
	/// Stores the `len` field (len).
	pub len: usize,
	/// Stores the `cap` field (cap).
	pub cap: usize
}

impl TokenList {
	/// Executes `init` (init).
	pub fn init(self: *mut Self, initial_cap: usize) -> bool {
		self.data = null;
		self.len = 0;
		self.cap = 0;
		if initial_cap == 0 {
			return true;
		}
		let mut pa: std.mem.PageAllocator = std.mem.PageAllocator.init();
		match pa.alloc(initial_cap * @of.size(Token), @of.align(Token)) {
			.Ok(raw) => {
				self.data = raw cast *mut Token;
				self.cap = initial_cap;
				return true;
			}
			.Err(_) => return false
		}
	}

	/// Executes `push` (push).
	pub fn push(self: *mut Self, tok: Token) -> bool {
		if self.len == self.cap {
			let new_cap: usize = self.cap == 0 ? 16 : self.cap * 2;
			let mut pa: std.mem.PageAllocator = std.mem.PageAllocator.init();
			match pa.alloc(new_cap * @of.size(Token), @of.align(Token)) {
				.Ok(raw) => {
					let next_buf: *mut Token = raw cast *mut Token;
					if self.data != null {
						std.mem.copy(raw, self.data cast *u8, self.len * @of.size(Token));
						pa.free(
							self.data cast *u8,
							self.cap * @of.size(Token),
							@of.align(Token)
						);
					}
					self.data = next_buf;
					self.cap = new_cap;
				}
				.Err(_) => return false
			}
		}
		self.data[self.len] = tok;
		self.len += 1;
		return true;
	}

	/// Executes `free` (free).
	pub fn free(self: *mut Self) -> void {
		if self.data != null {
			let mut pa: std.mem.PageAllocator = std.mem.PageAllocator.init();
			pa.free(self.data cast *u8, self.cap * @of.size(Token), @of.align(Token));
			self.data = null;
		}
		self.len = 0;
		self.cap = 0;
	}
}
