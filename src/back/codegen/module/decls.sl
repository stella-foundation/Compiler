mod back.codegen.module;
import "back/codegen/expressions.sl";
import "back/codegen/statements.sl";
import "back/codegen/types.sl";
import "back/llvm_ctx.sl";
import "front/ast.sl";
import "llvm/core.sl";
import "llvm/ir.sl";
import "llvm/llvm.sl";
import "middle/sema/generics.sl";
import "middle/sema/validation.sl";
import "middle/symbol.sl";
import "middle/types.sl";
import "std/str.sl";

/// Executes `apply_fn_abi_attrs`.
pub fn apply_fn_abi_attrs(
	cg: *mut back.codegen.expressions.CodegenState,
	fn_val: bind.llvm.core.Value,
	fn_st: *mut middle.types.StType,
	is_main: bool
) -> void {
	if fn_st == null {
		return;
	}
	let u: *mut middle.types.StType = middle.types.underlying_type(fn_st);
	if u == null || u.kind != middle.types.TypeKind.Function {
		return;
	}
	if u.fn_abi == middle.types.AbiKind.Stella && !is_main {
		bind.llvm.core.set_function_call_conv(fn_val, 8);
		return;
	}
	if u.fn_abi == middle.types.AbiKind.C {
		let ret_abi: back.codegen.types.CAbiArg = back.codegen.types.classify_c_abi(
			&cg.lc.ctx,
			&cg.lc.td,
			u.fn_ret,
			true
		);
		let mut p_idx: u32 = 1;
		if ret_abi.kind == back.codegen.types.CAbiKind.SRet {
			let sret_k: u32 = bind.llvm.core.enum_attr_kind(c"sret", 4);
			let sret_a: *void = bind.llvm.core.create_type_attr(
				&cg.lc.ctx,
				sret_k,
				ret_abi.storage_ty
			);
			bind.llvm.core.add_fn_attr_at_index(fn_val, p_idx, sret_a);
			p_idx += 1;
		}
		for let mut i: usize = 0; i < u.fn_params.len; i += 1 {
			let pa: back.codegen.types.CAbiArg = back.codegen.types.classify_c_abi(
				&cg.lc.ctx,
				&cg.lc.td,
				u.fn_params.data[i],
				false
			);
			if pa.kind == back.codegen.types.CAbiKind.ByVal {
				let byval_k: u32 = bind.llvm.core.enum_attr_kind(c"byval", 5);
				let byval_a: *void = bind.llvm.core.create_type_attr(
					&cg.lc.ctx,
					byval_k,
					pa.storage_ty
				);
				bind.llvm.core.add_fn_attr_at_index(fn_val, p_idx, byval_a);
			}
			p_idx += 1;
		}
	}
}

/// Executes `find_attr_val`.
pub fn find_attr_val(attrs: *front.ast.AttributeList, name: []u8) -> []u8 {
	for let mut i: usize = 0; i < attrs.attrs.len; i += 1 {
		let a: front.ast.Attribute = attrs.attrs.data[i];
		if !a.negated && std.str.eq(a.name, name) && a.args.len > 0 {
			return a.args.data[0];
		}
	}
	return "";
}

/// Executes `mangle_fn_name_in_mod`.
pub fn mangle_fn_name_in_mod(fn_d: *front.ast.FnDecl, mod_path: *front.ast.ValList<[]u8>) -> []u8 {
	if std.str.eq(fn_d.name, "main") {
		if fn_d.params.len == 2 {
			return "st$main(usize,**u8)";
		}
		return "st$main()";
	}
	return middle.symbol.mangle_symbol_name(mod_path, fn_d.name, &fn_d.attrs);
}

