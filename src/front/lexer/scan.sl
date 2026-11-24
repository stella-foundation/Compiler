mod front.lexer;
import "front/ast.sl";
import "front/log.sl";
import "front/token.sl";
import "std/mem.sl";
import "std/str.sl";

/// Represents the `Lexer` data structure.

impl Lexer {
	/// Executes `lex_number`.
	pub fn lex_number(self: *mut Lexer) -> bool {
		let start_pos: usize = self.pos;
		let mut start: front.log.SourceLoc = self.cur_loc();
		let mut is_hex: bool = false;
		let mut is_bin: bool = false;
		if self.peek(0) == '0' && (self.peek(1) == 'x' || self.peek(1) == 'X') {
			is_hex = true;
			self.adv();
			self.adv();
		} else if self.peek(0) == '0' && (self.peek(1) == 'b' || self.peek(1) == 'B') {
			is_bin = true;
			self.adv();
			self.adv();
		}

		let mut is_float: bool = false;
		let mut has_digits: bool = false;
		if !self.consume_digits(is_hex, is_bin, false, start, start_pos, &has_digits) {
			return false;
		}
		if !has_digits {
			start.length = span_len(self.pos, start_pos);
			if is_hex {
				self.report_diag(
					front.log.Level.Error,
					start,
					"missing digits after '0x'",
					front.log.DiagCode.LexInvalidNumber
				);
			} else if is_bin {
				self.report_diag(
					front.log.Level.Error,
					start,
					"missing digits after '0b'",
					front.log.DiagCode.LexInvalidNumber
				);
			} else {
				self.report_diag(
					front.log.Level.Error,
					start,
					"invalid number literal",
					front.log.DiagCode.LexInvalidNumber
				);
			}
			return false;
		}

		if !is_bin && self.peek(0) == '.' {
			let next_c: u8 = self.peek(1);
			let next_valid: bool = is_hex ? is_xdigit(next_c) : is_digit(next_c);
			if next_valid {
				is_float = true;
				self.adv();
				let mut frac_digits: bool = false;
				if !self.consume_digits(is_hex, is_bin, false, start, start_pos, &frac_digits) {
					return false;
				}
			} else if next_c == '_' {
				start.length = (self.pos - start_pos) cast i32;
				self.report_diag(
					front.log.Level.Error,
					start,
					"numeric separator '_' must appear between valid digits",
					front.log.DiagCode.LexInvalidNumber
				);
				return false;
			}
		}

		if !is_bin && ((is_hex && (self.peek(0) == 'p' || self.peek(0) == 'P'))
						|| (!is_hex && (self.peek(0) == 'e' || self.peek(0) == 'E'))) {
			is_float = true;
			self.adv();
			if self.peek(0) == '+' || self.peek(0) == '-' {
				self.adv();
			}
			let mut exp_digits: bool = false;
			if !self.consume_digits(is_hex, is_bin, true, start, start_pos, &exp_digits) {
				return false;
			}
			if !exp_digits {
				start.length = span_len(self.pos, start_pos);
				self.report_diag(
					front.log.Level.Error,
					start,
					"malformed exponent in floating-point literal",
					front.log.DiagCode.LexInvalidNumber
				);
				return false;
			}
		}

		let mut has_lossy_suffix: bool = false;
		if is_float && self.peek(0) == '~' {
			has_lossy_suffix = true;
			self.adv();
		}
		if !is_bin && (self.peek(0) == 'f' || self.peek(0) == 'F') {
			is_float = true;
			self.adv();
		}
		if is_float && !has_lossy_suffix && self.peek(0) == '~' {
			has_lossy_suffix = true;
			self.adv();
		}
		if is_float && self.peek(0) == '~' {
			start.length = (self.pos - start_pos + 1) cast i32;
			self.report_diag(
				front.log.Level.Error,
				start,
				"duplicate `~` suffix on floating-point literal",
				front.log.DiagCode.LexInvalidNumber
			);
			return false;
		}
		if self.peek(0) == '_' || (self.peek(0) == '.' && self.peek(1) == '_') {
			start.length = span_len(self.pos, start_pos);
			self.report_diag(
				front.log.Level.Error,
				start,
				"numeric separator '_' must appear between valid digits",
				front.log.DiagCode.LexInvalidNumber
			);
			return false;
		}

		let raw: []u8 = self.src[start_pos..self.pos];
		start.length = raw.len cast i32;
		let kind: front.token.TokenKind = is_float ? front.token.TokenKind.FloatLit
			: front.token.TokenKind.IntLit;
		let mut tok: front.token.Token = front.token.make_token(kind, start);
		tok.text = raw;
		if is_float {
			tok.flt_val = parse_float_literal(raw);
		} else {
			let pi: ParsedInt = parse_int_literal(raw);
			tok.int_val = pi.ok ? pi.value : 0;
			if pi.overflow {
				self.report_diag(
					front.log.Level.Error,
					start,
					"integer literal exceeds the maximum supported value",
					front.log.DiagCode.LexInvalidNumber
				);
			}
		}
		self.push_tok(tok);
		return true;
	}

