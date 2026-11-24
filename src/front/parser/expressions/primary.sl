mod front.parser;
import "front/ast.sl";
import "front/log.sl";
import "front/token.sl";
import "std/mem.sl";
import "std/str.sl";

/// Represents the `Parser` data structure.

impl Parser {
	pub fn parse_builtin_call(
		self: *mut Parser,
		module: []u8,
		member: []u8,
		loc: front.log.SourceLoc
	) -> *mut front.ast.Expr {
		let mut kind: front.ast.ExprKind = front.ast.ExprKind.Sizeof;
		if std.str.eq(module, "@of") && std.str.eq(member, "size") {
			kind = front.ast.ExprKind.Sizeof;
		} else if std.str.eq(module, "@of") && std.str.eq(member, "align") {
			kind = front.ast.ExprKind.Alignof;
		} else if std.str.eq(module, "@of") && std.str.eq(member, "bits") {
			kind = front.ast.ExprKind.Bitsof;
		} else if std.str.eq(module, "@of") && std.str.eq(member, "offset") {
			kind = front.ast.ExprKind.Offsetof;
		} else if std.str.eq(module, "@va") && std.str.eq(member, "start") {
			kind = front.ast.ExprKind.VaStart;
		} else if std.str.eq(module, "@va") && std.str.eq(member, "copy") {
			kind = front.ast.ExprKind.VaCopy;
		} else if std.str.eq(module, "@va") && std.str.eq(member, "end") {
			kind = front.ast.ExprKind.VaEnd;
		} else if std.str.eq(module, "@va") && std.str.eq(member, "arg") {
			kind = front.ast.ExprKind.VaArg;
		} else if std.str.eq(module, "@src") && std.str.eq(member, "file") {
			kind = front.ast.ExprKind.SrcFile;
		} else if std.str.eq(module, "@src") && std.str.eq(member, "line") {
			kind = front.ast.ExprKind.SrcLine;
		} else if std.str.eq(module, "@src")
			&& (std.str.eq(member, "fn") || std.str.eq(member, "func")) {
			kind = front.ast.ExprKind.SrcFn;
		} else if std.str.eq(module, "@src") && std.str.eq(member, "column") {
			kind = front.ast.ExprKind.SrcColumn;
		} else if std.str.eq(module, "@src") && std.str.eq(member, "embed") {
			kind = front.ast.ExprKind.SrcEmbed;
		} else if std.str.eq(module, "@syn") && std.str.eq(member, "stringify") {
			kind = front.ast.ExprKind.Stringify;
		} else if std.str.eq(module, "@diag") && std.str.eq(member, "warn") {
			kind = front.ast.ExprKind.DiagWarn;
		} else if std.str.eq(module, "@diag") && std.str.eq(member, "err") {
			kind = front.ast.ExprKind.DiagErr;
		} else {
			front.log.report(
				front.log.Level.Error,
				loc,
				"unknown built-in module member",
				front.log.DiagCode.ParseExpectedToken
			);
			return front.ast.alloc_expr(front.ast.ExprKind.Sizeof, loc);
		}

		let e: *mut front.ast.Expr = front.ast.alloc_expr(kind, loc);
		self.consume();

		if kind == front.ast.ExprKind.SrcFile || kind == front.ast.ExprKind.SrcLine
			|| kind == front.ast.ExprKind.SrcFn || kind == front.ast.ExprKind.SrcColumn {
			self.expect(front.token.TokenKind.RParen, "')' after source builtin");
			return e;
		}
		if kind == front.ast.ExprKind.Stringify || kind == front.ast.ExprKind.SrcEmbed {
			if !self.at(front.token.TokenKind.RParen) {
				e.args.push(self.parse_expr());
			}
			self.expect(front.token.TokenKind.RParen, "')'");
			return e;
		}
		if kind == front.ast.ExprKind.DiagWarn || kind == front.ast.ExprKind.DiagErr {
			if !self.at(front.token.TokenKind.RParen) {
				e.args.push(self.parse_expr());
				if self.accept(front.token.TokenKind.Comma)
					&& !self.at(front.token.TokenKind.RParen) {
					e.args.push(self.parse_expr());
				}
			}
			self.expect(front.token.TokenKind.RParen, "')'");
			return e;
		}
		if kind == front.ast.ExprKind.Sizeof || kind == front.ast.ExprKind.Alignof || kind
			== front.ast.ExprKind.Bitsof {
			if self.at(front.token.TokenKind.LBracket) && self.starts_type_at(self.idx) {
				let op_expr: *mut front.ast.Expr = front.ast.alloc_expr(
					front.ast.ExprKind.TypeValue,
					self.peek(0).loc
				);
				op_expr.layout_type = self.parse_type();
				e.lhs = op_expr;
			} else {
				e.lhs = self.parse_expr();
			}
			self.expect(front.token.TokenKind.RParen, "')'");
			return e;
		}
		if kind == front.ast.ExprKind.Offsetof {
			if self.at(front.token.TokenKind.LBracket) && self.starts_type_at(self.idx) {
				let op_expr: *mut front.ast.Expr = front.ast.alloc_expr(
					front.ast.ExprKind.TypeValue,
					self.peek(0).loc
				);
				op_expr.layout_type = self.parse_type();
				e.lhs = op_expr;
			} else {
				e.lhs = self.parse_expr();
			}
			if self.accept(front.token.TokenKind.Comma) && self.accept(front.token.TokenKind.Dot)
				&& self.at(front.token.TokenKind.Ident) {
				e.offsetof_member = self.consume().text;
			}
			self.expect(front.token.TokenKind.RParen, "')'");
			return e;
		}
		if kind == front.ast.ExprKind.VaArg {
			e.args.push(self.parse_expr());
			self.expect(front.token.TokenKind.Comma, "','");
			e.va_arg_ty = self.parse_type();
			self.expect(front.token.TokenKind.RParen, "')'");
			return e;
		}
		if kind == front.ast.ExprKind.VaCopy {
			e.args.push(self.parse_expr());
			self.expect(front.token.TokenKind.Comma, "','");
			e.args.push(self.parse_expr());
			self.expect(front.token.TokenKind.RParen, "')'");
			return e;
		}
		e.args.push(self.parse_expr());
		self.expect(front.token.TokenKind.RParen, "')'");
		return e;
	}

