mod front.parser;
pub import "front/parser/expressions.sl";
pub import "front/parser/statements.sl";
import "front/ast.sl";
import "front/log.sl";
import "front/token.sl";
import "std/mem.sl";
import "std/str.sl";


/// Executes `parse_fn_signature`.
pub fn parse_fn_signature(p: *mut Parser, fn_decl: *mut front.ast.FnDecl) -> void {
	parse_generic_params(p, &fn_decl.generic_params);
	p.expect(front.token.TokenKind.LParen, "'('");
	for !p.at(front.token.TokenKind.RParen) && !p.at(front.token.TokenKind.Eof) {
		if p.accept(front.token.TokenKind.DotDotDot) {
			fn_decl.is_variadic = true;
			break;
		}
		let mut pattrs: front.ast.AttributeList = front.ast.make_attr_list();
		p.parse_attributes(&pattrs);
		let ploc: front.log.SourceLoc = p.peek(0).loc;
		let is_mut: bool = p.accept(front.token.TokenKind.KwMut);
		let mut pname: []u8 = "";
		if p.at(front.token.TokenKind.Ident) || p.at(front.token.TokenKind.KwSelf) {
			pname = p.consume().text;
		} else {
			front.log.report(
				front.log.Level.Error,
				p.peek(0).loc,
				"expected parameter name",
				front.log.DiagCode.ParseExpectedToken
			);
			break;
		}
		p.expect(front.token.TokenKind.Colon, "':' after parameter name");
		let pty: *mut front.ast.TypeRef = p.parse_type();
		if is_mut {
			if fn_decl.is_macro {
				front.log.report(
					front.log.Level.Error,
					ploc,
					"`mut` is not allowed on macro parameters",
					front.log.DiagCode.ParseExpectedToken
				);
			} else if fn_decl.is_extern {
				front.log.report(
					front.log.Level.Error,
					ploc,
					"`mut` is not allowed on `extern fn` parameters",
					front.log.DiagCode.ParseExpectedToken
				);
			} else if pty != null && std.str.eq(pty.name, "type") {
				front.log.report(
					front.log.Level.Error,
					ploc,
					"`mut` is not allowed on comptime `type` parameters",
					front.log.DiagCode.ParseExpectedToken
				);
			}
		}
		let prm: front.ast.Param = {
			.name = pname,
			.ty = pty,
			.loc = ploc,
			.attrs = pattrs,
			.is_comptime = false,
			.is_mutable = is_mut
		};
		fn_decl.params.push(prm);
		if !p.at(front.token.TokenKind.RParen) {
			p.expect(front.token.TokenKind.Comma, "',' or ')'");
		}
	}
	p.expect(front.token.TokenKind.RParen, "')'");
	if p.accept(front.token.TokenKind.Arrow) {
		fn_decl.ret = p.parse_type();
	} else if !fn_decl.is_macro {
		front.log.report(
			front.log.Level.Error,
			p.peek(0).loc,
			"expected `->` and return type",
			front.log.DiagCode.ParseExpectedToken
		);
	}
}

/// Executes `parse_fn_into`.
pub fn parse_fn_into(
	p: *mut Parser,
	body: *mut front.ast.PtrList<front.ast.TopDecl>,
	is_pub: bool,
	attrs: front.ast.AttributeList,
	is_extern: bool
) -> bool {
	let loc: front.log.SourceLoc = p.peek(0).loc;
	p.consume();
	if !p.at(front.token.TokenKind.Ident) {
		front.log.report(
			front.log.Level.Error,
			p.peek(0).loc,
			"expected function name",
			front.log.DiagCode.ParseExpectedToken
		);
		return false;
	}
	let name: []u8 = p.consume().text;
	let fn_d: *mut front.ast.FnDecl = alloc_fn_decl(loc);
	fn_d.name = name;
	fn_d.is_pub = is_pub;
	fn_d.is_extern = is_extern;
	fn_d.attrs = attrs;
	parse_fn_signature(p, fn_d);
	if is_extern {
		p.expect(front.token.TokenKind.Semicolon, "';' after extern fn");
	} else {
		fn_d.body = parse_block(p);
	}
	let td: *mut front.ast.TopDecl = front.ast.alloc_top_decl(front.ast.TopKind.Fn);
	td.fn_decl = fn_d;
	body.push(td);
	return true;
}

