mod middle.sema.validation;
import "front/ast.sl";
import "front/log.sl";
import "middle/resolver.sl";
import "middle/symbol.sl";
import "std/err.sl";
import "std/io.sl";
import "std/mem.sl";
import "std/str.sl";

struct ImportTarget {
	imp: *front.ast.ImportDecl,
	targets: front.ast.PtrList<middle.resolver.LoadedModule>,
	used: bool
}

struct ImportScanCtx {
	entries: front.ast.ValList<ImportTarget>,
	root_mod_path: *front.ast.ValList<[]u8>
}

fn str_ends_with(s: []u8, suffix: []u8) -> bool {
	if s.len < suffix.len {
		return false;
	}
	return std.str.eq(s[(s.len - suffix.len)..s.len], suffix);
}

fn same_str_list(a: *front.ast.ValList<[]u8>, b: *front.ast.ValList<[]u8>) -> bool {
	if a == null || b == null {
		return false;
	}
	if a.len != b.len {
		return false;
	}
	for let mut i: usize = 0; i < a.len; i += 1 {
		if !std.str.eq(a.data[i], b.data[i]) {
			return false;
		}
	}
	return true;
}

fn has_lm(
	list: *front.ast.PtrList<middle.resolver.LoadedModule>,
	lm: *mut middle.resolver.LoadedModule
) -> bool {
	for let mut i: usize = 0; i < list.len; i += 1 {
		if list.data[i] == lm {
			return true;
		}
	}
	return false;
}

fn add_target_recursive(
	mtable: *mut middle.resolver.ModuleTable,
	lm: *mut middle.resolver.LoadedModule,
	out: *mut front.ast.PtrList<middle.resolver.LoadedModule>
) -> void {
	if lm == null || has_lm(out, lm) {
		return;
	}
	out.push(lm);
	for let mut i: usize = 0; i < lm.ast.decls.len; i += 1 {
		let td: *front.ast.TopDecl = lm.ast.decls.data[i];
		if td != null && td.kind == front.ast.TopKind.Import && td.imp != null
			&& td.imp.is_pub {
			collect_import_targets(mtable, lm.path, td.imp.written_path, out);
		}
	}
}

fn collect_import_targets(
	mtable: *mut middle.resolver.ModuleTable,
	from_path: []u8,
	wp: []u8,
	out: *mut front.ast.PtrList<middle.resolver.LoadedModule>
) -> void {
	if wp.len == 0 {
		return;
	}
	if str_ends_with(wp, "/*.sl") || str_ends_with(wp, "/*") {
		let dir_rel: []u8 = str_ends_with(wp, "/*.sl") ? wp[0..(wp.len - 5)]
			: wp[0..(wp.len - 2)];
		let dir_path: []u8 = mtable.resolve_dir_path(from_path, dir_rel);
		if dir_path.len == 0 {
			return;
		}
		let cdir: *mut u8 = front.ast.arena_alloc(dir_path.len + 1);
		if cdir == null {
			return;
		}
		std.mem.copy(cdir, dir_path.ptr, dir_path.len);
		cdir[dir_path.len] = 0;
		match std.io.dir.open(cdir) {
			.Ok(mut d_handle) => {
				let mut name_buf: [512]u8;
				for true {
					let mut ent: std.io.dir.Entry;
					let code: std.err.Code = std.io.dir.next(&d_handle, &name_buf[0], 512, &ent);
					if code != std.err.Code.Success || ent.name_length == 0 {
						break;
					}
					let ename: []u8 = name_buf[0..ent.name_length];
					if str_ends_with(ename, ".sl") {
						let full: []u8 = middle.resolver.join_path(dir_path, ename);
						add_target_recursive(mtable, mtable.find(full), out);
					}
				}
				d_handle.close();
			}
			.Err(_) => {}
		}
		return;
	}
	let resolved: []u8 = mtable.resolve_import_path(from_path, wp);
	if resolved.len > 0 {
		add_target_recursive(mtable, mtable.find(resolved), out);
	}
}

