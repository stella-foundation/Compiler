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

impl SemaContext {
	/// Executes `check_fn_body`.
	pub fn check_fn_body(self: *mut SemaContext, fn_d: *front.ast.FnDecl) -> void {
		if fn_d == null || fn_d.is_extern || fn_d.body == null || fn_d.is_macro {
			return;
		}
		// Skip uninstantiated generic templates
		if fn_d.generic_params.len > 0 {
			return;
		}
		self.scopes.enter();
		let prev_ret: *mut middle.types.StType = self.current_ret_ty;
		let prev_mt: bool = self.current_fn_must_tail;
		let prev_abi: middle.types.AbiKind = self.current_fn_abi;
		self.current_ret_ty = fn_d.ret != null ? self.resolve_type(fn_d.ret) : self.tx.void_t;
		self.current_fn_abi = extract_abi_attr(&fn_d.attrs, fn_d.loc, false);
		self.current_fn_must_tail = has_attr(&fn_d.attrs, "must_tail");
		if self.current_fn_abi == middle.types.AbiKind.C {
			if is_stella_repr_aggregate(self.current_ret_ty) {
				front.log.report(
					front.log.Level.Error,
					fn_d.loc,
					"type is not FFI-safe in #[abi(\"C\")] function",
					front.log.DiagCode.InvalidAttribute
				);
			}
		}
		for let mut i: usize = 0; i < fn_d.params.len; i += 1 {
			let prm: front.ast.Param = fn_d.params.data[i];
			let mut psym: middle.symbol.Symbol = middle.symbol.make_symbol(
				middle.symbol.SymKind.Param,
				prm.name,
				prm.loc
			);
			psym.ty = self.resolve_type(prm.ty);
			if self.current_fn_abi == middle.types.AbiKind.C && is_stella_repr_aggregate(psym.ty) {
				front.log.report(
					front.log.Level.Error,
					prm.loc,
					"parameter type is not FFI-safe in #[abi(\"C\")] function",
					front.log.DiagCode.InvalidAttribute
				);
			}
			psym.is_mutable = prm.is_mutable;
			if !std.str.eq(prm.name, "_") {
				self.scopes.define(psym);
			}
		}
		middle.sema.control_flow.check_control_flow(fn_d.body, 0, false);
		self.check_stmt(fn_d.body);
		for let mut i: usize = 0; i < fn_d.params.len && !self.in_imported_mod; i += 1 {
			let prm: front.ast.Param = fn_d.params.data[i];
			if prm.name.len > 0 && prm.name[0] != ('_' cast u8) {
				let ps: *middle.symbol.Symbol = self.scopes.lookup_current(prm.name);
				if ps != null && !ps.used {
					let mut mb: [160]u8;
					let mut mp: usize = 0;
					put_str_buf(&mb[0], &mp, 160, "unused parameter `");
					put_str_buf(&mb[0], &mp, 160, prm.name);
					put_str_buf(&mb[0], &mp, 160, "`");
					front.log.report(
						front.log.Level.Warning,
						prm.loc,
						mb[0..mp],
						front.log.DiagCode.WarningGeneral
					);
				}
			}
		}
		if self.current_ret_ty != null && self.current_ret_ty.kind != middle.types.TypeKind.Void
			&& !middle.types.is_poison(self.current_ret_ty) {
			if !middle.sema.control_flow.stmt_always_returns(fn_d.body) {
				front.log.report(
					front.log.Level.Error,
					fn_d.loc,
					"non-void function may exit without returning a value",
					front.log.DiagCode.InvalidControlFlow
				);
			}
		}
		self.current_ret_ty = prev_ret;
		self.current_fn_must_tail = prev_mt;
		self.current_fn_abi = prev_abi;
		self.scopes.leave();
	}

	/// Executes `make_child_mod_path` (make child mod path).
	pub fn make_child_mod_path(
		mod_path: *front.ast.ValList<[]u8>,
		name: []u8
	) -> front.ast.ValList<[]u8> {
		let mut child: front.ast.ValList<[]u8> = { .data = null, .len = 0, .cap = 0 };
		if mod_path != null {
			for let mut i: usize = 0; i < mod_path.len; i += 1 {
				child.push(mod_path.data[i]);
			}
		}
		child.push(name);
		return child;
	}

