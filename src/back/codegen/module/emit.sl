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


/// Executes `declare_impl_method`.
pub fn declare_impl_method(
	cg: *mut back.codegen.expressions.CodegenState,
	entry: *middle.sema.validation.ImplMethodEntry
) -> void {
	if entry == null || entry.fn_decl == null || entry.sym == null || entry.sym.ty == null {
		return;
	}
	if back.codegen.expressions.find_function(cg, entry.sym.mangled) != null {
		return;
	}
	let fn_ll_ty: bind.llvm.core.Type = back.codegen.types.to_llvm_fn_type(
		&cg.lc.ctx,
		&cg.lc.td,
		entry.sym.ty
	);
	let cname: *mut u8 = back.codegen.expressions.cstr_from_slice(entry.sym.mangled);
	let mut fn_val: bind.llvm.core.Value = bind.llvm.core.add_function(
		&cg.lc.mod_ref,
		cname != null ? (cname cast *u8) : c"method",
		fn_ll_ty
	);
	let is_generic_impl: bool = (entry.target_ty != null && entry.target_ty.generic_args.len > 0)
		|| entry.generic_params.len > 0;
	if !entry.fn_decl.is_pub && (entry.target_ty == null || !entry.target_ty.is_pub) {
		bind.llvm.core.set_linkage(&fn_val, bind.llvm.Linkage.Internal);
	} else if is_generic_impl {
		bind.llvm.core.set_linkage(&fn_val, bind.llvm.Linkage.LinkOnceODR);
	} else {
		bind.llvm.core.set_linkage(&fn_val, bind.llvm.Linkage.External);
	}
	apply_fn_abi_attrs(cg, fn_val, entry.sym.ty, false);
	let fs: back.codegen.expressions.FnSlot = {
		.name = entry.sym.mangled,
		.fn_val = fn_val,
		.fn_ll_ty = fn_ll_ty,
		.st_ty = entry.sym.ty
	};
	back.codegen.expressions.add_function_slot(cg, fs);
}

/// Executes `declare_instantiated_fns` (declare instantiated fns).
pub fn declare_instantiated_fns(cg: *mut back.codegen.expressions.CodegenState) -> void {
	for let mut i: usize = 0; i < cg.sema.impl_methods.len; i += 1 {
		declare_impl_method(cg, &cg.sema.impl_methods.data[i]);
	}
	for let mut i: usize = 0; i < cg.sema.generic_fns.len; i += 1 {
		let ginst: middle.sema.validation.GenericFnInst = cg.sema.generic_fns.data[i];
		if ginst.sym != null && ginst.sym.ty != null
			&& back.codegen.expressions.find_function(cg, ginst.sym.mangled) == null {
			let fn_ll_ty: bind.llvm.core.Type = back.codegen.types.to_llvm_fn_type(
				&cg.lc.ctx,
				&cg.lc.td,
				ginst.sym.ty
			);
			let cname: *mut u8 = back.codegen.expressions.cstr_from_slice(ginst.sym.mangled);
			let mut fn_val: bind.llvm.core.Value = bind.llvm.core.add_function(
				&cg.lc.mod_ref,
				cname != null ? (cname cast *u8) : c"gfn",
				fn_ll_ty
			);
			bind.llvm.core.set_linkage(&fn_val, bind.llvm.Linkage.LinkOnceODR);
			apply_fn_abi_attrs(cg, fn_val, ginst.sym.ty, false);
			let fs: back.codegen.expressions.FnSlot = {
				.name = ginst.sym.mangled,
				.fn_val = fn_val,
				.fn_ll_ty = fn_ll_ty,
				.st_ty = ginst.sym.ty
			};
			back.codegen.expressions.add_function_slot(cg, fs);
		}
	}
}