fn decls_declare_name(decls: *front.ast.PtrList<front.ast.TopDecl>, name: []u8) -> bool {
	for let mut i: usize = 0; i < decls.len; i += 1 {
		let td: *front.ast.TopDecl = decls.data[i];
		if td == null {
			continue;
		}
		match td.kind {
			.Mod => {
				if td.mod_decl != null && decls_declare_name(&td.mod_decl.body, name) {
					return true;
				}
			}
			.Fn => {
				if td.fn_decl != null && std.str.eq(td.fn_decl.name, name) {
					return true;
				}
			}
			.Struct => {
				if td.st != null && std.str.eq(td.st.name, name) {
					return true;
				}
			}
			.Union => {
				if td.un != null && std.str.eq(td.un.name, name) {
					return true;
				}
			}
			.Enum => {
				if td.en != null && std.str.eq(td.en.name, name) {
					return true;
				}
			}
			.TypeBinding => {
				if td.tb != null && std.str.eq(td.tb.name, name) {
					return true;
				}
			}
			.Var | .Const => {
				if td.glob != null && std.str.eq(td.glob.name, name) {
					return true;
				}
			}
			.Trait => {
				if td.trait_decl != null && std.str.eq(td.trait_decl.name, name) {
					return true;
				}
			}
			_ => {}
		}
	}
	return false;
}

fn decls_have_member(decls: *front.ast.PtrList<front.ast.TopDecl>, member: []u8) -> bool {
	for let mut i: usize = 0; i < decls.len; i += 1 {
		let td: *front.ast.TopDecl = decls.data[i];
		if td == null {
			continue;
		}
		if td.kind == front.ast.TopKind.Mod && td.mod_decl != null {
			if decls_have_member(&td.mod_decl.body, member) {
				return true;
			}
		} else if td.kind == front.ast.TopKind.Impl && td.impl_decl != null {
			for let mut j: usize = 0; j < td.impl_decl.methods.len; j += 1 {
				let m: *front.ast.FnDecl = td.impl_decl.methods.data[j];
				if m != null && std.str.eq(m.name, member) {
					return true;
				}
			}
			for let mut j: usize = 0; j < td.impl_decl.consts.len; j += 1 {
				let c: *front.ast.GlobalDecl = td.impl_decl.consts.data[j];
				if c != null && std.str.eq(c.name, member) {
					return true;
				}
			}
		}
	}
	return false;
}

fn mark_path(ctx: *mut ImportScanCtx, path: *front.ast.ValList<[]u8>) -> void {
	if path == null || path.len == 0 {
		return;
	}
	for let mut ei: usize = 0; ei < ctx.entries.len; ei += 1 {
		if ctx.entries.data[ei].used {
			continue;
		}
		let targets: *front.ast.PtrList<middle.resolver.LoadedModule> =
			&ctx.entries.data[ei].targets;
		for let mut ti: usize = 0; ti < targets.len; ti += 1 {
			let lm: *middle.resolver.LoadedModule = targets.data[ti];
			if lm == null {
				continue;
			}
			let ns: *front.ast.ValList<[]u8> = &lm.ast.mod_path;
			if path.len > ns.len && ns.len > 0 {
				let mut prefix_ok: bool = true;
				for let mut k: usize = 0; k < ns.len; k += 1 {
					if !std.str.eq(path.data[k], ns.data[k]) {
						prefix_ok = false;
						break;
					}
				}
				if prefix_ok && decls_declare_name(&lm.ast.decls, path.data[ns.len]) {
					ctx.entries.data[ei].used = true;
					break;
				}
			} else if ns.len == 0 && decls_declare_name(&lm.ast.decls, path.data[0]) {
				ctx.entries.data[ei].used = true;
				break;
			} else if path.len == 1 && same_str_list(ns, ctx.root_mod_path)
				&& decls_declare_name(&lm.ast.decls, path.data[0]) {
				ctx.entries.data[ei].used = true;
				break;
			}
		}
	}
}

fn mark_member_name(ctx: *mut ImportScanCtx, member: []u8) -> void {
	if member.len == 0 {
		return;
	}
	for let mut ei: usize = 0; ei < ctx.entries.len; ei += 1 {
		if ctx.entries.data[ei].used {
			continue;
		}
		let targets: *front.ast.PtrList<middle.resolver.LoadedModule> =
			&ctx.entries.data[ei].targets;
		for let mut ti: usize = 0; ti < targets.len; ti += 1 {
			let lm: *middle.resolver.LoadedModule = targets.data[ti];
			if lm != null && decls_have_member(&lm.ast.decls, member) {
				ctx.entries.data[ei].used = true;
				break;
			}
		}
	}
}