	/// Executes `lex_string` (lex string).
	pub fn lex_string(self: *mut Lexer, is_cstring: bool) -> bool {
		let start_pos: usize = self.pos;
		let mut start: front.log.SourceLoc = self.cur_loc();
		if is_cstring {
			self.adv();
		}
		self.adv();

		let mut cap: usize = 32;
		let mut len: usize = 0;
		let mut buf: *mut u8 = front.ast.arena_alloc(cap);
		if buf == null {
			return false;
		}

		for self.pos < self.src.len && self.peek(0) != '"' {
			let c: u8 = self.adv();
			let mut out_byte: u8 = c;
			if c == '\\' {
				if self.pos >= self.src.len {
					break;
				}
				let e: u8 = self.adv();
				if e == 'x' {
					let mut v: u32 = 0;
					let mut count: i32 = 0;
					for count < 2 && self.pos < self.src.len && is_xdigit(self.peek(0)) {
						v = (v << 4) | (hex_val(self.adv()) cast u32);
						count += 1;
					}
					if count != 2 {
						self.report_diag(
							front.log.Level.Error,
							start,
							"hex escape requires exactly two digits",
							front.log.DiagCode.LexInvalidCharacter
						);
					}
					out_byte = (v & 255) cast u8;
				} else {
					let mut v: u32 = 0;
					if !lex_escape(e, &v) {
						self.report_diag(
							front.log.Level.Warning,
							start,
							"unknown escape",
							front.log.DiagCode.WarningGeneral
						);
						v = e cast u32;
					}
					out_byte = (v & 255) cast u8;
				}
			}
			if len == cap {
				let new_cap: usize = cap * 2;
				let nb: *mut u8 = front.ast.arena_alloc(new_cap);
				if nb == null {
					return false;
				}
				std.mem.copy(nb, buf, len);
				buf = nb;
				cap = new_cap;
			}
			buf[len] = out_byte;
			len += 1;
		}

		if self.peek(0) == '"' {
			self.adv();
		} else {
			start.length = 1;
			self.report_diag(
				front.log.Level.Error,
				start,
				"unterminated string literal",
				front.log.DiagCode.LexUnterminatedString
			);
		}

		start.length = (self.pos - start_pos) cast i32;
		let mut tok: front.token.Token = front.token.make_token(
			front.token.TokenKind.StringLit,
			start
		);
		tok.is_cstring = is_cstring;
		tok.owns_text = true;
		tok.text = buf[0..len];
		self.push_tok(tok);
		return true;
	}

