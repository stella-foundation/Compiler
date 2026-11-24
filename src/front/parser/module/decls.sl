mod front.parser;
pub import "front/parser/expressions.sl";
pub import "front/parser/statements.sl";
import "front/ast.sl";
import "front/log.sl";
import "front/token.sl";
import "std/mem.sl";
import "std/str.sl";


/// Executes `parse_impl_into`.
pub fn parse_impl_into(
	p: *mut Parser,
	body: *mut front.ast.PtrList<front.ast.TopDecl>,
	attrs: front.ast.AttributeList
) -> bool {
	let loc: front.log.SourceLoc = p.peek(0).loc;
	p.consume();
	let mut im: *mut front.ast.ImplDecl = null;
	let raw: *mut u8 = front.ast.arena_alloc(@of.size(front.ast.ImplDecl));
	if raw == null {
		return false;
	}
	im = raw cast *mut front.ast.ImplDecl;
	*im = {
		.is_inherent = true,
		.trait_name = "",
		.trait_path = { .data = null, .len = 0, .cap = 0 },
		.generic_params = { .data = null, .len = 0, .cap = 0 },
		.target_type = null,
		.loc = loc,
		.attrs = attrs,
		.methods = { .data = null, .len = 0, .cap = 0 },
		.consts = { .data = null, .len = 0, .cap = 0 }
	};
	parse_generic_params(p, &im.generic_params);
	let first_ty: *mut front.ast.TypeRef = p.parse_type();
	if p.accept(front.token.TokenKind.KwFor) {
		im.is_inherent = false;
		if first_ty != null {
			im.trait_name = first_ty.name;
			for let mut i: usize = 0; i < first_ty.path.len; i += 1 {
				im.trait_path.push(first_ty.path.data[i]);
			}
		}
		im.target_type = p.parse_type();
	} else {
		im.is_inherent = true;
		im.target_type = first_ty;
	}
	p.expect(front.token.TokenKind.LBrace, "'{' after impl header");
	for !p.at(front.token.TokenKind.RBrace) && !p.at(front.token.TokenKind.Eof) {
		let mut mattrs: front.ast.AttributeList = front.ast.make_attr_list();
		p.parse_attributes(&mattrs);
		let mpub: bool = p.accept(front.token.TokenKind.KwPub);
		if p.at(front.token.TokenKind.KwFn) {
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
			fn_d.is_pub = mpub;
			fn_d.attrs = mattrs;
			parse_fn_signature(p, fn_d);
			fn_d.body = parse_block(p);
			im.methods.push(fn_d);
		} else if p.at(front.token.TokenKind.KwConst) {
			let cloc: front.log.SourceLoc = p.peek(0).loc;
			p.consume();
			if !p.at(front.token.TokenKind.Ident) {
				front.log.report(
					front.log.Level.Error,
					p.peek(0).loc,
					"expected const name",
					front.log.DiagCode.ParseExpectedToken
				);
				continue;
			}
			let cname: []u8 = p.consume().text;
			p.expect(front.token.TokenKind.Colon, "':'");
			let cty: *mut front.ast.TypeRef = p.parse_type();
			p.expect(front.token.TokenKind.Assign, "'='");
			let cinit: *mut front.ast.Expr = p.parse_expr();
			p.expect(front.token.TokenKind.Semicolon, "';'");
			let gd: *mut front.ast.GlobalDecl = alloc_global_decl(cloc);
			gd.name = cname;
			gd.ty = cty;
			gd.init = cinit;
			gd.is_const = true;
			gd.is_pub = mpub;
			gd.attrs = mattrs;
			im.consts.push(gd);
		} else {
			front.log.report(
				front.log.Level.Error,
				p.peek(0).loc,
				"expected 'fn' or 'const' in impl block",
				front.log.DiagCode.ParseExpectedToken
			);
			p.consume();
		}
	}
	p.expect(front.token.TokenKind.RBrace, "'}'");
	let td: *mut front.ast.TopDecl = front.ast.alloc_top_decl(front.ast.TopKind.Impl);
	td.impl_decl = im;
	body.push(td);
	return true;
}

