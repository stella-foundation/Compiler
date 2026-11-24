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
	pub fn check_stmt(self: *mut SemaContext, s: *front.ast.Stmt) -> void {
		if s == null {
			return;
		}
		match s.kind {
			.Block => {
				self.scopes.enter();
				for let mut i: usize = 0; i < s.body.len; i += 1 {
					self.check_stmt(s.body.data[i]);
				}
				self.scopes.leave();
			}
			.ExprStmt => {
				self.check_expr(s.expr, null);
			}
			.VarDecl | .ConstDecl => {
				for let mut i: usize = 0; i < s.vars.len; i += 1 {
					let v: front.ast.VarDeclInfo = s.vars.data[i];
					let mut vty: *mut middle.types.StType = self.resolve_type(v.ty);
					if v.ty != null && v.ty.kind == front.ast.TypeRefKind.Array
						&& v.ty.array_len_inferred && v.init != null {
						let elem: *mut middle.types.StType = self.resolve_type(v.ty.base);
						if v.init.kind == front.ast.ExprKind.ArrayLit {
							vty = self.tx.array_of(elem, v.init.args.len);
						} else if v.init.kind == front.ast.ExprKind.StringLit {
							let slen: usize = v.init.is_cstring ? (v.init.str_val.len + 1)
								: v.init.str_val.len;
							vty = self.tx.array_of(elem, slen);
						} else if v.init.kind == front.ast.ExprKind.SrcEmbed {
							self.check_expr(v.init, null);
							vty = self.tx.array_of(elem, v.init.str_val.len);
						}
					}
					if v.init != null {
						let vu: *mut middle.types.StType = middle.types.underlying_type(vty);
						if vu != null && vu.kind == middle.types.TypeKind.Float {
							let fl: *front.ast.Expr = unwrap_float_lit(v.init);
							if fl != null && !fl.flt_lossy_ok && !is_exact_float_lit(fl.str_val) {
								let mut tb: [64]u8;
								let tstr: []u8 = middle.types.format_type(vty, &tb[0], 64);
								let mut mb: [200]u8;
								let mut mp: usize = 0;
								put_str_buf(&mb[0], &mp, 200, "cannot initialize `");
								put_str_buf(&mb[0], &mp, 200, v.name);
								put_str_buf(&mb[0], &mp, 200, "`: value not representable in `");
								put_str_buf(&mb[0], &mp, 200, tstr);
								put_str_buf(&mb[0], &mp, 200, "`");
								front.log.report(
									front.log.Level.Error,
									v.init.loc,
									mb[0..mp],
									front.log.DiagCode.TypeMismatch
								);
							}
						}
						let ity: *mut middle.types.StType = self.check_expr(v.init, vty);
						if v.ty != null && v.ty.array_len_inferred {
							v.init.sema_ty = vty cast *void;
						}
						if !middle.types.is_poison(vty) && !middle.types.is_poison(ity)
							&& !middle.types.is_assignable_type(vty, ity) {
							let mut eb: [128]u8;
							let mut ab: [128]u8;
							let es: []u8 = middle.types.format_type(vty, &eb[0], 128);
							let as_s: []u8 = middle.types.format_type(ity, &ab[0], 128);
							let mut mb: [320]u8;
							let mut mp: usize = 0;
							let p1: []u8 =
								"initializer type does not match declared type: expected `";
							let p2: []u8 = "`, got `";
							let p3: []u8 = "`";
							std.mem.copy(&mb[mp], p1.ptr, p1.len);
							mp += p1.len;
							std.mem.copy(&mb[mp], es.ptr, es.len);
							mp += es.len;
							std.mem.copy(&mb[mp], p2.ptr, p2.len);
							mp += p2.len;
							std.mem.copy(&mb[mp], as_s.ptr, as_s.len);
							mp += as_s.len;
							std.mem.copy(&mb[mp], p3.ptr, p3.len);
							mp += p3.len;
							front.log.report(
								front.log.Level.Error,
								v.loc,
								mb[0..mp],
								front.log.DiagCode.TypeMismatch
							);
						}
					}
					let mut sym: middle.symbol.Symbol = middle.symbol.make_symbol(
						v.is_const ? middle.symbol.SymKind.Const : middle.symbol.SymKind.Var,
						v.name,
						v.loc
					);
					sym.ty = vty;
					sym.is_mutable = v.is_mutable;
					if v.is_const && v.init != null {
						let cv: middle.sema.const_eval.ConstVal =
							middle.sema.const_eval.eval_const_expr(
							v.init, &self.scopes, &self.tx
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
					if !std.str.eq(v.name, "_") && self.scopes.define(sym) == null {
						front.log.report(
							front.log.Level.Error,
							v.loc,
							"duplicate local declaration",
							front.log.DiagCode.DuplicateDeclaration
						);
					}
				}
			}
			.If => {
				let cty: *mut middle.types.StType = self.check_expr(s.cond, self.tx.bool_t);
				if !middle.types.is_poison(cty) && middle.types.underlying_type(cty).kind
					!= middle.types.TypeKind.Bool {
					front.log.report(
						front.log.Level.Error,
						s.loc,
						"if condition must be bool",
						front.log.DiagCode.TypeMismatch
					);
				}
				self.check_stmt(s.then_block);
				if s.else_block != null {
					self.check_stmt(s.else_block);
				}
			}
			.For => {
				self.scopes.enter();
				if s.for_init != null {
					self.check_stmt(s.for_init);
				}
				if s.for_cond != null {
					let cty: *mut middle.types.StType = self.check_expr(s.for_cond, self.tx.bool_t);
					if !middle.types.is_poison(cty) && middle.types.underlying_type(cty).kind
						!= middle.types.TypeKind.Bool {
						front.log.report(
							front.log.Level.Error,
							s.loc,
							"for condition must be bool",
							front.log.DiagCode.TypeMismatch
						);
					}
				}
				if s.for_step != null {
					self.check_expr(s.for_step, null);
				}
				self.check_stmt(s.loop_body);
				self.scopes.leave();
			}
			.Match => {
				let scr_ty: *mut middle.types.StType = self.check_expr(s.scrutinee, null);
				let scr_u: *mut middle.types.StType = middle.types.underlying_type(scr_ty);
				let scr_is_ptr: bool = scr_u != null && scr_u.kind == middle.types.TypeKind.Pointer;
				let scr_is_mut: bool = scr_is_ptr && scr_u.is_mutable;
				let enum_u: *mut middle.types.StType = scr_is_ptr
					? middle.types.underlying_type(scr_u.base) : scr_u;
				let mut has_wildcard: bool = false;
				let mut seen_vals: front.ast.ValList<u64> = { .data = null, .len = 0, .cap = 0 };
				for let mut i: usize = 0; i < s.arms.len; i += 1 {
					let arm: front.ast.MatchArm = s.arms.data[i];
					if has_wildcard {
						front.log.report(
							front.log.Level.Error,
							arm.loc,
							"unreachable match arm",
							front.log.DiagCode.InvalidControlFlow
						);
					}
					self.scopes.enter();
					for let mut j: usize = 0; j < arm.patterns.len; j += 1 {
						let pat: front.ast.MatchPattern = arm.patterns.data[j];
						if arm.patterns.len > 1 && pat.bindings.len > 0 {
							front.log.report(
								front.log.Level.Error,
								pat.loc,
								"bindings are not allowed in OR-patterns",
								front.log.DiagCode.InvalidControlFlow
							);
						}
						if pat.kind == front.ast.MatchPatternKind.Wildcard {
							has_wildcard = true;
						} else if pat.kind == front.ast.MatchPatternKind.Value && pat.expr != null {
							self.check_expr(pat.expr, scr_ty);
							if enum_u != null && enum_u.kind == middle.types.TypeKind.Enum
								&& (pat.expr.kind == front.ast.ExprKind.EnumMember || pat.expr.kind
								== front.ast.ExprKind.Member) {
								let vidx: isize = middle.types.field_index(enum_u, pat.expr.member);
								if vidx >= 0 {
									let key: u64 = vidx cast u64;
									let mut dup: bool = false;
									for let mut si: usize = 0; si < seen_vals.len; si += 1 {
										if seen_vals.data[si] == key {
											dup = true;
											break;
										}
									}
									if dup {
										front.log.report(
											front.log.Level.Error,
											pat.loc,
											"duplicate pattern in match",
											front.log.DiagCode.InvalidControlFlow
										);
									} else {
										seen_vals.push(key);
									}
								}
							} else {
								let cv: middle.sema.const_eval.ConstVal =
									middle.sema.const_eval.eval_const_expr(
										pat.expr,
										&self.scopes,
										&self.tx
									);
								if cv.kind == middle.sema.const_eval.ConstKind.Int {
									let mut dup: bool = false;
									for let mut si: usize = 0; si < seen_vals.len; si += 1 {
										if seen_vals.data[si] == cv.int_val {
											dup = true;
											break;
										}
									}
									if dup {
										front.log.report(
											front.log.Level.Error,
											pat.loc,
											"duplicate pattern in match",
											front.log.DiagCode.InvalidControlFlow
										);
									} else {
										seen_vals.push(cv.int_val);
									}
								}
							}
						} else if pat.kind == front.ast.MatchPatternKind.Variant {
							let mut vinfo_ptr: *middle.types.EnumVariantInfo = null;
							if enum_u != null && enum_u.kind == middle.types.TypeKind.Enum
								&& pat.expr != null {
								let vname: []u8 = pat.expr.member;
								let vidx: isize = middle.types.field_index(enum_u, vname);
								if vidx >= 0 && (vidx cast usize) < enum_u.enum_variants.len {
									vinfo_ptr = &enum_u.enum_variants.data[vidx cast usize];
									let key: u64 = vidx cast u64;
									let mut dup: bool = false;
									for let mut si: usize = 0; si < seen_vals.len; si += 1 {
										if seen_vals.data[si] == key {
											dup = true;
											break;
										}
									}
									if dup {
										front.log.report(
											front.log.Level.Error,
											pat.loc,
											"duplicate pattern in match",
											front.log.DiagCode.InvalidControlFlow
										);
									} else {
										seen_vals.push(key);
									}
									if vinfo_ptr.payload_kind == front.ast.EnumPayloadKind.Struct
										&& pat.bindings.len < vinfo_ptr.field_names.len {
										front.log.report(
											front.log.Level.Error,
											pat.loc,
											"missing field in struct variant pattern",
											front.log.DiagCode.InvalidControlFlow
										);
									}
								}
							}
							for let mut k: usize = 0; k < pat.bindings.len; k += 1 {
								let b: front.ast.MatchBinding = pat.bindings.data[k];
								if !std.str.eq(b.name, "_") {
									let mut bsym: middle.symbol.Symbol = middle.symbol.make_symbol(
										middle.symbol.SymKind.Var,
										b.name,
										b.loc
									);
									let mut fidx: usize = k;
									if vinfo_ptr != null && b.field_name.len > 0 {
										for let mut fi: usize = 0; fi
											< vinfo_ptr.field_names.len; fi += 1 {
											if std.str.eq(
												vinfo_ptr.field_names.data[fi],
												b.field_name
											) {
												fidx = fi;
												break;
											}
										}
									}
									if vinfo_ptr != null && fidx < vinfo_ptr.field_types.len {
										let fty: *mut middle.types.StType =
											vinfo_ptr.field_types.data[fidx];
										bsym.ty = scr_is_ptr
											? self.tx.pointer(fty, scr_is_mut, false) : fty;
									} else {
										bsym.ty = self.tx.poison_t;
									}
									bsym.is_mutable = b.is_mut;
									self.scopes.define(bsym);
								}
							}
						}
					}
					self.check_stmt(arm.body);
					self.scopes.leave();
				}
				if !has_wildcard {
					if enum_u != null && enum_u.kind == middle.types.TypeKind.Enum && seen_vals.len
						< enum_u.field_names.len {
						front.log.report(
							front.log.Level.Error,
							s.loc,
							"non-exhaustive match on enum",
							front.log.DiagCode.InvalidControlFlow
						);
					} else if scr_u != null
						&& (scr_u.kind == middle.types.TypeKind.SInt || scr_u.kind
						== middle.types.TypeKind.UInt) {
						front.log.report(
							front.log.Level.Error,
							s.loc,
							"non-exhaustive match on integer type",
							front.log.DiagCode.InvalidControlFlow
						);
					}
				}
				seen_vals.free_array();
			}
			.Return => {
				if self.current_ret_ty == null || self.current_ret_ty.kind
					== middle.types.TypeKind.Void {
					if s.ret_val != null {
						front.log.report(
							front.log.Level.Error,
							s.loc,
							"void function cannot return a value",
							front.log.DiagCode.TypeMismatch
						);
					}
				} else {
					if s.ret_val == null {
						front.log.report(
							front.log.Level.Error,
							s.loc,
							"non-void function must return a value",
							front.log.DiagCode.TypeMismatch
						);
					} else {
						let rty: *mut middle.types.StType = self.check_expr(
							s.ret_val,
							self.current_ret_ty
						);
						if !middle.types.is_poison(rty)
							&& !middle.types.is_assignable_type(self.current_ret_ty, rty) {
							front.log.report(
								front.log.Level.Error,
								s.loc,
								"return type mismatch",
								front.log.DiagCode.TypeMismatch
							);
						}
					}
				}
				if self.current_fn_must_tail {
					let mut tail_ok: bool = false;
					if s.ret_val != null && s.ret_val.kind == front.ast.ExprKind.Call
						&& s.ret_val.lhs != null && s.ret_val.lhs.sema_sym != null {
						let csym: *middle.symbol.Symbol = s.ret_val.lhs.sema_sym
							cast *middle.symbol.Symbol;
						if csym.ty != null {
							let cu: *mut middle.types.StType = middle.types.underlying_type(
								csym.ty
							);
							if cu != null && cu.kind == middle.types.TypeKind.Function && cu.fn_abi
								== self.current_fn_abi {
								tail_ok = true;
							}
						}
					}
					if !tail_ok {
						let mut mb: [128]u8;
						let mut mp: usize = 0;
						put_str_buf(
							&mb[0],
							&mp,
							128,
							"#[must_tail] requires every reachable return to be a direct call "
						);
						put_str_buf(&mb[0], &mp, 128, "with an LLVM-compatible signature");
						front.log.report(
							front.log.Level.Error,
							s.loc,
							(&mb[0])[0..mp],
							front.log.DiagCode.InvalidAttribute
						);
					}
				}
			}
			.Defer => self.check_stmt(s.defer_body),
			.Yield => {
				if s.ret_val != null {
					let yty: *mut middle.types.StType = self.check_expr(
						s.ret_val,
						self.current_yield_ty
					);
					if self.current_yield_ty == null && yty != null
						&& !middle.types.is_poison(yty) {
						self.current_yield_ty = yty;
					}
				}
			}
			.Asm => {
				for let mut i: usize = 0; i < s.asm_outputs.len; i += 1 {
					self.check_expr(s.asm_outputs.data[i].operand, null);
				}
				for let mut i: usize = 0; i < s.asm_inputs.len; i += 1 {
					self.check_expr(s.asm_inputs.data[i].operand, null);
				}
			}
			_ => {}
		}
	}

	/// Executes `register_top_decl_in_mod` (register top decl in mod).
}
