mod front.parser;
import "./expressions.sl";
import "front/ast.sl";
import "front/log.sl";
import "front/token.sl";
import "std/str.sl";

/// Executes `parse_block_cb` (parse block cb).
pub fn parse_block_cb(p: *mut Parser) -> *mut front.ast.Stmt {
	return parse_block(p);
}

/// Executes `parse_block` (parse block).
pub fn parse_block(p: *mut Parser) -> *mut front.ast.Stmt {
	let loc: front.log.SourceLoc = p.peek(0).loc;
	let s: *mut front.ast.Stmt = front.ast.alloc_stmt(front.ast.StmtKind.Block, loc);
	p.expect(front.token.TokenKind.LBrace, "'{'");
	let prev_struct_init: bool = p.allow_struct_init;
	p.allow_struct_init = true;
	for !p.at(front.token.TokenKind.RBrace) && !p.at(front.token.TokenKind.Eof) {
		let st: *mut front.ast.Stmt = parse_stmt(p, true);
		if st != null {
			s.body.push(st);
		} else if !p.at(front.token.TokenKind.RBrace) && !p.at(front.token.TokenKind.Eof) {
			p.consume();
		}
	}
	p.allow_struct_init = prev_struct_init;
	p.expect(front.token.TokenKind.RBrace, "'}'");
	return s;
}

/// Executes `parse_stmt` (parse stmt).
pub fn parse_stmt(p: *mut Parser, expect_semicolon: bool) -> *mut front.ast.Stmt {
	let mut attrs: front.ast.AttributeList = front.ast.make_attr_list();
	p.parse_attributes(&attrs);
	if attrs.attrs.len > 0 && !p.at(front.token.TokenKind.KwConst)
		&& !p.at(front.token.TokenKind.KwLet) {
		front.log.report(
			front.log.Level.Error,
			attrs.attrs.data[0].loc,
			"attribute is not valid on this statement",
			front.log.DiagCode.InvalidAttribute
		);
	}
	let k: front.token.TokenKind = p.peek(0).kind;
	if k == front.token.TokenKind.LBrace {
		return parse_block(p);
	}
	if k == front.token.TokenKind.KwIf {
		return parse_if(p);
	}
	if k == front.token.TokenKind.KwFor {
		return parse_for(p);
	}
	if k == front.token.TokenKind.KwMatch {
		return parse_match(p);
	}
	if k == front.token.TokenKind.KwLet {
		return parse_var_or_const(p, false, attrs, expect_semicolon);
	}
	if k == front.token.TokenKind.KwConst {
		return parse_var_or_const(p, true, attrs, expect_semicolon);
	}
	if k == front.token.TokenKind.KwReturn {
		return parse_return(p, expect_semicolon);
	}
	if k == front.token.TokenKind.KwDefer {
		return parse_defer(p, expect_semicolon);
	}
	if k == front.token.TokenKind.KwYield {
		return parse_yield(p, expect_semicolon);
	}
	if k == front.token.TokenKind.KwAsm {
		return parse_asm(p, expect_semicolon);
	}
	if k == front.token.TokenKind.KwUnreachable {
		let loc: front.log.SourceLoc = p.peek(0).loc;
		p.consume();
		if expect_semicolon {
			p.expect(front.token.TokenKind.Semicolon, "';'");
		}
		return front.ast.alloc_stmt(front.ast.StmtKind.Unreachable, loc);
	}
	if k == front.token.TokenKind.KwBreak {
		let loc: front.log.SourceLoc = p.peek(0).loc;
		p.consume();
		if expect_semicolon {
			p.expect(front.token.TokenKind.Semicolon, "';'");
		}
		return front.ast.alloc_stmt(front.ast.StmtKind.Break, loc);
	}
	if k == front.token.TokenKind.KwContinue {
		let loc: front.log.SourceLoc = p.peek(0).loc;
		p.consume();
		if expect_semicolon {
			p.expect(front.token.TokenKind.Semicolon, "';'");
		}
		return front.ast.alloc_stmt(front.ast.StmtKind.Continue, loc);
	}
	if k == front.token.TokenKind.Ident {
		let t0: front.token.Token = p.peek(0);
		let k1: front.token.TokenKind = p.peek(1).kind;
		let is_decl_like: bool = k1 == front.token.TokenKind.Ident || k1
			== front.token.TokenKind.KwMut;
		let is_ret_like: bool = k1 == front.token.TokenKind.IntLit || k1
			== front.token.TokenKind.FloatLit
			|| k1 == front.token.TokenKind.StringLit || k1 == front.token.TokenKind.KwTrue || k1
			== front.token.TokenKind.KwFalse
			|| k1 == front.token.TokenKind.LParen || k1 == front.token.TokenKind.Semicolon;
		if is_decl_like && front.log.levenshtein(t0.text, "let") <= 2 {
			let mut mb: [128]u8;
			let mut mp: usize = 0;
			let pfx: []u8 = "unknown keyword `";
			for let mut i: usize = 0; i < pfx.len && mp < 120; i += 1 {
				mb[mp] = pfx[i];
				mp += 1;
			}
			for let mut i: usize = 0; i < t0.text.len && mp < 120; i += 1 {
				mb[mp] = t0.text[i];
				mp += 1;
			}
			mb[mp] = '`' cast u8;
			mp += 1;
			front.log.report_with_help(
				front.log.Level.Error,
				t0.loc,
				mb[0..mp],
				front.log.DiagCode.ParseExpectedToken,
				"did you mean `let`?",
				"replace with `let`",
				"let"
			);
			return parse_var_or_const(p, false, attrs, expect_semicolon);
		}
		if (is_ret_like || is_decl_like) && front.log.levenshtein(t0.text, "return") <= 2 {
			let mut mb: [128]u8;
			let mut mp: usize = 0;
			let pfx: []u8 = "unknown keyword `";
			for let mut i: usize = 0; i < pfx.len && mp < 120; i += 1 {
				mb[mp] = pfx[i];
				mp += 1;
			}
			for let mut i: usize = 0; i < t0.text.len && mp < 120; i += 1 {
				mb[mp] = t0.text[i];
				mp += 1;
			}
			mb[mp] = '`' cast u8;
			mp += 1;
			front.log.report_with_help(
				front.log.Level.Error,
				t0.loc,
				mb[0..mp],
				front.log.DiagCode.ParseExpectedToken,
				"did you mean `return`?",
				"replace with `return`",
				"return"
			);
			return parse_return(p, expect_semicolon);
		}
	}
	return parse_expr_stmt_or_decl(p, expect_semicolon);
}