/// Executes `parse_macro_into`.
pub fn parse_macro_into(
	p: *mut Parser,
	body: *mut front.ast.PtrList<front.ast.TopDecl>,
	is_pub: bool,
	attrs: front.ast.AttributeList
) -> bool {
	let loc: front.log.SourceLoc = p.peek(0).loc;
	p.consume();
	if !p.at(front.token.TokenKind.Ident) {
		front.log.report(
			front.log.Level.Error,
			p.peek(0).loc,
			"expected macro name",
			front.log.DiagCode.ParseExpectedToken
		);
		return false;
	}
	let name: []u8 = p.consume().text;
	let fn_d: *mut front.ast.FnDecl = alloc_fn_decl(loc);
	fn_d.is_macro = true;
	fn_d.name = name;
	fn_d.is_pub = is_pub;
	fn_d.attrs = attrs;
	parse_fn_signature(p, fn_d);
	fn_d.body = parse_block(p);
	let td: *mut front.ast.TopDecl = front.ast.alloc_top_decl(front.ast.TopKind.Fn);
	td.fn_decl = fn_d;
	body.push(td);
	return true;
}

/// Executes `parse_struct_into`.
pub fn parse_struct_into(
	p: *mut Parser,
	body: *mut front.ast.PtrList<front.ast.TopDecl>,
	is_pub: bool,
	attrs: front.ast.AttributeList
) -> bool {
	let loc: front.log.SourceLoc = p.peek(0).loc;
	p.consume();
	if !p.at(front.token.TokenKind.Ident) {
		front.log.report(
			front.log.Level.Error,
			p.peek(0).loc,
			"expected struct name",
			front.log.DiagCode.ParseExpectedToken
		);
		return false;
	}
	let name: []u8 = p.consume().text;
	let mut st: *mut front.ast.StructDecl = null;
	let raw: *mut u8 = front.ast.arena_alloc(@of.size(front.ast.StructDecl));
	if raw == null {
		return false;
	}
	st = raw cast *mut front.ast.StructDecl;
	*st = {
		.name = name,
		.field_names = { .data = null, .len = 0, .cap = 0 },
		.field_types = { .data = null, .len = 0, .cap = 0 },
		.field_is_pub = { .data = null, .len = 0, .cap = 0 },
		.is_pub = is_pub,
		.is_opaque = false,
		.loc = loc,
		.attrs = attrs,
		.generic_params = { .data = null, .len = 0, .cap = 0 }
	};
	parse_generic_params(p, &st.generic_params);
	if p.accept(front.token.TokenKind.Semicolon) {
		st.is_opaque = true;
	} else {
		p.expect(front.token.TokenKind.LBrace, "'{'");
		for !p.at(front.token.TokenKind.RBrace) && !p.at(front.token.TokenKind.Eof) {
			let fpub: bool = p.accept(front.token.TokenKind.KwPub);
			if !p.at(front.token.TokenKind.Ident) {
				let ut: front.token.Token = p.peek(0);
				let mut mb: [128]u8;
				let mut mp: usize = 0;
				let pfx: []u8 = "expected struct field name, got `";
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
				break;
			}
			let fname: []u8 = p.consume().text;
			if !p.accept(front.token.TokenKind.Colon) {
				front.log.report_with_help(
					front.log.Level.Error,
					p.peek(0).loc,
					"expected `:` after struct field name",
					front.log.DiagCode.ParseExpectedToken,
					"",
					"insert `: `",
					": "
				);
			}
			let fty: *mut front.ast.TypeRef = p.parse_type();
			st.field_names.push(fname);
			st.field_types.push(fty);
			st.field_is_pub.push(fpub);
			if !p.accept(front.token.TokenKind.Comma) {
				break;
			}
		}
		p.expect(front.token.TokenKind.RBrace, "'}'");
	}
	let td: *mut front.ast.TopDecl = front.ast.alloc_top_decl(front.ast.TopKind.Struct);
	td.st = st;
	body.push(td);
	return true;
}

