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

/// Executes `declare_decls_in_mod`.
pub fn declare_decls_in_mod(
	cg: *mut back.codegen.expressions.CodegenState,
	decls: *front.ast.PtrList<front.ast.TopDecl>,
	mod_path: *front.ast.ValList<[]u8>
) -> void {
	let prev_mod: *front.ast.ValList<[]u8> = cg.sema.current_mod_path;
	cg.sema.current_mod_path = mod_path;
	for let mut i: usize = 0; i < decls.len; i += 1 {
		let td: *front.ast.TopDecl = decls.data[i];
		if td == null {
			continue;
		}
		if td.kind == front.ast.TopKind.Mod && td.mod_decl != null {
			let mut child: front.ast.ValList<[]u8> = { .data = null, .len = 0, .cap = 0 };
			if mod_path != null {
				for let mut k: usize = 0; k < mod_path.len; k += 1 {
					child.push(mod_path.data[k]);
				}
			}
			child.push(td.mod_decl.name);
			declare_decls_in_mod(cg, &td.mod_decl.body, &child);
		} else if (td.kind == front.ast.TopKind.Var || td.kind == front.ast.TopKind.Const)
			&& td.glob != null {
			let sym: *middle.symbol.Symbol = cg.sema.lookup_in_mod(mod_path, td.glob.name);
			let mangled: []u8 = sym != null ? sym.mangled
				: middle.symbol.mangle_symbol_name(mod_path, td.glob.name, &td.glob.attrs);
			if back.codegen.expressions.find_global(cg, mangled) == null {
				let st_ty: *mut middle.types.StType = sym != null && sym.ty != null
					? sym.ty
					: cg.sema.resolve_type(td.glob.ty);
				let ll_ty: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
					&cg.lc.ctx,
					&cg.lc.td,
					st_ty
				);
				let cname: *mut u8 = back.codegen.expressions.cstr_from_slice(mangled);
				let mut gv: bind.llvm.core.Value = bind.llvm.core.add_global(
					&cg.lc.mod_ref,
					ll_ty,
					cname != null ? (cname cast *u8) : c"glob"
				);
				if !td.glob.is_extern {
					if td.glob.init != null {
						let init_v: bind.llvm.core.Value = back.codegen.expressions.emit_expr(
							cg,
							td.glob.init,
							st_ty
						);
						bind.llvm.core.set_initializer(&gv, init_v);
					} else {
						bind.llvm.core.set_initializer(
							&gv,
							bind.llvm.core.constant.null_value(ll_ty)
						);
					}
				}
				if td.glob.is_const {
					bind.llvm.core.set_global_constant(&gv, true);
				}
				if !td.glob.is_pub && !td.glob.is_extern {
					bind.llvm.core.set_linkage(&gv, bind.llvm.Linkage.Internal);
				}
				let gs: back.codegen.expressions.GlobalSlot = {
					.name = mangled,
					.ptr = gv,
					.st_ty = st_ty,
					.ll_ty = ll_ty
				};
				back.codegen.expressions.add_global_slot(cg, gs);
			}
		} else if td.kind == front.ast.TopKind.Fn && td.fn_decl != null {
			declare_fn_in_mod(cg, td.fn_decl, mod_path);
		}
	}
	cg.sema.current_mod_path = prev_mod;
}

/// Executes `module_has_private_mutable_global` (module has private mutable global).
pub fn module_has_private_mutable_global(m: *front.ast.Module) -> bool {
	if m == null {
		return false;
	}
	for let mut i: usize = 0; i < m.decls.len; i += 1 {
		let td: *front.ast.TopDecl = m.decls.data[i];
		if td != null && td.kind == front.ast.TopKind.Var && td.glob != null
			&& !td.glob.is_pub && !td.glob.is_const && !td.glob.is_extern {
			return true;
		}
	}
	return false;
}