fn parse_if(p: *mut Parser) -> *mut front.ast.Stmt {
	let loc: front.log.SourceLoc = p.peek(0).loc;
	p.consume();
	let prev_struct_init: bool = p.allow_struct_init;
	p.allow_struct_init = false;
	let cond: *mut front.ast.Expr = p.parse_expr();
	p.allow_struct_init = prev_struct_init;

	let s: *mut front.ast.Stmt = front.ast.alloc_stmt(front.ast.StmtKind.If, loc);
	s.cond = cond;
	s.then_block = parse_block(p);
	if p.accept(front.token.TokenKind.KwElse) {
		if p.at(front.token.TokenKind.KwIf) {
			s.else_block = parse_if(p);
		} else {
			s.else_block = parse_block(p);
		}
	}
	return s;
}

fn parse_for(p: *mut Parser) -> *mut front.ast.Stmt {
	let loc: front.log.SourceLoc = p.peek(0).loc;
	p.consume();
	let s: *mut front.ast.Stmt = front.ast.alloc_stmt(front.ast.StmtKind.For, loc);
	if p.at(front.token.TokenKind.LBrace) {
		s.loop_body = parse_block(p);
		return s;
	}
	let prev_struct_init: bool = p.allow_struct_init;
	p.allow_struct_init = false;

	if p.at(front.token.TokenKind.KwLet) || p.at(front.token.TokenKind.KwConst) {
		s.for_init = parse_var_or_const(
			p,
			p.at(front.token.TokenKind.KwConst),
			front.ast.make_attr_list(),
			false
		);
		p.expect(front.token.TokenKind.Semicolon, "';' after for-init");
		if !p.at(front.token.TokenKind.Semicolon) {
			s.for_cond = p.parse_expr();
		}
		p.expect(front.token.TokenKind.Semicolon, "';' after for-condition");
		if !p.at(front.token.TokenKind.LBrace) {
			s.for_step = p.parse_expr();
		}
		p.allow_struct_init = prev_struct_init;
		s.loop_body = parse_block(p);
		return s;
	}

	if p.accept(front.token.TokenKind.Semicolon) {
		if !p.at(front.token.TokenKind.Semicolon) {
			s.for_cond = p.parse_expr();
		}
		p.expect(front.token.TokenKind.Semicolon, "';' after for-condition");
		if !p.at(front.token.TokenKind.LBrace) {
			s.for_step = p.parse_expr();
		}
		p.allow_struct_init = prev_struct_init;
		s.loop_body = parse_block(p);
		return s;
	}

	let first: *mut front.ast.Expr = p.parse_expr();
	if p.accept(front.token.TokenKind.Semicolon) {
		if p.at(front.token.TokenKind.LBrace) {
			s.for_cond = first;
		} else {
			let second: *mut front.ast.Expr = !p.at(front.token.TokenKind.Semicolon)
				? p.parse_expr() : null;
			if p.accept(front.token.TokenKind.Semicolon) {
				let init_s: *mut front.ast.Stmt = front.ast.alloc_stmt(
					front.ast.StmtKind.ExprStmt,
					first != null ? first.loc : loc
				);
				init_s.expr = first;
				s.for_init = init_s;
				s.for_cond = second;
				if !p.at(front.token.TokenKind.LBrace) {
					s.for_step = p.parse_expr();
				}
			} else {
				// 2-clause for: `for cond; step { ... }`
				s.for_cond = first;
				s.for_step = second;
			}
		}
	} else {
		s.for_cond = first;
	}
	p.allow_struct_init = prev_struct_init;
	s.loop_body = parse_block(p);
	return s;
}

