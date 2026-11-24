mod middle.sema.validation;
import "front/ast.sl";
import "front/log.sl";
import "front/token.sl";
import "middle/resolver.sl";
import "middle/sema/const_eval.sl";
import "middle/sema/control_flow.sl";
import "middle/sema/generics.sl";
import "middle/symbol.sl";
import "middle/types.sl";
import "std/mem.sl";
import "std/str.sl";

/// Executes `register_impl_method`.
pub fn register_impl_method(
	self: *mut SemaContext,
	target_ty: *mut middle.types.StType,
	fn_d: *front.ast.FnDecl,
	mod_path: *front.ast.ValList<[]u8>
) -> *mut middle.symbol.Symbol {
	if fn_d == null || target_ty == null || fn_d.generic_params.len > 0 {
		return null;
	}
	let prev_self: *mut middle.types.StType = self.current_self_ty;
	self.current_self_ty = target_ty;

	let mut ptypes: front.ast.PtrList<middle.types.StType> = {
		.data = null,
		.len = 0,
		.cap = 0
	};
	let prev_mod: *front.ast.ValList<[]u8> = self.current_mod_path;
	if mod_path != null && mod_path.len > 0 {
		self.current_mod_path = mod_path;
	}
	for let mut i: usize = 0; i < fn_d.params.len; i += 1 {
		ptypes.push(self.resolve_type(fn_d.params.data[i].ty));
	}
	let rty: *mut middle.types.StType = fn_d.ret != null ? self.resolve_type(fn_d.ret)
		: self.tx.void_t;
	self.current_mod_path = prev_mod;
	let fty: *mut middle.types.StType = self.tx.function_of(
		ptypes,
		rty,
		fn_d.is_variadic,
		middle.types.AbiKind.Stella
	);
	ptypes.free_array();

	self.current_self_ty = prev_self;

	let mut mangled: []u8 = "";
	if target_ty.generic_args.len == 0 {
		let mut mpath: front.ast.ValList<[]u8> = { .data = null, .len = 0, .cap = 0 };
		if mod_path != null {
			for let mut k: usize = 0; k < mod_path.len; k += 1 {
				mpath.push(mod_path.data[k]);
			}
		}
		mpath.push(target_ty.name);
		mangled = middle.symbol.mangle_fn_with_sig(&mpath, fn_d.name, fty, &fn_d.attrs);
		mpath.free_array();
	} else {
		mangled = self.mangle_method_name(mod_path, target_ty, fn_d.name);
	}
	let mut sym: middle.symbol.Symbol = middle.symbol.make_symbol(
		middle.symbol.SymKind.Fn,
		fn_d.name,
		fn_d.loc
	);
	sym.mangled = mangled;
	sym.ty = fty;
	sym.fn_decl = fn_d;
	sym.is_pub = fn_d.is_pub;

	let raw: *mut u8 = front.ast.arena_alloc(@of.size(middle.symbol.Symbol));
	if raw == null {
		return null;
	}
	let ptr: *mut middle.symbol.Symbol = raw cast *mut middle.symbol.Symbol;
	*ptr = sym;
	let entry: ImplMethodEntry = {
		.target_ty = target_ty,
		.fn_decl = fn_d,
		.sym = ptr,
		.mod_path = mod_path != null ? *mod_path : { .data = null, .len = 0, .cap = 0 },
		.generic_params = { .data = null, .len = 0, .cap = 0 }
	};
	self.impl_methods.push(entry);
	return ptr;
}

