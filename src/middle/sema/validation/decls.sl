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
	/// Executes `register_top_decl_in_mod`.
	pub fn register_top_decl_in_mod(
		self: *mut SemaContext,
		td: *front.ast.TopDecl,
		mod_path: *front.ast.ValList<[]u8>,
		is_imported: bool
	) -> void {
		if td == null {
			return;
		}
		let mut added_sym: *mut middle.symbol.Symbol = null;
		match td.kind {
			.Struct => {
				let st: *front.ast.StructDecl = td.st;
				let ty: *mut middle.types.StType = self.tx.struct_of(st.name, st.is_pub);
				if mod_path != null && mod_path.len > 0 {
					ty.mangled_name = middle.symbol.mangle_symbol_name(mod_path, st.name, null);
				}
				ty.is_foreign = is_imported;
				ty.explicit_align = extract_align_attr(&st.attrs);
				ty.is_opaque = st.is_opaque;
				let mut sym: middle.symbol.Symbol = middle.symbol.make_symbol(
					middle.symbol.SymKind.Struct,
					st.name,
					st.loc
				);
				sym.ty = ty;
				sym.st = st;
				sym.is_pub = st.is_pub;
				sym.is_imported = is_imported;
				if is_imported {
					if sym.is_pub && self.scopes.lookup_current(sym.simple) == null {
						added_sym = self.scopes.define(sym);
					} else {
						let raw: *mut u8 = front.ast.arena_alloc(@of.size(middle.symbol.Symbol));
						if raw != null {
							let ptr: *mut middle.symbol.Symbol = raw cast *mut middle.symbol.Symbol;
							*ptr = sym;
							added_sym = ptr;
						}
					}
				} else if self.scopes.define_or_replace_imported(sym) == null {
					front.log.report(
						front.log.Level.Error,
						st.loc,
						"duplicate struct declaration",
						front.log.DiagCode.DuplicateDeclaration
					);
				}
			}
			.Union => {
				let un: *front.ast.UnionDecl = td.un;
				let ty: *mut middle.types.StType = self.tx.union_of(un.name, un.is_pub);
				if mod_path != null && mod_path.len > 0 {
					ty.mangled_name = middle.symbol.mangle_symbol_name(mod_path, un.name, null);
				}
				ty.is_foreign = is_imported;
				ty.explicit_align = extract_align_attr(&un.attrs);
				let mut sym: middle.symbol.Symbol = middle.symbol.make_symbol(
					middle.symbol.SymKind.Union,
					un.name,
					un.loc
				);
				sym.ty = ty;
				sym.un = un;
				sym.is_pub = un.is_pub;
				sym.is_imported = is_imported;
				if is_imported {
					if sym.is_pub && self.scopes.lookup_current(sym.simple) == null {
						added_sym = self.scopes.define(sym);
					} else {
						let raw: *mut u8 = front.ast.arena_alloc(@of.size(middle.symbol.Symbol));
						if raw != null {
							let ptr: *mut middle.symbol.Symbol = raw cast *mut middle.symbol.Symbol;
							*ptr = sym;
							added_sym = ptr;
						}
					}
				} else if self.scopes.define_or_replace_imported(sym) == null {
					front.log.report(
						front.log.Level.Error,
						un.loc,
						"duplicate union declaration",
						front.log.DiagCode.DuplicateDeclaration
					);
				}
			}
			.Enum => {
				let en: *front.ast.EnumDecl = td.en;
				let backing: *mut middle.types.StType = en.backing != null
					? self.resolve_type(en.backing) : self.tx.uint(32);
				let ty: *mut middle.types.StType = self.tx.enum_of(en.name, backing, en.is_pub);
				if mod_path != null && mod_path.len > 0 {
					ty.mangled_name = middle.symbol.mangle_symbol_name(mod_path, en.name, null);
				}
				ty.explicit_align = extract_align_attr(&en.attrs);
				if en.generic_params.len > 0 {
					for let mut i: usize = 0; i < en.members.len; i += 1 {
						ty.field_names.push(en.members.data[i].name);
						ty.enum_values.push(i cast u64);
					}
				}
				let mut sym: middle.symbol.Symbol = middle.symbol.make_symbol(
					middle.symbol.SymKind.Enum,
					en.name,
					en.loc
				);
				sym.ty = ty;
				sym.en = en;
				sym.is_pub = en.is_pub;
				sym.is_imported = is_imported;
				if is_imported {
					if sym.is_pub && self.scopes.lookup_current(sym.simple) == null {
						added_sym = self.scopes.define(sym);
					} else {
						let raw: *mut u8 = front.ast.arena_alloc(@of.size(middle.symbol.Symbol));
						if raw != null {
							let ptr: *mut middle.symbol.Symbol = raw cast *mut middle.symbol.Symbol;
							*ptr = sym;
							added_sym = ptr;
						}
					}
				} else if self.scopes.define_or_replace_imported(sym) == null {
					front.log.report(
						front.log.Level.Error,
						en.loc,
						"duplicate enum declaration",
						front.log.DiagCode.DuplicateDeclaration
					);
				}
			}
			.TypeBinding => {
				let tb: *front.ast.TypeBindingDecl = td.tb;
				let target: *mut middle.types.StType = self.resolve_type(tb.target);
				let ty: *mut middle.types.StType = self.tx.type_binding_of(
					tb.name,
					target,
					tb.is_pub
				);
				let mut sym: middle.symbol.Symbol = middle.symbol.make_symbol(
					middle.symbol.SymKind.TypeBinding,
					tb.name,
					tb.loc
				);
				sym.ty = ty;
				sym.tb = tb;
				sym.is_pub = tb.is_pub;
				if is_imported {
					if sym.is_pub && self.scopes.lookup_current(sym.simple) == null {
						added_sym = self.scopes.define(sym);
					} else {
						let raw: *mut u8 = front.ast.arena_alloc(@of.size(middle.symbol.Symbol));
						if raw != null {
							let ptr: *mut middle.symbol.Symbol = raw cast *mut middle.symbol.Symbol;
							*ptr = sym;
							added_sym = ptr;
						}
					}
				} else if self.scopes.define_or_replace_imported(sym) == null {
					front.log.report(
						front.log.Level.Error,
						tb.loc,
						"duplicate type binding",
						front.log.DiagCode.DuplicateDeclaration
					);
				}
			}
			.Fn => {
				let fn_d: *front.ast.FnDecl = td.fn_decl;
				let fn_abi: middle.types.AbiKind = extract_abi_attr(
					&fn_d.attrs,
					fn_d.loc,
					!is_imported
				);
				if fn_d.is_variadic && !fn_d.is_macro && fn_abi != middle.types.AbiKind.C {
					front.log.report(
						front.log.Level.Error,
						fn_d.loc,
						"variadic functions (...) are only supported with #[abi(\"C\")]",
						front.log.DiagCode.InvalidAttribute
					);
				}
				let mut fty: *mut middle.types.StType = null;
				if fn_d.generic_params.len == 0 {
					let mut ptypes: front.ast.PtrList<middle.types.StType> = {
						.data = null,
						.len = 0,
						.cap = 0
					};
					for let mut i: usize = 0; i < fn_d.params.len; i += 1 {
						let pt: *mut middle.types.StType = self.resolve_type(
							fn_d.params.data[i].ty
						);
						let pu: *mut middle.types.StType = middle.types.underlying_type(pt);
						if pu != null && pu.is_opaque {
							front.log.report(
								front.log.Level.Error,
								fn_d.params.data[i].loc,
								"parameter must have a non-void, non-zero-sized storage type",
								front.log.DiagCode.TypeMismatch
							);
						}
						ptypes.push(pt);
					}
					let rty: *mut middle.types.StType = fn_d.ret != null
						? self.resolve_type(fn_d.ret) : self.tx.void_t;
					fty = self.tx.function_of(ptypes, rty, fn_d.is_variadic, fn_abi);
					ptypes.free_array();
				}
				for let mut gi: usize = 0; gi < fn_d.generic_params.len; gi += 1 {
					let gp: front.ast.GenericParam = fn_d.generic_params.data[gi];
					for let mut bi: usize = 0; bi < gp.trait_bounds.len; bi += 1 {
						let btr: *front.ast.TypeRef = gp.trait_bounds.data[bi];
						if btr != null && btr.path.len >= 2 {
							for let mut si: usize = 0; si < self.imported_syms.len; si += 1 {
								if self.imported_syms.data[si].mod_path.len > 0
									&& std.str.eq(
										self.imported_syms.data[si].mod_path.data[0],
										btr.path.data[0]
									)
									&& self.imported_syms.data[si].sym != null {
									self.imported_syms.data[si].sym.used = true;
								}
							}
						}
					}
				}
				let mut sym: middle.symbol.Symbol = middle.symbol.make_symbol(
					middle.symbol.SymKind.Fn,
					fn_d.name,
					fn_d.loc
				);
				let mut mangled: []u8 = fn_d.is_extern
					? middle.symbol.mangle_symbol_name(mod_path, fn_d.name, &fn_d.attrs)
					: middle.symbol.mangle_fn_with_sig(mod_path, fn_d.name, fty, &fn_d.attrs);
				sym.mangled = mangled;
				sym.ty = fty;
				sym.fn_decl = fn_d;
				sym.is_pub = fn_d.is_pub;
				sym.is_imported = is_imported;
				if is_imported {
					if sym.is_pub && self.scopes.lookup_current(sym.simple) == null {
						added_sym = self.scopes.define(sym);
					} else {
						let raw: *mut u8 = front.ast.arena_alloc(@of.size(middle.symbol.Symbol));
						if raw != null {
							let ptr: *mut middle.symbol.Symbol = raw cast *mut middle.symbol.Symbol;
							*ptr = sym;
							added_sym = ptr;
						}
					}
				} else if self.scopes.define_or_replace_imported(sym) == null {
					let existing: *middle.symbol.Symbol = self.scopes.lookup_current(fn_d.name);
					let mut diff_sig: bool = false;
					if existing != null && existing.kind == middle.symbol.SymKind.Fn && existing.ty
						!= null && fty != null {
						let eu: *mut middle.types.StType = middle.types.underlying_type(
							existing.ty
						);
						let fu: *mut middle.types.StType = middle.types.underlying_type(fty);
						if eu != null && fu != null && eu.kind == middle.types.TypeKind.Function
							&& fu.kind == middle.types.TypeKind.Function {
							if eu.fn_params.len != fu.fn_params.len {
								diff_sig = true;
							} else {
								for let mut pi: usize = 0; pi < eu.fn_params.len; pi += 1 {
									if !middle.types.eq_type(
										eu.fn_params.data[pi],
										fu.fn_params.data[pi]
									) {
										diff_sig = true;
										break;
									}
								}
							}
						}
					}
					if existing != null && existing.kind == middle.symbol.SymKind.Fn
						&& (diff_sig || fn_d.generic_params.len > 0
						|| (existing.fn_decl != null && existing.fn_decl.generic_params.len > 0)) {
						let mut dup_gen: bool = false;
						if fn_d.generic_params.len > 0 && existing.fn_decl != null
							&& existing.fn_decl.generic_params.len == fn_d.generic_params.len
							&& existing.fn_decl.params.len == fn_d.params.len {
							dup_gen = true;
							for let mut gi: usize = 0; gi < fn_d.generic_params.len; gi += 1 {
								if fn_d.generic_params.data[gi].type_set.len
									!= existing.fn_decl.generic_params.data[gi].type_set.len {
									dup_gen = false;
									break;
								}
							}
						}
						if dup_gen {
							front.log.report(
								front.log.Level.Error,
								fn_d.loc,
								"duplicate overload for generic function",
								front.log.DiagCode.DuplicateDeclaration
							);
						} else {
							self.scopes.define_overload(sym);
						}
					} else {
						let mut mb: [160]u8;
						let mut mp: usize = 0;
						put_str_buf(&mb[0], &mp, 160, "redefinition of function `");
						put_str_buf(&mb[0], &mp, 160, fn_d.name);
						put_str_buf(&mb[0], &mp, 160, "` with identical parameter types");
						let mut nb: [160]u8;
						let mut np: usize = 0;
						put_str_buf(&nb[0], &np, 160, "previous definition of '");
						put_str_buf(&nb[0], &np, 160, fn_d.name);
						put_str_buf(&nb[0], &np, 160, "' was here");
						front.log.report_with_note(
							front.log.Level.Error,
							fn_d.loc,
							mb[0..mp],
							front.log.DiagCode.DuplicateDeclaration,
							nb[0..np],
							existing != null ? existing.loc : front.log.empty_loc()
						);
					}
				}
			}
			.Var | .Const => {
				let gd: *front.ast.GlobalDecl = td.glob;
				let mut gty: *mut middle.types.StType = self.resolve_type(gd.ty);
				if gd.ty != null && gd.ty.kind == front.ast.TypeRefKind.Array
					&& gd.ty.array_len_inferred && gd.init != null {
					let elem: *mut middle.types.StType = self.resolve_type(gd.ty.base);
					if gd.init.kind == front.ast.ExprKind.ArrayLit {
						gty = self.tx.array_of(elem, gd.init.args.len);
					} else if gd.init.kind == front.ast.ExprKind.StringLit {
						let slen: usize = gd.init.is_cstring ? (gd.init.str_val.len + 1)
							: gd.init.str_val.len;
						gty = self.tx.array_of(elem, slen);
					} else if gd.init.kind == front.ast.ExprKind.SrcEmbed {
						self.check_expr(gd.init, null);
						gty = self.tx.array_of(elem, gd.init.str_val.len);
					}
				}
				let mut sym: middle.symbol.Symbol = middle.symbol.make_symbol(
					gd.is_const ? middle.symbol.SymKind.Const : middle.symbol.SymKind.Var,
					gd.name,
					gd.loc
				);
				sym.mangled = middle.symbol.mangle_symbol_name(mod_path, gd.name, &gd.attrs);
				if !gd.is_pub && !gd.is_extern {
					sym.mangled = middle.symbol.mangle_private_global_name(
						sym.mangled,
						gd.loc.file
					);
				}
				sym.ty = gty;
				sym.glob = gd;
				sym.is_pub = gd.is_pub;
				sym.is_imported = is_imported;
				sym.is_mutable = gd.is_mutable;
				if gd.is_const && gd.init != null {
					let cv: middle.sema.const_eval.ConstVal =
						middle.sema.const_eval.eval_const_expr(
						gd.init, &self.scopes, &self.tx
					);
					if cv.kind != middle.sema.const_eval.ConstKind.Invalid {
						sym.has_const_value = true;
						sym.const_value_is_float = cv.kind
							== middle.sema.const_eval.ConstKind.Float;
						sym.const_int_val = cv.int_val;
						sym.const_flt_val = cv.flt_val;
						sym.const_bool_val = cv.bool_val;
					}
				}
				if is_imported {
					if sym.is_pub && self.scopes.lookup_current(sym.simple) == null {
						added_sym = self.scopes.define(sym);
					} else {
						let raw: *mut u8 = front.ast.arena_alloc(@of.size(middle.symbol.Symbol));
						if raw != null {
							let ptr: *mut middle.symbol.Symbol = raw cast *mut middle.symbol.Symbol;
							*ptr = sym;
							added_sym = ptr;
						}
					}
				} else if self.scopes.define_or_replace_imported(sym) == null {
					front.log.report(
						front.log.Level.Error,
						gd.loc,
						"duplicate global declaration",
						front.log.DiagCode.DuplicateDeclaration
					);
				}
			}
			.Trait => {
				if td.trait_decl != null {
					if is_imported {
						self.foreign_traits.push(td.trait_decl.name);
					} else {
						self.traits.push(td.trait_decl);
					}
				}
			}
			.Impl => {
				let imp: *front.ast.ImplDecl = td.impl_decl;
				if imp != null {
					let mut is_gen_imp: bool = imp.generic_params.len > 0;
					if !is_gen_imp && imp.target_type != null && imp.target_type.generic_args.len
						> 0 {
						for let mut ga: usize = 0; ga < imp.target_type.generic_args.len; ga += 1 {
							let arg_tr: *front.ast.TypeRef =
								imp.target_type.generic_args.data[ga].ty;
							if arg_tr != null && arg_tr.kind == front.ast.TypeRefKind.Named
								&& arg_tr.path.len == 1
								&& middle.types.prim_from_name(&self.tx, arg_tr.path.data[0])
								== null
								&& self.scopes.lookup(arg_tr.path.data[0]) == null {
								is_gen_imp = true;
								break;
							}
						}
					}
					if is_gen_imp {
						let ge: GenericImplEntry = {
							.imp = imp,
							.mod_path = mod_path != null ? *mod_path : {
								.data = null,
								.len = 0,
								.cap = 0
							}
						};
						self.generic_impls.push(ge);
					} else if imp.target_type != null {
						let target_ty: *mut middle.types.StType = self.resolve_type(
							imp.target_type
						);
						if target_ty != null && !middle.types.is_poison(target_ty) {
							let tu_chk: *mut middle.types.StType = middle.types.underlying_type(
								target_ty
							);
							if !is_imported && tu_chk != null && tu_chk.is_foreign {
								let mut tb: [64]u8;
								let tstr: []u8 = middle.types.format_type(target_ty, &tb[0], 64);
								if imp.is_inherent {
									let mut mb: [200]u8;
									let mut mp: usize = 0;
									put_str_buf(
										&mb[0],
										&mp,
										200,
										"cannot define inherent implementation for foreign type `"
									);
									put_str_buf(&mb[0], &mp, 200, tstr);
									put_str_buf(&mb[0], &mp, 200, "`");
									front.log.report_custom(
										front.log.Level.Error,
										imp.loc,
										mb[0..mp],
										"E_ORPHAN_RULE",
										front.log.Phase.Semantic
									);
								} else if imp.trait_name.len > 0 {
									let mut is_ft: bool = false;
									for let mut fti: usize = 0; fti
										< self.foreign_traits.len; fti += 1 {
										if std.str.eq(
											self.foreign_traits.data[fti],
											imp.trait_name
										) {
											is_ft = true;
											break;
										}
									}
									if is_ft {
										let mut mb: [200]u8;
										let mut mp: usize = 0;
										put_str_buf(
											&mb[0],
											&mp,
											200,
											"cannot implement foreign trait `"
										);
										put_str_buf(&mb[0], &mp, 200, imp.trait_name);
										put_str_buf(&mb[0], &mp, 200, "` for foreign type `");
										put_str_buf(&mb[0], &mp, 200, tstr);
										put_str_buf(&mb[0], &mp, 200, "`");
										front.log.report_custom(
											front.log.Level.Error,
											imp.loc,
											mb[0..mp],
											"E_ORPHAN_RULE",
											front.log.Phase.Semantic
										);
									}
								}
							}
							if !imp.is_inherent && imp.trait_name.len > 0 {
								let tu: *mut middle.types.StType = middle.types.underlying_type(
									target_ty
								);
								for let mut ti: usize = 0; ti < self.trait_impls.len; ti += 1 {
									if std.str.eq(
										self.trait_impls.data[ti].trait_name,
										imp.trait_name
									)
										&& middle.types.eq_type(
											self.trait_impls.data[ti].target_ty,
											tu
										) {
										let mut tb: [64]u8;
										let tstr: []u8 = middle.types.format_type(
											target_ty,
											&tb[0],
											64
										);
										let mut mb: [200]u8;
										let mut mp: usize = 0;
										put_str_buf(
											&mb[0],
											&mp,
											200,
											"duplicate implementation of trait `"
										);
										put_str_buf(&mb[0], &mp, 200, imp.trait_name);
										put_str_buf(&mb[0], &mp, 200, "` for type `");
										put_str_buf(&mb[0], &mp, 200, tstr);
										put_str_buf(&mb[0], &mp, 200, "`");
										front.log.report_custom(
											front.log.Level.Error,
											imp.loc,
											mb[0..mp],
											"E_DUPLICATE_IMPL",
											front.log.Phase.Semantic
										);
										break;
									}
								}
								let mut tdecl: *front.ast.TraitDecl = null;
								for let mut ti: usize = 0; ti < self.traits.len; ti += 1 {
									if std.str.eq(self.traits.data[ti].name, imp.trait_name) {
										tdecl = self.traits.data[ti];
										break;
									}
								}
								if tdecl != null {
									let prev_self_t: *mut middle.types.StType =
										self.current_self_ty;
									self.current_self_ty = target_ty;
									for let mut tm: usize = 0; tm < tdecl.methods.len; tm += 1 {
										let req: *front.ast.FnDecl = tdecl.methods.data[tm];
										let mut found: *front.ast.FnDecl = null;
										for let mut im: usize = 0; im < imp.methods.len; im += 1 {
											if std.str.eq(imp.methods.data[im].name, req.name) {
												found = imp.methods.data[im];
												break;
											}
										}
										if found == null {
											if req.body == null {
												let mut mb: [200]u8;
												let mut mp: usize = 0;
												put_str_buf(
													&mb[0],
													&mp,
													200,
													"missing implementation for trait method `"
												);
												put_str_buf(&mb[0], &mp, 200, req.name);
												put_str_buf(&mb[0], &mp, 200, "` of trait `");
												put_str_buf(&mb[0], &mp, 200, imp.trait_name);
												put_str_buf(&mb[0], &mp, 200, "`");
												front.log.report_custom(
													front.log.Level.Error,
													imp.loc,
													mb[0..mp],
													"E_TRAIT_MISSING_METHOD",
													front.log.Phase.Semantic
												);
											}
										} else {
											let pcnt: usize = req.params.len < found.params.len
												? req.params.len : found.params.len;
											for let mut pi: usize = 0; pi < pcnt; pi += 1 {
												let ety: *mut middle.types.StType =
													self.resolve_type(req.params.data[pi].ty);
												let gty: *mut middle.types.StType =
													self.resolve_type(found.params.data[pi].ty);
												if !middle.types.eq_type(ety, gty) {
													let mut eb: [64]u8;
													let mut gb: [64]u8;
													let estr: []u8 = middle.types.format_type(
														ety,
														&eb[0],
														64
													);
													let gstr: []u8 = middle.types.format_type(
														gty,
														&gb[0],
														64
													);
													let mut mb: [220]u8;
													let mut mp: usize = 0;
													put_str_buf(&mb[0], &mp, 220, "parameter ");
													put_u64_buf(
														&mb[0],
														&mp,
														220,
														(pi + 1) cast u64
													);
													put_str_buf(&mb[0], &mp, 220, " of method `");
													put_str_buf(&mb[0], &mp, 220, found.name);
													put_str_buf(
														&mb[0],
														&mp,
														220,
														"` has mismatched type: expected `"
													);
													put_str_buf(&mb[0], &mp, 220, estr);
													put_str_buf(&mb[0], &mp, 220, "`, got `");
													put_str_buf(&mb[0], &mp, 220, gstr);
													put_str_buf(&mb[0], &mp, 220, "`");
													front.log.report_custom(
														front.log.Level.Error,
														found.loc,
														mb[0..mp],
														"E_TRAIT_SIGNATURE_MISMATCH",
														front.log.Phase.Semantic
													);
												}
											}
											let eret: *mut middle.types.StType =
												self.resolve_type(req.ret);
											let gret: *mut middle.types.StType =
												self.resolve_type(found.ret);
											if req.params.len != found.params.len
												|| !middle.types.eq_type(eret, gret) {
												front.log.report_custom(
													front.log.Level.Error,
													found.loc,
													"trait method signature mismatch",
													"E_TRAIT_SIGNATURE_MISMATCH",
													front.log.Phase.Semantic
												);
											}
										}
									}
									for let mut im: usize = 0; im < imp.methods.len; im += 1 {
										let imd: *front.ast.FnDecl = imp.methods.data[im];
										let mut in_tr: bool = false;
										for let mut tm: usize = 0; tm < tdecl.methods.len; tm += 1 {
											if std.str.eq(tdecl.methods.data[tm].name, imd.name) {
												in_tr = true;
												break;
											}
										}
										if !in_tr {
											let mut mb: [200]u8;
											let mut mp: usize = 0;
											put_str_buf(&mb[0], &mp, 200, "method `");
											put_str_buf(&mb[0], &mp, 200, imd.name);
											put_str_buf(
												&mb[0],
												&mp,
												200,
												"` is not declared in trait `"
											);
											put_str_buf(&mb[0], &mp, 200, imp.trait_name);
											put_str_buf(&mb[0], &mp, 200, "`");
											front.log.report_custom(
												front.log.Level.Error,
												imd.loc,
												mb[0..mp],
												"E_TRAIT_UNKNOWN_METHOD",
												front.log.Phase.Semantic
											);
										}
									}
									self.current_self_ty = prev_self_t;
								}
								let te: TraitImplEntry = {
									.trait_name = imp.trait_name,
									.target_ty = tu
								};
								self.trait_impls.push(te);
							}
							for let mut i: usize = 0; i < imp.methods.len; i += 1 {
								let msym: *mut middle.symbol.Symbol = self.register_impl_method(
									target_ty,
									imp.methods.data[i],
									mod_path
								);
								if msym != null && !imp.is_inherent && imp.trait_name.len > 0 {
									let mut mpath: front.ast.ValList<[]u8> = {
										.data = null,
										.len = 0,
										.cap = 0
									};
									if mod_path != null {
										for let mut k: usize = 0; k < mod_path.len; k += 1 {
											mpath.push(mod_path.data[k]);
										}
									}
									mpath.push(imp.trait_name);
									mpath.push(target_ty.name);
									msym.mangled = middle.symbol.mangle_fn_with_sig(
										&mpath,
										imp.methods.data[i].name,
										msym.ty,
										&imp.methods.data[i].attrs
									);
									mpath.free_array();
								}
							}
							if !imp.is_inherent && imp.trait_name.len > 0 {
								for let mut ti: usize = 0; ti < self.traits.len; ti += 1 {
									if std.str.eq(self.traits.data[ti].name, imp.trait_name) {
										let tdecl: *front.ast.TraitDecl = self.traits.data[ti];
										for let mut tm: usize = 0; tm < tdecl.methods.len; tm += 1 {
											let req: *front.ast.FnDecl = tdecl.methods.data[tm];
											if req.body == null {
												continue;
											}
											let mut found: bool = false;
											for let mut im: usize = 0; im
												< imp.methods.len; im += 1 {
												if std.str.eq(imp.methods.data[im].name, req.name) {
													found = true;
													break;
												}
											}
											if !found {
												let msym: *mut middle.symbol.Symbol =
													self.register_impl_method(
														target_ty,
														req,
														mod_path
													);
												if msym != null {
													let tn: []u8 = imp.trait_name;
													let old_m: []u8 = msym.mangled;
													let mbuf: *mut u8 = front.ast.arena_alloc(
										tn.len + 1 + old_m.len
									);
													if mbuf != null {
														std.mem.copy(mbuf, tn.ptr, tn.len);
														mbuf[tn.len] = '$' cast u8;
														std.mem.copy(
															&mbuf[tn.len + 1],
															old_m.ptr,
															old_m.len
														);
														msym.mangled =
															mbuf[0..(tn.len + 1 + old_m.len)];
													}
												}
											}
										}
										break;
									}
								}
							}
							for let mut ci: usize = 0; ci < imp.consts.len; ci += 1 {
								let gd: *front.ast.GlobalDecl = imp.consts.data[ci];
								if gd == null {
									continue;
								}
								let cty: *mut middle.types.StType = self.resolve_type(gd.ty);
								let mut csym: middle.symbol.Symbol = middle.symbol.make_symbol(
									middle.symbol.SymKind.Const,
									gd.name,
									gd.loc
								);
								csym.ty = cty;
								csym.glob = gd;
								csym.is_pub = gd.is_pub;
								if gd.init != null {
									let cv: middle.sema.const_eval.ConstVal =
										middle.sema.const_eval.eval_const_expr(
											gd.init,
											&self.scopes,
											&self.tx
										);
									if cv.kind != middle.sema.const_eval.ConstKind.Invalid {
										csym.has_const_value = true;
										csym.const_value_is_float = cv.kind
											== middle.sema.const_eval.ConstKind.Float;
										csym.const_int_val = cv.int_val;
										csym.const_flt_val = cv.flt_val;
										csym.const_bool_val = cv.bool_val;
									}
								}
								let raw: *mut u8 = front.ast.arena_alloc(
									@of.size(middle.symbol.Symbol)
								);
								if raw != null {
									let ptr: *mut middle.symbol.Symbol = raw
										cast *mut middle.symbol.Symbol;
									*ptr = csym;
									let ice: ImplConstEntry = {
										.target_ty = middle.types.underlying_type(target_ty),
										.name = gd.name,
										.sym = ptr
									};
									self.impl_consts.push(ice);
								}
							}
						}
					}
				}
			}
			_ => {}
		}
		if is_imported && added_sym != null && mod_path != null {
			added_sym.mod_path = *mod_path;
			let qs: QualifiedSym = { .mod_path = *mod_path, .sym = added_sym };
			self.add_imported_sym(qs);
		}
	}

	/// Executes `register_top_decl` (register top decl).
	pub fn register_top_decl(self: *mut SemaContext, td: *front.ast.TopDecl) -> void {
		self.register_top_decl_in_mod(td, null, false);
	}

	/// Executes `populate_type_fields` (populate type fields).
	pub fn populate_type_fields(self: *mut SemaContext, td: *front.ast.TopDecl) -> void {
		if td == null {
			return;
		}
		if td.kind == front.ast.TopKind.Struct && td.st != null && td.st.generic_params.len == 0 {
			let mut sym: *middle.symbol.Symbol = self.current_mod_path != null
				? self.lookup_in_mod(self.current_mod_path, td.st.name)
				: null;
			if sym == null {
				sym = self.scopes.lookup(td.st.name);
			}
			if sym != null && sym.ty != null {
				for let mut i: usize = 0; i < td.st.field_names.len; i += 1 {
					sym.ty.field_names.push(td.st.field_names.data[i]);
					sym.ty.fields.push(self.resolve_type(td.st.field_types.data[i]));
					sym.ty.field_is_pub.push(td.st.field_is_pub.data[i]);
				}
				finalize_struct_layout(
					sym.ty,
					&td.st.attrs,
					(self.tx.pointer_width / 8) cast usize,
					td.st.loc
				);
			}
		} else if td.kind == front.ast.TopKind.Union && td.un != null && td.un.generic_params.len
			== 0 {
			let mut sym: *middle.symbol.Symbol = self.current_mod_path != null
				? self.lookup_in_mod(self.current_mod_path, td.un.name)
				: null;
			if sym == null {
				sym = self.scopes.lookup(td.un.name);
			}
			if sym != null && sym.ty != null {
				for let mut i: usize = 0; i < td.un.field_names.len; i += 1 {
					sym.ty.field_names.push(td.un.field_names.data[i]);
					sym.ty.fields.push(self.resolve_type(td.un.field_types.data[i]));
					sym.ty.field_is_pub.push(td.un.field_is_pub.data[i]);
				}
			}
		} else if td.kind == front.ast.TopKind.Enum && td.en != null && td.en.generic_params.len
			== 0 {
			let mut sym: *middle.symbol.Symbol = self.current_mod_path != null
				? self.lookup_in_mod(self.current_mod_path, td.en.name)
				: null;
			if sym == null {
				sym = self.scopes.lookup(td.en.name);
			}
			if sym != null && sym.ty != null && sym.ty.field_names.len == 0 {
				self.populate_enum_type(td.en, sym.ty);
			}
		}
	}

	/// Executes `check_fn_body` (check fn body).
}
