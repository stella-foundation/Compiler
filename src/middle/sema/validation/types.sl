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
	pub fn resolve_type(
		self: *mut SemaContext,
		tr: *front.ast.TypeRef
	) -> *mut middle.types.StType {
		if tr == null {
			return self.tx.void_t;
		}
		match tr.kind {
			.SelfType => {
				if self.current_self_ty != null {
					return self.current_self_ty;
				}
				front.log.report_custom(
					front.log.Level.Error,
					tr.loc,
					"`Self` is only allowed within trait definitions and impl blocks",
					"E_INVALID_SELF",
					front.log.Phase.Semantic
				);
				return self.tx.self_t;
			}
			.Pointer => {
				let base: *mut middle.types.StType = self.resolve_type(tr.base);
				return self.tx.pointer(base, tr.is_mutable, tr.is_volatile);
			}
			.Slice => {
				let elem: *mut middle.types.StType = self.resolve_type(tr.base);
				return self.tx.slice(elem, tr.is_mutable, tr.is_volatile);
			}
			.Array => {
				let elem: *mut middle.types.StType = self.resolve_type(tr.base);
				let mut len: usize = tr.array_len;
				if tr.array_len_expr != null {
					let mut found_gconst: bool = false;
					if tr.array_len_expr.kind == front.ast.ExprKind.Ident
						&& tr.array_len_expr.path.len == 1 {
						for let mut si: usize = self.generic_subst.len; si > 0; {
							si -= 1;
							if self.generic_subst.data[si].is_const
								&& std.str.eq(
									self.generic_subst.data[si].name,
									tr.array_len_expr.path.data[0]
								) {
								len = self.generic_subst.data[si].const_val cast usize;
								found_gconst = true;
								break;
							}
						}
					}
					if !found_gconst {
						let cv: middle.sema.const_eval.ConstVal =
							middle.sema.const_eval.eval_const_expr(
							tr.array_len_expr, &self.scopes, &self.tx
						);
						let arr_err: []u8 =
							"array length is not a valid non-negative compile-time constant";
						if cv.kind == middle.sema.const_eval.ConstKind.Int {
							if (cv.int_val cast i64) < 0 {
								front.log.report(
									front.log.Level.Error,
									tr.loc,
									arr_err,
									front.log.DiagCode.General
								);
							} else {
								len = cv.int_val cast usize;
							}
						} else if !tr.array_len_inferred && tr.array_len_expr.kind
							!= front.ast.ExprKind.IntLit {
							front.log.report(
								front.log.Level.Error,
								tr.loc,
								arr_err,
								front.log.DiagCode.General
							);
						}
					}
				}
				return self.tx.array_of(elem, len);
			}
			.Function => {
				let mut params: front.ast.PtrList<middle.types.StType> = {
					.data = null,
					.len = 0,
					.cap = 0
				};
				for let mut i: usize = 0; i < tr.fn_params.len; i += 1 {
					params.push(self.resolve_type(tr.fn_params.data[i]));
				}
				let ret: *mut middle.types.StType = self.resolve_type(tr.fn_ret);
				let fabi: middle.types.AbiKind = extract_abi_attr(&tr.fn_attrs, tr.loc, true);
				let ft: *mut middle.types.StType = self.tx.function_of(
					params,
					ret,
					tr.fn_variadic,
					fabi
				);
				params.free_array();
				return ft;
			}
			.TypeOf => {
				if tr.typeof_expr != null {
					return self.check_expr(tr.typeof_expr, null);
				}
				return self.tx.poison_t;
			}
			.Named => {
				if tr.path.len <= 1 {
					let name: []u8 = tr.path.len == 1 ? tr.path.data[0] : tr.name;
					let subst_ty: *mut middle.types.StType =
						middle.sema.generics.lookup_generic_subst(&self.generic_subst, name);
					if subst_ty != null {
						return subst_ty;
					}
					let prim: *mut middle.types.StType = middle.types.prim_from_name(
						&self.tx,
						name
					);
					if prim != null {
						return prim;
					}
					if self.current_mod_path != null {
						let msym: *mut middle.symbol.Symbol = self.lookup_in_mod_or_parents(
							self.current_mod_path,
							name
						);
						if msym != null && msym.ty != null {
							msym.used = true;
							if tr.generic_args.len > 0 {
								return self.instantiate_generic_type(
									msym,
									&tr.generic_args,
									tr.loc
								);
							}
							return msym.ty;
						}
					}
					let sym: *mut middle.symbol.Symbol = self.scopes.lookup(name);
					if sym != null && sym.ty != null {
						sym.used = true;
						if tr.generic_args.len > 0 {
							return self.instantiate_generic_type(sym, &tr.generic_args, tr.loc);
						}
						return sym.ty;
					}
					for let mut mi: usize = 0; mi < self.mod_names.len; mi += 1 {
						if std.str.eq(self.mod_names.data[mi], name) {
							let mut mmb: [160]u8;
							let mut mmp: usize = 0;
							put_str_buf(&mmb[0], &mmp, 160, "`");
							put_str_buf(&mmb[0], &mmp, 160, name);
							put_str_buf(&mmb[0], &mmp, 160, "` is a module, not a type");
							front.log.report(
								front.log.Level.Error,
								tr.loc,
								mmb[0..mmp],
								front.log.DiagCode.UndefinedType
							);
							return self.tx.poison_t;
						}
					}
					let mut mb: [160]u8;
					let mut mp: usize = 0;
					let p1: []u8 = "unknown type `";
					std.mem.copy(&mb[mp], p1.ptr, p1.len);
					mp += p1.len;
					let nlen: usize = name.len < 120 ? name.len : 120;
					if nlen > 0 {
						std.mem.copy(&mb[mp], name.ptr, nlen);
						mp += nlen;
					}
					mb[mp] = '`' cast u8;
					mp += 1;
					front.log.report(
						front.log.Level.Error,
						tr.loc,
						mb[0..mp],
						front.log.DiagCode.UndefinedType
					);
					return self.tx.poison_t;
				}
				let qsym: *mut middle.symbol.Symbol = self.lookup_qualified(&tr.path, tr.path.len);
				if qsym != null && qsym.ty != null {
					if tr.generic_args.len > 0 {
						return self.instantiate_generic_type(qsym, &tr.generic_args, tr.loc);
					}
					return qsym.ty;
				}
				// Qualified path fallback: check last segment
				let last: []u8 = tr.path.data[tr.path.len - 1];
				let sym: *middle.symbol.Symbol = self.scopes.lookup(last);
				if sym != null && sym.ty != null {
					if tr.generic_args.len > 0 {
						return self.instantiate_generic_type(sym, &tr.generic_args, tr.loc);
					}
					return sym.ty;
				}
				let mut mb2: [160]u8;
				let mut mp2: usize = 0;
				let p1b: []u8 = "unknown type `";
				std.mem.copy(&mb2[mp2], p1b.ptr, p1b.len);
				mp2 += p1b.len;
				let nlen2: usize = last.len < 120 ? last.len : 120;
				if nlen2 > 0 {
					std.mem.copy(&mb2[mp2], last.ptr, nlen2);
					mp2 += nlen2;
				}
				mb2[mp2] = '`' cast u8;
				mp2 += 1;
				front.log.report(
					front.log.Level.Error,
					tr.loc,
					mb2[0..mp2],
					front.log.DiagCode.UndefinedType
				);
				return self.tx.poison_t;
			}
		}
	}

	/// Executes `check_expr` (check expr).
}