/// Executes `declare_imported_module_opts` (declare imported module opts).
pub fn declare_imported_module_opts(
	cg: *mut back.codegen.expressions.CodegenState,
	m: *front.ast.Module,
	skip_priv_mut: bool
) -> void {
	if m == null {
		return;
	}
	let prev_mod: *front.ast.ValList<[]u8> = cg.sema.current_mod_path;
	cg.sema.current_mod_path = &m.mod_path;
	for let mut i: usize = 0; i < m.decls.len; i += 1 {
		let td: *front.ast.TopDecl = m.decls.data[i];
		if td == null {
			continue;
		}
		if td.kind == front.ast.TopKind.Mod && td.mod_decl != null {
			let mut child: front.ast.ValList<[]u8> = { .data = null, .len = 0, .cap = 0 };
			for let mut k: usize = 0; k < m.mod_path.len; k += 1 {
				child.push(m.mod_path.data[k]);
			}
			child.push(td.mod_decl.name);
			declare_decls_in_mod(cg, &td.mod_decl.body, &child);
		} else if (td.kind == front.ast.TopKind.Var || td.kind == front.ast.TopKind.Const)
			&& td.glob != null {
			if skip_priv_mut && !td.glob.is_pub && !td.glob.is_const && !td.glob.is_extern {
				continue;
			}
			let mut sym: *middle.symbol.Symbol = cg.sema.lookup_in_mod(&m.mod_path, td.glob.name);
			let mut mangled: []u8 = sym != null ? sym.mangled
				: middle.symbol.mangle_symbol_name(&m.mod_path, td.glob.name, &td.glob.attrs);
			if !td.glob.is_pub && !td.glob.is_extern && sym == null {
				mangled = middle.symbol.mangle_private_global_name(mangled, td.glob.loc.file);
			}
			if back.codegen.expressions.find_global(cg, mangled) == null {
				let st_ty: *mut middle.types.StType = sym != null && sym.ty != null ? sym.ty
					: cg.sema.resolve_type(td.glob.ty);
				let ll_ty: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
					&cg.lc.ctx,
					&cg.lc.td,
					st_ty
				);
				let cname: *mut u8 = back.codegen.expressions.cstr_from_slice(mangled);
				let mut gv: bind.llvm.core.Value = bind.llvm.core.add_global(
					&cg.lc.mod_ref,
					ll_ty,
					cname != null ? (cname cast *u8) : c"glob"
				);
				if !td.glob.is_extern && (!skip_priv_mut || !td.glob.is_pub || td.glob.is_const) {
					if td.glob.init != null {
						let init_v: bind.llvm.core.Value = back.codegen.expressions.emit_expr(
							cg,
							td.glob.init,
							st_ty
						);
						bind.llvm.core.set_initializer(&gv, init_v);
					} else {
						bind.llvm.core.set_initializer(
							&gv,
							bind.llvm.core.constant.null_value(ll_ty)
						);
					}
				}
				if td.glob.is_const {
					bind.llvm.core.set_global_constant(&gv, true);
				}
				if !td.glob.is_pub && !td.glob.is_extern {
					bind.llvm.core.set_linkage(&gv, bind.llvm.Linkage.Internal);
				} else if skip_priv_mut && td.glob.is_pub && td.glob.is_const
					&& !td.glob.is_extern {
					bind.llvm.core.set_linkage(&gv, bind.llvm.Linkage.AvailableExternally);
				}
				let gs: back.codegen.expressions.GlobalSlot = {
					.name = mangled,
					.ptr = gv,
					.st_ty = st_ty,
					.ll_ty = ll_ty
				};
				back.codegen.expressions.add_global_slot(cg, gs);
			}
		} else if td.kind == front.ast.TopKind.Fn && td.fn_decl != null {
			declare_fn_in_mod(cg, td.fn_decl, &m.mod_path);
		}
	}
	cg.sema.current_mod_path = prev_mod;
}

/// Executes `declare_imported_module` (declare imported module).
pub fn declare_imported_module(
	cg: *mut back.codegen.expressions.CodegenState,
	m: *front.ast.Module
) -> void {
	declare_imported_module_opts(cg, m, false);
}