/// Executes `emit_module` (emit module).
pub fn emit_module(cg: *mut back.codegen.expressions.CodegenState, m: *front.ast.Module) -> bool {
	if m == null {
		return true;
	}
	cg.has_emit_stmt_cb = true;
	cg.emit_stmt_cb = back.codegen.statements.emit_stmt;
	let root_mod: *front.ast.ValList<[]u8> = m.mod_path.len > 0 ? &m.mod_path : null;
	for let mut i: usize = 0; i < m.decls.len; i += 1 {
		let td: *front.ast.TopDecl = m.decls.data[i];
		if td.kind == front.ast.TopKind.Mod && td.mod_decl != null {
			let mut child: front.ast.ValList<[]u8> = { .data = null, .len = 0, .cap = 0 };
			for let mut k: usize = 0; k < m.mod_path.len; k += 1 {
				child.push(m.mod_path.data[k]);
			}
			child.push(td.mod_decl.name);
			declare_decls_in_mod(cg, &td.mod_decl.body, &child);
		} else if (td.kind == front.ast.TopKind.Var || td.kind == front.ast.TopKind.Const)
			&& td.glob != null {
			emit_global_decl(cg, td.glob);
		} else if td.kind == front.ast.TopKind.Fn && td.fn_decl != null {
			declare_fn_in_mod(cg, td.fn_decl, root_mod);
		}
	}
	declare_instantiated_fns(cg);
	for let mut i: usize = 0; i < m.decls.len; i += 1 {
		let td: *front.ast.TopDecl = m.decls.data[i];
		if td.kind == front.ast.TopKind.Mod && td.mod_decl != null {
			let mut child: front.ast.ValList<[]u8> = { .data = null, .len = 0, .cap = 0 };
			for let mut k: usize = 0; k < m.mod_path.len; k += 1 {
				child.push(m.mod_path.data[k]);
			}
			child.push(td.mod_decl.name);
			emit_decls_bodies_in_mod(cg, &td.mod_decl.body, &child);
		} else if td.kind == front.ast.TopKind.Fn && td.fn_decl != null {
			emit_fn_body_in_mod(cg, td.fn_decl, root_mod);
		}
	}
	for let mut i: usize = 0; i < cg.sema.impl_methods.len; i += 1 {
		let entry: middle.sema.validation.ImplMethodEntry = cg.sema.impl_methods.data[i];
		if entry.fn_decl != null && !entry.fn_decl.is_extern && entry.fn_decl.body != null {
			let prev_mod: *front.ast.ValList<[]u8> = cg.sema.current_mod_path;
			cg.sema.current_mod_path = &entry.mod_path;
			let fs: *mut back.codegen.expressions.FnSlot = back.codegen.expressions.find_function(
				cg,
				entry.sym.mangled
			);
			if fs != null {
				let prev_self: *mut middle.types.StType = cg.sema.current_self_ty;
				cg.sema.current_self_ty = entry.target_ty;
				let prev_subst: usize = cg.sema.generic_subst.len;
				if entry.target_ty != null && entry.generic_params.len > 0
					&& entry.target_ty.generic_args.len > 0 {
					let gcount: usize = entry.generic_params.len < entry.target_ty.generic_args.len
						? entry.generic_params.len
						: entry.target_ty.generic_args.len;
					for let mut gi: usize = 0; gi < gcount; gi += 1 {
						let ge: middle.sema.generics.GenericSubstEntry = {
							.name = entry.generic_params.data[gi].name,
							.is_const = false,
							.ty = entry.target_ty.generic_args.data[gi],
							.const_val = 0
						};
						cg.sema.generic_subst.push(ge);
					}
				}
				// Emit method body using fs directly
				cg.current_fn = fs.fn_val;
				cg.current_fn_ret = fs.st_ty != null ? fs.st_ty.fn_ret : cg.sema.tx.void_t;
				cg.locals.len = 0;
				cg.defers.len = 0;
				cg.loop_stack.len = 0;
				cg.scope_depth = 1;
				let entry_bb: *void = bind.llvm.core.append_basic_block(
					&cg.lc.ctx,
					fs.fn_val,
					c"entry"
				);
				bind.llvm.ir.position_at_end(&cg.lc.builder, entry_bb);
				for let mut pi: usize = 0; pi < entry.fn_decl.params.len; pi += 1 {
					let prm: front.ast.Param = entry.fn_decl.params.data[pi];
					let pst: *mut middle.types.StType = (fs.st_ty != null && pi
						< fs.st_ty.fn_params.len)
						? fs.st_ty.fn_params.data[pi]
						: cg.sema.resolve_type(prm.ty);
					let pll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
						&cg.lc.ctx,
						&cg.lc.td,
						pst
					);
					let cname: *mut u8 = back.codegen.expressions.cstr_from_slice(prm.name);
					let alloca_ptr: bind.llvm.core.Value = bind.llvm.ir.alloca(
						&cg.lc.builder,
						pll,
						cname != null ? (cname cast *u8) : c"arg"
					);
					let param_val: bind.llvm.core.Value = bind.llvm.core.param(
						&fs.fn_val,
						pi cast u32
					);
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
				cg.sema.recheck_fn_body(entry.fn_decl, fs.st_ty);
				back.codegen.statements.emit_stmt(cg, entry.fn_decl.body);
				if !back.codegen.expressions.block_has_terminator(cg) {
					if cg.current_fn_ret == null
						|| middle.types.underlying_type(cg.current_fn_ret).kind
						== middle.types.TypeKind.Void {
						bind.llvm.ir.ret_void(&cg.lc.builder);
					} else {
						let ret_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
							&cg.lc.ctx,
							&cg.lc.td,
							cg.current_fn_ret
						);
						bind.llvm.ir.ret(
							&cg.lc.builder,
							bind.llvm.core.constant.null_value(ret_ll)
						);
					}
				}
				cg.locals.len = 0;
				cg.defers.len = 0;
				cg.scope_depth = 0;
				cg.sema.current_self_ty = prev_self;
				cg.sema.generic_subst.len = prev_subst;
				cg.sema.current_self_ty = prev_self;
			}
			cg.sema.current_mod_path = prev_mod;
		}
	}
	for let mut i: usize = 0; i < cg.sema.generic_fns.len; i += 1 {
		let ginst: middle.sema.validation.GenericFnInst = cg.sema.generic_fns.data[i];
		if ginst.origin_fn != null && !ginst.origin_fn.is_extern && ginst.origin_fn.body != null
			&& !ginst.origin_fn.is_macro && ginst.sym != null {
			let fs: *mut back.codegen.expressions.FnSlot = back.codegen.expressions.find_function(
				cg,
				ginst.sym.mangled
			);
			if fs != null {
				let prev_subst: usize = cg.sema.generic_subst.len;
				let prev_self: *mut middle.types.StType = cg.sema.current_self_ty;
				if ginst.self_ty != null {
					cg.sema.current_self_ty = ginst.self_ty;
				}
				for let mut ei: usize = 0; ei < ginst.extra_subst.len; ei += 1 {
					cg.sema.generic_subst.push(ginst.extra_subst.data[ei]);
				}
				let gcount: usize = ginst.origin_fn.generic_params.len < ginst.args.len
					? ginst.origin_fn.generic_params.len
					: ginst.args.len;
				for let mut gi: usize = 0; gi < gcount; gi += 1 {
					let is_c: bool = ginst.origin_fn.generic_params.data[gi].kind
						== front.ast.GenericParamKind.Const;
					let ge: middle.sema.generics.GenericSubstEntry = {
						.name = ginst.origin_fn.generic_params.data[gi].name,
						.is_const = is_c,
						.ty = ginst.args.data[gi],
						.const_val = is_c && ginst.args.data[gi] != null
							? (ginst.args.data[gi].width cast i64) : 0
					};
					cg.sema.generic_subst.push(ge);
				}
				cg.current_fn = fs.fn_val;
				cg.current_fn_ret = fs.st_ty != null ? fs.st_ty.fn_ret : cg.sema.tx.void_t;
				cg.locals.len = 0;
				cg.defers.len = 0;
				cg.loop_stack.len = 0;
				cg.scope_depth = 1;
				let entry_bb: *void = bind.llvm.core.append_basic_block(
					&cg.lc.ctx,
					fs.fn_val,
					c"entry"
				);
				bind.llvm.ir.position_at_end(&cg.lc.builder, entry_bb);
				for let mut pi: usize = 0; pi < ginst.origin_fn.params.len; pi += 1 {
					let prm: front.ast.Param = ginst.origin_fn.params.data[pi];
					let pst: *mut middle.types.StType = (fs.st_ty != null && pi
						< fs.st_ty.fn_params.len)
						? fs.st_ty.fn_params.data[pi]
						: cg.sema.tx.void_t;
					let pll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
						&cg.lc.ctx,
						&cg.lc.td,
						pst
					);
					let cname: *mut u8 = back.codegen.expressions.cstr_from_slice(prm.name);
					let alloca_ptr: bind.llvm.core.Value = back.codegen.expressions.alloca_in_entry(
						cg,
						pll,
						cname != null ? (cname cast *u8) : c"arg"
					);
					let param_val: bind.llvm.core.Value = bind.llvm.core.param(
						&fs.fn_val,
						pi cast u32
					);
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
				let prev_mod: *front.ast.ValList<[]u8> = cg.sema.current_mod_path;
				if ginst.mod_path.len > 0 {
					cg.sema.current_mod_path = &ginst.mod_path;
				}
				cg.sema.recheck_fn_body(ginst.origin_fn, fs.st_ty);
				back.codegen.statements.emit_stmt(cg, ginst.origin_fn.body);
				cg.sema.current_mod_path = prev_mod;
				if !back.codegen.expressions.block_has_terminator(cg) {
					if cg.current_fn_ret == null
						|| middle.types.underlying_type(cg.current_fn_ret).kind
						== middle.types.TypeKind.Void {
						bind.llvm.ir.ret_void(&cg.lc.builder);
					} else {
						let ret_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
							&cg.lc.ctx,
							&cg.lc.td,
							cg.current_fn_ret
						);
						bind.llvm.ir.ret(
							&cg.lc.builder,
							bind.llvm.core.constant.null_value(ret_ll)
						);
					}
				}
				cg.locals.len = 0;
				cg.defers.len = 0;
				cg.scope_depth = 0;
				cg.sema.current_self_ty = prev_self;
				cg.sema.generic_subst.len = prev_subst;
			}
		}
	}
	let m0: *mut back.codegen.expressions.FnSlot = back.codegen.expressions.find_function(
		cg,
		"st$main()"
	);
	let m2: *mut back.codegen.expressions.FnSlot = back.codegen.expressions.find_function(
		cg,
		"st$main(usize,**u8)"
	);
	let target_main: *mut back.codegen.expressions.FnSlot = m2 != null ? m2 : m0;
	if target_main != null && back.codegen.expressions.find_function(cg, "main") == null {
		let i32_t: bind.llvm.core.Type = bind.llvm.core.type.int32(&cg.lc.ctx);
		let ptr_t: bind.llvm.core.Type = bind.llvm.core.type.pointer(&cg.lc.ctx, 0);
		let mut p_tys: [2]*void;
		p_tys[0] = i32_t.handle;
		p_tys[1] = ptr_t.handle;
		let main_ll_ty: bind.llvm.core.Type = bind.llvm.core.type.function(
			i32_t,
			&p_tys[0],
			2,
			false
		);
		let main_fn: bind.llvm.core.Value = bind.llvm.core.add_function(
			&cg.lc.mod_ref,
			c"main",
			main_ll_ty
		);
		let bb: *void = bind.llvm.core.append_basic_block(&cg.lc.ctx, main_fn, c"entry");
		bind.llvm.ir.position_at_end(&cg.lc.builder, bb);
		let is_void_ret: bool = target_main.st_ty != null && target_main.st_ty.fn_ret != null
			&& middle.types.underlying_type(target_main.st_ty.fn_ret).kind
			== middle.types.TypeKind.Void;
		let cname_call: *u8 = is_void_ret ? c"" : c"rc";
		let mut call_res: bind.llvm.core.Value = bind.llvm.core.wrap_value(null);
		if m2 != null {
			let usize_t: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
				&cg.lc.ctx,
				&cg.lc.td,
				cg.sema.tx.usize_t
			);
			let argc_v: bind.llvm.core.Value = bind.llvm.ir.sext(
				&cg.lc.builder,
				bind.llvm.core.param(&main_fn, 0),
				usize_t,
				c"argc64"
			);
			let argv_v: bind.llvm.core.Value = bind.llvm.core.param(&main_fn, 1);
			let mut cargs: [2]*void;
			cargs[0] = argc_v.handle;
			cargs[1] = argv_v.handle;
			call_res = bind.llvm.ir.call(
				&cg.lc.builder,
				target_main.fn_ll_ty,
				target_main.fn_val,
				&cargs[0],
				2,
				cname_call
			);
		} else {
			call_res = bind.llvm.ir.call(
				&cg.lc.builder,
				target_main.fn_ll_ty,
				target_main.fn_val,
				null,
				0,
				cname_call
			);
		}
		if is_void_ret {
			bind.llvm.ir.ret(&cg.lc.builder, bind.llvm.core.constant.integer(i32_t, 0, false));
		} else {
			let ret_u: *mut middle.types.StType = target_main.st_ty != null
				? middle.types.underlying_type(target_main.st_ty.fn_ret) : null;
			let mut final_rc: bind.llvm.core.Value = call_res;
			if ret_u != null
				&& (ret_u.kind == middle.types.TypeKind.UInt || ret_u.kind
				== middle.types.TypeKind.SInt) {
				if ret_u.width < 32 {
					final_rc = ret_u.kind == middle.types.TypeKind.SInt
						? bind.llvm.ir.sext(&cg.lc.builder, call_res, i32_t, c"rcext")
						: bind.llvm.ir.zext(&cg.lc.builder, call_res, i32_t, c"rcext");
				} else if ret_u.width > 32 {
					final_rc = bind.llvm.ir.trunc(&cg.lc.builder, call_res, i32_t, c"rctr");
				}
			} else if ret_u != null && ret_u.kind == middle.types.TypeKind.Bool {
				final_rc = bind.llvm.ir.zext(&cg.lc.builder, call_res, i32_t, c"rcext");
			}
			bind.llvm.ir.ret(&cg.lc.builder, final_rc);
		}
	}
	return back.llvm_ctx.verify_module(cg.lc);
}