	/// Executes `register_types_in_list` (register types in list).
	pub fn register_types_in_list(
		self: *mut SemaContext,
		decls: *front.ast.PtrList<front.ast.TopDecl>,
		mod_path: *front.ast.ValList<[]u8>
	) -> void {
		let prev_mod: *front.ast.ValList<[]u8> = self.current_mod_path;
		self.current_mod_path = mod_path;
		for let mut i: usize = 0; i < decls.len; i += 1 {
			let td: *front.ast.TopDecl = decls.data[i];
			if td == null {
				continue;
			}
			if td.kind == front.ast.TopKind.Mod && td.mod_decl != null {
				let mut child: front.ast.ValList<[]u8> = SemaContext.make_child_mod_path(
					mod_path,
					td.mod_decl.name
				);
				self.register_types_in_list(&td.mod_decl.body, &child);
			} else if (td.kind == front.ast.TopKind.Struct && td.st != null)
				|| (td.kind == front.ast.TopKind.Union && td.un != null)
				|| (td.kind == front.ast.TopKind.Enum && td.en != null)
				|| (td.kind == front.ast.TopKind.TypeBinding && td.tb != null) {
				self.register_top_decl_in_mod(td, mod_path, true);
			}
		}
		self.current_mod_path = prev_mod;
	}

	/// Executes `register_decls_in_list` (register decls in list).
	pub fn register_decls_in_list(
		self: *mut SemaContext,
		decls: *front.ast.PtrList<front.ast.TopDecl>,
		mod_path: *front.ast.ValList<[]u8>
	) -> void {
		let prev_mod: *front.ast.ValList<[]u8> = self.current_mod_path;
		self.current_mod_path = mod_path;
		for let mut i: usize = 0; i < decls.len; i += 1 {
			let td: *front.ast.TopDecl = decls.data[i];
			if td == null {
				continue;
			}
			if td.kind == front.ast.TopKind.Mod && td.mod_decl != null {
				let mut child: front.ast.ValList<[]u8> = SemaContext.make_child_mod_path(
					mod_path,
					td.mod_decl.name
				);
				self.register_decls_in_list(&td.mod_decl.body, &child);
			} else {
				let mut is_pub_decl: bool = false;
				match td.kind {
					.Fn => is_pub_decl = td.fn_decl != null && td.fn_decl.is_pub,
					.Var | .Const => is_pub_decl = td.glob != null && td.glob.is_pub,
					.Trait => is_pub_decl = td.trait_decl != null && td.trait_decl.is_pub,
					.Impl => is_pub_decl = td.impl_decl != null,
					_ => {}
				}
				if is_pub_decl {
					self.register_top_decl_in_mod(td, mod_path, true);
				}
			}
		}
		for let mut i: usize = 0; i < decls.len; i += 1 {
			let td: *front.ast.TopDecl = decls.data[i];
			if td != null && ((td.kind == front.ast.TopKind.Struct && td.st != null)
				|| (td.kind == front.ast.TopKind.Union && td.un != null)
				|| (td.kind == front.ast.TopKind.Enum && td.en != null)) {
				self.populate_type_fields(td);
			}
		}
		self.current_mod_path = prev_mod;
	}

	/// Executes `register_imported_types` (register imported types).
	pub fn register_imported_types(self: *mut SemaContext, m: *front.ast.Module) -> void {
		if m == null {
			return;
		}
		self.register_types_in_list(&m.decls, &m.mod_path);
	}

	/// Executes `register_imported_module` (register imported module).
	pub fn register_imported_module(self: *mut SemaContext, m: *front.ast.Module) -> void {
		if m == null {
			return;
		}
		self.register_decls_in_list(&m.decls, &m.mod_path);
	}