/// Executes `emit_decls_bodies_in_mod`.
pub fn emit_decls_bodies_in_mod(
	cg: *mut back.codegen.expressions.CodegenState,
	decls: *front.ast.PtrList<front.ast.TopDecl>,
	mod_path: *front.ast.ValList<[]u8>
) -> void {
	let prev_mod: *front.ast.ValList<[]u8> = cg.sema.current_mod_path;
	cg.sema.current_mod_path = mod_path;
	for let mut i: usize = 0; i < decls.len; i += 1 {
		let td: *front.ast.TopDecl = decls.data[i];
		if td == null {
			continue;
		}
		if td.kind == front.ast.TopKind.Mod && td.mod_decl != null {
			let mut child: front.ast.ValList<[]u8> = { .data = null, .len = 0, .cap = 0 };
			if mod_path != null {
				for let mut k: usize = 0; k < mod_path.len; k += 1 {
					child.push(mod_path.data[k]);
				}
			}
			child.push(td.mod_decl.name);
			emit_decls_bodies_in_mod(cg, &td.mod_decl.body, &child);
		} else if td.kind == front.ast.TopKind.Fn && td.fn_decl != null {
			emit_fn_body_in_mod(cg, td.fn_decl, mod_path);
		}
	}
	cg.sema.current_mod_path = prev_mod;
}

/// Marks public imported functions (including nested modules) as `AvailableExternally`.
pub fn mark_imported_decls_avail_ext(
	cg: *mut back.codegen.expressions.CodegenState,
	decls: *front.ast.PtrList<front.ast.TopDecl>,
	mod_path: *front.ast.ValList<[]u8>
) -> void {
	for let mut i: usize = 0; i < decls.len; i += 1 {
		let td: *front.ast.TopDecl = decls.data[i];
		if td == null {
			continue;
		}
		if td.kind == front.ast.TopKind.Mod && td.mod_decl != null {
			let mut child: front.ast.ValList<[]u8> = { .data = null, .len = 0, .cap = 0 };
			if mod_path != null {
				for let mut k: usize = 0; k < mod_path.len; k += 1 {
					child.push(mod_path.data[k]);
				}
			}
			child.push(td.mod_decl.name);
			mark_imported_decls_avail_ext(cg, &td.mod_decl.body, &child);
		} else if td.kind == front.ast.TopKind.Fn && td.fn_decl != null
			&& !td.fn_decl.is_extern && !td.fn_decl.is_macro && td.fn_decl.generic_params.len == 0
			&& td.fn_decl.is_pub {
			let sym: *middle.symbol.Symbol = cg.sema.lookup_fn_by_decl(mod_path, td.fn_decl);
			let mangled: []u8 = sym != null ? sym.mangled
				: mangle_fn_name_in_mod(td.fn_decl, mod_path);
			let fs: *mut back.codegen.expressions.FnSlot = back.codegen.expressions.find_function(
				cg,
				mangled
			);
			if fs != null {
				bind.llvm.core.set_linkage(&fs.fn_val, bind.llvm.Linkage.AvailableExternally);
			}
		} else if td.kind == front.ast.TopKind.Const && td.glob != null && td.glob.is_pub
			&& !td.glob.is_extern && !has_attr(&td.glob.attrs, "export")
			&& !has_attr(&td.glob.attrs, "link_name") {
			let mangled: []u8 = middle.symbol.mangle_symbol_name(
				mod_path,
				td.glob.name,
				&td.glob.attrs
			);
			let gs: *mut back.codegen.expressions.GlobalSlot =
				back.codegen.expressions.find_global(cg, mangled);
			if gs != null {
				bind.llvm.core.set_linkage(&gs.ptr, bind.llvm.Linkage.AvailableExternally);
			}
		} else if td.kind == front.ast.TopKind.Impl && td.impl_decl != null
			&& td.impl_decl.generic_params.len == 0 {
			for let mut mi: usize = 0; mi < td.impl_decl.methods.len; mi += 1 {
				let md: *front.ast.FnDecl = td.impl_decl.methods.data[mi];
				if md == null || !md.is_pub || md.generic_params.len > 0 {
					continue;
				}
				for let mut ei: usize = 0; ei < cg.sema.impl_methods.len; ei += 1 {
					let entry: middle.sema.validation.ImplMethodEntry =
						cg.sema.impl_methods.data[ei];
					if entry.fn_decl == md && entry.sym != null {
						let fs: *mut back.codegen.expressions.FnSlot =
							back.codegen.expressions.find_function(cg, entry.sym.mangled);
						if fs != null {
							bind.llvm.core.set_linkage(
								&fs.fn_val,
								bind.llvm.Linkage.AvailableExternally
							);
						}
					}
				}
			}
		}
	}
}