/// Executes `infer_type_param` (infer type param).
pub fn infer_type_param(
	gname: []u8,
	pat: *front.ast.TypeRef,
	actual: *mut middle.types.StType
) -> *mut middle.types.StType {
	if pat == null || actual == null {
		return null;
	}
	let u: *mut middle.types.StType = middle.types.underlying_type(actual);
	match pat.kind {
		.Named => {
			let pname: []u8 = pat.path.len == 1 ? pat.path.data[0] : pat.name;
			if std.str.eq(pname, gname) {
				return actual;
			}
			if pat.generic_args.len > 0 && u != null && u.generic_args.len > 0 {
				let cnt: usize = pat.generic_args.len < u.generic_args.len
					? pat.generic_args.len : u.generic_args.len;
				for let mut i: usize = 0; i < cnt; i += 1 {
					let r: *mut middle.types.StType = SemaContext.infer_type_param(
						gname,
						pat.generic_args.data[i].ty,
						u.generic_args.data[i]
					);
					if r != null {
						return r;
					}
				}
			}
			return null;
		}
		.Pointer => {
			if u != null && u.kind == middle.types.TypeKind.Pointer {
				return SemaContext.infer_type_param(gname, pat.base, u.base);
			}
			return null;
		}
		.Slice => {
			if u != null && u.kind == middle.types.TypeKind.Slice {
				return SemaContext.infer_type_param(gname, pat.base, u.base);
			}
			if u != null && u.kind == middle.types.TypeKind.Pointer {
				let ub: *mut middle.types.StType = middle.types.underlying_type(u.base);
				if ub != null && ub.kind == middle.types.TypeKind.Array {
					return SemaContext.infer_type_param(gname, pat.base, ub.base);
				}
			}
			return null;
		}
		_ => return null
	}
}