	/// Executes `parse_postfix` (parse postfix).
	pub fn parse_postfix(self: *mut Parser) -> *mut front.ast.Expr {
		let mut base: *mut front.ast.Expr = self.parse_primary();
		for true {
			if (base.kind == front.ast.ExprKind.Ident || base.kind == front.ast.ExprKind.Member)
				&& self.generic_call_suffix() {
				self.parse_generic_args(&base.generic_args);
			} else if !self.in_match_pattern && self.at(front.token.TokenKind.LParen) {
				let mut bmod: []u8 = "";
				let mut bmem: []u8 = "";
				if is_builtin_member(base, &bmod, &bmem) {
					base = self.parse_builtin_call(bmod, bmem, base.loc);
					continue;
				}
				let e: *mut front.ast.Expr = front.ast.alloc_expr(
					front.ast.ExprKind.Call,
					self.peek(0).loc
				);
				e.lhs = base;
				if self.parsing_generic_arg {
					self.generic_arg_nesting += 1;
				}
				self.consume();
				for !self.at(front.token.TokenKind.RParen) && !self.at(front.token.TokenKind.Eof) {
					e.args.push(self.parse_expr());
					if !self.at(front.token.TokenKind.RParen) {
						self.expect(front.token.TokenKind.Comma, "comma or ')'");
					}
				}
				self.expect(front.token.TokenKind.RParen, "')'");
				if self.parsing_generic_arg && self.generic_arg_nesting > 0 {
					self.generic_arg_nesting -= 1;
				}
				base = e;
			} else if self.allow_struct_init && self.at(front.token.TokenKind.LBrace)
				&& (base.kind == front.ast.ExprKind.EnumMember || base.kind
				== front.ast.ExprKind.Member) {
				let e: *mut front.ast.Expr = front.ast.alloc_expr(
					front.ast.ExprKind.VariantInit,
					self.peek(0).loc
				);
				e.is_struct_variant = true;
				if base.kind == front.ast.ExprKind.Member {
					e.lhs = base.lhs;
					e.member = base.member;
				} else {
					e.member = base.member;
				}
				self.consume();
				for !self.at(front.token.TokenKind.RBrace) && !self.at(front.token.TokenKind.Eof) {
					if !self.at(front.token.TokenKind.Ident) {
						front.log.report(
							front.log.Level.Error,
							self.peek(0).loc,
							"expected field name",
							front.log.DiagCode.ParseExpectedToken
						);
						break;
					}
					let fname: []u8 = self.consume().text;
					self.expect(front.token.TokenKind.Colon, "':'");
					let val: *mut front.ast.Expr = self.parse_expr();
					e.field_names.push(fname);
					e.args.push(val);
					if !self.accept(front.token.TokenKind.Comma) {
						break;
					}
				}
				self.expect(front.token.TokenKind.RBrace, "'}'");
				base = e;
			} else if self.at(front.token.TokenKind.Dot) {
				self.consume();
				let src_fn_member: bool = self.at(front.token.TokenKind.KwFn) && base != null
					&& base.kind == front.ast.ExprKind.Ident && base.path.len == 1
					&& std.str.eq(base.path.data[0], "@src");
				let kw_member: bool = self.at(front.token.TokenKind.KwType)
					|| self.at(front.token.TokenKind.KwFn);
				if !self.at(front.token.TokenKind.Ident) && !kw_member {
					front.log.report(
						front.log.Level.Error,
						self.peek(0).loc,
						"expected member name after '.'",
						front.log.DiagCode.ParseExpectedToken
					);
					break;
				}
				let e: *mut front.ast.Expr = front.ast.alloc_expr(
					front.ast.ExprKind.Member,
					self.peek(0).loc
				);
				e.lhs = base;
				if src_fn_member {
					self.consume();
					e.member = "fn";
				} else {
					e.member = self.consume().text;
				}
				let mut bmod: []u8 = "";
				let mut bmem: []u8 = "";
				if is_builtin_member(e, &bmod, &bmem) && std.str.eq(bmod, "@src")
					&& self.at(front.token.TokenKind.LParen) {
					base = self.parse_builtin_call(bmod, bmem, e.loc);
				} else {
					base = e;
				}
			} else if self.at(front.token.TokenKind.LBracket) {
				let lloc: front.log.SourceLoc = self.peek(0).loc;
				self.consume();
				if self.accept(front.token.TokenKind.DotDot) {
					let mut end_e: *mut front.ast.Expr = null;
					if !self.at(front.token.TokenKind.RBracket) {
						end_e = self.parse_expr();
					}
					self.expect(front.token.TokenKind.RBracket, "']'");
					let e: *mut front.ast.Expr = front.ast.alloc_expr(
						front.ast.ExprKind.Slice,
						lloc
					);
					e.lhs = base;
					e.index_low = end_e;
					base = e;
				} else {
					let idx_e: *mut front.ast.Expr = self.parse_expr();
					if self.accept(front.token.TokenKind.DotDot) {
						let mut end_e: *mut front.ast.Expr = null;
						if !self.at(front.token.TokenKind.RBracket) {
							end_e = self.parse_expr();
						}
						self.expect(front.token.TokenKind.RBracket, "']'");
						let e: *mut front.ast.Expr = front.ast.alloc_expr(
							front.ast.ExprKind.Slice,
							idx_e != null ? idx_e.loc : lloc
						);
						e.lhs = base;
						e.rhs = idx_e;
						e.index_low = end_e;
						base = e;
					} else {
						let mut low_e: *mut front.ast.Expr = null;
						if self.accept(front.token.TokenKind.Colon) {
							low_e = self.parse_expr();
						}
						self.expect(front.token.TokenKind.RBracket, "']'");
						let e: *mut front.ast.Expr = front.ast.alloc_expr(
							front.ast.ExprKind.Index,
							idx_e != null ? idx_e.loc : lloc
						);
						e.lhs = base;
						e.rhs = idx_e;
						e.is_bit_range = low_e != null;
						e.index_low = low_e;
						base = e;
					}
				}
			} else if self.at(front.token.TokenKind.KwCast)
				|| self.at(front.token.TokenKind.KwBitcast) {
				let op_loc: front.log.SourceLoc = self.peek(0).loc;
				let is_bit: bool = self.at(front.token.TokenKind.KwBitcast);
				self.consume();
				let ty: *mut front.ast.TypeRef = self.parse_type();
				if ty == null {
					break;
				}
				let e: *mut front.ast.Expr = front.ast.alloc_expr(front.ast.ExprKind.Cast, op_loc);
				e.is_bitcast = is_bit;
				e.lhs = base;
				e.cast_type = ty;
				base = e;
			} else {
				break;
			}
		}
		return base;
	}

