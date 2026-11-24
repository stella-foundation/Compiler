mod front.lexer;
import "front/ast.sl";
import "front/log.sl";
import "front/token.sl";
import "std/mem.sl";
import "std/str.sl";

/// Represents the `Lexer` data structure.

impl Lexer {
	/// Executes `report_diag` (report diag).
	pub fn report_diag(
		self: *Lexer,
		level: front.log.Level,
		loc: front.log.SourceLoc,
		msg: []u8,
		code: front.log.DiagCode
	) -> void {
		if self.emit_diagnostics {
			front.log.report(level, loc, msg, code);
		}
	}

	/// Executes `peek` (peek).
	pub fn peek(self: *Lexer, off: usize) -> u8 {
		if self.pos + off < self.src.len {
			return self.src[self.pos + off];
		}
		return 0;
	}

	/// Executes `adv` (adv).
	pub fn adv(self: *mut Lexer) -> u8 {
		if self.pos >= self.src.len {
			return 0;
		}
		let c: u8 = self.src[self.pos];
		self.pos += 1;
		if c == '\n' {
			self.line += 1;
			self.col = 1;
		} else {
			self.col += 1;
		}
		return c;
	}

	/// Executes `cur_loc` (cur loc).
	pub fn cur_loc(self: *Lexer) -> front.log.SourceLoc {
		return front.log.make_loc(self.fname, self.line, self.col, 0);
	}

	/// Executes `push_tok` (push tok).
	pub fn push_tok(self: *mut Lexer, tok: front.token.Token) -> void {
		self.out.push(tok);
	}

	/// Executes `skip_ws_comments` (skip ws comments).
	pub fn skip_ws_comments(self: *mut Lexer) -> void {
		for self.pos < self.src.len {
			let c: u8 = self.peek(0);
			if c == ' ' || c == '\t' || c == '\r' || c == '\n' {
				self.adv();
				continue;
			}
			if c == '/' && self.peek(1) == '/' {
				for self.pos < self.src.len && self.peek(0) != '\n' {
					self.adv();
				}
				continue;
			}
			break;
		}
	}

	/// Executes `lex_ident_or_kw` (lex ident or kw).
	pub fn lex_ident_or_kw(self: *mut Lexer) -> bool {
		let start_line: i32 = self.line;
		let start_col: i32 = self.col;
		let start_pos: usize = self.pos;
		for self.pos < self.src.len && is_ident_cont(self.src[self.pos]) {
			self.pos += 1;
		}
		let len: usize = self.pos - start_pos;
		self.col += len cast i32;
		let sv: []u8 = self.src[start_pos..self.pos];
		let kind: front.token.TokenKind = kw_lookup(sv);
		let mut tok: front.token.Token = front.token.make_token(
			kind,
			front.log.make_loc(self.fname, start_line, start_col, len cast i32)
		);
		tok.text = sv;
		self.push_tok(tok);
		return true;
	}

	/// Executes `lex_builtin_module` (lex builtin module).
	pub fn lex_builtin_module(self: *mut Lexer) -> bool {
		let mut start: front.log.SourceLoc = self.cur_loc();
		self.adv();
		if !is_ident_start(self.peek(0)) {
			start.length = 1;
			self.report_diag(
				front.log.Level.Error,
				start,
				"bare '@' must be followed by an identifier",
				front.log.DiagCode.LexInvalidCharacter
			);
			return false;
		}
		let name_start: usize = self.pos;
		for self.pos < self.src.len && is_ident_cont(self.peek(0)) {
			self.adv();
		}
		let name: []u8 = self.src[name_start..self.pos];
		if !std.str.eq(name, "of") && !std.str.eq(name, "va") && !std.str.eq(name, "src")
			&& !std.str.eq(name, "syn") && !std.str.eq(name, "diag") {
			start.length = (name.len + 1) cast i32;
			self.report_diag(
				front.log.Level.Error,
				start,
				"unknown compiler builtin",
				front.log.DiagCode.LexInvalidCharacter
			);
			return false;
		}
		start.length = (name.len + 1) cast i32;
		let mut tok: front.token.Token = front.token.make_token(
			front.token.TokenKind.BuiltinModuleRef,
			start
		);
		tok.text = name;
		self.push_tok(tok);
		return true;
	}

	/// Executes `lex_define_ref` (lex define ref).
	pub fn lex_define_ref(self: *mut Lexer) -> bool {
		let mut start: front.log.SourceLoc = self.cur_loc();
		self.adv();
		let name_start: usize = self.pos;
		for self.pos < self.src.len && is_ident_cont(self.peek(0)) {
			self.adv();
		}
		let name: []u8 = self.src[name_start..self.pos];
		start.length = (name.len + 1) cast i32;
		let mut tok: front.token.Token = front.token.make_token(
			front.token.TokenKind.DefineRef,
			start
		);
		tok.text = name;
		self.push_tok(tok);
		return true;
	}

	/// Executes `consume_digits` (consume digits).
	pub fn consume_digits(
		self: *mut Lexer,
		is_hex: bool,
		is_bin: bool,
		force_dec: bool,
		start: front.log.SourceLoc,
		start_pos: usize,
		has_digits_out: *mut bool
	) -> bool {
		*has_digits_out = false;
		for self.pos < self.src.len {
			let c: u8 = self.peek(0);
			let valid: bool = force_dec ? is_digit(c)
				: (is_hex ? is_xdigit(c) : (is_bin ? is_bin_digit(c) : is_digit(c)));
			if valid {
				self.adv();
				*has_digits_out = true;
				continue;
			}
			if c == '_' {
				let next_c: u8 = self.peek(1);
				let next_valid: bool = force_dec ? is_digit(next_c)
					: (is_hex ? is_xdigit(next_c)
					: (is_bin ? is_bin_digit(next_c) : is_digit(next_c)));
				if !(*has_digits_out) || !next_valid {
					let len: i32 = span_len(self.pos, start_pos);
					let err_loc: front.log.SourceLoc = front.log.make_loc(
						start.file,
						start.line,
						start.column,
						len
					);
					self.report_diag(
						front.log.Level.Error,
						err_loc,
						"numeric separator '_' must appear between valid digits",
						front.log.DiagCode.LexInvalidNumber
					);
					return false;
				}
				self.adv();
				continue;
			}
			break;
		}
		return true;
	}

	/// Executes `lex_number` (lex number).
}