	/// Executes `lex_char` (lex char).
	pub fn lex_char(self: *mut Lexer) -> bool {
		let start_pos: usize = self.pos;
		let mut start: front.log.SourceLoc = self.cur_loc();
		self.adv();
		let mut v: u32 = 0;
		let mut has_value: bool = false;
		if self.peek(0) == '\\' {
			self.adv();
			let e: u8 = self.adv();
			has_value = true;
			if e == 'x' {
				let mut count: i32 = 0;
				for count < 2 && self.pos < self.src.len && is_xdigit(self.peek(0)) {
					v = (v << 4) | (hex_val(self.adv()) cast u32);
					count += 1;
				}
				if count != 2 {
					self.report_diag(
						front.log.Level.Error,
						start,
						"hex escape requires exactly two digits",
						front.log.DiagCode.LexInvalidCharacter
					);
				}
			} else if !lex_escape(e, &v) {
				self.report_diag(
					front.log.Level.Warning,
					start,
					"unknown escape",
					front.log.DiagCode.WarningGeneral
				);
				v = e cast u32;
			}
		} else if self.peek(0) != 0 && self.peek(0) != '\'' {
			v = self.adv() cast u32;
			has_value = true;
		}
		if !has_value {
			self.report_diag(
				front.log.Level.Error,
				start,
				"empty char literal",
				front.log.DiagCode.LexUnterminatedChar
			);
		}
		if self.peek(0) == '\'' {
			self.adv();
		} else {
			start.length = 1;
			self.report_diag(
				front.log.Level.Error,
				start,
				"unterminated char literal",
				front.log.DiagCode.LexUnterminatedChar
			);
		}
		start.length = (self.pos - start_pos) cast i32;
		let mut tok: front.token.Token = front.token.make_token(
			front.token.TokenKind.CharLit,
			start
		);
		tok.char_val = v & 255;
		tok.text = self.src[start_pos..self.pos];
		self.push_tok(tok);
		return true;
	}

	/// Executes `lex_arith_op` (lex arith op).
	pub fn lex_arith_op(
		self: *mut Lexer,
		op: front.token.Op,
		start_pos: usize,
		start_loc: front.log.SourceLoc
	) -> void {
		let mut tok: front.token.Token = front.token.make_token(
			front.token.TokenKind.Operator,
			start_loc
		);
		tok.op = op;
		if self.peek(0) == '%' {
			self.adv();
			tok.variant = front.token.OpVariant.Wrap;
		} else if self.peek(0) == '|' {
			self.adv();
			tok.variant = front.token.OpVariant.Sat;
		}
		if self.peek(0) == '=' {
			self.adv();
			tok.compound_assignment = true;
		}
		tok.text = self.src[start_pos..self.pos];
		tok.loc.length = tok.text.len cast i32;
		self.push_tok(tok);
	}

	/// Executes `lex_simple_compound_op` (lex simple compound op).
	pub fn lex_simple_compound_op(
		self: *mut Lexer,
		op: front.token.Op,
		start_pos: usize,
		start_loc: front.log.SourceLoc
	) -> void {
		let mut tok: front.token.Token = front.token.make_token(
			front.token.TokenKind.Operator,
			start_loc
		);
		tok.op = op;
		if self.peek(0) == '=' {
			self.adv();
			tok.compound_assignment = true;
		}
		tok.text = self.src[start_pos..self.pos];
		tok.loc.length = tok.text.len cast i32;
		self.push_tok(tok);
	}

