mod front.parser;
import "front/ast.sl";
import "front/log.sl";
import "front/token.sl";
import "std/mem.sl";
import "std/str.sl";

/// Represents the `Parser` data structure.

impl Parser {
	/// Executes `peek` (peek).
	pub fn peek(self: *Parser, off: usize) -> front.token.Token {
		if self.toks.len == 0 {
			return front.token.make_token(front.token.TokenKind.Eof, front.log.empty_loc());
		}
		let i: usize = self.idx + off;
		if i >= self.toks.len {
			return self.toks.data[self.toks.len - 1];
		}
		return self.toks.data[i];
	}

	/// Executes `consume` (consume).
	pub fn consume(self: *mut Parser) -> front.token.Token {
		let t: front.token.Token = self.peek(0);
		if self.toks.len > 0 && self.idx < self.toks.len - 1 {
			self.idx += 1;
		}
		return t;
	}

	/// Executes `at` (at).
	pub fn at(self: *Parser, k: front.token.TokenKind) -> bool {
		return self.peek(0).kind == k;
	}

	/// Executes `at_binop` (at binop).
	pub fn at_binop(self: *Parser, o: front.token.Op) -> bool {
		let t: front.token.Token = self.peek(0);
		return t.kind == front.token.TokenKind.Operator && t.op == o && !t.compound_assignment;
	}

	/// Executes `accept` (accept).
	pub fn accept(self: *mut Parser, k: front.token.TokenKind) -> bool {
		if self.at(k) {
			self.consume();
			return true;
		}
		return false;
	}

	/// Executes `expect` (expect).
	pub fn expect(self: *mut Parser, k: front.token.TokenKind, what: []u8) -> bool {
		if self.accept(k) {
			return true;
		}
		let t: front.token.Token = self.peek(0);
		let mut inner: []u8 = what;
		let mut suffix: []u8 = "";
		if what.len >= 2 && what[0] == '\'' {
			for let mut qi: usize = 1; qi < what.len; qi += 1 {
				if what[qi] == '\'' {
					inner = what[1..qi];
					if qi + 1 < what.len {
						suffix = what[qi + 1..what.len];
					}
					break;
				}
			}
		}
		let mut msg: []u8 = "unexpected token";
		let total: usize = 10 + inner.len + 1 + suffix.len
			+ (t.text.len > 0 ? (11 + t.text.len + 1) : 0);
		let buf: *mut u8 = front.ast.arena_alloc(total);
		if buf != null {
			let mut pos: usize = 0;
			let pfx: []u8 = "expected `";
			std.mem.copy(&buf[pos], pfx.ptr, pfx.len);
			pos += pfx.len;
			if inner.len > 0 {
				std.mem.copy(&buf[pos], inner.ptr, inner.len);
				pos += inner.len;
			}
			buf[pos] = '`' cast u8;
			pos += 1;
			if suffix.len > 0 {
				std.mem.copy(&buf[pos], suffix.ptr, suffix.len);
				pos += suffix.len;
			}
			if t.text.len > 0 {
				let mid: []u8 = " but got `";
				std.mem.copy(&buf[pos], mid.ptr, mid.len);
				pos += mid.len;
				std.mem.copy(&buf[pos], t.text.ptr, t.text.len);
				pos += t.text.len;
				buf[pos] = '`' cast u8;
				pos += 1;
			}
			msg = buf[0..pos];
		}
		if k == front.token.TokenKind.Semicolon {
			front.log.report_with_help(
				front.log.Level.Error,
				t.loc,
				msg,
				front.log.DiagCode.ParseExpectedToken,
				"",
				"insert `;`",
				";"
			);
		} else if k == front.token.TokenKind.Colon {
			front.log.report_with_help(
				front.log.Level.Error,
				t.loc,
				msg,
				front.log.DiagCode.ParseExpectedToken,
				"",
				"insert `:`",
				":"
			);
		} else {
			front.log.report(
				front.log.Level.Error,
				t.loc,
				msg,
				front.log.DiagCode.ParseExpectedToken
			);
		}
		if t.kind != front.token.TokenKind.Eof && k != front.token.TokenKind.Semicolon && k
			!= front.token.TokenKind.Colon {
			self.consume();
		}
		return false;
	}

