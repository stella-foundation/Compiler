mod front.parser;
pub import "front/parser/expressions.sl";
pub import "front/parser/statements.sl";
import "front/ast.sl";
import "front/log.sl";
import "front/token.sl";
import "std/mem.sl";
import "std/str.sl";


/// Executes `alloc_fn_decl`.
pub fn alloc_fn_decl(loc: front.log.SourceLoc) -> *mut front.ast.FnDecl {
	let raw: *mut u8 = front.ast.arena_alloc(@of.size(front.ast.FnDecl));
	if raw == null {
		return null;
	}
	let d: *mut front.ast.FnDecl = raw cast *mut front.ast.FnDecl;
	*d = {
		.is_macro = false,
		.name = "",
		.params = { .data = null, .len = 0, .cap = 0 },
		.ret = null,
		.body = null,
		.is_pub = false,
		.is_variadic = false,
		.is_extern = false,
		.loc = loc,
		.attrs = front.ast.make_attr_list(),
		.generic_params = { .data = null, .len = 0, .cap = 0 }
	};
	return d;
}

/// Executes `alloc_global_decl`.
pub fn alloc_global_decl(loc: front.log.SourceLoc) -> *mut front.ast.GlobalDecl {
	let raw: *mut u8 = front.ast.arena_alloc(@of.size(front.ast.GlobalDecl));
	if raw == null {
		return null;
	}
	let d: *mut front.ast.GlobalDecl = raw cast *mut front.ast.GlobalDecl;
	*d = {
		.name = "",
		.ty = null,
		.init = null,
		.is_const = false,
		.is_mutable = false,
		.is_static = false,
		.is_thread_local = false,
		.is_pub = false,
		.is_extern = false,
		.loc = loc,
		.attrs = front.ast.make_attr_list()
	};
	return d;
}

/// Executes `is_top_sync_token`.
pub fn is_top_sync_token(k: front.token.TokenKind) -> bool {
	match k {
		.KwMod | .KwImport | .KwPub | .KwExtern | .KwFn | .KwMacro
		| .KwLet | .KwConst | .KwStruct | .KwUnion | .KwEnum
		| .KwTrait | .KwImpl | .RBrace | .Eof => return true,
		_ => return false
	}
}

/// Executes `starts_with_namespace_header`.
pub fn starts_with_namespace_header(p: *Parser) -> bool {
	let mut scan: usize = p.idx;
	for scan + 1 < p.toks.len
		&& p.toks.data[scan].kind == front.token.TokenKind.Hash
		&& p.toks.data[scan + 1].kind == front.token.TokenKind.LBracket {
		let mut depth: i32 = 0;
		for scan < p.toks.len {
			if p.toks.data[scan].kind == front.token.TokenKind.LBracket {
				depth += 1;
			} else if p.toks.data[scan].kind == front.token.TokenKind.RBracket {
				depth -= 1;
				if depth == 0 {
					scan += 1;
					break;
				}
			}
			scan += 1;
		}
		if depth != 0 {
			return false;
		}
	}
	if scan >= p.toks.len || p.toks.data[scan].kind != front.token.TokenKind.KwMod {
		return false;
	}
	scan += 1;
	if scan >= p.toks.len || p.toks.data[scan].kind != front.token.TokenKind.Ident {
		return false;
	}
	scan += 1;
	for scan + 1 < p.toks.len
		&& p.toks.data[scan].kind == front.token.TokenKind.Dot
		&& p.toks.data[scan + 1].kind == front.token.TokenKind.Ident {
		scan += 2;
	}
	return scan < p.toks.len && p.toks.data[scan].kind == front.token.TokenKind.Semicolon;
}

/// Executes `parse_dotted_path`.
pub fn parse_dotted_path(p: *mut Parser, out: *mut front.ast.ValList<[]u8>) -> bool {
	if !p.at(front.token.TokenKind.Ident) {
		front.log.report(
			front.log.Level.Error,
			p.peek(0).loc,
			"expected identifier",
			front.log.DiagCode.ParseExpectedToken
		);
		return false;
	}
	out.push(p.consume().text);
	for p.accept(front.token.TokenKind.Dot) {
		if !p.at(front.token.TokenKind.Ident) {
			front.log.report(
				front.log.Level.Error,
				p.peek(0).loc,
				"expected identifier after '.'",
				front.log.DiagCode.ParseExpectedToken
			);
			return false;
		}
		out.push(p.consume().text);
	}
	return true;
}