	/// Executes `tokenize` (tokenize).
	pub fn tokenize(self: *mut Lexer) -> bool {
		for self.pos < self.src.len {
			self.skip_ws_comments();
			if self.pos >= self.src.len {
				break;
			}
			let c: u8 = self.peek(0);
			if c == 'c' && self.peek(1) == '"' {
				if !self.lex_string(true) {
					return false;
				}
				continue;
			}
			if is_ident_start(c) {
				if !self.lex_ident_or_kw() {
					return false;
				}
				continue;
			}
			if c == '@' {
				if !self.lex_builtin_module() {
					return false;
				}
				continue;
			}
			if c == '#' && self.peek(1) != '[' && is_ident_start(self.peek(1)) {
				if !self.lex_define_ref() {
					return false;
				}
				continue;
			}
			if is_digit(c) {
				if !self.lex_number() {
					return false;
				}
				continue;
			}
			if c == '"' {
				if !self.lex_string(false) {
					return false;
				}
				continue;
			}
			if c == '\'' {
				if !self.lex_char() {
					return false;
				}
				continue;
			}

			let start_pos: usize = self.pos;
			let start_loc: front.log.SourceLoc = self.cur_loc();
			self.adv();

			if c == '(' {
				let mut t: front.token.Token = front.token.make_token(
					front.token.TokenKind.LParen,
					start_loc
				);
				t.text = "(";
				t.loc.length = 1;
				self.push_tok(t);
			} else if c == ')' {
				let mut t: front.token.Token = front.token.make_token(
					front.token.TokenKind.RParen,
					start_loc
				);
				t.text = ")";
				t.loc.length = 1;
				self.push_tok(t);
			} else if c == '{' {
				let mut t: front.token.Token = front.token.make_token(
					front.token.TokenKind.LBrace,
					start_loc
				);
				t.text = "{";
				t.loc.length = 1;
				self.push_tok(t);
			} else if c == '}' {
				let mut t: front.token.Token = front.token.make_token(
					front.token.TokenKind.RBrace,
					start_loc
				);
				t.text = "}";
				t.loc.length = 1;
				self.push_tok(t);
			} else if c == '[' {
				let mut t: front.token.Token = front.token.make_token(
					front.token.TokenKind.LBracket,
					start_loc
				);
				t.text = "[";
				t.loc.length = 1;
				self.push_tok(t);
			} else if c == ']' {
				let mut t: front.token.Token = front.token.make_token(
					front.token.TokenKind.RBracket,
					start_loc
				);
				t.text = "]";
				t.loc.length = 1;
				self.push_tok(t);
			} else if c == ',' {
				let mut t: front.token.Token = front.token.make_token(
					front.token.TokenKind.Comma,
					start_loc
				);
				t.text = ",";
				t.loc.length = 1;
				self.push_tok(t);
			} else if c == '#' {
				let mut t: front.token.Token = front.token.make_token(
					front.token.TokenKind.Hash,
					start_loc
				);
				t.text = "#";
				t.loc.length = 1;
				self.push_tok(t);
			} else if c == ';' {
				let mut t: front.token.Token = front.token.make_token(
					front.token.TokenKind.Semicolon,
					start_loc
				);
				t.text = ";";
				t.loc.length = 1;
				self.push_tok(t);
			} else if c == ':' {
				let mut t: front.token.Token = front.token.make_token(
					front.token.TokenKind.Colon,
					start_loc
				);
				t.text = ":";
				t.loc.length = 1;
				self.push_tok(t);
			} else if c == '?' {
				let mut t: front.token.Token = front.token.make_token(
					front.token.TokenKind.Question,
					start_loc
				);
				t.text = "?";
				t.loc.length = 1;
				self.push_tok(t);
			} else if c == '~' {
				let mut t: front.token.Token = front.token.make_token(
					front.token.TokenKind.Tilde,
					start_loc
				);
				t.text = "~";
				t.loc.length = 1;
				self.push_tok(t);
			} else if c == '+' {
				self.lex_arith_op(front.token.Op.Add, start_pos, start_loc);
			} else if c == '-' {
				if self.peek(0) == '>' {
					self.adv();
					let mut t: front.token.Token = front.token.make_token(
						front.token.TokenKind.Arrow,
						start_loc
					);
					t.text = "->";
					t.loc.length = 2;
					self.push_tok(t);
				} else {
					self.lex_arith_op(front.token.Op.Sub, start_pos, start_loc);
				}
			} else if c == '*' {
				self.lex_arith_op(front.token.Op.Mul, start_pos, start_loc);
			} else if c == '/' {
				self.lex_simple_compound_op(front.token.Op.Div, start_pos, start_loc);
			} else if c == '%' {
				self.lex_simple_compound_op(front.token.Op.Mod, start_pos, start_loc);
			} else if c == '^' {
				self.lex_simple_compound_op(front.token.Op.BitXor, start_pos, start_loc);
			} else if c == '&' {
				if self.peek(0) == '&' {
					self.adv();
					let mut t: front.token.Token = front.token.make_token(
						front.token.TokenKind.Operator,
						start_loc
					);
					t.op = front.token.Op.LogicalAnd;
					t.text = "&&";
					t.loc.length = 2;
					self.push_tok(t);
				} else {
					self.lex_simple_compound_op(front.token.Op.BitAnd, start_pos, start_loc);
				}
			} else if c == '|' {
				if self.peek(0) == '|' {
					self.adv();
					let mut t: front.token.Token = front.token.make_token(
						front.token.TokenKind.Operator,
						start_loc
					);
					t.op = front.token.Op.LogicalOr;
					t.text = "||";
					t.loc.length = 2;
					self.push_tok(t);
				} else {
					self.lex_simple_compound_op(front.token.Op.BitOr, start_pos, start_loc);
				}
			} else if c == '!' {
				if self.peek(0) == '=' {
					self.adv();
					let mut t: front.token.Token = front.token.make_token(
						front.token.TokenKind.Operator,
						start_loc
					);
					t.op = front.token.Op.Ne;
					t.text = "!=";
					t.loc.length = 2;
					self.push_tok(t);
				} else {
					let mut t: front.token.Token = front.token.make_token(
						front.token.TokenKind.Bang,
						start_loc
					);
					t.text = "!";
					t.loc.length = 1;
					self.push_tok(t);
				}
			} else if c == '=' {
				if self.peek(0) == '=' {
					self.adv();
					let mut t: front.token.Token = front.token.make_token(
						front.token.TokenKind.Operator,
						start_loc
					);
					t.op = front.token.Op.Eq;
					t.text = "==";
					t.loc.length = 2;
					self.push_tok(t);
				} else if self.peek(0) == '>' {
					self.adv();
					let mut t: front.token.Token = front.token.make_token(
						front.token.TokenKind.FatArrow,
						start_loc
					);
					t.text = "=>";
					t.loc.length = 2;
					self.push_tok(t);
				} else {
					let mut t: front.token.Token = front.token.make_token(
						front.token.TokenKind.Assign,
						start_loc
					);
					t.text = "=";
					t.loc.length = 1;
					self.push_tok(t);
				}
			} else if c == '<' {
				if self.peek(0) == '<' {
					self.adv();
					self.lex_simple_compound_op(front.token.Op.Shl, start_pos, start_loc);
				} else if self.peek(0) == '=' {
					self.adv();
					let mut t: front.token.Token = front.token.make_token(
						front.token.TokenKind.Operator,
						start_loc
					);
					t.op = front.token.Op.Le;
					t.text = "<=";
					t.loc.length = 2;
					self.push_tok(t);
				} else {
					let mut t: front.token.Token = front.token.make_token(
						front.token.TokenKind.Operator,
						start_loc
					);
					t.op = front.token.Op.Lt;
					t.text = "<";
					t.loc.length = 1;
					self.push_tok(t);
				}
			} else if c == '>' {
				if self.peek(0) == '>' {
					self.adv();
					self.lex_simple_compound_op(front.token.Op.Shr, start_pos, start_loc);
				} else if self.peek(0) == '=' {
					self.adv();
					let mut t: front.token.Token = front.token.make_token(
						front.token.TokenKind.Operator,
						start_loc
					);
					t.op = front.token.Op.Ge;
					t.text = ">=";
					t.loc.length = 2;
					self.push_tok(t);
				} else {
					let mut t: front.token.Token = front.token.make_token(
						front.token.TokenKind.Operator,
						start_loc
					);
					t.op = front.token.Op.Gt;
					t.text = ">";
					t.loc.length = 1;
					self.push_tok(t);
				}
			} else if c == '.' {
				if self.peek(0) == '.' && self.peek(1) == '.' {
					self.adv();
					self.adv();
					let mut t: front.token.Token = front.token.make_token(
						front.token.TokenKind.DotDotDot,
						start_loc
					);
					t.text = "...";
					t.loc.length = 3;
					self.push_tok(t);
				} else if self.peek(0) == '.' {
					self.adv();
					let mut t: front.token.Token = front.token.make_token(
						front.token.TokenKind.DotDot,
						start_loc
					);
					t.text = "..";
					t.loc.length = 2;
					self.push_tok(t);
				} else {
					let mut t: front.token.Token = front.token.make_token(
						front.token.TokenKind.Dot,
						start_loc
					);
					t.text = ".";
					t.loc.length = 1;
					self.push_tok(t);
				}
			} else {
				let mut err_loc: front.log.SourceLoc = start_loc;
				err_loc.length = 1;
				self.report_diag(
					front.log.Level.Error,
					err_loc,
					"unexpected character",
					front.log.DiagCode.LexInvalidCharacter
				);
				return false;
			}
		}

		let eof_tok: front.token.Token = front.token.make_token(
			front.token.TokenKind.Eof,
			self.cur_loc()
		);
		self.push_tok(eof_tok);
		return !front.log.has_error();
	}
}