	/// Executes `parse_primary` (parse primary).
	pub fn parse_primary(self: *mut Parser) -> *mut front.ast.Expr {
		let t: front.token.Token = self.peek(0);
		if t.kind == front.token.TokenKind.IntLit {
			self.consume();
			let e: *mut front.ast.Expr = front.ast.alloc_expr(front.ast.ExprKind.IntLit, t.loc);
			e.int_val = t.int_val;
			e.str_val = t.text;
			return e;
		}
		if t.kind == front.token.TokenKind.FloatLit {
			self.consume();
			let e: *mut front.ast.Expr = front.ast.alloc_expr(front.ast.ExprKind.FloatLit, t.loc);
			e.flt_val = t.flt_val;
			e.str_val = t.text;
			if t.text.len > 0 && t.text[t.text.len - 1] == ('~' cast u8) {
				e.flt_lossy_ok = true;
			}
			if self.accept(front.token.TokenKind.Tilde) {
				if e.flt_lossy_ok {
					front.log.report(
						front.log.Level.Error,
						t.loc,
						"duplicate `~` suffix on floating-point literal",
						front.log.DiagCode.LexInvalidNumber
					);
				}
				e.flt_lossy_ok = true;
				if self.at(front.token.TokenKind.Tilde) {
					let t2: front.token.Token = self.consume();
					front.log.report(
						front.log.Level.Error,
						t2.loc,
						"duplicate `~` suffix on floating-point literal",
						front.log.DiagCode.LexInvalidNumber
					);
				}
			}
			return e;
		}
		if t.kind == front.token.TokenKind.StringLit {
			self.consume();
			let e: *mut front.ast.Expr = front.ast.alloc_expr(front.ast.ExprKind.StringLit, t.loc);
			e.str_val = t.text;
			e.is_cstring = t.is_cstring;
			return e;
		}
		if t.kind == front.token.TokenKind.CharLit {
			self.consume();
			let e: *mut front.ast.Expr = front.ast.alloc_expr(front.ast.ExprKind.CharLit, t.loc);
			e.char_val = t.char_val;
			return e;
		}
		if t.kind == front.token.TokenKind.KwTrue || t.kind == front.token.TokenKind.KwFalse {
			self.consume();
			let e: *mut front.ast.Expr = front.ast.alloc_expr(front.ast.ExprKind.BoolLit, t.loc);
			e.int_val = t.kind == front.token.TokenKind.KwTrue ? 1 : 0;
			return e;
		}
		if t.kind == front.token.TokenKind.KwNull {
			self.consume();
			return front.ast.alloc_expr(front.ast.ExprKind.NullLit, t.loc);
		}
		if t.kind == front.token.TokenKind.DefineRef {
			self.consume();
			let e: *mut front.ast.Expr = front.ast.alloc_expr(front.ast.ExprKind.DefineRef, t.loc);
			e.member = t.text;
			return e;
		}
		if t.kind == front.token.TokenKind.BuiltinModuleRef {
			self.consume();
			let e: *mut front.ast.Expr = front.ast.alloc_expr(front.ast.ExprKind.Ident, t.loc);
			if std.str.eq(t.text, "of") {
				e.path.push("@of");
			} else if std.str.eq(t.text, "va") {
				e.path.push("@va");
			} else if std.str.eq(t.text, "src") {
				e.path.push("@src");
			} else if std.str.eq(t.text, "syn") {
				e.path.push("@syn");
			} else if std.str.eq(t.text, "diag") {
				e.path.push("@diag");
			}
			return e;
		}
		if t.kind == front.token.TokenKind.DotDotDot {
			self.consume();
			return front.ast.alloc_expr(front.ast.ExprKind.VariadicSplice, t.loc);
		}
		if t.kind == front.token.TokenKind.Ident || t.kind == front.token.TokenKind.KwSelf {
			self.consume();
			let e: *mut front.ast.Expr = front.ast.alloc_expr(front.ast.ExprKind.Ident, t.loc);
			e.path.push(t.text);
			return e;
		}
		if t.kind == front.token.TokenKind.Dot {
			self.consume();
			if !self.at(front.token.TokenKind.Ident) {
				front.log.report(
					front.log.Level.Error,
					self.peek(0).loc,
					"expected enum member name after '.'",
					front.log.DiagCode.ParseExpectedToken
				);
				return front.ast.alloc_expr(front.ast.ExprKind.EnumMember, t.loc);
			}
			let mem_tok: front.token.Token = self.consume();
			let e: *mut front.ast.Expr = front.ast.alloc_expr(
				front.ast.ExprKind.EnumMember,
				mem_tok.loc
			);
			e.member = mem_tok.text;
			return e;
		}
		if t.kind == front.token.TokenKind.LParen {
			self.consume();
			let e: *mut front.ast.Expr = self.parse_expr();
			self.expect(front.token.TokenKind.RParen, "')'");
			if e != null {
				e.parenthesized = true;
			}
			return e;
		}
		if t.kind == front.token.TokenKind.LBracket {
			self.consume();
			let e: *mut front.ast.Expr = front.ast.alloc_expr(front.ast.ExprKind.ArrayLit, t.loc);
			for !self.at(front.token.TokenKind.RBracket) && !self.at(front.token.TokenKind.Eof) {
				e.args.push(self.parse_expr());
				if !self.at(front.token.TokenKind.RBracket) {
					self.expect(front.token.TokenKind.Comma, "',' or ']' in array literal");
				}
			}
			self.expect(front.token.TokenKind.RBracket, "']'");
			return e;
		}
		if t.kind == front.token.TokenKind.LBrace {
			// Struct literal `{ .field = val, ... }` or empty `{}` vs block expression `{ ... }`
			let next_t: front.token.Token = self.peek(1);
			if next_t.kind == front.token.TokenKind.Dot || next_t.kind
				== front.token.TokenKind.RBrace {
				self.consume();
				let e: *mut front.ast.Expr = front.ast.alloc_expr(
					front.ast.ExprKind.StructLit,
					t.loc
				);
				for !self.at(front.token.TokenKind.RBrace) && !self.at(front.token.TokenKind.Eof) {
					self.expect(
						front.token.TokenKind.Dot,
						"'.' before field name in struct literal"
					);
					if !self.at(front.token.TokenKind.Ident) {
						front.log.report(
							front.log.Level.Error,
							self.peek(0).loc,
							"expected field name",
							front.log.DiagCode.ParseExpectedToken
						);
						break;
					}
					let fname: []u8 = self.consume().text;
					self.expect(front.token.TokenKind.Assign, "'='");
					let val: *mut front.ast.Expr = self.parse_expr();
					e.field_names.push(fname);
					e.args.push(val);
					if !self.accept(front.token.TokenKind.Comma) {
						break;
					}
				}
				self.expect(front.token.TokenKind.RBrace, "'}'");
				return e;
			}
			let blk: *mut front.ast.Stmt = self.parse_block_fn(self);
			let e: *mut front.ast.Expr = front.ast.alloc_expr(front.ast.ExprKind.Block, t.loc);
			e.block = blk;
			return e;
		}

		if t.kind == front.token.TokenKind.KwIf || t.kind == front.token.TokenKind.KwFor || t.kind
			== front.token.TokenKind.KwMatch {
			let s: *mut front.ast.Stmt = self.parse_stmt_fn(self);
			let e: *mut front.ast.Expr = front.ast.alloc_expr(front.ast.ExprKind.Block, t.loc);
			e.block = s;
			return e;
		}
		front.log.report(
			front.log.Level.Error,
			t.loc,
			"expected expression",
			front.log.DiagCode.ParseExpectedToken
		);
		if t.kind != front.token.TokenKind.Eof {
			self.consume();
		}
		return front.ast.alloc_expr(front.ast.ExprKind.IntLit, t.loc);
	}
}