fn flatten_member_chain(e: *front.ast.Expr, out: *mut front.ast.ValList<[]u8>) -> bool {
	if e == null {
		return false;
	}
	if e.kind == front.ast.ExprKind.Ident {
		for let mut i: usize = 0; i < e.path.len; i += 1 {
			out.push(e.path.data[i]);
		}
		return out.len > 0;
	}
	if e.kind == front.ast.ExprKind.Member && e.lhs != null && e.member.len > 0 {
		if flatten_member_chain(e.lhs, out) {
			out.push(e.member);
			return true;
		}
	}
	return false;
}

fn scan_generic_params(
	ctx: *mut ImportScanCtx,
	gps: *front.ast.ValList<front.ast.GenericParam>
) -> void {
	for let mut i: usize = 0; i < gps.len; i += 1 {
		let gp: *front.ast.GenericParam = &gps.data[i];
		if gp.const_type != null {
			scan_type_ref(ctx, gp.const_type);
		}
		for let mut j: usize = 0; j < gp.trait_bounds.len; j += 1 {
			scan_type_ref(ctx, gp.trait_bounds.data[j]);
		}
	}
}

fn scan_generic_args(
	ctx: *mut ImportScanCtx,
	args: *front.ast.ValList<front.ast.GenericArg>
) -> void {
	for let mut i: usize = 0; i < args.len; i += 1 {
		let arg: *front.ast.GenericArg = &args.data[i];
		if arg.ty != null {
			scan_type_ref(ctx, arg.ty);
		}
		if arg.value != null {
			scan_expr(ctx, arg.value);
		}
	}
}

fn scan_type_ref(ctx: *mut ImportScanCtx, tr: *front.ast.TypeRef) -> void {
	if tr == null {
		return;
	}
	if tr.kind == front.ast.TypeRefKind.Named {
		mark_path(ctx, &tr.path);
	}
	if tr.base != null {
		scan_type_ref(ctx, tr.base);
	}
	for let mut i: usize = 0; i < tr.fn_params.len; i += 1 {
		scan_type_ref(ctx, tr.fn_params.data[i]);
	}
	if tr.fn_ret != null {
		scan_type_ref(ctx, tr.fn_ret);
	}
	if tr.array_len_expr != null {
		scan_expr(ctx, tr.array_len_expr);
	}
	if tr.typeof_expr != null {
		scan_expr(ctx, tr.typeof_expr);
	}
	scan_generic_args(ctx, &tr.generic_args);
}

fn scan_expr(ctx: *mut ImportScanCtx, e: *front.ast.Expr) -> void {
	if e == null {
		return;
	}
	if e.kind == front.ast.ExprKind.Ident || e.kind == front.ast.ExprKind.StructLit {
		mark_path(ctx, &e.path);
	} else if e.kind == front.ast.ExprKind.Member {
		let mut chain: front.ast.ValList<[]u8> = { .data = null, .len = 0, .cap = 0 };
		if flatten_member_chain(e, &chain) {
			mark_path(ctx, &chain);
		}
		if e.member.len > 0 {
			mark_member_name(ctx, e.member);
		}
	}
	if e.lhs != null {
		scan_expr(ctx, e.lhs);
	}
	if e.rhs != null {
		scan_expr(ctx, e.rhs);
	}
	if e.index_low != null {
		scan_expr(ctx, e.index_low);
	}
	if e.condition != null {
		scan_expr(ctx, e.condition);
	}
	if e.then_expr != null {
		scan_expr(ctx, e.then_expr);
	}
	if e.else_expr != null {
		scan_expr(ctx, e.else_expr);
	}
	for let mut i: usize = 0; i < e.args.len; i += 1 {
		scan_expr(ctx, e.args.data[i]);
	}
	if e.block != null {
		scan_stmt(ctx, e.block);
	}
	scan_generic_args(ctx, &e.generic_args);
	if e.cast_type != null {
		scan_type_ref(ctx, e.cast_type);
	}
	if e.layout_type != null {
		scan_type_ref(ctx, e.layout_type);
	}
	if e.va_arg_ty != null {
		scan_type_ref(ctx, e.va_arg_ty);
	}
}