/// Executes `instantiate_generic_fn` (instantiate generic fn).
pub fn instantiate_generic_fn(
	self: *mut SemaContext,
	origin_sym: *middle.symbol.Symbol,
	arg_exprs: *front.ast.PtrList<front.ast.Expr>,
	explicit_gargs: *front.ast.ValList<front.ast.GenericArg>
) -> *mut middle.symbol.Symbol {
	if origin_sym == null || origin_sym.fn_decl == null {
		return null;
	}
	let fn_d: *front.ast.FnDecl = origin_sym.fn_decl;
	let mut resolved: front.ast.PtrList<middle.types.StType> = {
		.data = null,
		.len = 0,
		.cap = 0
	};
	if explicit_gargs != null && explicit_gargs.len > 0 {
		for let mut i: usize = 0; i < explicit_gargs.len; i += 1 {
			if i < fn_d.generic_params.len && fn_d.generic_params.data[i].kind
				== front.ast.GenericParamKind.Const {
				let mut cval: u64 = 0;
				let ga: front.ast.GenericArg = explicit_gargs.data[i];
				if ga.value != null {
					let cv: middle.sema.const_eval.ConstVal =
						middle.sema.const_eval.eval_const_expr(
							ga.value,
							&self.scopes,
							&self.tx
						);
					if cv.kind == middle.sema.const_eval.ConstKind.Int {
						cval = cv.int_val;
					}
				} else if ga.ty != null && ga.ty.kind == front.ast.TypeRefKind.Named
					&& ga.ty.path.len == 1 {
					let csym: *middle.symbol.Symbol = self.scopes.lookup(ga.ty.path.data[0]);
					if csym != null && csym.has_const_value {
						cval = csym.const_int_val;
					}
				}
				let cw: i32 = cval > 0 ? (cval cast i32) : 1;
				resolved.push(self.tx.uint(cw));
			} else {
				resolved.push(self.resolve_type(explicit_gargs.data[i].ty));
			}
		}
	} else {
		let mut arg_tys: front.ast.PtrList<middle.types.StType> = {
			.data = null,
			.len = 0,
			.cap = 0
		};
		for let mut i: usize = 0; i < arg_exprs.len; i += 1 {
			arg_tys.push(self.check_expr(arg_exprs.data[i], null));
		}
		for let mut gi: usize = 0; gi < fn_d.generic_params.len; gi += 1 {
			let gname: []u8 = fn_d.generic_params.data[gi].name;
			let mut inferred: *mut middle.types.StType = null;
			let pcount: usize = fn_d.params.len < arg_tys.len ? fn_d.params.len : arg_tys.len;
			for let mut pi: usize = 0; pi < pcount; pi += 1 {
				if pi < arg_exprs.len && arg_exprs.data[pi] != null
					&& (arg_exprs.data[pi].kind == front.ast.ExprKind.IntLit
					|| arg_exprs.data[pi].kind == front.ast.ExprKind.FloatLit)
					&& fn_d.generic_params.data[gi].type_set.len > 0 {
					continue;
				}
				inferred = SemaContext.infer_type_param(
					gname,
					fn_d.params.data[pi].ty,
					arg_tys.data[pi]
				);
				if inferred != null {
					break;
				}
			}
			if inferred == null && fn_d.generic_params.data[gi].type_set.len > 0 {
				let mut mb: [160]u8;
				let mut mp: usize = 0;
				put_str_buf(&mb[0], &mp, 160, "no matching public function for call to `");
				put_str_buf(&mb[0], &mp, 160, fn_d.name);
				put_str_buf(&mb[0], &mp, 160, "`");
				front.log.report(
					front.log.Level.Error,
					fn_d.loc,
					mb[0..mp],
					front.log.DiagCode.InvalidCall
				);
			}
			resolved.push(inferred != null ? inferred : self.tx.poison_t);
		}
		arg_tys.free_array();
	}

	for let mut i: usize = 0; i < self.generic_fns.len; i += 1 {
		let inst: GenericFnInst = self.generic_fns.data[i];
		if inst.origin_fn == fn_d && inst.args.len == resolved.len {
			let mut all_eq: bool = true;
			for let mut j: usize = 0; j < resolved.len; j += 1 {
				if !middle.types.eq_type(inst.args.data[j], resolved.data[j]) {
					all_eq = false;
					break;
				}
			}
			if all_eq {
				resolved.free_array();
				return inst.sym;
			}
		}
	}

	let prev_len: usize = self.generic_subst.len;
	let count: usize = fn_d.generic_params.len < resolved.len ? fn_d.generic_params.len
		: resolved.len;
	for let mut i: usize = 0; i < count; i += 1 {
		if fn_d.generic_params.data[i].kind == front.ast.GenericParamKind.Const {
			let mut cval: u64 = 0;
			if explicit_gargs != null && i < explicit_gargs.len {
				let ga: front.ast.GenericArg = explicit_gargs.data[i];
				if ga.value != null {
					let cv: middle.sema.const_eval.ConstVal =
						middle.sema.const_eval.eval_const_expr(
							ga.value,
							&self.scopes,
							&self.tx
						);
					if cv.kind == middle.sema.const_eval.ConstKind.Int {
						cval = cv.int_val;
					}
				} else if ga.ty != null && ga.ty.kind == front.ast.TypeRefKind.Named
					&& ga.ty.path.len == 1 {
					let csym: *middle.symbol.Symbol = self.scopes.lookup(ga.ty.path.data[0]);
					if csym != null && csym.has_const_value {
						cval = csym.const_int_val;
					}
				}
			}
			let ge: middle.sema.generics.GenericSubstEntry = {
				.name = fn_d.generic_params.data[i].name,
				.is_const = true,
				.ty = self.tx.usize_t,
				.const_val = cval cast i64
			};
			self.generic_subst.push(ge);
			continue;
		}
		middle.sema.generics.check_type_set_constraint(
			&fn_d.generic_params.data[i],
			resolved.data[i],
			fn_d.loc
		);
		let gp_chk: *front.ast.GenericParam = &fn_d.generic_params.data[i];
		let ru_chk: *mut middle.types.StType = middle.types.underlying_type(resolved.data[i]);
		if gp_chk.trait_bounds.len > 0 && ru_chk != null {
			let is_prim: bool = ru_chk.kind == middle.types.TypeKind.UInt || ru_chk.kind
				== middle.types.TypeKind.SInt || ru_chk.kind == middle.types.TypeKind.Float
				|| ru_chk.kind == middle.types.TypeKind.Bool;
			let mut has_user_trait: bool = false;
			for let mut bi: usize = 0; bi < gp_chk.trait_bounds.len; bi += 1 {
				let btr: *front.ast.TypeRef = gp_chk.trait_bounds.data[bi];
				if btr != null {
					let bname: []u8 = btr.path.len > 0 ? btr.path.data[btr.path.len - 1]
						: btr.name;
					for let mut ti: usize = 0; ti < self.traits.len; ti += 1 {
						if std.str.eq(self.traits.data[ti].name, bname) {
							has_user_trait = true;
							break;
						}
					}
				}
			}
			if is_prim || has_user_trait {
				if !self.check_trait_bounds(gp_chk, resolved.data[i], fn_d.loc) {
					if has_user_trait && !is_prim {
						let btr0: *front.ast.TypeRef = gp_chk.trait_bounds.data[0];
						let bname0: []u8 = btr0 != null
							? (btr0.path.len > 0 ? btr0.path.data[btr0.path.len - 1]
							: btr0.name)
							: "";
						let mut tb: [64]u8;
						let tstr: []u8 = middle.types.format_type(resolved.data[i], &tb[0], 64);
						let mut mb: [160]u8;
						let mut mp: usize = 0;
						put_str_buf(&mb[0], &mp, 160, "type `");
						put_str_buf(&mb[0], &mp, 160, tstr);
						put_str_buf(&mb[0], &mp, 160, "` does not implement trait `");
						put_str_buf(&mb[0], &mp, 160, bname0);
						put_str_buf(&mb[0], &mp, 160, "`");
						front.log.report(
							front.log.Level.Error,
							fn_d.loc,
							mb[0..mp],
							front.log.DiagCode.GenericConstraint
						);
					} else {
						let mut mb: [160]u8;
						let mut mp: usize = 0;
						put_str_buf(
							&mb[0],
							&mp,
							160,
							"no matching public function for call to `"
						);
						put_str_buf(&mb[0], &mp, 160, fn_d.name);
						put_str_buf(&mb[0], &mp, 160, "`");
						front.log.report(
							front.log.Level.Error,
							fn_d.loc,
							mb[0..mp],
							front.log.DiagCode.InvalidCall
						);
					}
				}
			}
		}
		let ge: middle.sema.generics.GenericSubstEntry = {
			.name = fn_d.generic_params.data[i].name,
			.is_const = false,
			.ty = resolved.data[i],
			.const_val = 0
		};
		self.generic_subst.push(ge);
	}

	let mut ptypes: front.ast.PtrList<middle.types.StType> = {
		.data = null,
		.len = 0,
		.cap = 0
	};
	let prev_mod: *front.ast.ValList<[]u8> = self.current_mod_path;
	if origin_sym.mod_path.len > 0 {
		self.current_mod_path = &origin_sym.mod_path;
	}
	for let mut i: usize = 0; i < fn_d.params.len; i += 1 {
		ptypes.push(self.resolve_type(fn_d.params.data[i].ty));
	}
	let rty: *mut middle.types.StType = fn_d.ret != null ? self.resolve_type(fn_d.ret)
		: self.tx.void_t;
	self.current_mod_path = prev_mod;
	let fty: *mut middle.types.StType = self.tx.function_of(
		ptypes,
		rty,
		fn_d.is_variadic,
		middle.types.AbiKind.Stella
	);
	ptypes.free_array();

	let idx: usize = self.generic_fns.len;
	let mut mangled: []u8 = fn_d.name;
	let total: usize = 4 + fn_d.name.len + 5;
	let buf: *mut u8 = front.ast.arena_alloc(total);
	if buf != null {
		buf[0] = 's' cast u8;
		buf[1] = 't' cast u8;
		buf[2] = 'g' cast u8;
		buf[3] = '$' cast u8;
		std.mem.copy(&buf[4], fn_d.name.ptr, fn_d.name.len);
		let mut pos: usize = 4 + fn_d.name.len;
		buf[pos] = '$' cast u8;
		pos += 1;
		for let mut d: usize = 0; d < 4; d += 1 {
			let nib: u8 = ((idx >> ((3 - d) * 4)) & 0xF) cast u8;
			buf[pos] = nib < 10 ? ('0' cast u8 + nib) : ('a' cast u8 + (nib - 10));
			pos += 1;
		}
		mangled = buf[0..pos];
	}

		let mut sym: middle.symbol.Symbol = middle.symbol.make_symbol(
			middle.symbol.SymKind.Fn,
			fn_d.name,
			fn_d.loc
		);
		sym.mangled = mangled;
		sym.ty = fty;
		sym.fn_decl = fn_d;
		sym.is_pub = fn_d.is_pub;

		let mut sym_ptr: *mut middle.symbol.Symbol = null;
		let raw: *mut u8 = front.ast.arena_alloc(@of.size(middle.symbol.Symbol));
		if raw != null {
			sym_ptr = raw cast *mut middle.symbol.Symbol;
			*sym_ptr = sym;
		}
		let mut extra_sub: front.ast.ValList<middle.sema.generics.GenericSubstEntry> = {
			.data = null,
			.len = 0,
			.cap = 0
		};
		for let mut ei: usize = 0; ei < prev_len; ei += 1 {
			extra_sub.push(self.generic_subst.data[ei]);
		}
		let inst: GenericFnInst = {
			.origin_fn = fn_d,
			.args = resolved,
			.sym = sym_ptr,
			.mod_path = origin_sym.mod_path,
			.self_ty = self.current_self_ty,
			.extra_subst = extra_sub
		};
		self.generic_fns.push(inst);

		if !fn_d.is_extern && fn_d.body != null && !fn_d.is_macro {
			let prev_mod: *front.ast.ValList<[]u8> = self.current_mod_path;
			if origin_sym.mod_path.len > 0 {
				self.current_mod_path = &origin_sym.mod_path;
			}
			self.scopes.enter();
			let prev_ret: *mut middle.types.StType = self.current_ret_ty;
			self.current_ret_ty = rty;
			for let mut i: usize = 0; i < fn_d.params.len; i += 1 {
				let prm: front.ast.Param = fn_d.params.data[i];
				let mut psym: middle.symbol.Symbol = middle.symbol.make_symbol(
					middle.symbol.SymKind.Param,
					prm.name,
					prm.loc
				);
				psym.ty = fty.fn_params.data[i];
				psym.is_mutable = prm.is_mutable;
				self.scopes.define(psym);
			}
			self.check_stmt(fn_d.body);
			self.current_ret_ty = prev_ret;
			self.scopes.leave();
			self.current_mod_path = prev_mod;
		}

		self.generic_subst.len = prev_len;
		return sym_ptr;
	}