fn parse_match_pattern(p: *mut Parser) -> front.ast.MatchPattern {
	let loc: front.log.SourceLoc = p.peek(0).loc;
	let mut pat: front.ast.MatchPattern = {
		.kind = front.ast.MatchPatternKind.Value,
		.expr = null,
		.bindings = { .data = null, .len = 0, .cap = 0 },
		.is_struct_pattern = false,
		.loc = loc
	};
	if p.at(front.token.TokenKind.Ident) && std.str.eq(p.peek(0).text, "_") {
		p.consume();
		pat.kind = front.ast.MatchPatternKind.Wildcard;
		return pat;
	}
	let prev_struct_init: bool = p.allow_struct_init;
	let prev_match_pat: bool = p.in_match_pattern;
	p.allow_struct_init = false;
	p.in_match_pattern = true;
	let e: *mut front.ast.Expr = p.parse_unary();
	p.in_match_pattern = prev_match_pat;
	p.allow_struct_init = prev_struct_init;

	if e != null
		&& (e.kind == front.ast.ExprKind.EnumMember || e.kind == front.ast.ExprKind.Member) {
		if p.accept(front.token.TokenKind.LParen) {
			pat.kind = front.ast.MatchPatternKind.Variant;
			pat.expr = e;
			for !p.at(front.token.TokenKind.RParen) && !p.at(front.token.TokenKind.Eof) {
				let bloc: front.log.SourceLoc = p.peek(0).loc;
				let is_mut: bool = p.accept(front.token.TokenKind.KwMut);
				let mut bname: []u8 = "_";
				if p.at(front.token.TokenKind.Ident) {
					bname = p.consume().text;
				} else {
					front.log.report(
						front.log.Level.Error,
						p.peek(0).loc,
						"expected binding name in variant pattern",
						front.log.DiagCode.ParseExpectedToken
					);
				}
				let b: front.ast.MatchBinding = {
					.name = bname,
					.field_name = "",
					.is_mut = is_mut,
					.loc = bloc
				};
				pat.bindings.push(b);
				if !p.accept(front.token.TokenKind.Comma) {
					break;
				}
			}
			p.expect(front.token.TokenKind.RParen, "')'");
			return pat;
		}
		if p.at(front.token.TokenKind.LBrace) {
			p.consume();
			pat.kind = front.ast.MatchPatternKind.Variant;
			pat.is_struct_pattern = true;
			pat.expr = e;
			for !p.at(front.token.TokenKind.RBrace) && !p.at(front.token.TokenKind.Eof) {
				let bloc: front.log.SourceLoc = p.peek(0).loc;
				if !p.at(front.token.TokenKind.Ident) {
					front.log.report(
						front.log.Level.Error,
						p.peek(0).loc,
						"expected field name in struct variant pattern",
						front.log.DiagCode.ParseExpectedToken
					);
					break;
				}
				let fname: []u8 = p.consume().text;
				let mut bname: []u8 = fname;
				let mut is_mut: bool = false;
				if p.accept(front.token.TokenKind.Colon) {
					is_mut = p.accept(front.token.TokenKind.KwMut);
					if p.at(front.token.TokenKind.Ident) {
						bname = p.consume().text;
					} else {
						front.log.report(
							front.log.Level.Error,
							p.peek(0).loc,
							"expected binding name after ':'",
							front.log.DiagCode.ParseExpectedToken
						);
					}
				}
				let b: front.ast.MatchBinding = {
					.name = bname,
					.field_name = fname,
					.is_mut = is_mut,
					.loc = bloc
				};
				pat.bindings.push(b);
				if !p.accept(front.token.TokenKind.Comma) {
					break;
				}
			}
			p.expect(front.token.TokenKind.RBrace, "'}'");
			return pat;
		}
	}
	pat.kind = front.ast.MatchPatternKind.Value;
	pat.expr = e;
	return pat;
}