/// Executes `emit_global_decl`.
pub fn emit_global_decl(
	cg: *mut back.codegen.expressions.CodegenState,
	gd: *front.ast.GlobalDecl
) -> void {
	if gd == null {
		return;
	}
	let sym: *middle.symbol.Symbol = cg.sema.scopes.lookup(gd.name);
	let st_ty: *mut middle.types.StType = sym != null && sym.ty != null
		? sym.ty
		: cg.sema.resolve_type(gd.ty);
	let ll_ty: bind.llvm.core.Type = back.codegen.types.to_llvm_type(&cg.lc.ctx, &cg.lc.td, st_ty);
	let mangled: []u8 = (!gd.is_pub && !gd.is_extern)
		? middle.symbol.mangle_private_global_name(gd.name, gd.loc.file)
		: (sym != null ? sym.mangled : gd.name);
	let cname: *mut u8 = back.codegen.expressions.cstr_from_slice(mangled);
	let mut gv: bind.llvm.core.Value = bind.llvm.core.add_global(
		&cg.lc.mod_ref,
		ll_ty,
		cname != null ? (cname cast *u8) : c"glob"
	);
	if !gd.is_extern {
		let mut init_val: bind.llvm.core.Value = bind.llvm.core.constant.null_value(ll_ty);
		if sym != null && sym.has_const_value {
			if sym.const_value_is_float {
				init_val = bind.llvm.core.constant.real(ll_ty, sym.const_flt_val);
			} else if st_ty.kind == middle.types.TypeKind.Bool {
				init_val = bind.llvm.core.constant.integer(
					ll_ty,
					sym.const_bool_val ? (1 cast u64) : (0 cast u64),
					false
				);
			} else {
				let is_signed: bool = middle.types.underlying_type(st_ty).kind
					== middle.types.TypeKind.SInt;
				init_val = bind.llvm.core.constant.integer(ll_ty, sym.const_int_val, is_signed);
			}
		} else if gd.init != null && gd.init.kind == front.ast.ExprKind.IntLit {
			let is_signed: bool = middle.types.underlying_type(st_ty).kind
				== middle.types.TypeKind.SInt;
			init_val = bind.llvm.core.constant.integer(ll_ty, gd.init.int_val, is_signed);
		} else if gd.init != null && gd.init.kind == front.ast.ExprKind.FloatLit {
			init_val = bind.llvm.core.constant.real(ll_ty, gd.init.flt_val);
		} else if gd.init != null && gd.init.kind == front.ast.ExprKind.BoolLit {
			init_val = bind.llvm.core.constant.integer(
				ll_ty,
				gd.init.int_val != 0 ? (1 cast u64) : (0 cast u64),
				false
			);
		} else if gd.init != null
			&& (gd.init.kind == front.ast.ExprKind.StringLit || gd.init.kind
			== front.ast.ExprKind.SrcEmbed) {
			let s: []u8 = gd.init.str_val;
			let st_u: *mut middle.types.StType = middle.types.underlying_type(st_ty);
			if st_u != null && st_u.kind == middle.types.TypeKind.Array {
				init_val = bind.llvm.core.constant.string(
					&cg.lc.ctx,
					s.len > 0 ? s.ptr : c"",
					s.len,
					!gd.init.is_cstring
				);
			} else {
				let arr_sz: u64 = (s.len + 1) cast u64;
				let arr_ty: bind.llvm.core.Type = bind.llvm.core.type.array(
					bind.llvm.core.type.int8(&cg.lc.ctx),
					arr_sz
				);
				let mut gstr: bind.llvm.core.Value = bind.llvm.core.add_global(
					&cg.lc.mod_ref,
					arr_ty,
					c".gstr"
				);
				let cstr_val: bind.llvm.core.Value = bind.llvm.core.constant.string(
					&cg.lc.ctx,
					s.len > 0 ? s.ptr : c"",
					s.len,
					false
				);
				bind.llvm.core.set_initializer(&gstr, cstr_val);
				bind.llvm.core.set_global_constant(&gstr, true);
				bind.llvm.core.set_linkage(&gstr, bind.llvm.Linkage.Private);
				if st_u != null && st_u.kind == middle.types.TypeKind.Pointer {
					init_val = gstr;
				} else if st_u != null && st_u.kind == middle.types.TypeKind.Slice {
					let len_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
						&cg.lc.ctx,
						&cg.lc.td,
						cg.sema.tx.usize_t
					);
					let len_v: bind.llvm.core.Value = bind.llvm.core.constant.integer(
						len_ll,
						s.len cast u64,
						false
					);
					let mut elems: [2]*void;
					elems[0] = gstr.handle;
					elems[1] = len_v.handle;
					init_val = bind.llvm.core.constant.struct_val(&cg.lc.ctx, &elems[0], 2, false);
				}
			}
		}
		bind.llvm.core.set_initializer(&gv, init_val);
	}
	if gd.is_const {
		bind.llvm.core.set_global_constant(&gv, true);
	}
	if !gd.is_pub && !gd.is_extern {
		bind.llvm.core.set_linkage(&gv, bind.llvm.Linkage.Internal);
	}
	let sec: []u8 = find_attr_val(&gd.attrs, "section");
	if sec.len > 0 {
		let csec: *mut u8 = back.codegen.expressions.cstr_from_slice(sec);
		if csec != null {
			bind.llvm.core.set_section(&gv, csec);
		}
	}
	let gs: back.codegen.expressions.GlobalSlot = {
		.name = mangled,
		.ptr = gv,
		.st_ty = st_ty,
		.ll_ty = ll_ty
	};
	back.codegen.expressions.add_global_slot(cg, gs);
}