/// Executes `parse_union_into`.
pub fn parse_union_into(
	p: *mut Parser,
	body: *mut front.ast.PtrList<front.ast.TopDecl>,
	is_pub: bool,
	attrs: front.ast.AttributeList
) -> bool {
	let loc: front.log.SourceLoc = p.peek(0).loc;
	p.consume();
	if !p.at(front.token.TokenKind.Ident) {
		front.log.report(
			front.log.Level.Error,
			p.peek(0).loc,
			"expected union name",
			front.log.DiagCode.ParseExpectedToken
		);
		return false;
	}
	let name: []u8 = p.consume().text;
	let mut un: *mut front.ast.UnionDecl = null;
	let raw: *mut u8 = front.ast.arena_alloc(@of.size(front.ast.UnionDecl));
	if raw == null {
		return false;
	}
	un = raw cast *mut front.ast.UnionDecl;
	*un = {
		.name = name,
		.field_names = { .data = null, .len = 0, .cap = 0 },
		.field_types = { .data = null, .len = 0, .cap = 0 },
		.field_is_pub = { .data = null, .len = 0, .cap = 0 },
		.is_pub = is_pub,
		.loc = loc,
		.attrs = attrs,
		.generic_params = { .data = null, .len = 0, .cap = 0 }
	};
	parse_generic_params(p, &un.generic_params);
	p.expect(front.token.TokenKind.LBrace, "'{' after union name");
	for !p.at(front.token.TokenKind.RBrace) && !p.at(front.token.TokenKind.Eof) {
		let fpub: bool = p.accept(front.token.TokenKind.KwPub);
		if !p.at(front.token.TokenKind.Ident) {
			front.log.report(
				front.log.Level.Error,
				p.peek(0).loc,
				"expected field name",
				front.log.DiagCode.ParseExpectedToken
			);
			break;
		}
		let fname: []u8 = p.consume().text;
		if !p.accept(front.token.TokenKind.Colon) {
			front.log.report_with_help(
				front.log.Level.Error,
				p.peek(0).loc,
				"expected `:` after union field name",
				front.log.DiagCode.ParseExpectedToken,
				"",
				"insert `: `",
				": "
			);
		}
		let fty: *mut front.ast.TypeRef = p.parse_type();
		un.field_names.push(fname);
		un.field_types.push(fty);
		un.field_is_pub.push(fpub);
		if !p.accept(front.token.TokenKind.Comma) {
			break;
		}
	}
	p.expect(front.token.TokenKind.RBrace, "'}'");
	let td: *mut front.ast.TopDecl = front.ast.alloc_top_decl(front.ast.TopKind.Union);
	td.un = un;
	body.push(td);
	return true;
}

/// Executes `parse_enum_into`.
pub fn parse_enum_into(
	p: *mut Parser,
	body: *mut front.ast.PtrList<front.ast.TopDecl>,
	is_pub: bool,
	attrs: front.ast.AttributeList
) -> bool {
	let loc: front.log.SourceLoc = p.peek(0).loc;
	p.consume();
	if !p.at(front.token.TokenKind.Ident) {
		front.log.report(
			front.log.Level.Error,
			p.peek(0).loc,
			"expected enum name",
			front.log.DiagCode.ParseExpectedToken
		);
		return false;
	}
	let name: []u8 = p.consume().text;
	let mut en: *mut front.ast.EnumDecl = null;
	let raw: *mut u8 = front.ast.arena_alloc(@of.size(front.ast.EnumDecl));
	if raw == null {
		return false;
	}
	en = raw cast *mut front.ast.EnumDecl;
	*en = {
		.name = name,
		.members = { .data = null, .len = 0, .cap = 0 },
		.is_pub = is_pub,
		.loc = loc,
		.attrs = attrs,
		.backing = null,
		.generic_params = { .data = null, .len = 0, .cap = 0 }
	};
	parse_generic_params(p, &en.generic_params);
	if p.accept(front.token.TokenKind.Colon) {
		en.backing = p.parse_type();
	} else if !p.at(front.token.TokenKind.LBrace) && !p.at(front.token.TokenKind.Eof) {
		front.log.report_with_help(
			front.log.Level.Error,
			p.peek(0).loc,
			"expected `:` before enum underlying type",
			front.log.DiagCode.ParseExpectedToken,
			"",
			"insert `: `",
			": "
		);
		en.backing = p.parse_type();
	}
	p.expect(front.token.TokenKind.LBrace, "'{' after enum header");
	for !p.at(front.token.TokenKind.RBrace) && !p.at(front.token.TokenKind.Eof) {
		let mloc: front.log.SourceLoc = p.peek(0).loc;
		if !p.at(front.token.TokenKind.Ident) {
			front.log.report(
				front.log.Level.Error,
				p.peek(0).loc,
				"expected enum member name",
				front.log.DiagCode.ParseExpectedToken
			);
			break;
		}
		let mname: []u8 = p.consume().text;
		let mut mem: front.ast.EnumMember = {
			.name = mname,
			.payload_kind = front.ast.EnumPayloadKind.Unit,
			.payload_fields = { .data = null, .len = 0, .cap = 0 },
			.value = null,
			.loc = mloc
		};
		if p.accept(front.token.TokenKind.LParen) {
			mem.payload_kind = front.ast.EnumPayloadKind.Tuple;
			for !p.at(front.token.TokenKind.RParen) && !p.at(front.token.TokenKind.Eof) {
				let floc: front.log.SourceLoc = p.peek(0).loc;
				let fty: *mut front.ast.TypeRef = p.parse_type();
				let vf: front.ast.EnumVariantField = { .name = "", .ty = fty, .loc = floc };
				mem.payload_fields.push(vf);
				if !p.accept(front.token.TokenKind.Comma) {
					break;
				}
			}
			p.expect(front.token.TokenKind.RParen, "')'");
		} else if p.accept(front.token.TokenKind.LBrace) {
			mem.payload_kind = front.ast.EnumPayloadKind.Struct;
			for !p.at(front.token.TokenKind.RBrace) && !p.at(front.token.TokenKind.Eof) {
				let floc: front.log.SourceLoc = p.peek(0).loc;
				if !p.at(front.token.TokenKind.Ident) {
					front.log.report(
						front.log.Level.Error,
						p.peek(0).loc,
						"expected variant field name",
						front.log.DiagCode.ParseExpectedToken
					);
					break;
				}
				let fname: []u8 = p.consume().text;
				p.expect(front.token.TokenKind.Colon, "':'");
				let fty: *mut front.ast.TypeRef = p.parse_type();
				let vf: front.ast.EnumVariantField = { .name = fname, .ty = fty, .loc = floc };
				mem.payload_fields.push(vf);
				if !p.accept(front.token.TokenKind.Comma) {
					break;
				}
			}
			p.expect(front.token.TokenKind.RBrace, "'}'");
		}
		if p.accept(front.token.TokenKind.Assign) {
			mem.value = p.parse_expr();
		}
		en.members.push(mem);
		if !p.accept(front.token.TokenKind.Comma) {
			break;
		}
	}
	p.expect(front.token.TokenKind.RBrace, "'}'");
	let td: *mut front.ast.TopDecl = front.ast.alloc_top_decl(front.ast.TopKind.Enum);
	td.en = en;
	body.push(td);
	return true;
}