impl SemaContext {
	/// Executes `instantiate_mapper_for_arg`.
	pub fn instantiate_mapper_for_arg(
		self: *mut SemaContext,
		msym: *middle.symbol.Symbol,
		arg: *mut front.ast.Expr
	) -> void {
		if msym == null || arg == null {
			return;
		}
		let aty: *mut middle.types.StType = arg.sema_ty != null
			? (arg.sema_ty cast *mut middle.types.StType)
			: self.tx.void_t;
		for let mut qi: usize = 0; qi < self.imported_syms.len; qi += 1 {
			let qs: QualifiedSym = self.imported_syms.data[qi];
			if qs.sym == null || qs.sym.fn_decl == null
				|| qs.sym.fn_decl.generic_params.len > 0
				|| !std.str.eq(qs.sym.simple, msym.simple) {
				continue;
			}
			if !SemaContext.mod_paths_equal(&qs.mod_path, &msym.mod_path) {
				continue;
			}
			let cqu: *mut middle.types.StType = qs.sym.ty != null
				? middle.types.underlying_type(qs.sym.ty)
				: null;
			if cqu != null && cqu.fn_params.len == 1
				&& middle.types.is_assignable_type(cqu.fn_params.data[0], aty) {
				return;
			}
		}
		let mut one: front.ast.PtrList<front.ast.Expr> = { .data = null, .len = 0, .cap = 0 };
		one.push(arg);
		for let mut qi: usize = 0; qi < self.imported_syms.len; qi += 1 {
			let qs: QualifiedSym = self.imported_syms.data[qi];
			if qs.sym == null || qs.sym.fn_decl == null
				|| qs.sym.fn_decl.generic_params.len != 1
				|| !std.str.eq(qs.sym.simple, msym.simple) {
				continue;
			}
			if !SemaContext.mod_paths_equal(&qs.mod_path, &msym.mod_path) {
				continue;
			}
			let gp: *front.ast.GenericParam = &qs.sym.fn_decl.generic_params.data[0];
			if middle.sema.generics.matches_type_set_constraint(gp, aty) {
				self.instantiate_generic_fn(qs.sym, &one, null);
				break;
			}
		}
		one.free_array();
	}