fn parse_match(p: *mut Parser) -> *mut front.ast.Stmt {
	let loc: front.log.SourceLoc = p.peek(0).loc;
	p.consume();
	let prev_struct_init: bool = p.allow_struct_init;
	p.allow_struct_init = false;
	let scrutinee: *mut front.ast.Expr = p.parse_expr();
	p.allow_struct_init = prev_struct_init;

	let s: *mut front.ast.Stmt = front.ast.alloc_stmt(front.ast.StmtKind.Match, loc);
	s.scrutinee = scrutinee;
	p.expect(front.token.TokenKind.LBrace, "'{' after match expression");
	for !p.at(front.token.TokenKind.RBrace) && !p.at(front.token.TokenKind.Eof) {
		let arm_loc: front.log.SourceLoc = p.peek(0).loc;
		let mut arm: front.ast.MatchArm = {
			.patterns = { .data = null, .len = 0, .cap = 0 },
			.body = null,
			.loc = arm_loc
		};
		arm.patterns.push(parse_match_pattern(p));
		for p.at_binop(front.token.Op.BitOr) {
			p.consume();
			arm.patterns.push(parse_match_pattern(p));
		}
		p.expect(front.token.TokenKind.FatArrow, "'=>' after match pattern");
		if p.at(front.token.TokenKind.LBrace) {
			arm.body = parse_block(p);
		} else {
			let st_loc: front.log.SourceLoc = p.peek(0).loc;
			let inner: *mut front.ast.Stmt = parse_stmt(p, false);
			let blk: *mut front.ast.Stmt = front.ast.alloc_stmt(front.ast.StmtKind.Block, st_loc);
			if inner != null {
				blk.body.push(inner);
			}
			arm.body = blk;
			if !p.at(front.token.TokenKind.RBrace) {
				p.expect(front.token.TokenKind.Comma, "','");
			}
		}
		s.arms.push(arm);
	}
	p.expect(front.token.TokenKind.RBrace, "'}'");
	return s;
}