/// Executes `parse_generic_params`.
pub fn parse_generic_params(
	p: *mut Parser,
	out: *mut front.ast.ValList<front.ast.GenericParam>
) -> void {
	if !p.at_binop(front.token.Op.Lt) {
		return;
	}
	p.consume();
	for !p.at_binop(front.token.Op.Gt) && !p.at(front.token.TokenKind.Eof) {
		let loc: front.log.SourceLoc = p.peek(0).loc;
		let mut gp: front.ast.GenericParam = {
			.kind = front.ast.GenericParamKind.Type,
			.name = "",
			.const_type = null,
			.type_set = { .data = null, .len = 0, .cap = 0 },
			.trait_bounds = { .data = null, .len = 0, .cap = 0 },
			.loc = loc
		};
		if p.accept(front.token.TokenKind.KwConst) {
			gp.kind = front.ast.GenericParamKind.Const;
			if p.at(front.token.TokenKind.Ident) {
				gp.name = p.consume().text;
			} else {
				front.log.report(
					front.log.Level.Error,
					p.peek(0).loc,
					"expected const generic parameter name",
					front.log.DiagCode.ParseExpectedToken
				);
			}
			p.expect(front.token.TokenKind.Colon, "':' after const generic parameter");
			gp.const_type = p.parse_type();
		} else {
			if p.at(front.token.TokenKind.Ident) {
				gp.name = p.consume().text;
			} else {
				front.log.report(
					front.log.Level.Error,
					p.peek(0).loc,
					"expected generic parameter name",
					front.log.DiagCode.ParseExpectedToken
				);
				break;
			}
			if p.accept(front.token.TokenKind.Colon) {
				for true {
					let mloc: front.log.SourceLoc = p.peek(0).loc;
					if p.at(front.token.TokenKind.Ident) && std.str.eq(p.peek(0).text, "i") {
						p.consume();
						let m: front.ast.TypeSetMember = {
							.kind = front.ast.TypeSetMemberKind.Sint,
							.name = "i",
							.loc = mloc
						};
						gp.type_set.push(m);
					} else if p.at(front.token.TokenKind.Ident) && std.str.eq(p.peek(0).text, "u") {
						p.consume();
						let m: front.ast.TypeSetMember = {
							.kind = front.ast.TypeSetMemberKind.Uint,
							.name = "u",
							.loc = mloc
						};
						gp.type_set.push(m);
					} else if p.at(front.token.TokenKind.Ident) && std.str.eq(p.peek(0).text, "f") {
						p.consume();
						let m: front.ast.TypeSetMember = {
							.kind = front.ast.TypeSetMemberKind.Float,
							.name = "f",
							.loc = mloc
						};
						gp.type_set.push(m);
					} else {
						let bound: *mut front.ast.TypeRef = p.parse_type();
						if bound != null {
							let bname: []u8 = bound.path.len == 1 ? bound.path.data[0] : bound.name;
							let is_int_prim: bool = std.str.eq(bname, "usize")
								|| std.str.eq(bname, "isize")
								|| std.str.eq(bname, "u8") || std.str.eq(bname, "u16")
								|| std.str.eq(bname, "u32") || std.str.eq(bname, "u64")
								|| std.str.eq(bname, "i8") || std.str.eq(bname, "i16")
								|| std.str.eq(bname, "i32") || std.str.eq(bname, "i64")
								|| std.str.eq(bname, "bool");
							if is_int_prim && gp.type_set.len == 0 && gp.trait_bounds.len == 0 {
								gp.kind = front.ast.GenericParamKind.Const;
								gp.const_type = bound;
							} else {
								gp.trait_bounds.push(bound);
							}
						}
					}
					if !p.at_binop(front.token.Op.BitOr) && !p.at_binop(front.token.Op.Add) {
						break;
					}
					p.consume();
				}
			} else if !p.at(front.token.TokenKind.Comma) && !p.at_binop(front.token.Op.Gt) {
				p.expect(front.token.TokenKind.Colon, "':'");
			}
		}
		out.push(gp);
		if !p.at_binop(front.token.Op.Gt) {
			p.expect(front.token.TokenKind.Comma, "',' or '>' in generic parameters");
		}
	}
	if p.at_binop(front.token.Op.Gt) {
		p.consume();
	} else {
		front.log.report(
			front.log.Level.Error,
			p.peek(0).loc,
			"expected '>' closing generic parameters",
			front.log.DiagCode.ParseExpectedToken
		);
	}
}