	/// Executes `parse_attributes` (parse attributes).
	pub fn parse_attributes(self: *mut Parser, out: *mut front.ast.AttributeList) -> void {
		for self.at(front.token.TokenKind.Hash) {
			let list_loc: front.log.SourceLoc = self.peek(0).loc;
			if out.loc.line == 0 {
				out.loc = list_loc;
			}
			self.consume();
			self.expect(front.token.TokenKind.LBracket, "'[' after '#'");
			for !self.at(front.token.TokenKind.RBracket) && !self.at(front.token.TokenKind.Eof) {
				let mut a: front.ast.Attribute = {
					.name = "",
					.negated = false,
					.args = { .data = null, .len = 0, .cap = 0 },
					.arg_is_string = { .data = null, .len = 0, .cap = 0 },
					.loc = self.peek(0).loc
				};
				if self.accept(front.token.TokenKind.Bang) {
					a.negated = true;
				}
				if is_attr_name_token(self.peek(0).kind) {
					a.name = self.consume().text;
					if std.str.eq(a.name, "unused") {
						front.log.report(
							front.log.Level.Error,
							a.loc,
							"unknown attribute `#[unused]`",
							front.log.DiagCode.General
						);
					}
				} else {
					front.log.report(
						front.log.Level.Error,
						self.peek(0).loc,
						"expected attribute name",
						front.log.DiagCode.ParseExpectedToken
					);
					if !self.at(front.token.TokenKind.RBracket)
						&& !self.at(front.token.TokenKind.Eof) {
						self.consume();
					}
					continue;
				}
				if self.accept(front.token.TokenKind.LParen) {
					for !self.at(front.token.TokenKind.RParen)
						&& !self.at(front.token.TokenKind.Eof) {
						let arg_tok: front.token.Token = self.peek(0);
						if arg_tok.kind == front.token.TokenKind.StringLit {
							self.consume();
							a.args.push(arg_tok.text);
							a.arg_is_string.push(true);
						} else if arg_tok.kind == front.token.TokenKind.IntLit || arg_tok.kind
							== front.token.TokenKind.Ident {
							self.consume();
							a.args.push(arg_tok.text);
							a.arg_is_string.push(false);
						} else {
							front.log.report(
								front.log.Level.Error,
								arg_tok.loc,
								"expected attribute argument",
								front.log.DiagCode.ParseExpectedToken
							);
							self.consume();
						}
						if !self.at(front.token.TokenKind.RParen) {
							self.expect(front.token.TokenKind.Comma, "',' or ')' in attribute");
						}
					}
					self.expect(front.token.TokenKind.RParen, "')' after attribute arguments");
				}
				out.attrs.push(a);
				if !self.accept(front.token.TokenKind.Comma) {
					break;
				}
			}
			self.expect(front.token.TokenKind.RBracket, "']' after attributes");
		}
	}

	/// Executes `starts_type_at` (starts type at).
	pub fn starts_type_at(self: *Parser, mut pos: usize) -> bool {
		if self.toks.len == 0 || pos >= self.toks.len {
			return false;
		}
		for pos < self.toks.len && self.toks.data[pos].kind == front.token.TokenKind.Operator
			&& self.toks.data[pos].op == front.token.Op.Mul
			&& !self.toks.data[pos].compound_assignment {
			pos += 1;
			for pos < self.toks.len && (self.toks.data[pos].kind == front.token.TokenKind.KwMut
				|| self.toks.data[pos].kind == front.token.TokenKind.KwVolatile) {
				pos += 1;
			}
		}
		if pos >= self.toks.len {
			return false;
		}
		let k: front.token.TokenKind = self.toks.data[pos].kind;
		if k == front.token.TokenKind.Ident || k == front.token.TokenKind.KwFn
			|| k == front.token.TokenKind.KwType || k == front.token.TokenKind.KwSelf {
			return true;
		}
		if k == front.token.TokenKind.LBracket {
			let mut depth: i32 = 0;
			for pos < self.toks.len {
				if self.toks.data[pos].kind == front.token.TokenKind.LBracket {
					depth += 1;
				} else if self.toks.data[pos].kind == front.token.TokenKind.RBracket {
					depth -= 1;
					if depth == 0 {
						pos += 1;
						for pos < self.toks.len
							&& (self.toks.data[pos].kind == front.token.TokenKind.KwMut
							|| self.toks.data[pos].kind == front.token.TokenKind.KwVolatile) {
							pos += 1;
						}
						return self.starts_type_at(pos);
					}
				}
				pos += 1;
			}
		}
		return false;
	}