fn parse_var_or_const(
	p: *mut Parser,
	is_const: bool,
	attrs: front.ast.AttributeList,
	expect_semicolon: bool
) -> *mut front.ast.Stmt {
	let loc: front.log.SourceLoc = p.peek(0).loc;
	p.consume();
	let s: *mut front.ast.Stmt = front.ast.alloc_stmt(
		is_const ? front.ast.StmtKind.ConstDecl : front.ast.StmtKind.VarDecl,
		loc
	);

	let mut is_static: bool = false;
	let mut is_thread_local: bool = false;
	let mut lead_mut: bool = false;
	if !is_const {
		for p.at(front.token.TokenKind.KwStatic) || p.at(front.token.TokenKind.KwThreadLocal)
			|| p.at(front.token.TokenKind.KwMut) {
			if p.accept(front.token.TokenKind.KwStatic) {
				is_static = true;
			} else if p.accept(front.token.TokenKind.KwMut) {
				lead_mut = true;
			} else {
				p.consume();
				is_thread_local = true;
			}
		}
	}

	for true {
		let vloc: front.log.SourceLoc = p.peek(0).loc;
		let mut is_mut: bool = lead_mut;
		if !is_const && p.accept(front.token.TokenKind.KwMut) {
			is_mut = true;
		}
		let mut vname: []u8 = "";
		if p.at(front.token.TokenKind.Ident) {
			vname = p.consume().text;
		} else {
			front.log.report(
				front.log.Level.Error,
				p.peek(0).loc,
				"expected variable name",
				front.log.DiagCode.ParseExpectedToken
			);
			break;
		}
		let mut ty: *mut front.ast.TypeRef = null;
		if p.expect(front.token.TokenKind.Colon, "':'") {
			ty = p.parse_type();
		} else {
			ty = p.parse_type();
		}
		let mut init: *mut front.ast.Expr = null;
		if p.accept(front.token.TokenKind.Assign) {
			init = p.parse_expr();
		}
		let v: front.ast.VarDeclInfo = {
			.name = vname,
			.ty = ty,
			.init = init,
			.loc = vloc,
			.is_const = is_const,
			.is_mutable = is_mut,
			.is_static = is_static,
			.is_thread_local = is_thread_local,
			.attrs = attrs
		};
		s.vars.push(v);
		if !p.accept(front.token.TokenKind.Comma) {
			break;
		}
	}
	if expect_semicolon {
		p.expect(front.token.TokenKind.Semicolon, "';'");
	}
	return s;
}

fn parse_return(p: *mut Parser, expect_semicolon: bool) -> *mut front.ast.Stmt {
	let loc: front.log.SourceLoc = p.peek(0).loc;
	p.consume();
	let s: *mut front.ast.Stmt = front.ast.alloc_stmt(front.ast.StmtKind.Return, loc);
	if !p.at(front.token.TokenKind.Semicolon) && !p.at(front.token.TokenKind.RBrace)
		&& !p.at(front.token.TokenKind.Comma) {
		s.ret_val = p.parse_expr();
	}
	if expect_semicolon {
		p.expect(front.token.TokenKind.Semicolon, "';'");
	}
	return s;
}

fn parse_defer(p: *mut Parser, expect_semicolon: bool) -> *mut front.ast.Stmt {
	let loc: front.log.SourceLoc = p.peek(0).loc;
	p.consume();
	let s: *mut front.ast.Stmt = front.ast.alloc_stmt(front.ast.StmtKind.Defer, loc);
	if p.at(front.token.TokenKind.Semicolon) {
		front.log.report(
			front.log.Level.Error,
			p.peek(0).loc,
			"defer requires a statement",
			front.log.DiagCode.ParseExpectedToken
		);
		p.consume();
		return s;
	}
	if p.at(front.token.TokenKind.KwDefer) {
		front.log.report(
			front.log.Level.Error,
			p.peek(0).loc,
			"nested defer is not allowed",
			front.log.DiagCode.ParseExpectedToken
		);
	}
	if p.at(front.token.TokenKind.LBrace) {
		s.defer_body = parse_block(p);
	} else {
		s.defer_body = parse_stmt(p, expect_semicolon);
	}
	return s;
}

fn parse_yield(p: *mut Parser, expect_semicolon: bool) -> *mut front.ast.Stmt {
	let loc: front.log.SourceLoc = p.peek(0).loc;
	p.consume();
	let s: *mut front.ast.Stmt = front.ast.alloc_stmt(front.ast.StmtKind.Yield, loc);
	if !p.at(front.token.TokenKind.Semicolon) && !p.at(front.token.TokenKind.RBrace)
		&& !p.at(front.token.TokenKind.Comma) {
		s.ret_val = p.parse_expr();
	}
	if expect_semicolon {
		p.expect(front.token.TokenKind.Semicolon, "';'");
	}
	return s;
}