fn scan_stmt(ctx: *mut ImportScanCtx, s: *front.ast.Stmt) -> void {
	if s == null {
		return;
	}
	for let mut i: usize = 0; i < s.body.len; i += 1 {
		scan_stmt(ctx, s.body.data[i]);
	}
	if s.expr != null {
		scan_expr(ctx, s.expr);
	}
	for let mut i: usize = 0; i < s.vars.len; i += 1 {
		if s.vars.data[i].ty != null {
			scan_type_ref(ctx, s.vars.data[i].ty);
		}
		if s.vars.data[i].init != null {
			scan_expr(ctx, s.vars.data[i].init);
		}
	}
	if s.cond != null {
		scan_expr(ctx, s.cond);
	}
	if s.then_block != null {
		scan_stmt(ctx, s.then_block);
	}
	if s.else_block != null {
		scan_stmt(ctx, s.else_block);
	}
	if s.for_init != null {
		scan_stmt(ctx, s.for_init);
	}
	if s.for_cond != null {
		scan_expr(ctx, s.for_cond);
	}
	if s.for_step != null {
		scan_expr(ctx, s.for_step);
	}
	if s.loop_body != null {
		scan_stmt(ctx, s.loop_body);
	}
	if s.scrutinee != null {
		scan_expr(ctx, s.scrutinee);
	}
	for let mut i: usize = 0; i < s.arms.len; i += 1 {
		let arm: *front.ast.MatchArm = &s.arms.data[i];
		for let mut pi: usize = 0; pi < arm.patterns.len; pi += 1 {
			if arm.patterns.data[pi].expr != null {
				scan_expr(ctx, arm.patterns.data[pi].expr);
			}
		}
		if arm.body != null {
			scan_stmt(ctx, arm.body);
		}
	}
	if s.ret_val != null {
		scan_expr(ctx, s.ret_val);
	}
	if s.defer_body != null {
		scan_stmt(ctx, s.defer_body);
	}
	for let mut i: usize = 0; i < s.asm_outputs.len; i += 1 {
		if s.asm_outputs.data[i].operand != null {
			scan_expr(ctx, s.asm_outputs.data[i].operand);
		}
	}
	for let mut i: usize = 0; i < s.asm_inputs.len; i += 1 {
		if s.asm_inputs.data[i].operand != null {
			scan_expr(ctx, s.asm_inputs.data[i].operand);
		}
	}
}

fn scan_fn_decl(ctx: *mut ImportScanCtx, fd: *front.ast.FnDecl) -> void {
	if fd == null {
		return;
	}
	for let mut i: usize = 0; i < fd.params.len; i += 1 {
		if fd.params.data[i].ty != null {
			scan_type_ref(ctx, fd.params.data[i].ty);
		}
	}
	if fd.ret != null {
		scan_type_ref(ctx, fd.ret);
	}
	scan_generic_params(ctx, &fd.generic_params);
	if fd.body != null {
		scan_stmt(ctx, fd.body);
	}
}