	/// Executes `generic_call_suffix` (generic call suffix).
	pub fn generic_call_suffix(self: *Parser) -> bool {
		if !self.at_binop(front.token.Op.Lt) {
			return false;
		}
		let mut depth: i32 = 0;
		let mut pos: usize = self.idx;
		for pos < self.toks.len {
			let t: front.token.Token = self.toks.data[pos];
			if t.kind == front.token.TokenKind.Operator && !t.compound_assignment && t.op
				== front.token.Op.Lt {
				depth += 1;
			} else if t.kind == front.token.TokenKind.Operator && !t.compound_assignment && t.op
				== front.token.Op.Gt {
				depth -= 1;
				if depth == 0 {
					let next_pos: usize = pos + 1;
					if next_pos < self.toks.len {
						let nk: front.token.TokenKind = self.toks.data[next_pos].kind;
						return nk == front.token.TokenKind.LParen || nk == front.token.TokenKind.Dot
							|| nk == front.token.TokenKind.LBrace;
					}
					return false;
				}
			} else if t.kind == front.token.TokenKind.Semicolon || t.kind
				== front.token.TokenKind.LBrace
				|| t.kind == front.token.TokenKind.RBrace || t.kind == front.token.TokenKind.Eof {
				return false;
			}
			pos += 1;
		}
		return false;
	}

	/// Executes `parse_generic_args` (parse generic args).
	pub fn parse_generic_args(
		self: *mut Parser,
		out: *mut front.ast.ValList<front.ast.GenericArg>
	) -> void {
		if !self.at_binop(front.token.Op.Lt) {
			return;
		}
		self.consume();
		let prev_parsing: bool = self.parsing_generic_arg;
		let prev_nesting: u32 = self.generic_arg_nesting;
		self.parsing_generic_arg = true;
		self.generic_arg_nesting = 0;

		for !self.at_binop(front.token.Op.Gt) && !self.at(front.token.TokenKind.Eof) {
			let loc: front.log.SourceLoc = self.peek(0).loc;
			let mut ga: front.ast.GenericArg = {
				.kind = front.ast.GenericArgKind.Type,
				.ty = null,
				.value = null,
				.loc = loc
			};
			if self.starts_type_at(self.idx) {
				ga.kind = front.ast.GenericArgKind.Type;
				ga.ty = self.parse_type();
			} else {
				ga.kind = front.ast.GenericArgKind.Value;
				ga.value = self.parse_expr();
			}
			out.push(ga);
			if !self.at_binop(front.token.Op.Gt) {
				self.expect(front.token.TokenKind.Comma, "',' or '>' in generic arguments");
			}
		}
		if self.at_binop(front.token.Op.Gt) {
			self.consume();
		} else {
			front.log.report(
				front.log.Level.Error,
				self.peek(0).loc,
				"expected '>' closing generic arguments",
				front.log.DiagCode.ParseExpectedToken
			);
		}
		self.parsing_generic_arg = prev_parsing;
		self.generic_arg_nesting = prev_nesting;
	}