	/// Walks an expression in a macro body to instantiate variadic splice mappers.
	pub fn instantiate_variadic_mappers_expr(
		self: *mut SemaContext,
		me: *front.ast.Expr,
		call_e: *front.ast.Expr,
		fixed_argc: usize
	) -> void {
		if me == null {
			return;
		}
		if me.kind == front.ast.ExprKind.Call && me.args.len == 1 && me.args.data[0] != null
			&& me.args.data[0].kind == front.ast.ExprKind.VariadicSplice
			&& me.lhs != null && me.lhs.sema_sym != null {
			let msym: *middle.symbol.Symbol = me.lhs.sema_sym cast *middle.symbol.Symbol;
			for let mut i: usize = fixed_argc; i < call_e.args.len; i += 1 {
				self.instantiate_mapper_for_arg(msym, call_e.args.data[i]);
			}
			return;
		}
		self.instantiate_variadic_mappers_expr(me.lhs, call_e, fixed_argc);
		self.instantiate_variadic_mappers_expr(me.rhs, call_e, fixed_argc);
		self.instantiate_variadic_mappers_expr(me.condition, call_e, fixed_argc);
		self.instantiate_variadic_mappers_expr(me.then_expr, call_e, fixed_argc);
		self.instantiate_variadic_mappers_expr(me.else_expr, call_e, fixed_argc);
		for let mut i: usize = 0; i < me.args.len; i += 1 {
			self.instantiate_variadic_mappers_expr(me.args.data[i], call_e, fixed_argc);
		}
	}