	/// Executes `check_decls_in_mod` (check decls in mod).
	pub fn check_decls_in_mod(
		self: *mut SemaContext,
		decls: *front.ast.PtrList<front.ast.TopDecl>,
		mod_path: *front.ast.ValList<[]u8>
	) -> bool {
		let prev_mod: *front.ast.ValList<[]u8> = self.current_mod_path;
		self.current_mod_path = mod_path;
		self.scopes.enter();
		for let mut i: usize = 0; i < decls.len; i += 1 {
			let td: *front.ast.TopDecl = decls.data[i];
			if td == null {
				continue;
			}
			if td.kind == front.ast.TopKind.Fn && td.fn_decl != null {
				let qsym: *mut middle.symbol.Symbol = self.lookup_fn_by_decl(mod_path, td.fn_decl);
				if qsym == null {
					self.register_top_decl_in_mod(td, mod_path, true);
				}
			} else if (td.kind == front.ast.TopKind.Var || td.kind == front.ast.TopKind.Const)
				&& td.glob != null {
				let qsym: *mut middle.symbol.Symbol = self.lookup_in_mod(mod_path, td.glob.name);
				if qsym == null {
					self.register_top_decl_in_mod(td, mod_path, true);
				}
			}
		}
		for let mut i: usize = 0; i < decls.len; i += 1 {
			let td: *front.ast.TopDecl = decls.data[i];
			if td == null {
				continue;
			}
			if td.kind == front.ast.TopKind.Mod && td.mod_decl != null {
				let mut child: front.ast.ValList<[]u8> = SemaContext.make_child_mod_path(
					mod_path,
					td.mod_decl.name
				);
				self.check_decls_in_mod(&td.mod_decl.body, &child);
			} else if td.kind == front.ast.TopKind.Fn {
				self.check_fn_body(td.fn_decl);
			} else if (td.kind == front.ast.TopKind.Var || td.kind == front.ast.TopKind.Const)
				&& td.glob != null && td.glob.init != null {
				let gty: *mut middle.types.StType = self.resolve_type(td.glob.ty);
				self.check_expr(td.glob.init, gty);
			} else if td.kind == front.ast.TopKind.Impl && td.impl_decl != null
				&& td.impl_decl.generic_params.len == 0 && td.impl_decl.target_type != null {
				let target_ty: *mut middle.types.StType = self.resolve_type(
					td.impl_decl.target_type
				);
				let prev_self: *mut middle.types.StType = self.current_self_ty;
				self.current_self_ty = target_ty;
				for let mut j: usize = 0; j < td.impl_decl.methods.len; j += 1 {
					self.check_fn_body(td.impl_decl.methods.data[j]);
				}
				if !td.impl_decl.is_inherent && td.impl_decl.trait_name.len > 0 {
					for let mut ti: usize = 0; ti < self.traits.len; ti += 1 {
						if std.str.eq(self.traits.data[ti].name, td.impl_decl.trait_name) {
							let tdecl: *front.ast.TraitDecl = self.traits.data[ti];
							for let mut tm: usize = 0; tm < tdecl.methods.len; tm += 1 {
								let req: *front.ast.FnDecl = tdecl.methods.data[tm];
								if req.body == null {
									continue;
								}
								let mut found: bool = false;
								for let mut im: usize = 0; im < td.impl_decl.methods.len; im += 1 {
									if std.str.eq(td.impl_decl.methods.data[im].name, req.name) {
										found = true;
										break;
									}
								}
								if !found {
									self.check_fn_body(req);
								}
							}
							break;
						}
					}
				}
				self.current_self_ty = prev_self;
			}
		}
		self.scopes.leave();
		self.current_mod_path = prev_mod;
		return !front.log.has_error();
	}

	/// Executes `check_imported_module` (check imported module).
	pub fn check_imported_module(self: *mut SemaContext, m: *front.ast.Module) -> bool {
		if m == null {
			return true;
		}
		let prev_imp: bool = self.in_imported_mod;
		self.in_imported_mod = true;
		let ok: bool = self.check_decls_in_mod(&m.decls, &m.mod_path);
		self.in_imported_mod = prev_imp;
		return ok;
	}