/// Executes `emit_imported_module_bodies_avail_ext` (emit imported module bodies avail ext).
pub fn emit_imported_module_bodies_avail_ext(
	cg: *mut back.codegen.expressions.CodegenState,
	m: *front.ast.Module
) -> void {
	if m == null {
		return;
	}
	cg.has_emit_stmt_cb = true;
	cg.emit_stmt_cb = back.codegen.statements.emit_stmt;
	emit_decls_bodies_in_mod(cg, &m.decls, &m.mod_path);
	mark_imported_decls_avail_ext(cg, &m.decls, &m.mod_path);
}

/// Executes `has_attr`.
pub fn has_attr(attrs: *front.ast.AttributeList, name: []u8) -> bool {
	if attrs == null {
		return false;
	}
	for let mut i: usize = 0; i < attrs.attrs.len; i += 1 {
		let a: *front.ast.Attribute = &attrs.attrs.data[i];
		if !a.negated && std.str.eq(a.name, name) {
			return true;
		}
	}
	return false;
}

/// Executes `mark_imported_decls_internal`.
pub fn mark_imported_decls_internal(
	cg: *mut back.codegen.expressions.CodegenState,
	decls: *front.ast.PtrList<front.ast.TopDecl>,
	mod_path: *front.ast.ValList<[]u8>
) -> void {
	for let mut i: usize = 0; i < decls.len; i += 1 {
		let td: *front.ast.TopDecl = decls.data[i];
		if td == null {
			continue;
		}
		if td.kind == front.ast.TopKind.Mod && td.mod_decl != null {
			let mut child: front.ast.ValList<[]u8> = { .data = null, .len = 0, .cap = 0 };
			if mod_path != null {
				for let mut k: usize = 0; k < mod_path.len; k += 1 {
					child.push(mod_path.data[k]);
				}
			}
			child.push(td.mod_decl.name);
			mark_imported_decls_internal(cg, &td.mod_decl.body, &child);
		} else if td.kind == front.ast.TopKind.Fn && td.fn_decl != null
			&& !td.fn_decl.is_extern && !td.fn_decl.is_macro && td.fn_decl.generic_params.len == 0
			&& !std.str.eq(td.fn_decl.name, "main")
			&& !has_attr(&td.fn_decl.attrs, "export")
			&& !has_attr(&td.fn_decl.attrs, "link_name") {
			let sym: *middle.symbol.Symbol = cg.sema.lookup_fn_by_decl(mod_path, td.fn_decl);
			let mangled: []u8 = sym != null ? sym.mangled
				: mangle_fn_name_in_mod(td.fn_decl, mod_path);
			let fs: *mut back.codegen.expressions.FnSlot = back.codegen.expressions.find_function(
				cg,
				mangled
			);
			if fs != null {
				bind.llvm.core.set_linkage(&fs.fn_val, bind.llvm.Linkage.Internal);
			}
		} else if (td.kind == front.ast.TopKind.Var || td.kind == front.ast.TopKind.Const)
			&& td.glob != null && !td.glob.is_extern
			&& !has_attr(&td.glob.attrs, "export")
			&& !has_attr(&td.glob.attrs, "link_name") {
			let mangled: []u8 = middle.symbol.mangle_symbol_name(mod_path, td.glob.name, null);
			let gs: *mut back.codegen.expressions.GlobalSlot =
				back.codegen.expressions.find_global(cg, mangled);
			if gs != null {
				bind.llvm.core.set_linkage(&gs.ptr, bind.llvm.Linkage.Internal);
			}
		}
	}
}

/// Executes `emit_imported_module_bodies` (emit imported module bodies).
pub fn emit_imported_module_bodies(
	cg: *mut back.codegen.expressions.CodegenState,
	m: *front.ast.Module
) -> void {
	if m == null {
		return;
	}
	cg.has_emit_stmt_cb = true;
	cg.emit_stmt_cb = back.codegen.statements.emit_stmt;
	emit_decls_bodies_in_mod(cg, &m.decls, &m.mod_path);
	mark_imported_decls_internal(cg, &m.decls, &m.mod_path);
}