/// Executes `parse_trait_into`.
pub fn parse_trait_into(
	p: *mut Parser,
	body: *mut front.ast.PtrList<front.ast.TopDecl>,
	is_pub: bool,
	attrs: front.ast.AttributeList
) -> bool {
	let loc: front.log.SourceLoc = p.peek(0).loc;
	p.consume();
	if !p.at(front.token.TokenKind.Ident) {
		front.log.report(
			front.log.Level.Error,
			p.peek(0).loc,
			"expected trait name",
			front.log.DiagCode.ParseExpectedToken
		);
		return false;
	}
	let name: []u8 = p.consume().text;
	let mut tr: *mut front.ast.TraitDecl = null;
	let raw: *mut u8 = front.ast.arena_alloc(@of.size(front.ast.TraitDecl));
	if raw == null {
		return false;
	}
	tr = raw cast *mut front.ast.TraitDecl;
	*tr = {
		.name = name,
		.is_pub = is_pub,
		.loc = loc,
		.attrs = attrs,
		.methods = { .data = null, .len = 0, .cap = 0 }
	};
	let mut tr_gparams: front.ast.ValList<front.ast.GenericParam> = {
		.data = null,
		.len = 0,
		.cap = 0
	};
	parse_generic_params(p, &tr_gparams);
	p.expect(front.token.TokenKind.LBrace, "'{' after trait name");
	for !p.at(front.token.TokenKind.RBrace) && !p.at(front.token.TokenKind.Eof) {
		let mut mattrs: front.ast.AttributeList = front.ast.make_attr_list();
		p.parse_attributes(&mattrs);
		p.accept(front.token.TokenKind.KwPub);
		if !p.at(front.token.TokenKind.KwFn) {
			front.log.report(
				front.log.Level.Error,
				p.peek(0).loc,
				"expected 'fn' inside trait",
				front.log.DiagCode.ParseExpectedToken
			);
			p.consume();
			continue;
		}
		let mloc: front.log.SourceLoc = p.peek(0).loc;
		p.consume();
		if !p.at(front.token.TokenKind.Ident) {
			front.log.report(
				front.log.Level.Error,
				p.peek(0).loc,
				"expected method name",
				front.log.DiagCode.ParseExpectedToken
			);
			continue;
		}
		let mname: []u8 = p.consume().text;
		let fn_d: *mut front.ast.FnDecl = alloc_fn_decl(mloc);
		fn_d.name = mname;
		fn_d.is_pub = true;
		fn_d.attrs = mattrs;
		parse_fn_signature(p, fn_d);
		for let mut pi: usize = 0; pi < fn_d.params.len; pi += 1 {
			if fn_d.params.data[pi].is_mutable {
				front.log.report(
					front.log.Level.Error,
					fn_d.params.data[pi].loc,
					"`mut` is not allowed in trait method prototypes",
					front.log.DiagCode.ParseExpectedToken
				);
			}
		}
		if p.at(front.token.TokenKind.LBrace) {
			fn_d.body = parse_block(p);
		} else {
			p.expect(front.token.TokenKind.Semicolon, "';'");
		}
		tr.methods.push(fn_d);
	}
	p.expect(front.token.TokenKind.RBrace, "'}'");
	let td: *mut front.ast.TopDecl = front.ast.alloc_top_decl(front.ast.TopKind.Trait);
	td.trait_decl = tr;
	body.push(td);
	return true;
}