fn scan_decls(ctx: *mut ImportScanCtx, decls: *front.ast.PtrList<front.ast.TopDecl>) -> void {
	for let mut i: usize = 0; i < decls.len; i += 1 {
		let td: *front.ast.TopDecl = decls.data[i];
		if td == null {
			continue;
		}
		match td.kind {
			.Mod => {
				if td.mod_decl != null {
					scan_decls(ctx, &td.mod_decl.body);
				}
			}
			.Fn => scan_fn_decl(ctx, td.fn_decl),
			.Struct => {
				if td.st != null {
					for let mut j: usize = 0; j < td.st.field_types.len; j += 1 {
						scan_type_ref(ctx, td.st.field_types.data[j]);
					}
					scan_generic_params(ctx, &td.st.generic_params);
				}
			}
			.Union => {
				if td.un != null {
					for let mut j: usize = 0; j < td.un.field_types.len; j += 1 {
						scan_type_ref(ctx, td.un.field_types.data[j]);
					}
					scan_generic_params(ctx, &td.un.generic_params);
				}
			}
			.TypeBinding => {
				if td.tb != null {
					scan_type_ref(ctx, td.tb.target);
					scan_generic_params(ctx, &td.tb.generic_params);
				}
			}
			.Var | .Const => {
				if td.glob != null {
					scan_type_ref(ctx, td.glob.ty);
					scan_expr(ctx, td.glob.init);
				}
			}
			.Enum => {
				if td.en != null {
					scan_type_ref(ctx, td.en.backing);
					for let mut j: usize = 0; j < td.en.members.len; j += 1 {
						scan_expr(ctx, td.en.members.data[j].value);
					}
					scan_generic_params(ctx, &td.en.generic_params);
				}
			}
			.Trait => {
				if td.trait_decl != null {
					for let mut j: usize = 0; j < td.trait_decl.methods.len; j += 1 {
						scan_fn_decl(ctx, td.trait_decl.methods.data[j]);
					}
				}
			}
			.Impl => {
				if td.impl_decl != null {
					if td.impl_decl.trait_path.len > 0 {
						mark_path(ctx, &td.impl_decl.trait_path);
					}
					scan_type_ref(ctx, td.impl_decl.target_type);
					scan_generic_params(ctx, &td.impl_decl.generic_params);
					for let mut j: usize = 0; j < td.impl_decl.consts.len; j += 1 {
						let c: *front.ast.GlobalDecl = td.impl_decl.consts.data[j];
						if c != null {
							scan_type_ref(ctx, c.ty);
							scan_expr(ctx, c.init);
						}
					}
					for let mut j: usize = 0; j < td.impl_decl.methods.len; j += 1 {
						scan_fn_decl(ctx, td.impl_decl.methods.data[j]);
					}
				}
			}
			_ => {}
		}
	}
}

impl SemaContext {
	/// Warns on private imports in `root_lm` whose symbols are never referenced.
	pub fn check_unused_imports(
		self: *SemaContext,
		mtable: *mut middle.resolver.ModuleTable,
		root_lm: *middle.resolver.LoadedModule
	) -> void {
		if mtable == null || root_lm == null {
			return;
		}
		let mut ctx: ImportScanCtx = {
			.entries = { .data = null, .len = 0, .cap = 0 },
			.root_mod_path = &root_lm.ast.mod_path
		};
		for let mut i: usize = 0; i < root_lm.ast.decls.len; i += 1 {
			let td: *front.ast.TopDecl = root_lm.ast.decls.data[i];
			if td != null && td.kind == front.ast.TopKind.Import && td.imp != null
				&& !td.imp.is_pub {
				let mut entry: ImportTarget = {
					.imp = td.imp,
					.targets = { .data = null, .len = 0, .cap = 0 },
					.used = false
				};
				collect_import_targets(mtable, root_lm.path, td.imp.written_path, &entry.targets);
				ctx.entries.push(entry);
			}
		}
		if ctx.entries.len == 0 {
			return;
		}
		for let mut si: usize = 0; si < self.imported_syms.len; si += 1 {
			let sym: *middle.symbol.Symbol = self.imported_syms.data[si].sym;
			if sym != null && sym.used {
				for let mut ei: usize = 0; ei < ctx.entries.len; ei += 1 {
					if ctx.entries.data[ei].used {
						continue;
					}
					let targets: *front.ast.PtrList<middle.resolver.LoadedModule> =
						&ctx.entries.data[ei].targets;
					for let mut ti: usize = 0; ti < targets.len; ti += 1 {
						let lm: *middle.resolver.LoadedModule = targets.data[ti];
						if lm != null
							&& same_str_list(
								&lm.ast.mod_path,
								&self.imported_syms.data[si].mod_path
							)
							&& decls_declare_name(&lm.ast.decls, sym.simple) {
							ctx.entries.data[ei].used = true;
							break;
						}
					}
				}
			}
		}
		scan_decls(&ctx, &root_lm.ast.decls);
		for let mut ei: usize = 0; ei < ctx.entries.len; ei += 1 {
			if !ctx.entries.data[ei].used {
				front.log.report(
					front.log.Level.Warning,
					ctx.entries.data[ei].imp.loc,
					"unused import",
					front.log.DiagCode.WarningGeneral
				);
			}
		}
	}
}