	/// Executes `check_module` (check module).
	pub fn check_module(self: *mut SemaContext, m: *front.ast.Module) -> bool {
		if m == null {
			return true;
		}
		let prev_mod: *front.ast.ValList<[]u8> = self.current_mod_path;
		self.current_mod_path = m.mod_path.len > 0 ? &m.mod_path : null;
		// Pass 1: register types and consts first so forward references in array lengths work
		for let mut i: usize = 0; i < m.decls.len; i += 1 {
			let td: *front.ast.TopDecl = m.decls.data[i];
			if td == null {
				continue;
			}
			if td.kind == front.ast.TopKind.Mod && td.mod_decl != null {
				self.mod_names.push(td.mod_decl.name);
				let mut child: front.ast.ValList<[]u8> = SemaContext.make_child_mod_path(
					&m.mod_path,
					td.mod_decl.name
				);
				self.register_types_in_list(&td.mod_decl.body, &child);
				self.register_decls_in_list(&td.mod_decl.body, &child);
			} else if td.kind == front.ast.TopKind.Struct || td.kind == front.ast.TopKind.Union
				|| td.kind == front.ast.TopKind.Enum || td.kind == front.ast.TopKind.TypeBinding
				|| td.kind == front.ast.TopKind.Const || td.kind == front.ast.TopKind.Trait {
				self.register_top_decl_in_mod(td, m.mod_path.len > 0 ? &m.mod_path : null, false);
			}
		}
		for let mut i: usize = 0; i < m.decls.len; i += 1 {
			self.populate_type_fields(m.decls.data[i]);
		}
		// Pass 2: register vars, fns, and impls after types/enums/consts are populated
		for let mut i: usize = 0; i < m.decls.len; i += 1 {
			let td: *front.ast.TopDecl = m.decls.data[i];
			if td == null {
				continue;
			}
			if td.kind != front.ast.TopKind.Mod && td.kind != front.ast.TopKind.Struct
				&& td.kind != front.ast.TopKind.Union && td.kind != front.ast.TopKind.Enum
				&& td.kind != front.ast.TopKind.TypeBinding && td.kind != front.ast.TopKind.Const
				&& td.kind != front.ast.TopKind.Trait {
				self.register_top_decl_in_mod(td, m.mod_path.len > 0 ? &m.mod_path : null, false);
			}
		}
		for let mut i: usize = 0; i < m.decls.len; i += 1 {
			let td: *front.ast.TopDecl = m.decls.data[i];
			if td.kind == front.ast.TopKind.Mod && td.mod_decl != null {
				self.mod_names.push(td.mod_decl.name);
				let mut child: front.ast.ValList<[]u8> = SemaContext.make_child_mod_path(
					&m.mod_path,
					td.mod_decl.name
				);
				self.check_decls_in_mod(&td.mod_decl.body, &child);
			} else if td.kind == front.ast.TopKind.Fn {
				self.check_fn_body(td.fn_decl);
			} else if td.kind == front.ast.TopKind.Impl && td.impl_decl != null
				&& td.impl_decl.generic_params.len == 0 && td.impl_decl.target_type != null
				&& td.impl_decl.target_type.generic_args.len == 0 {
				let target_ty: *mut middle.types.StType = self.resolve_type(
					td.impl_decl.target_type
				);
				let prev_self: *mut middle.types.StType = self.current_self_ty;
				self.current_self_ty = target_ty;
				for let mut j: usize = 0; j < td.impl_decl.methods.len; j += 1 {
					self.check_fn_body(td.impl_decl.methods.data[j]);
				}
				if !td.impl_decl.is_inherent && td.impl_decl.trait_name.len > 0 {
					for let mut ti: usize = 0; ti < self.traits.len; ti += 1 {
						if std.str.eq(self.traits.data[ti].name, td.impl_decl.trait_name) {
							let tdecl: *front.ast.TraitDecl = self.traits.data[ti];
							for let mut tm: usize = 0; tm < tdecl.methods.len; tm += 1 {
								let req: *front.ast.FnDecl = tdecl.methods.data[tm];
								if req.body == null {
									continue;
								}
								let mut found: bool = false;
								for let mut im: usize = 0; im < td.impl_decl.methods.len; im += 1 {
									if std.str.eq(td.impl_decl.methods.data[im].name, req.name) {
										found = true;
										break;
									}
								}
								if !found {
									self.check_fn_body(req);
								}
							}
							break;
						}
					}
				}
				self.current_self_ty = prev_self;
			} else if (td.kind == front.ast.TopKind.Var || td.kind == front.ast.TopKind.Const)
				&& td.glob != null {
				if td.glob.init != null {
					let gsym: *middle.symbol.Symbol = self.scopes.lookup(td.glob.name);
					let gty: *mut middle.types.StType = (gsym != null && gsym.ty != null) ? gsym.ty
						: self.resolve_type(td.glob.ty);
					let ity: *mut middle.types.StType = self.check_expr(td.glob.init, gty);
					if !middle.types.is_poison(gty) && !middle.types.is_poison(ity)
						&& !middle.types.is_assignable_type(gty, ity) {
						front.log.report(
							front.log.Level.Error,
							td.glob.loc,
							"global initializer type mismatch",
							front.log.DiagCode.TypeMismatch
						);
					}
				}
			}
		}
		self.current_mod_path = prev_mod;
		return !front.log.has_error();
	}
}