/// Executes `declare_fn_in_mod`.
pub fn declare_fn_in_mod(
	cg: *mut back.codegen.expressions.CodegenState,
	fn_d: *front.ast.FnDecl,
	mod_path: *front.ast.ValList<[]u8>
) -> void {
	if fn_d == null || fn_d.is_macro || fn_d.generic_params.len > 0 {
		return;
	}
	let mut sym: *middle.symbol.Symbol = cg.sema.lookup_fn_by_decl(mod_path, fn_d);
	if sym == null {
		sym = cg.sema.scopes.lookup(fn_d.name);
	}
	let mangled: []u8 = (sym != null && !std.str.eq(fn_d.name, "main")) ? sym.mangled
		: mangle_fn_name_in_mod(fn_d, mod_path);
	if back.codegen.expressions.find_function(cg, mangled) != null {
		return;
	}
	let mut fn_st: *mut middle.types.StType = sym != null ? sym.ty : null;
	if fn_st == null {
		let mut ptypes: front.ast.PtrList<middle.types.StType> = {
			.data = null,
			.len = 0,
			.cap = 0
		};
		for let mut i: usize = 0; i < fn_d.params.len; i += 1 {
			ptypes.push(cg.sema.resolve_type(fn_d.params.data[i].ty));
		}
		let rty: *mut middle.types.StType = fn_d.ret != null ? cg.sema.resolve_type(fn_d.ret)
			: cg.sema.tx.void_t;
		fn_st = cg.sema.tx.function_of(ptypes, rty, fn_d.is_variadic, middle.types.AbiKind.Stella);
		ptypes.free_array();
	}
	let fn_ll_ty: bind.llvm.core.Type = back.codegen.types.to_llvm_fn_type(
		&cg.lc.ctx,
		&cg.lc.td,
		fn_st
	);
	let cname: *mut u8 = back.codegen.expressions.cstr_from_slice(mangled);
	let mut fn_val: bind.llvm.core.Value = bind.llvm.core.add_function(
		&cg.lc.mod_ref,
		cname != null ? (cname cast *u8) : c"fn",
		fn_ll_ty
	);
	apply_fn_abi_attrs(cg, fn_val, fn_st, std.str.eq(fn_d.name, "main"));
	let sec: []u8 = find_attr_val(&fn_d.attrs, "section");
	if sec.len > 0 {
		let csec: *mut u8 = back.codegen.expressions.cstr_from_slice(sec);
		if csec != null {
			bind.llvm.core.set_section(&fn_val, csec);
		}
	}
	let fs: back.codegen.expressions.FnSlot = {
		.name = mangled,
		.fn_val = fn_val,
		.fn_ll_ty = fn_ll_ty,
		.st_ty = fn_st
	};
	back.codegen.expressions.add_function_slot(cg, fs);
}