/// Executes `parse_global_into`.
pub fn parse_global_into(
	p: *mut Parser,
	body: *mut front.ast.PtrList<front.ast.TopDecl>,
	is_pub: bool,
	is_const: bool,
	attrs: front.ast.AttributeList,
	is_extern: bool
) -> bool {
	let loc: front.log.SourceLoc = p.peek(0).loc;
	p.consume();
	let mut is_static: bool = false;
	let mut is_tl: bool = false;
	let mut is_mut: bool = false;
	if !is_const {
		for p.at(front.token.TokenKind.KwStatic) || p.at(front.token.TokenKind.KwThreadLocal)
			|| p.at(front.token.TokenKind.KwMut) {
			if p.accept(front.token.TokenKind.KwStatic) {
				is_static = true;
			} else if p.accept(front.token.TokenKind.KwMut) {
				is_mut = true;
			} else {
				p.consume();
				is_tl = true;
			}
		}
	}
	if !p.at(front.token.TokenKind.Ident) {
		front.log.report(
			front.log.Level.Error,
			p.peek(0).loc,
			"expected global name",
			front.log.DiagCode.ParseExpectedToken
		);
		return false;
	}
	let name: []u8 = p.consume().text;
	let mut generic_params: front.ast.ValList<front.ast.GenericParam> = {
		.data = null,
		.len = 0,
		.cap = 0
	};
	if is_const {
		parse_generic_params(p, &generic_params);
	}
	let mut ty: *mut front.ast.TypeRef = null;
	if p.accept(front.token.TokenKind.Colon) {
		ty = p.parse_type();
	} else {
		front.log.report(
			front.log.Level.Error,
			p.peek(0).loc,
			"expected ':' and type annotation",
			front.log.DiagCode.ParseExpectedToken
		);
	}
	let is_type_binding: bool = is_const && ty != null
		&& ty.kind == front.ast.TypeRefKind.Named && std.str.eq(ty.single, "type");
	if is_type_binding {
		let mut tb: *mut front.ast.TypeBindingDecl = null;
		let raw: *mut u8 = front.ast.arena_alloc(@of.size(front.ast.TypeBindingDecl));
		if raw == null {
			return false;
		}
		tb = raw cast *mut front.ast.TypeBindingDecl;
		p.expect(front.token.TokenKind.Assign, "'='");
		let target: *mut front.ast.TypeRef = p.parse_type();
		p.expect(front.token.TokenKind.Semicolon, "';'");
		*tb = {
			.name = name,
			.target = target,
			.is_pub = is_pub,
			.loc = loc,
			.attrs = attrs,
			.generic_params = generic_params
		};
		let td: *mut front.ast.TopDecl = front.ast.alloc_top_decl(front.ast.TopKind.TypeBinding);
		td.tb = tb;
		body.push(td);
		return true;
	}
	let mut init: *mut front.ast.Expr = null;
	if p.accept(front.token.TokenKind.Assign) {
		init = p.parse_expr();
	}
	p.expect(front.token.TokenKind.Semicolon, "';'");
	let gd: *mut front.ast.GlobalDecl = alloc_global_decl(loc);
	gd.name = name;
	gd.ty = ty;
	gd.init = init;
	gd.is_const = is_const;
	gd.is_mutable = is_mut;
	gd.is_static = is_static;
	gd.is_thread_local = is_tl;
	gd.is_pub = is_pub;
	gd.is_extern = is_extern;
	gd.attrs = attrs;
	let td: *mut front.ast.TopDecl = front.ast.alloc_top_decl(
		is_const ? front.ast.TopKind.Const : front.ast.TopKind.Var
	);
	td.glob = gd;
	body.push(td);
	return true;
}

/// Executes `parse_import_into`.
pub fn parse_import_into(
	p: *mut Parser,
	body: *mut front.ast.PtrList<front.ast.TopDecl>,
	is_pub: bool,
	attrs: front.ast.AttributeList
) -> bool {
	let loc: front.log.SourceLoc = p.peek(0).loc;
	p.consume();
	let mut imp: *mut front.ast.ImportDecl = null;
	let raw: *mut u8 = front.ast.arena_alloc(@of.size(front.ast.ImportDecl));
	if raw == null {
		return false;
	}
	imp = raw cast *mut front.ast.ImportDecl;
	*imp = {
		.written_path = "",
		.path = { .data = null, .len = 0, .cap = 0 },
		.is_pub = is_pub,
		.loc = loc,
		.attrs = attrs
	};
	if p.at(front.token.TokenKind.StringLit) {
		imp.written_path = p.consume().text;
	} else {
		parse_dotted_path(p, &imp.path);
	}
	p.expect(front.token.TokenKind.Semicolon, "';' after import");
	let td: *mut front.ast.TopDecl = front.ast.alloc_top_decl(front.ast.TopKind.Import);
	td.imp = imp;
	body.push(td);
	return true;
}