	/// Executes `parse_type` (parse type).
	pub fn parse_type(self: *mut Parser) -> *mut front.ast.TypeRef {
		// Collect leading pointer qualifiers
		let mut ptr_locs: front.ast.ValList<front.log.SourceLoc> = {
			.data = null,
			.len = 0,
			.cap = 0
		};
		let mut ptr_muts: front.ast.ValList<bool> = { .data = null, .len = 0, .cap = 0 };
		let mut ptr_vols: front.ast.ValList<bool> = { .data = null, .len = 0, .cap = 0 };
		for self.at_binop(front.token.Op.Mul) {
			let ploc: front.log.SourceLoc = self.peek(0).loc;
			self.consume();
			let mut is_mut: bool = false;
			let mut is_vol: bool = false;
			for self.at(front.token.TokenKind.KwMut) || self.at(front.token.TokenKind.KwVolatile) {
				if self.accept(front.token.TokenKind.KwMut) {
					is_mut = true;
				} else {
					self.consume();
					is_vol = true;
				}
			}
			ptr_locs.push(ploc);
			ptr_muts.push(is_mut);
			ptr_vols.push(is_vol);
		}

		let mut type_attrs: front.ast.AttributeList = front.ast.make_attr_list();
		if self.at(front.token.TokenKind.Hash) {
			self.parse_attributes(&type_attrs);
			if !self.at(front.token.TokenKind.KwFn) {
				front.log.report(
					front.log.Level.Error,
					type_attrs.loc,
					"attributes on type references are only allowed on function types 'fn(...)'",
					front.log.DiagCode.InvalidAttribute
				);
			}
		}

		let mut base: *mut front.ast.TypeRef = null;
		if self.at(front.token.TokenKind.KwFn) {
			let loc: front.log.SourceLoc = self.peek(0).loc;
			self.consume();
			self.expect(front.token.TokenKind.LParen, "'('");
			let r: *mut front.ast.TypeRef = front.ast.alloc_typeref(
				front.ast.TypeRefKind.Function,
				loc
			);
			r.fn_attrs = type_attrs;
			for !self.at(front.token.TokenKind.RParen) && !self.at(front.token.TokenKind.Eof) {
				if self.accept(front.token.TokenKind.DotDotDot) {
					r.fn_variadic = true;
					break;
				}
				let p: *mut front.ast.TypeRef = self.parse_type();
				if p != null {
					r.fn_params.push(p);
				}
				if !self.at(front.token.TokenKind.RParen) {
					self.expect(front.token.TokenKind.Comma, "comma or ')'");
				}
			}
			self.expect(front.token.TokenKind.RParen, "')'");
			self.expect(front.token.TokenKind.Arrow, "'->'");
			r.fn_ret = self.parse_type();
			r.name = "fn";
			r.single = "fn";
			base = r;
		} else if self.at(front.token.TokenKind.LBracket) {
			let lloc: front.log.SourceLoc = self.peek(0).loc;
			self.consume();
			if self.accept(front.token.TokenKind.RBracket) {
				let mut is_mut: bool = false;
				let mut is_vol: bool = false;
				for self.at(front.token.TokenKind.KwMut)
					|| self.at(front.token.TokenKind.KwVolatile) {
					if self.accept(front.token.TokenKind.KwMut) {
						is_mut = true;
					} else {
						self.consume();
						is_vol = true;
					}
				}
				let elem: *mut front.ast.TypeRef = self.parse_type();
				let r: *mut front.ast.TypeRef = front.ast.alloc_typeref(
					front.ast.TypeRefKind.Slice,
					lloc
				);
				r.is_mutable = is_mut;
				r.is_volatile = is_vol;
				r.base = elem;
				base = r;
			} else {
				let mut len_expr: *mut front.ast.Expr = null;
				let mut len: usize = 0;
				let mut inferred: bool = false;
				if self.at(front.token.TokenKind.Ident) && std.str.eq(self.peek(0).text, "_") {
					self.consume();
					inferred = true;
				} else {
					len_expr = self.parse_expr();
					if len_expr != null && len_expr.kind == front.ast.ExprKind.IntLit {
						len = len_expr.int_val cast usize;
					}
				}
				self.expect(front.token.TokenKind.RBracket, "']'");
				let elem: *mut front.ast.TypeRef = self.parse_type();
				let r: *mut front.ast.TypeRef = front.ast.alloc_typeref(
					front.ast.TypeRefKind.Array,
					lloc
				);
				r.array_len = len;
				r.array_len_expr = len_expr;
				r.array_len_inferred = inferred;
				r.base = elem;
				base = r;
			}
		} else if self.at(front.token.TokenKind.BuiltinModuleRef)
			&& std.str.eq(self.peek(0).text, "va") {
			let loc: front.log.SourceLoc = self.peek(0).loc;
			self.consume();
			self.expect(front.token.TokenKind.Dot, "'.' after '@va'");
			if !self.at(front.token.TokenKind.Ident) || !std.str.eq(self.peek(0).text, "list") {
				front.log.report(
					front.log.Level.Error,
					self.peek(0).loc,
					"expected member '@va.list' in a type reference",
					front.log.DiagCode.ParseExpectedToken
				);
				ptr_locs.free_array();
				ptr_muts.free_array();
				ptr_vols.free_array();
				return null;
			}
			self.consume();
			let r: *mut front.ast.TypeRef = front.ast.alloc_typeref(
				front.ast.TypeRefKind.Named,
				loc
			);
			r.name = "@va.list";
			r.single = "@va.list";
			r.path.push("@va.list");
			base = r;
		} else if self.at(front.token.TokenKind.BuiltinModuleRef)
			&& std.str.eq(self.peek(0).text, "of") {
			let loc: front.log.SourceLoc = self.peek(0).loc;
			self.consume();
			self.expect(front.token.TokenKind.Dot, "'.' after '@of'");
			if !self.at(front.token.TokenKind.Ident) || !std.str.eq(self.peek(0).text, "type") {
				front.log.report(
					front.log.Level.Error,
					self.peek(0).loc,
					"expected member '@of.type' in a type reference",
					front.log.DiagCode.ParseExpectedToken
				);
				ptr_locs.free_array();
				ptr_muts.free_array();
				ptr_vols.free_array();
				return null;
			}
			self.consume();
			self.expect(front.token.TokenKind.LParen, "'(' after '@of.type'");
			let r: *mut front.ast.TypeRef = front.ast.alloc_typeref(
				front.ast.TypeRefKind.TypeOf,
				loc
			);
			r.typeof_expr = self.parse_expr();
			self.expect(front.token.TokenKind.RParen, "')' after '@of.type'");
			base = r;
		} else if self.at(front.token.TokenKind.KwType) {
			let loc: front.log.SourceLoc = self.peek(0).loc;
			self.consume();
			let r: *mut front.ast.TypeRef = front.ast.alloc_typeref(
				front.ast.TypeRefKind.Named,
				loc
			);
			r.name = "type";
			r.single = "type";
			base = r;
		} else if self.at(front.token.TokenKind.KwSelf) {
			let loc: front.log.SourceLoc = self.peek(0).loc;
			self.consume();
			let r: *mut front.ast.TypeRef = front.ast.alloc_typeref(
				front.ast.TypeRefKind.SelfType,
				loc
			);
			r.name = "Self";
			r.single = "Self";
			base = r;
		} else if self.at(front.token.TokenKind.Ident) {
			let loc: front.log.SourceLoc = self.peek(0).loc;
			let r: *mut front.ast.TypeRef = front.ast.alloc_typeref(
				front.ast.TypeRefKind.Named,
				loc
			);
			let first: []u8 = self.consume().text;
			r.path.push(first);
			r.single = first;
			r.name = first;
			for self.at(front.token.TokenKind.Dot) {
				self.consume();
				if self.at(front.token.TokenKind.Ident) {
					let seg: []u8 = self.consume().text;
					r.path.push(seg);
					r.name = seg;
					r.single = "";
				} else {
					front.log.report(
						front.log.Level.Error,
						self.peek(0).loc,
						"expected identifier after '.' in type",
						front.log.DiagCode.ParseExpectedToken
					);
					break;
				}
			}
			if self.at_binop(front.token.Op.Lt) {
				self.parse_generic_args(&r.generic_args);
			}
			base = r;
		} else {
			let ut: front.token.Token = self.peek(0);
			let mut mb: [128]u8;
			let mut mp: usize = 0;
			let pfx: []u8 = "expected type, got `";
			for let mut ci: usize = 0; ci < pfx.len && mp < 120; ci += 1 {
				mb[mp] = pfx[ci];
				mp += 1;
			}
			for let mut ci: usize = 0; ci < ut.text.len && mp < 120; ci += 1 {
				mb[mp] = ut.text[ci];
				mp += 1;
			}
			mb[mp] = '`' cast u8;
			mp += 1;
			front.log.report(
				front.log.Level.Error,
				ut.loc,
				mb[0..mp],
				front.log.DiagCode.ParseExpectedToken
			);
			ptr_locs.free_array();
			ptr_muts.free_array();
			ptr_vols.free_array();
			return null;
		}

		// Wrap pointer layers from innermost to outermost
		let mut i: usize = ptr_locs.len;
		for i > 0 {
			i -= 1;
			let p: *mut front.ast.TypeRef = front.ast.alloc_typeref(
				front.ast.TypeRefKind.Pointer,
				ptr_locs.data[i]
			);
			p.is_mutable = ptr_muts.data[i];
			p.is_volatile = ptr_vols.data[i];
			p.base = base;
			base = p;
		}
		ptr_locs.free_array();
		ptr_muts.free_array();
		ptr_vols.free_array();
		return base;
	}

	/// Executes `parse_expr` (parse expr).
}