/// Executes `emit_fn_body_in_mod`.
pub fn emit_fn_body_in_mod(
	cg: *mut back.codegen.expressions.CodegenState,
	fn_d: *front.ast.FnDecl,
	mod_path: *front.ast.ValList<[]u8>
) -> void {
	if fn_d == null || fn_d.is_extern || fn_d.body == null || fn_d.is_macro
		|| fn_d.generic_params.len > 0 {
		return;
	}
	let sym: *middle.symbol.Symbol = cg.sema.lookup_fn_by_decl(mod_path, fn_d);
	let mangled: []u8 = (sym != null && !std.str.eq(fn_d.name, "main")) ? sym.mangled
		: mangle_fn_name_in_mod(fn_d, mod_path);
	let fs: *mut back.codegen.expressions.FnSlot = back.codegen.expressions.find_function(
		cg,
		mangled
	);
	if fs == null {
		return;
	}
	if !fn_d.is_pub && !fn_d.is_extern && !std.str.eq(fn_d.name, "main") {
		bind.llvm.core.set_linkage(&fs.fn_val, bind.llvm.Linkage.Internal);
	}
	cg.current_fn = fs.fn_val;
	cg.current_fn_ret = fs.st_ty != null ? fs.st_ty.fn_ret : cg.sema.tx.void_t;
	cg.locals.len = 0;
	cg.defers.len = 0;
	cg.loop_stack.len = 0;
	cg.scope_depth = 1;

	let entry_bb: *void = bind.llvm.core.append_basic_block(&cg.lc.ctx, fs.fn_val, c"entry");
	bind.llvm.ir.position_at_end(&cg.lc.builder, entry_bb);

	for let mut i: usize = 0; i < fn_d.params.len; i += 1 {
		let prm: front.ast.Param = fn_d.params.data[i];
		let pst: *mut middle.types.StType = (fs.st_ty != null && i < fs.st_ty.fn_params.len)
			? fs.st_ty.fn_params.data[i]
			: cg.sema.resolve_type(prm.ty);
		let pll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(&cg.lc.ctx, &cg.lc.td, pst);
		let cname: *mut u8 = back.codegen.expressions.cstr_from_slice(prm.name);
		let alloca_ptr: bind.llvm.core.Value = bind.llvm.ir.alloca(
			&cg.lc.builder,
			pll,
			cname != null ? (cname cast *u8) : c"arg"
		);
		let param_val: bind.llvm.core.Value = bind.llvm.core.param(&fs.fn_val, i cast u32);
		bind.llvm.ir.store(&cg.lc.builder, param_val, alloca_ptr);
		let ls: back.codegen.expressions.LocalSlot = {
			.name = prm.name,
			.ptr = alloca_ptr,
			.st_ty = pst,
			.ll_ty = pll,
			.scope_depth = 1
		};
		cg.locals.push(ls);
	}

	back.codegen.statements.emit_stmt(cg, fn_d.body);

	if !back.codegen.expressions.block_has_terminator(cg) {
		if cg.current_fn_ret == null || middle.types.underlying_type(cg.current_fn_ret).kind
			== middle.types.TypeKind.Void {
			bind.llvm.ir.ret_void(&cg.lc.builder);
		} else {
			let ret_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
				&cg.lc.ctx,
				&cg.lc.td,
				cg.current_fn_ret
			);
			bind.llvm.ir.ret(&cg.lc.builder, bind.llvm.core.constant.null_value(ret_ll));
		}
	}
	cg.locals.len = 0;
	cg.defers.len = 0;
	cg.scope_depth = 0;
}