/// Executes `parse_mod_into`.
pub fn parse_mod_into(
	p: *mut Parser,
	body: *mut front.ast.PtrList<front.ast.TopDecl>,
	is_pub: bool,
	attrs: front.ast.AttributeList
) -> bool {
	let loc: front.log.SourceLoc = p.peek(0).loc;
	p.consume();
	if !p.at(front.token.TokenKind.Ident) && !p.at(front.token.TokenKind.KwType) {
		front.log.report(
			front.log.Level.Error,
			p.peek(0).loc,
			"expected module name",
			front.log.DiagCode.ParseExpectedToken
		);
		return false;
	}
	let name: []u8 = p.consume().text;
	if p.at(front.token.TokenKind.Dot) || p.at(front.token.TokenKind.Semicolon) {
		let p1: []u8 = "at most one file-level `mod` declaration is allowed per file, ";
		let p2: []u8 = "and it must appear before all other declarations";
		let mut mb: [128]u8;
		std.mem.copy(&mb[0], p1.ptr, p1.len);
		std.mem.copy(&mb[p1.len], p2.ptr, p2.len);
		front.log.report_custom(
			front.log.Level.Error,
			loc,
			(&mb[0])[0..(p1.len + p2.len)],
			"E_PARSE_UNEXPECTED_TOKEN",
			front.log.Phase.Parser
		);
		for !p.at(front.token.TokenKind.Semicolon) && !p.at(front.token.TokenKind.Eof) {
			p.consume();
		}
		p.accept(front.token.TokenKind.Semicolon);
		return false;
	}
	let mut md: *mut front.ast.ModDecl = null;
	let raw: *mut u8 = front.ast.arena_alloc(@of.size(front.ast.ModDecl));
	if raw == null {
		return false;
	}
	md = raw cast *mut front.ast.ModDecl;
	*md = {
		.name = name,
		.body = { .data = null, .len = 0, .cap = 0 },
		.is_pub = is_pub,
		.loc = loc,
		.attrs = attrs
	};
	p.expect(front.token.TokenKind.LBrace, "'{' after mod name");
	for !p.at(front.token.TokenKind.RBrace) && !p.at(front.token.TokenKind.Eof) {
		parse_top_into(p, &md.body, true);
	}
	p.expect(front.token.TokenKind.RBrace, "'}'");
	let td: *mut front.ast.TopDecl = front.ast.alloc_top_decl(front.ast.TopKind.Mod);
	td.mod_decl = md;
	body.push(td);
	return true;
}

/// Executes `parse_top_if`.
pub fn parse_top_if(p: *mut Parser, body: *mut front.ast.PtrList<front.ast.TopDecl>) -> bool {
	let loc: front.log.SourceLoc = p.peek(0).loc;
	let mut cd: *mut front.ast.ConditionalDecl = null;
	let raw: *mut u8 = front.ast.arena_alloc(@of.size(front.ast.ConditionalDecl));
	if raw == null {
		return false;
	}
	cd = raw cast *mut front.ast.ConditionalDecl;
	*cd = { .arms = { .data = null, .len = 0, .cap = 0 }, .loc = loc };
	for true {
		let arm_loc: front.log.SourceLoc = p.peek(0).loc;
		p.consume();
		let prev_struct_init: bool = p.allow_struct_init;
		p.allow_struct_init = false;
		let cond: *mut front.ast.Expr = p.parse_expr();
		p.allow_struct_init = prev_struct_init;
		p.expect(front.token.TokenKind.LBrace, "'{'");
		let mut arm: front.ast.ConditionalArm = {
			.cond = cond,
			.body = { .data = null, .len = 0, .cap = 0 },
			.loc = arm_loc
		};
		for !p.at(front.token.TokenKind.RBrace) && !p.at(front.token.TokenKind.Eof) {
			parse_top_into(p, &arm.body, true);
		}
		p.expect(front.token.TokenKind.RBrace, "'}'");
		cd.arms.push(arm);
		if !p.accept(front.token.TokenKind.KwElse) {
			break;
		}
		if !p.at(front.token.TokenKind.KwIf) {
			let else_loc: front.log.SourceLoc = p.peek(0).loc;
			p.expect(front.token.TokenKind.LBrace, "'{'");
			let mut else_arm: front.ast.ConditionalArm = {
				.cond = null,
				.body = { .data = null, .len = 0, .cap = 0 },
				.loc = else_loc
			};
			for !p.at(front.token.TokenKind.RBrace) && !p.at(front.token.TokenKind.Eof) {
				parse_top_into(p, &else_arm.body, true);
			}
			p.expect(front.token.TokenKind.RBrace, "'}'");
			cd.arms.push(else_arm);
			break;
		}
	}
	let td: *mut front.ast.TopDecl = front.ast.alloc_top_decl(front.ast.TopKind.Conditional);
	td.conditional = cd;
	body.push(td);
	return true;
}