	/// Walks a statement in a macro body to instantiate variadic splice mappers.
	pub fn instantiate_variadic_mappers_stmt(
		self: *mut SemaContext,
		ms: *front.ast.Stmt,
		call_e: *front.ast.Expr,
		fixed_argc: usize
	) -> void {
		if ms == null {
			return;
		}
		self.instantiate_variadic_mappers_expr(ms.expr, call_e, fixed_argc);
		self.instantiate_variadic_mappers_expr(ms.ret_val, call_e, fixed_argc);
		self.instantiate_variadic_mappers_expr(ms.cond, call_e, fixed_argc);
		self.instantiate_variadic_mappers_stmt(ms.then_block, call_e, fixed_argc);
		self.instantiate_variadic_mappers_stmt(ms.else_block, call_e, fixed_argc);
		self.instantiate_variadic_mappers_stmt(ms.loop_body, call_e, fixed_argc);
		for let mut i: usize = 0; i < ms.body.len; i += 1 {
			self.instantiate_variadic_mappers_stmt(ms.body.data[i], call_e, fixed_argc);
		}
	}

	/// Executes `recheck_fn_body` (recheck fn body).
	pub fn recheck_fn_body(
		self: *mut SemaContext,
		fn_decl: *front.ast.FnDecl,
		fn_ty: *mut middle.types.StType
	) -> void {
		if fn_decl == null || fn_decl.body == null || fn_ty == null {
			return;
		}
		self.scopes.enter();
		let prev_ret: *mut middle.types.StType = self.current_ret_ty;
		let prev_imp: bool = self.in_imported_mod;
		self.current_ret_ty = fn_ty.fn_ret;
		self.in_imported_mod = true;
		for let mut i: usize = 0; i < fn_decl.params.len; i += 1 {
			let prm: front.ast.Param = fn_decl.params.data[i];
			let mut psym: middle.symbol.Symbol = middle.symbol.make_symbol(
				middle.symbol.SymKind.Param,
				prm.name,
				prm.loc
			);
			psym.ty = i < fn_ty.fn_params.len ? fn_ty.fn_params.data[i] : self.tx.void_t;
			psym.is_mutable = prm.is_mutable;
			self.scopes.define(psym);
		}
		self.check_stmt(fn_decl.body);
		self.in_imported_mod = prev_imp;
		self.current_ret_ty = prev_ret;
		self.scopes.leave();
	}

}