fn parse_asm(p: *mut Parser, expect_semicolon: bool) -> *mut front.ast.Stmt {
	let loc: front.log.SourceLoc = p.peek(0).loc;
	p.consume();
	let s: *mut front.ast.Stmt = front.ast.alloc_stmt(front.ast.StmtKind.Asm, loc);
	if p.accept(front.token.TokenKind.KwVolatile) {
		s.asm_volatile = true;
	}
	if p.accept(front.token.TokenKind.LBrace) {
		if p.at(front.token.TokenKind.StringLit) {
			s.asm_code = p.consume().text;
		}
		if p.accept(front.token.TokenKind.Colon) {
			for !p.at(front.token.TokenKind.Colon) && !p.at(front.token.TokenKind.RBrace)
				&& !p.at(front.token.TokenKind.Eof) {
				let c: []u8 = p.at(front.token.TokenKind.StringLit) ? p.consume().text : "";
				p.expect(front.token.TokenKind.LParen, "'(' for asm output operand");
				let op_expr: *mut front.ast.Expr = p.parse_expr();
				p.expect(front.token.TokenKind.RParen, "')' after asm output operand");
				let ao: front.ast.AsmOperand = {
					.constraint = c,
					.operand = op_expr,
					.is_clobber = false
				};
				s.asm_outputs.push(ao);
				if !p.accept(front.token.TokenKind.Comma) {
					break;
				}
			}
		}
		if p.accept(front.token.TokenKind.Colon) {
			for !p.at(front.token.TokenKind.Colon) && !p.at(front.token.TokenKind.RBrace)
				&& !p.at(front.token.TokenKind.Eof) {
				let c: []u8 = p.at(front.token.TokenKind.StringLit) ? p.consume().text : "";
				p.expect(front.token.TokenKind.LParen, "'(' for asm input operand");
				let op_expr: *mut front.ast.Expr = p.parse_expr();
				p.expect(front.token.TokenKind.RParen, "')' after asm input operand");
				let ai: front.ast.AsmOperand = {
					.constraint = c,
					.operand = op_expr,
					.is_clobber = false
				};
				s.asm_inputs.push(ai);
				if !p.accept(front.token.TokenKind.Comma) {
					break;
				}
			}
		}
		if p.accept(front.token.TokenKind.Colon) {
			for !p.at(front.token.TokenKind.RBrace) && !p.at(front.token.TokenKind.Eof) {
				if p.at(front.token.TokenKind.StringLit) {
					s.asm_clobbers.push(p.consume().text);
				} else {
					p.consume();
				}
				if !p.accept(front.token.TokenKind.Comma) {
					break;
				}
			}
		}
		p.expect(front.token.TokenKind.RBrace, "'}' after asm");
		if expect_semicolon {
			p.expect(front.token.TokenKind.Semicolon, "';'");
		}
		return s;
	}
	p.expect(front.token.TokenKind.LParen, "'(' or '{' after asm");
	if p.at(front.token.TokenKind.StringLit) {
		s.asm_code = p.consume().text;
	} else {
		front.log.report(
			front.log.Level.Error,
			p.peek(0).loc,
			"expected assembly template string",
			front.log.DiagCode.ParseExpectedToken
		);
	}
	let mut depth: i32 = 1;
	for depth > 0 && !p.at(front.token.TokenKind.Eof) {
		if p.at(front.token.TokenKind.LParen) {
			depth += 1;
		} else if p.at(front.token.TokenKind.RParen) {
			depth -= 1;
			if depth == 0 {
				break;
			}
		}
		p.consume();
	}
	p.expect(front.token.TokenKind.RParen, "')' after asm");
	if expect_semicolon {
		p.expect(front.token.TokenKind.Semicolon, "';'");
	}
	return s;
}

fn parse_expr_stmt_or_decl(p: *mut Parser, expect_semicolon: bool) -> *mut front.ast.Stmt {
	let loc: front.log.SourceLoc = p.peek(0).loc;
	let e: *mut front.ast.Expr = p.parse_expr();
	if expect_semicolon {
		p.expect(front.token.TokenKind.Semicolon, "';'");
	}
	let s: *mut front.ast.Stmt = front.ast.alloc_stmt(front.ast.StmtKind.ExprStmt, loc);
	s.expr = e;
	return s;
}