/// Executes `sync_top_level`.
pub fn sync_top_level(p: *mut Parser) -> void {
	for !p.at(front.token.TokenKind.Eof) {
		if p.accept(front.token.TokenKind.Semicolon) {
			return;
		}
		if is_top_sync_token(p.peek(0).kind) {
			return;
		}
		p.consume();
	}
}

/// Executes `parse_top_into`.
pub fn parse_top_into(
	p: *mut Parser,
	body: *mut front.ast.PtrList<front.ast.TopDecl>,
	inside_block: bool
) -> bool {
	let mut attrs: front.ast.AttributeList = front.ast.make_attr_list();
	p.parse_attributes(&attrs);
	let is_pub: bool = p.accept(front.token.TokenKind.KwPub);
	let is_extern: bool = p.accept(front.token.TokenKind.KwExtern);

	let k: front.token.TokenKind = p.peek(0).kind;
	if k == front.token.TokenKind.KwImport {
		return parse_import_into(p, body, is_pub, attrs);
	}
	if k == front.token.TokenKind.KwMod {
		return parse_mod_into(p, body, is_pub, attrs);
	}
	if k == front.token.TokenKind.KwFn {
		return parse_fn_into(p, body, is_pub, attrs, is_extern);
	}
	if k == front.token.TokenKind.KwMacro {
		return parse_macro_into(p, body, is_pub, attrs);
	}
	if k == front.token.TokenKind.KwStruct {
		return parse_struct_into(p, body, is_pub, attrs);
	}
	if k == front.token.TokenKind.KwUnion {
		return parse_union_into(p, body, is_pub, attrs);
	}
	if k == front.token.TokenKind.KwEnum {
		return parse_enum_into(p, body, is_pub, attrs);
	}
	if k == front.token.TokenKind.KwTrait {
		return parse_trait_into(p, body, is_pub, attrs);
	}
	if k == front.token.TokenKind.KwImpl {
		return parse_impl_into(p, body, attrs);
	}
	if k == front.token.TokenKind.KwLet || k == front.token.TokenKind.KwConst {
		return parse_global_into(
			p,
			body,
			is_pub,
			k == front.token.TokenKind.KwConst,
			attrs,
			is_extern
		);
	}
	if k == front.token.TokenKind.KwIf && !is_pub && !is_extern {
		return parse_top_if(p, body);
	}

	let ut: front.token.Token = p.peek(0);
	let mut mb: [128]u8;
	let mut mp: usize = 0;
	let pfx: []u8 = "unexpected top-level token `";
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
	if !p.at(front.token.TokenKind.Eof) {
		p.consume();
	}
	if !inside_block {
		sync_top_level(p);
	}
	return false;
}

/// Executes `parse_stmt_cb`.
pub fn parse_stmt_cb(p: *mut Parser) -> *mut front.ast.Stmt {
	return parse_stmt(p, false);
}

/// Executes `parse_module` (parse module).
pub fn parse_module(p: *mut Parser, out: *mut front.ast.Module) -> bool {
	p.parse_block_fn = parse_block_cb;
	p.parse_stmt_fn = parse_stmt_cb;
	if starts_with_namespace_header(p) {
		p.parse_attributes(&out.file_attrs);
		out.mod_loc = p.peek(0).loc;
		p.consume();
		parse_dotted_path(p, &out.mod_path);
		p.expect(front.token.TokenKind.Semicolon, "';' after mod header");
	}
	for !p.at(front.token.TokenKind.Eof) {
		parse_top_into(p, &out.decls, false);
	}
	return !front.log.has_error();
}
