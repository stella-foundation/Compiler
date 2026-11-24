mod back.codegen.expressions;
import "back/codegen/types.sl";
import "back/llvm_ctx.sl";
import "front/ast.sl";
import "front/token.sl";
import "llvm/core.sl";
import "llvm/ir.sl";
import "llvm/llvm.sl";
import "llvm/target.sl";
import "middle/sema/validation.sl";
import "middle/symbol.sl";
import "middle/types.sl";
import "std/mem.sl";
import "std/str.sl";

/// Represents the `LocalSlot` data structure.

pub fn emit_expr(
	cg: *mut CodegenState,
	e: *front.ast.Expr,
	expected: *mut middle.types.StType
) -> bind.llvm.core.Value {
	if e == null {
		return bind.llvm.core.wrap_value(null);
	}
	match e.kind {
		.IntLit => {
			let ty: *mut middle.types.StType = expr_type(cg, e, expected);
			let ll_ty: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
				&cg.lc.ctx,
				&cg.lc.td,
				ty
			);
			let is_signed: bool = middle.types.underlying_type(ty).kind
				== middle.types.TypeKind.SInt;
			return bind.llvm.core.constant.integer(ll_ty, e.int_val, is_signed);
		}
		.FloatLit => {
			let ty: *mut middle.types.StType = expr_type(cg, e, expected);
			let ll_ty: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
				&cg.lc.ctx,
				&cg.lc.td,
				ty
			);
			return bind.llvm.core.constant.real(ll_ty, e.flt_val);
		}
		.BoolLit => {
			let ll_ty: bind.llvm.core.Type = bind.llvm.core.type.int1(&cg.lc.ctx);
			return bind.llvm.core.constant.integer(
				ll_ty,
				e.int_val != 0 ? (1 cast u64) : (0 cast u64),
				false
			);
		}
		.CharLit => {
			let ll_ty: bind.llvm.core.Type = bind.llvm.core.type.int8(&cg.lc.ctx);
			return bind.llvm.core.constant.integer(ll_ty, e.char_val cast u64, false);
		}
		.StringLit | .SrcEmbed => {
			let exp_ty: *mut middle.types.StType = expected != null ? expected
				: (e.sema_ty cast *mut middle.types.StType);
			let exp_u: *mut middle.types.StType = middle.types.underlying_type(exp_ty);
			if exp_u != null && exp_u.kind == middle.types.TypeKind.Array {
				let arr_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
					&cg.lc.ctx,
					&cg.lc.td,
					exp_u
				);
				let i8_t: bind.llvm.core.Type = bind.llvm.core.type.int8(&cg.lc.ctx);
				let mut agg: bind.llvm.core.Value = bind.llvm.core.constant.null_value(arr_ll);
				let copy_len: usize = e.str_val.len < exp_u.array_len ? e.str_val.len
					: exp_u.array_len;
				for let mut i: usize = 0; i < copy_len; i += 1 {
					let ch: bind.llvm.core.Value = bind.llvm.core.constant.integer(
						i8_t,
						e.str_val.ptr[i] cast u64,
						false
					);
					agg = bind.llvm.ir.insert_value(&cg.lc.builder, agg, ch, i cast u32, c"sch");
				}
				return agg;
			}
			let ptr_val: bind.llvm.core.Value = emit_global_string(cg, e.str_val);
			if e.is_cstring {
				return ptr_val;
			}
			let slice_st: *mut middle.types.StType = cg.sema.tx.slice(
				cg.sema.tx.uint(8),
				false,
				false
			);
			let slice_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
				&cg.lc.ctx,
				&cg.lc.td,
				slice_st
			);
			let len_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
				&cg.lc.ctx,
				&cg.lc.td,
				cg.sema.tx.usize_t
			);
			let len_val: bind.llvm.core.Value = bind.llvm.core.constant.integer(
				len_ll,
				e.str_val.len cast u64,
				false
			);
			let mut agg: bind.llvm.core.Value = bind.llvm.core.constant.undef(slice_ll);
			agg = bind.llvm.ir.insert_value(&cg.lc.builder, agg, ptr_val, 0, c"s0");
			agg = bind.llvm.ir.insert_value(&cg.lc.builder, agg, len_val, 1, c"s1");
			return agg;
		}
		.NullLit => {
			let ty: *mut middle.types.StType = expected != null ? expected
				: cg.sema.tx.pointer(cg.sema.tx.void_t, false, false);
			return bind.llvm.core.constant.null_value(
				back.codegen.types.to_llvm_type(&cg.lc.ctx, &cg.lc.td, ty)
			);
		}
		.Ident => {
			if e.path.len == 1 {
				let loc_slot: *mut LocalSlot = find_local(cg, e.path.data[0]);
				if loc_slot != null {
					let cname: *mut u8 = cstr_from_slice(loc_slot.name);
					let lv: bind.llvm.core.Value = bind.llvm.ir.load(
						&cg.lc.builder,
						loc_slot.ll_ty,
						loc_slot.ptr,
						cname != null ? (cname cast *u8) : c"ld"
					);
					return lv;
				}
			}
			if e.sema_sym != null {
				let sym: *middle.symbol.Symbol = e.sema_sym cast *middle.symbol.Symbol;
				if sym.kind == middle.symbol.SymKind.Fn {
					if sym.fn_decl != null && sym.fn_decl.is_macro {
						return bind.llvm.core.wrap_value(null);
					}
					let fn_slot: *mut FnSlot = find_function(cg, sym.mangled);
					if fn_slot != null {
						return fn_slot.fn_val;
					}
				} else if sym.kind == middle.symbol.SymKind.Const && sym.has_const_value {
					let cty: *mut middle.types.StType = sym.ty != null ? sym.ty : expected;
					let ll_ty: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
						&cg.lc.ctx,
						&cg.lc.td,
						cty
					);
					if sym.const_value_is_float {
						return bind.llvm.core.constant.real(ll_ty, sym.const_flt_val);
					}
					return bind.llvm.core.constant.integer(ll_ty, sym.const_int_val, false);
				} else if sym.kind == middle.symbol.SymKind.Const && sym.has_const_value && sym.ty
					!= null {
					let cll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
						&cg.lc.ctx,
						&cg.lc.td,
						sym.ty
					);
					if sym.const_value_is_float {
						return bind.llvm.core.constant.real(cll, sym.const_flt_val);
					}
					if middle.types.underlying_type(sym.ty).kind == middle.types.TypeKind.Bool {
						return bind.llvm.core.constant.integer(
							cll,
							sym.const_bool_val ? (1 cast u64) : (0 cast u64),
							false
						);
					}
					let is_s: bool = middle.types.underlying_type(sym.ty).kind
						== middle.types.TypeKind.SInt;
					return bind.llvm.core.constant.integer(cll, sym.const_int_val, is_s);
				} else if sym.kind == middle.symbol.SymKind.Var || sym.kind
					== middle.symbol.SymKind.Const {
					let glob_slot: *mut GlobalSlot = find_global(cg, sym.mangled);
					if glob_slot != null {
						return bind.llvm.ir.load(
							&cg.lc.builder,
							glob_slot.ll_ty,
							glob_slot.ptr,
							c"gld"
						);
					}
				}
			}
			if e.path.len == 1 {
				let name: []u8 = e.path.data[0];
				let glob_slot: *mut GlobalSlot = find_global(cg, name);
				if glob_slot != null {
					return bind.llvm.ir.load(
						&cg.lc.builder,
						glob_slot.ll_ty,
						glob_slot.ptr,
						c"gld"
					);
				}
				let fn_slot: *mut FnSlot = find_function(cg, name);
				if fn_slot != null {
					return fn_slot.fn_val;
				}
			}
			return bind.llvm.core.wrap_value(null);
		}
		.EnumMember => {
			let ety: *mut middle.types.StType = expected != null ? expected
				: (e.sema_ty cast *mut middle.types.StType);
			if ety != null {
				let u: *mut middle.types.StType = middle.types.underlying_type(ety);
				if u != null && u.kind == middle.types.TypeKind.Enum {
					let idx: isize = middle.types.field_index(u, e.member);
					if idx >= 0 {
						let ll_ty: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
							&cg.lc.ctx,
							&cg.lc.td,
							u
						);
						if u.is_tagged_enum {
							let tag_ll: bind.llvm.core.Type = u.base != null
								? back.codegen.types.to_llvm_type(&cg.lc.ctx, &cg.lc.td, u.base)
								: bind.llvm.core.type.int32(&cg.lc.ctx);
							let tag_val: bind.llvm.core.Value = bind.llvm.core.constant.integer(
								tag_ll,
								u.enum_values.data[idx cast usize],
								false
							);
							let mut agg: bind.llvm.core.Value = bind.llvm.core.constant.null_value(
								ll_ty
							);
							return bind.llvm.ir.insert_value(
								&cg.lc.builder,
								agg,
								tag_val,
								0,
								c"ev"
							);
						}
						return bind.llvm.core.constant.integer(
							ll_ty,
							u.enum_values.data[idx cast usize],
							false
						);
					}
				}
			}
			return bind.llvm.core.wrap_value(null);
		}
		.AddrOf => {
			return emit_lvalue(cg, e.lhs, null);
		}
		.Deref => {
			let ptr_ty: *mut middle.types.StType = expr_type(cg, e.lhs, null);
			let ptr_val: bind.llvm.core.Value = emit_expr(cg, e.lhs, ptr_ty);
			let u: *mut middle.types.StType = middle.types.underlying_type(ptr_ty);
			let elem_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
				&cg.lc.ctx,
				&cg.lc.td,
				u.base
			);
			return bind.llvm.ir.load(&cg.lc.builder, elem_ll, ptr_val, c"deref");
		}
		.Unary => {
			let ty: *mut middle.types.StType = expr_type(cg, e.lhs, expected);
			let v: bind.llvm.core.Value = emit_expr(cg, e.lhs, ty);
			let u: *mut middle.types.StType = middle.types.underlying_type(ty);
			if std.str.eq(e.unary_op, "!") {
				return bind.llvm.ir.not_val(&cg.lc.builder, v, c"lnot");
			}
			if std.str.eq(e.unary_op, "~") {
				return bind.llvm.ir.not_val(&cg.lc.builder, v, c"bnot");
			}
			if u != null && u.kind == middle.types.TypeKind.Float {
				return bind.llvm.ir.fneg(&cg.lc.builder, v, c"fneg");
			}
			return bind.llvm.ir.neg(&cg.lc.builder, v, c"neg");
		}
		.Binary => {
			let lt: *mut middle.types.StType = expr_type(cg, e.lhs, expected);
			let u: *mut middle.types.StType = middle.types.underlying_type(lt);
			if u != null && u.kind == middle.types.TypeKind.Pointer
				&& (e.op == .Add || e.op == .Sub) {
				let lv: bind.llvm.core.Value = emit_expr(cg, e.lhs, lt);
				let rt: *mut middle.types.StType = expr_type(cg, e.rhs, cg.sema.tx.usize_t);
				let ru: *mut middle.types.StType = middle.types.underlying_type(rt);
				if ru != null && ru.kind == middle.types.TypeKind.Pointer && e.op == .Sub {
					let rv: bind.llvm.core.Value = emit_expr(cg, e.rhs, rt);
					let isize_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
						&cg.lc.ctx,
						&cg.lc.td,
						cg.sema.tx.isize_t
					);
					let li: bind.llvm.core.Value = bind.llvm.ir.ptrtoint(
						&cg.lc.builder,
						lv,
						isize_ll,
						c"pli"
					);
					let ri: bind.llvm.core.Value = bind.llvm.ir.ptrtoint(
						&cg.lc.builder,
						rv,
						isize_ll,
						c"pri"
					);
					return bind.llvm.ir.sub(&cg.lc.builder, li, ri, c"pdiff");
				}
				let mut rv: bind.llvm.core.Value = emit_expr(cg, e.rhs, cg.sema.tx.usize_t);
				if e.op == .Sub {
					let zero: bind.llvm.core.Value = bind.llvm.core.constant.integer(
						back.codegen.types.to_llvm_type(
							&cg.lc.ctx,
							&cg.lc.td,
							cg.sema.tx.usize_t
						), 0, false
					);
					rv = bind.llvm.ir.sub(&cg.lc.builder, zero, rv, c"pneg");
				}
				let elem_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
					&cg.lc.ctx,
					&cg.lc.td,
					u.base
				);
				let mut idxs: [1]*void;
				idxs[0] = rv.handle;
				return bind.llvm.ir.gep(&cg.lc.builder, elem_ll, lv, &idxs[0], 1, c"pgep");
			}
			if e.op == .LogicalAnd || e.op == .LogicalOr {
				let is_and: bool = e.op == .LogicalAnd;
				let bool_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
					&cg.lc.ctx,
					&cg.lc.td,
					cg.sema.tx.bool_t
				);
				let lv: bind.llvm.core.Value = emit_expr(cg, e.lhs, cg.sema.tx.bool_t);
				let lhs_end_bb: *void = bind.llvm.ir.insert_block(&cg.lc.builder);
				let rhs_bb: *void = bind.llvm.core.append_basic_block(
					&cg.lc.ctx,
					cg.current_fn,
					is_and ? c"and.rhs" : c"or.rhs"
				);
				let end_bb: *void = bind.llvm.core.append_basic_block(
					&cg.lc.ctx,
					cg.current_fn,
					is_and ? c"and.end" : c"or.end"
				);
				if is_and {
					bind.llvm.ir.cond_branch(&cg.lc.builder, lv, rhs_bb, end_bb);
				} else {
					bind.llvm.ir.cond_branch(&cg.lc.builder, lv, end_bb, rhs_bb);
				}
				bind.llvm.ir.position_at_end(&cg.lc.builder, rhs_bb);
				let rv: bind.llvm.core.Value = emit_expr(cg, e.rhs, cg.sema.tx.bool_t);
				let rhs_end_bb: *void = bind.llvm.ir.insert_block(&cg.lc.builder);
				let rhs_falls: bool = !block_has_terminator(cg);
				if rhs_falls {
					bind.llvm.ir.branch(&cg.lc.builder, end_bb);
				}
				bind.llvm.ir.position_at_end(&cg.lc.builder, end_bb);
				let phi_v: bind.llvm.core.Value = bind.llvm.ir.phi(
					&cg.lc.builder,
					bool_ll,
					is_and ? c"and" : c"or"
				);
				let short_v: bind.llvm.core.Value = bind.llvm.core.constant.integer(
					bool_ll,
					is_and ? 0 : 1,
					false
				);
				if rhs_falls {
					let mut vals: [2]*void = [short_v.handle, rv.handle];
					let mut bbs: [2]*void = [lhs_end_bb, rhs_end_bb];
					bind.llvm.ir.add_incoming(phi_v, &vals[0], &bbs[0], 2);
				} else {
					let mut vals: [1]*void = [short_v.handle];
					let mut bbs: [1]*void = [lhs_end_bb];
					bind.llvm.ir.add_incoming(phi_v, &vals[0], &bbs[0], 1);
				}
				return phi_v;
			}
			let lv: bind.llvm.core.Value = emit_expr(cg, e.lhs, lt);
			let rv: bind.llvm.core.Value = emit_expr(cg, e.rhs, lt);
			let is_flt: bool = u != null && u.kind == middle.types.TypeKind.Float;
			let is_signed: bool = u != null && u.kind == middle.types.TypeKind.SInt;
			match e.op {
				.Add => {
					if is_flt {
						return bind.llvm.ir.fadd(&cg.lc.builder, lv, rv, c"fadd");
					}
					if e.op_variant == front.token.OpVariant.Sat && u != null {
						let mut la: i64 = 0;
						let mut rb: i64 = 0;
						if const_int_val(e.lhs, &la) && const_int_val(e.rhs, &rb) && u.width > 0
							&& u.width <= 64 {
							let ty_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
								&cg.lc.ctx,
								&cg.lc.td,
								u
							);
							if !is_signed {
								let max_v: u64 = u.width == 64 ? 0xFFFFFFFFFFFFFFFF
									: (((1 cast u64) << (u.width cast u64)) - 1);
								let a: u64 = la cast u64;
								let b: u64 = rb cast u64;
								let res: u64 = (a > max_v - b) ? max_v : (a + b);
								return bind.llvm.core.constant.integer(ty_ll, res, false);
							} else if u.width < 64 {
								let max_s: i64 = ((1 cast i64) << ((u.width - 1) cast i64)) - 1;
								let min_s: i64 = -((1 cast i64) << ((u.width - 1) cast i64));
								let mut sum: i64 = la + rb;
								if sum > max_s {
									sum = max_s;
								}
								if sum < min_s {
									sum = min_s;
								}
								return bind.llvm.core.constant.integer(ty_ll, sum cast u64, true);
							}
						}
						if !is_signed && u.width > 64 && bind.llvm.core.constant.is_constant_int(lv)
							&& bind.llvm.core.constant.is_constant_int(rv) {
							return bind.llvm.core.constant.integer(
								back.codegen.types.to_llvm_type(&cg.lc.ctx, &cg.lc.td, u),
								0xFFFFFFFFFFFFFFFF,
								true
							);
						}
						return emit_sat_intrinsic(
							cg,
							false,
							is_signed,
							u.width,
							back.codegen.types.to_llvm_type(&cg.lc.ctx, &cg.lc.td, u),
							lv,
							rv
						);
					}
					if e.op_variant == front.token.OpVariant.Wrap {
						return bind.llvm.ir.add(&cg.lc.builder, lv, rv, c"add");
					}
					return is_signed
						? bind.llvm.ir.nsw_add(&cg.lc.builder, lv, rv, c"add")
						: bind.llvm.ir.nuw_add(&cg.lc.builder, lv, rv, c"add");
				}
				.Sub => {
					if is_flt {
						return bind.llvm.ir.fsub(&cg.lc.builder, lv, rv, c"fsub");
					}
					if e.op_variant == front.token.OpVariant.Sat && u != null {
						let mut la: i64 = 0;
						let mut rb: i64 = 0;
						if const_int_val(e.lhs, &la) && const_int_val(e.rhs, &rb) && u.width > 0
							&& u.width <= 64 {
							let ty_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
								&cg.lc.ctx,
								&cg.lc.td,
								u
							);
							if !is_signed {
								let a: u64 = la cast u64;
								let b: u64 = rb cast u64;
								let res: u64 = a >= b ? (a - b) : 0;
								return bind.llvm.core.constant.integer(ty_ll, res, false);
							} else if u.width < 64 {
								let max_s: i64 = ((1 cast i64) << ((u.width - 1) cast i64)) - 1;
								let min_s: i64 = -((1 cast i64) << ((u.width - 1) cast i64));
								let mut diff: i64 = la - rb;
								if diff > max_s {
									diff = max_s;
								}
								if diff < min_s {
									diff = min_s;
								}
								return bind.llvm.core.constant.integer(ty_ll, diff cast u64, true);
							}
						}
						return emit_sat_intrinsic(
							cg,
							true,
							is_signed,
							u.width,
							back.codegen.types.to_llvm_type(&cg.lc.ctx, &cg.lc.td, u),
							lv,
							rv
						);
					}
					if e.op_variant == front.token.OpVariant.Wrap {
						return bind.llvm.ir.sub(&cg.lc.builder, lv, rv, c"sub");
					}
					return is_signed
						? bind.llvm.ir.nsw_sub(&cg.lc.builder, lv, rv, c"sub")
						: bind.llvm.ir.nuw_sub(&cg.lc.builder, lv, rv, c"sub");
				}
				.Mul => {
					if is_flt {
						return bind.llvm.ir.fmul(&cg.lc.builder, lv, rv, c"fmul");
					}
					if e.op_variant == front.token.OpVariant.Sat && u != null {
						return emit_sat_mul(
							cg,
							is_signed,
							u.width,
							back.codegen.types.to_llvm_type(&cg.lc.ctx, &cg.lc.td, u),
							lv,
							rv
						);
					}
					if e.op_variant == front.token.OpVariant.Wrap {
						return bind.llvm.ir.mul(&cg.lc.builder, lv, rv, c"mul");
					}
					return is_signed
						? bind.llvm.ir.nsw_mul(&cg.lc.builder, lv, rv, c"mul")
						: bind.llvm.ir.nuw_mul(&cg.lc.builder, lv, rv, c"mul");
				}
				.Div => {
					if is_flt {
						return bind.llvm.ir.fdiv(&cg.lc.builder, lv, rv, c"fdiv");
					}
					return is_signed ? bind.llvm.ir.sdiv(&cg.lc.builder, lv, rv, c"sdiv")
						: bind.llvm.ir.udiv(&cg.lc.builder, lv, rv, c"udiv");
				}
				.Mod => {
					if is_flt {
						return bind.llvm.ir.frem(&cg.lc.builder, lv, rv, c"frem");
					}
					return is_signed ? bind.llvm.ir.srem(&cg.lc.builder, lv, rv, c"srem")
						: bind.llvm.ir.urem(&cg.lc.builder, lv, rv, c"urem");
				}
				.BitAnd | .LogicalAnd => {
					return bind.llvm.ir.bit_and(&cg.lc.builder, lv, rv, c"and");
				}
				.BitOr | .LogicalOr => return bind.llvm.ir.bit_or(&cg.lc.builder, lv, rv, c"or"),
				.BitXor => return bind.llvm.ir.bit_xor(&cg.lc.builder, lv, rv, c"xor"),
				.Shl => return bind.llvm.ir.shl(&cg.lc.builder, lv, rv, c"shl"),
				.Shr => {
					return is_signed ? bind.llvm.ir.ashr(&cg.lc.builder, lv, rv, c"ashr")
						: bind.llvm.ir.lshr(&cg.lc.builder, lv, rv, c"lshr");
				}
				.Eq => {
					return is_flt
						? bind.llvm.ir.real_compare(
							&cg.lc.builder,
							bind.llvm.RealPredicate.OEQ,
							lv,
							rv,
							c"feq"
						)
						: bind.llvm.ir.integer_compare(
							&cg.lc.builder,
							bind.llvm.IntPredicate.Equal,
							lv,
							rv,
							c"eq"
						);
				}
				.Ne => {
					return is_flt
						? bind.llvm.ir.real_compare(
							&cg.lc.builder,
							bind.llvm.RealPredicate.ONE,
							lv,
							rv,
							c"fne"
						)
						: bind.llvm.ir.integer_compare(
							&cg.lc.builder,
							bind.llvm.IntPredicate.NotEqual,
							lv,
							rv,
							c"ne"
						);
				}
				.Lt => {
					if is_flt {
						return bind.llvm.ir.real_compare(
							&cg.lc.builder,
							bind.llvm.RealPredicate.OLT,
							lv,
							rv,
							c"flt"
						);
					}
					return bind.llvm.ir.integer_compare(
						&cg.lc.builder,
						is_signed ? bind.llvm.IntPredicate.SignedLessThan
							: bind.llvm.IntPredicate.UnsignedLessThan,
						lv,
						rv,
						c"lt"
					);
				}
				.Le => {
					if is_flt {
						return bind.llvm.ir.real_compare(
							&cg.lc.builder,
							bind.llvm.RealPredicate.OLE,
							lv,
							rv,
							c"fle"
						);
					}
					return bind.llvm.ir.integer_compare(
						&cg.lc.builder,
						is_signed ? bind.llvm.IntPredicate.SignedLessOrEqual
							: bind.llvm.IntPredicate.UnsignedLessOrEqual,
						lv,
						rv,
						c"le"
					);
				}
				.Gt => {
					if is_flt {
						return bind.llvm.ir.real_compare(
							&cg.lc.builder,
							bind.llvm.RealPredicate.OGT,
							lv,
							rv,
							c"fgt"
						);
					}
					return bind.llvm.ir.integer_compare(
						&cg.lc.builder,
						is_signed ? bind.llvm.IntPredicate.SignedGreaterThan
							: bind.llvm.IntPredicate.UnsignedGreaterThan,
						lv,
						rv,
						c"gt"
					);
				}
				.Ge => {
					if is_flt {
						return bind.llvm.ir.real_compare(
							&cg.lc.builder,
							bind.llvm.RealPredicate.OGE,
							lv,
							rv,
							c"fge"
						);
					}
					return bind.llvm.ir.integer_compare(
						&cg.lc.builder,
						is_signed ? bind.llvm.IntPredicate.SignedGreaterOrEqual
							: bind.llvm.IntPredicate.UnsignedGreaterOrEqual,
						lv,
						rv,
						c"ge"
					);
				}
			}
		}
		.Assign => {
			let mut lval_ty: *mut middle.types.StType = null;
			let lptr: bind.llvm.core.Value = emit_lvalue(cg, e.lhs, &lval_ty);
			let rval: bind.llvm.core.Value = emit_expr(cg, e.rhs, lval_ty);
			bind.llvm.ir.store(&cg.lc.builder, rval, lptr);
			return rval;
		}
		.Conditional => {
			let cond_val: bind.llvm.core.Value = emit_expr(cg, e.condition, cg.sema.tx.bool_t);
			let ty: *mut middle.types.StType = expr_type(cg, e, expected);
			let u: *mut middle.types.StType = middle.types.underlying_type(ty);
			let is_void: bool = u == null || u.kind == middle.types.TypeKind.Void;
			let ll_ty: bind.llvm.core.Type = is_void ? bind.llvm.core.type.void_type(&cg.lc.ctx)
				: back.codegen.types.to_llvm_type(&cg.lc.ctx, &cg.lc.td, ty);
			let then_bb: *void = bind.llvm.core.append_basic_block(
				&cg.lc.ctx,
				cg.current_fn,
				c"cond.then"
			);
			let else_bb: *void = bind.llvm.core.append_basic_block(
				&cg.lc.ctx,
				cg.current_fn,
				c"cond.else"
			);
			let end_bb: *void = bind.llvm.core.append_basic_block(
				&cg.lc.ctx,
				cg.current_fn,
				c"cond.end"
			);
			bind.llvm.ir.cond_branch(&cg.lc.builder, cond_val, then_bb, else_bb);
			bind.llvm.ir.position_at_end(&cg.lc.builder, then_bb);
			let tv: bind.llvm.core.Value = emit_expr(cg, e.then_expr, ty);
			let then_end_bb: *void = bind.llvm.ir.insert_block(&cg.lc.builder);
			let then_falls: bool = !block_has_terminator(cg);
			if then_falls {
				bind.llvm.ir.branch(&cg.lc.builder, end_bb);
			}
			bind.llvm.ir.position_at_end(&cg.lc.builder, else_bb);
			let ev: bind.llvm.core.Value = emit_expr(cg, e.else_expr, ty);
			let else_end_bb: *void = bind.llvm.ir.insert_block(&cg.lc.builder);
			let else_falls: bool = !block_has_terminator(cg);
			if else_falls {
				bind.llvm.ir.branch(&cg.lc.builder, end_bb);
			}
			bind.llvm.ir.position_at_end(&cg.lc.builder, end_bb);
			if is_void {
				return bind.llvm.core.wrap_value(null);
			}
			let phi_v: bind.llvm.core.Value = bind.llvm.ir.phi(&cg.lc.builder, ll_ty, c"cond");
			if then_falls && tv.handle != null {
				let mut v1: [1]*void = [tv.handle];
				let mut b1: [1]*void = [then_end_bb];
				bind.llvm.ir.add_incoming(phi_v, &v1[0], &b1[0], 1);
			}
			if else_falls && ev.handle != null {
				let mut v2: [1]*void = [ev.handle];
				let mut b2: [1]*void = [else_end_bb];
				bind.llvm.ir.add_incoming(phi_v, &v2[0], &b2[0], 1);
			}
			return phi_v;
		}
		.Cast => {
			let src_ty: *mut middle.types.StType = expr_type(cg, e.lhs, null);
			let dst_ty: *mut middle.types.StType = cg.sema.resolve_type(e.cast_type);
			let src_val: bind.llvm.core.Value = emit_expr(cg, e.lhs, src_ty);
			return emit_cast(cg, src_val, src_ty, dst_ty, e.is_bitcast);
		}
		.Call => {
			if e.lhs != null && !e.is_method_call && (e.lhs.kind == front.ast.ExprKind.EnumMember
				|| (e.lhs.kind == front.ast.ExprKind.Member && e.lhs.sema_ty != null
				&& middle.types.underlying_type(e.lhs.sema_ty cast *mut middle.types.StType) != null
				&& middle.types.underlying_type(e.lhs.sema_ty cast *mut middle.types.StType).kind
				== middle.types.TypeKind.Enum
				&& middle.types.underlying_type(
					e.lhs.sema_ty cast *mut middle.types.StType
				).is_tagged_enum)) {
				let ety: *mut middle.types.StType = e.lhs.sema_ty != null
					? (e.lhs.sema_ty cast *mut middle.types.StType) : expected;
				let eu: *mut middle.types.StType = middle.types.underlying_type(ety);
				if eu != null && eu.kind == middle.types.TypeKind.Enum && eu.is_tagged_enum {
					let vidx: isize = middle.types.field_index(eu, e.lhs.member);
					if vidx >= 0 {
						let ll_ty: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
							&cg.lc.ctx,
							&cg.lc.td,
							eu
						);
						let tmp_ptr: bind.llvm.core.Value = alloca_in_entry(cg, ll_ty, c"evtmp");
						let tag_ll: bind.llvm.core.Type = eu.base != null
							? back.codegen.types.to_llvm_type(&cg.lc.ctx, &cg.lc.td, eu.base)
							: bind.llvm.core.type.int32(&cg.lc.ctx);
						let tag_val: bind.llvm.core.Value = bind.llvm.core.constant.integer(
							tag_ll,
							eu.enum_values.data[vidx cast usize],
							false
						);
						let tag_ptr: bind.llvm.core.Value = bind.llvm.ir.struct_gep(
							&cg.lc.builder,
							ll_ty,
							tmp_ptr,
							0,
							c"evtag"
						);
						bind.llvm.ir.store(&cg.lc.builder, tag_val, tag_ptr);
						if e.args.len > 0 && (vidx cast usize) < eu.enum_variants.len {
							let vi: middle.types.EnumVariantInfo =
								eu.enum_variants.data[vidx cast usize];
							let pay_st: bind.llvm.core.Type =
								back.codegen.types.tagged_enum_payload_struct(
									&cg.lc.ctx,
									&cg.lc.td,
									&vi
								);
							let pay_ptr: bind.llvm.core.Value = bind.llvm.ir.struct_gep(
								&cg.lc.builder,
								ll_ty,
								tmp_ptr,
								1,
								c"evpay"
							);
							for let mut i: usize = 0; i < e.args.len; i += 1 {
								let fty: *mut middle.types.StType = i < vi.field_types.len
									? vi.field_types.data[i] : null;
								let fval: bind.llvm.core.Value = emit_expr(cg, e.args.data[i], fty);
								let fptr: bind.llvm.core.Value = bind.llvm.ir.struct_gep(
									&cg.lc.builder,
									pay_st,
									pay_ptr,
									i cast u32,
									c"evfld"
								);
								bind.llvm.ir.store(&cg.lc.builder, fval, fptr);
							}
						}
						return bind.llvm.ir.load(&cg.lc.builder, ll_ty, tmp_ptr, c"evld");
					}
				}
			}
			if e.is_method_call && e.lhs != null && e.lhs.kind == front.ast.ExprKind.Member
				&& e.lhs.sema_sym != null {
				let msym: *middle.symbol.Symbol = e.lhs.sema_sym cast *middle.symbol.Symbol;
				let u: *mut middle.types.StType = middle.types.underlying_type(msym.ty);
				let fn_ll_ty: bind.llvm.core.Type = back.codegen.types.to_llvm_fn_type(
					&cg.lc.ctx,
					&cg.lc.td,
					u
				);
				let fn_slot: *mut FnSlot = find_function(cg, msym.mangled);
				let callee_val: bind.llvm.core.Value = fn_slot != null ? fn_slot.fn_val
					: bind.llvm.core.wrap_value(null);
				let total_argc: usize = e.args.len + 1;
				let is_void: bool = u != null && u.fn_ret != null
					&& middle.types.underlying_type(u.fn_ret).kind == middle.types.TypeKind.Void;
				let call_name: *u8 = is_void ? c"" : c"call";
				let raw: *mut u8 = front.ast.arena_alloc(total_argc * @of.size(usize));
				if raw == null {
					return bind.llvm.core.wrap_value(null);
				}
				let arg_ptrs: *mut *void = raw cast *mut *void;
				let recv_ty: *mut middle.types.StType = expr_type(cg, e.lhs.lhs, null);
				let recv_u: *mut middle.types.StType = middle.types.underlying_type(
					recv_ty
				);
				let self_param_ty: *mut middle.types.StType = u.fn_params.len > 0
					? u.fn_params.data[0] : null;
				let self_u: *mut middle.types.StType = middle.types.underlying_type(
					self_param_ty
				);
				let mut self_val: bind.llvm.core.Value = bind.llvm.core.wrap_value(null);
				if self_u != null && self_u.kind == middle.types.TypeKind.Pointer
					&& (recv_u == null || recv_u.kind != middle.types.TypeKind.Pointer) {
					self_val = emit_lvalue(cg, e.lhs.lhs, null);
					if self_val.handle == null && recv_ty != null {
						let recv_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
							&cg.lc.ctx,
							&cg.lc.td,
							recv_ty
						);
						let tmp_s: bind.llvm.core.Value = alloca_in_entry(cg, recv_ll, c"selftmp");
						let rv: bind.llvm.core.Value = emit_expr(cg, e.lhs.lhs, recv_ty);
						if rv.handle != null {
							bind.llvm.ir.store(&cg.lc.builder, rv, tmp_s);
						}
						self_val = tmp_s;
					}
				} else if (self_u == null || self_u.kind != middle.types.TypeKind.Pointer)
					&& recv_u != null && recv_u.kind == middle.types.TypeKind.Pointer {
					let ptr_v: bind.llvm.core.Value = emit_expr(cg, e.lhs.lhs, recv_ty);
					let val_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
						&cg.lc.ctx,
						&cg.lc.td,
						self_param_ty
					);
					self_val = bind.llvm.ir.load(&cg.lc.builder, val_ll, ptr_v, c"selfld");
				} else {
					self_val = emit_expr(cg, e.lhs.lhs, recv_ty);
				}
				arg_ptrs[0] = self_val.handle;
				for let mut i: usize = 0; i < e.args.len; i += 1 {
					let pty: *mut middle.types.StType = (u != null && (i + 1)
						< u.fn_params.len)
						? u.fn_params.data[i + 1] : null;
					arg_ptrs[i + 1] = emit_expr(cg, e.args.data[i], pty).handle;
				}
				let res: bind.llvm.core.Value = bind.llvm.ir.call(
					&cg.lc.builder,
					fn_ll_ty,
					callee_val,
					arg_ptrs,
					total_argc cast u32,
					call_name
				);
				if u == null || u.fn_abi == middle.types.AbiKind.Stella {
					bind.llvm.core.set_instr_call_conv(res, 8);
				}
				return res;
			}
			let callee_ty: *mut middle.types.StType = expr_type(cg, e.lhs, null);
			if e.lhs != null && e.lhs.sema_sym != null {
				let csym: *middle.symbol.Symbol = e.lhs.sema_sym cast *middle.symbol.Symbol;
				if csym.kind == middle.symbol.SymKind.Fn && csym.fn_decl != null
					&& csym.fn_decl.is_macro {
					let m_ty: *mut middle.types.StType = expr_type(cg, e, expected);
					let m_u: *mut middle.types.StType = middle.types.underlying_type(m_ty);
					let m_void: bool = m_u == null || m_u.kind == middle.types.TypeKind.Void;
					let m_ll: bind.llvm.core.Type = m_void
						? bind.llvm.core.type.void_type(&cg.lc.ctx)
						: back.codegen.types.to_llvm_type(&cg.lc.ctx, &cg.lc.td, m_ty);
					if csym.fn_decl.body != null && cg.has_emit_stmt_cb {
						let prev_locals_len: usize = cg.locals.len;
						let prev_caller_len: usize = cg.macro_caller_locals_len;
						cg.macro_caller_locals_len = prev_locals_len;
						let c_u: *mut middle.types.StType = middle.types.underlying_type(callee_ty);
						for let mut pi: usize = 0; pi < csym.fn_decl.params.len
							&& pi < e.args.len; pi += 1 {
							let pty: *mut middle.types.StType = (c_u != null
								&& pi < c_u.fn_params.len) ? c_u.fn_params.data[pi]
								: expr_type(cg, e.args.data[pi], null);
							let pval: bind.llvm.core.Value = emit_expr(cg, e.args.data[pi], pty);
							let pll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
								&cg.lc.ctx,
								&cg.lc.td,
								pty
							);
							let cname: *mut u8 = cstr_from_slice(
								csym.fn_decl.params.data[pi].name
							);
							let slot: bind.llvm.core.Value = alloca_in_entry(
								cg,
								pll,
								cname != null ? (cname cast *u8) : c"marg"
							);
							bind.llvm.ir.store(&cg.lc.builder, pval, slot);
							let ls: LocalSlot = {
								.name = csym.fn_decl.params.data[pi].name,
								.ptr = slot,
								.st_ty = pty,
								.ll_ty = pll,
								.scope_depth = cg.scope_depth
							};
							cg.locals.push(ls);
						}
						let prev_slot: bind.llvm.core.Value = cg.yield_slot;
						let prev_ty: *mut middle.types.StType = cg.yield_ty;
						let prev_end: *void = cg.yield_end_bb;
						let prev_yd: u32 = cg.yield_scope_depth;
						let prev_va: *front.ast.PtrList<front.ast.Expr> = cg.macro_varargs;
						let prev_fa: usize = cg.macro_fixed_argc;
						let res_slot: bind.llvm.core.Value = m_void
							? bind.llvm.core.wrap_value(null)
							: alloca_in_entry(cg, m_ll, c"mac.tmp");
						let end_bb: *void = bind.llvm.core.append_basic_block(
							&cg.lc.ctx,
							cg.current_fn,
							c"mac.end"
						);
						cg.yield_slot = res_slot;
						cg.yield_ty = m_ty;
						cg.yield_end_bb = end_bb;
						cg.yield_scope_depth = cg.scope_depth;
						cg.macro_varargs = &e.args;
						cg.macro_fixed_argc = csym.fn_decl.params.len;
						cg.emit_stmt_cb(cg, csym.fn_decl.body);
						if !block_has_terminator(cg) {
							bind.llvm.ir.branch(&cg.lc.builder, end_bb);
						}
						bind.llvm.ir.position_at_end(&cg.lc.builder, end_bb);
						cg.yield_slot = prev_slot;
						cg.yield_ty = prev_ty;
						cg.yield_end_bb = prev_end;
						cg.yield_scope_depth = prev_yd;
						cg.macro_varargs = prev_va;
						cg.macro_fixed_argc = prev_fa;
						cg.macro_caller_locals_len = prev_caller_len;
						cg.locals.len = prev_locals_len;
						if m_void {
							return bind.llvm.core.wrap_value(null);
						}
						return bind.llvm.ir.load(&cg.lc.builder, m_ll, res_slot, c"mac");
					}
					if m_void {
						return bind.llvm.core.wrap_value(null);
					}
					return bind.llvm.core.constant.null_value(m_ll);
				}
			}
			let u: *mut middle.types.StType = middle.types.underlying_type(callee_ty);
			let fn_ll_ty: bind.llvm.core.Type = back.codegen.types.to_llvm_fn_type(
				&cg.lc.ctx,
				&cg.lc.td,
				u
			);
			let callee_val: bind.llvm.core.Value = emit_expr(cg, e.lhs, callee_ty);
			let argc: usize = e.args.len;
			let is_c_abi: bool = u != null && u.fn_abi == middle.types.AbiKind.C;
			if is_c_abi {
				let ret_abi: back.codegen.types.CAbiArg = back.codegen.types.classify_c_abi(
					&cg.lc.ctx,
					&cg.lc.td,
					u.fn_ret,
					true
				);
				let has_sret: bool = ret_abi.kind == back.codegen.types.CAbiKind.SRet;
				let is_void_call: bool = has_sret
					|| (u.fn_ret != null && middle.types.underlying_type(u.fn_ret).kind
					== middle.types.TypeKind.Void);
				let call_name: *u8 = is_void_call ? c"" : c"call";
				let total_ll_argc: usize = argc + (has_sret ? 1 : 0);
				let mut sret_slot: bind.llvm.core.Value = bind.llvm.core.wrap_value(null);
				if has_sret {
					sret_slot = alloca_in_entry(cg, ret_abi.storage_ty, c"sret");
				}
				let mut res: bind.llvm.core.Value = bind.llvm.core.wrap_value(null);
				if total_ll_argc == 0 {
					res = bind.llvm.ir.call(
						&cg.lc.builder,
						fn_ll_ty,
						callee_val,
						null,
						0,
						call_name
					);
				} else {
					let raw: *mut u8 = front.ast.arena_alloc(total_ll_argc * @of.size(usize));
					if raw == null {
						return bind.llvm.core.wrap_value(null);
					}
					let arg_ptrs: *mut *void = raw cast *mut *void;
					let mut out_i: usize = 0;
					if has_sret {
						arg_ptrs[out_i] = sret_slot.handle;
						out_i += 1;
					}
					for let mut i: usize = 0; i < argc; i += 1 {
						let pty: *mut middle.types.StType = i < u.fn_params.len
							? u.fn_params.data[i] : null;
						let av: bind.llvm.core.Value = emit_expr(cg, e.args.data[i], pty);
						let cv: bind.llvm.core.Value = pty != null
							? coerce_value(cg, av, expr_type(cg, e.args.data[i], pty), pty)
							: av;
						if pty != null {
							let pa: back.codegen.types.CAbiArg =
								back.codegen.types.classify_c_abi(
									&cg.lc.ctx,
									&cg.lc.td,
									pty,
									false
								);
							if pa.kind == back.codegen.types.CAbiKind.ByVal {
								let bv: bind.llvm.core.Value = alloca_in_entry(
									cg,
									pa.storage_ty,
									c"byval"
								);
								bind.llvm.ir.store(&cg.lc.builder, cv, bv);
								arg_ptrs[out_i] = bv.handle;
							} else if pa.kind == back.codegen.types.CAbiKind.Coerce {
								let ctmp: bind.llvm.core.Value = alloca_in_entry(
									cg,
									pa.coerced_ty,
									c"cc"
								);
								bind.llvm.ir.store(&cg.lc.builder, cv, ctmp);
								let ldv: bind.llvm.core.Value = bind.llvm.ir.load(
									&cg.lc.builder,
									pa.coerced_ty,
									ctmp,
									c"ccl"
								);
								arg_ptrs[out_i] = ldv.handle;
							} else {
								arg_ptrs[out_i] = cv.handle;
							}
						} else {
							arg_ptrs[out_i] = cv.handle;
						}
						out_i += 1;
					}
					res = bind.llvm.ir.call(
						&cg.lc.builder,
						fn_ll_ty,
						callee_val,
						arg_ptrs,
						total_ll_argc cast u32,
						call_name
					);
					let mut attr_idx: u32 = 1;
					if has_sret {
						let sret_k: u32 = bind.llvm.core.enum_attr_kind(c"sret", 4);
						let sret_a: *void = bind.llvm.core.create_type_attr(
							&cg.lc.ctx,
							sret_k,
							ret_abi.storage_ty
						);
						bind.llvm.core.add_call_site_attr(res, attr_idx, sret_a);
						attr_idx += 1;
					}
					for let mut i: usize = 0; i < argc && i < u.fn_params.len; i += 1 {
						let pa: back.codegen.types.CAbiArg =
							back.codegen.types.classify_c_abi(
								&cg.lc.ctx,
								&cg.lc.td,
								u.fn_params.data[i],
								false
							);
						if pa.kind == back.codegen.types.CAbiKind.ByVal {
							let bv_k: u32 = bind.llvm.core.enum_attr_kind(c"byval", 5);
							let bv_a: *void = bind.llvm.core.create_type_attr(
								&cg.lc.ctx,
								bv_k,
								pa.storage_ty
							);
							bind.llvm.core.add_call_site_attr(res, attr_idx, bv_a);
						}
						attr_idx += 1;
					}
				}
				if has_sret {
					return bind.llvm.ir.load(
						&cg.lc.builder,
						ret_abi.storage_ty,
						sret_slot,
						c"sret.ld"
					);
				}
				if ret_abi.kind == back.codegen.types.CAbiKind.Coerce {
					let rtmp: bind.llvm.core.Value = alloca_in_entry(
						cg,
						ret_abi.coerced_ty,
						c"cret"
					);
					bind.llvm.ir.store(&cg.lc.builder, res, rtmp);
					return bind.llvm.ir.load(&cg.lc.builder, ret_abi.storage_ty, rtmp, c"cret.ld");
				}
				return res;
			}
			let is_void: bool = u != null && u.fn_ret != null
				&& middle.types.underlying_type(u.fn_ret).kind == middle.types.TypeKind.Void;
			let call_name: *u8 = is_void ? c"" : c"call";
			let mut is_main_call: bool = false;
			if e.lhs != null && e.lhs.sema_sym != null {
				let csym2: *middle.symbol.Symbol = e.lhs.sema_sym cast *middle.symbol.Symbol;
				if std.str.eq(csym2.simple, "main") {
					is_main_call = true;
				}
			}
			if argc == 0 {
				let res0: bind.llvm.core.Value = bind.llvm.ir.call(
					&cg.lc.builder,
					fn_ll_ty,
					callee_val,
					null,
					0,
					call_name
				);
				if !is_main_call {
					bind.llvm.core.set_instr_call_conv(res0, 8);
				}
				return res0;
			}
			let raw: *mut u8 = front.ast.arena_alloc(argc * @of.size(usize));
			if raw == null {
				return bind.llvm.core.wrap_value(null);
			}
			let arg_ptrs: *mut *void = raw cast *mut *void;
			for let mut i: usize = 0; i < argc; i += 1 {
				let pty: *mut middle.types.StType = (u != null && i < u.fn_params.len)
					? u.fn_params.data[i] : null;
				let av: bind.llvm.core.Value = emit_expr(cg, e.args.data[i], pty);
				arg_ptrs[i] = pty != null
					? coerce_value(cg, av, expr_type(cg, e.args.data[i], pty), pty).handle
					: av.handle;
			}
			let res: bind.llvm.core.Value = bind.llvm.ir.call(
				&cg.lc.builder,
				fn_ll_ty,
				callee_val,
				arg_ptrs,
				argc cast u32,
				call_name
			);
			if !is_main_call {
				bind.llvm.core.set_instr_call_conv(res, 8);
			}
			return res;
		}
		.Member => {
			if e.sema_sym != null {
				let sym: *middle.symbol.Symbol = e.sema_sym cast *middle.symbol.Symbol;
				if sym.kind == middle.symbol.SymKind.Fn {
					if sym.fn_decl != null && sym.fn_decl.is_macro {
						return bind.llvm.core.wrap_value(null);
					}
					let fn_slot: *mut FnSlot = find_function(cg, sym.mangled);
					if fn_slot != null {
						return fn_slot.fn_val;
					}
				} else if sym.kind == middle.symbol.SymKind.Const && sym.has_const_value {
					let cty: *mut middle.types.StType = sym.ty != null ? sym.ty : expected;
					let ll_ty: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
						&cg.lc.ctx,
						&cg.lc.td,
						cty
					);
					if sym.const_value_is_float {
						return bind.llvm.core.constant.real(ll_ty, sym.const_flt_val);
					}
					return bind.llvm.core.constant.integer(ll_ty, sym.const_int_val, false);
				} else if sym.kind == middle.symbol.SymKind.Const && sym.has_const_value && sym.ty
					!= null {
					let cll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
						&cg.lc.ctx,
						&cg.lc.td,
						sym.ty
					);
					if sym.const_value_is_float {
						return bind.llvm.core.constant.real(cll, sym.const_flt_val);
					}
					if middle.types.underlying_type(sym.ty).kind == middle.types.TypeKind.Bool {
						return bind.llvm.core.constant.integer(
							cll,
							sym.const_bool_val ? (1 cast u64) : (0 cast u64),
							false
						);
					}
					let is_s: bool = middle.types.underlying_type(sym.ty).kind
						== middle.types.TypeKind.SInt;
					return bind.llvm.core.constant.integer(cll, sym.const_int_val, is_s);
				} else if sym.kind == middle.symbol.SymKind.Var || sym.kind
					== middle.symbol.SymKind.Const {
					let glob_slot: *mut GlobalSlot = find_global(cg, sym.mangled);
					if glob_slot != null {
						return bind.llvm.ir.load(
							&cg.lc.builder,
							glob_slot.ll_ty,
							glob_slot.ptr,
							c"gld"
						);
					}
				}
			}
			let lhs_ty: *mut middle.types.StType = expr_type(cg, e.lhs, null);
			let lu: *mut middle.types.StType = middle.types.underlying_type(lhs_ty);
			if lu != null && lu.kind == middle.types.TypeKind.Enum {
				let idx: isize = middle.types.field_index(lu, e.member);
				if idx >= 0 {
					let ll_ty: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
						&cg.lc.ctx,
						&cg.lc.td,
						lu
					);
					if lu.is_tagged_enum {
						let tag_ll: bind.llvm.core.Type = lu.base != null
							? back.codegen.types.to_llvm_type(&cg.lc.ctx, &cg.lc.td, lu.base)
							: bind.llvm.core.type.int32(&cg.lc.ctx);
						let tag_val: bind.llvm.core.Value = bind.llvm.core.constant.integer(
							tag_ll,
							lu.enum_values.data[idx cast usize],
							false
						);
						let mut agg: bind.llvm.core.Value = bind.llvm.core.constant.null_value(
							ll_ty
						);
						return bind.llvm.ir.insert_value(&cg.lc.builder, agg, tag_val, 0, c"ev");
					}
					return bind.llvm.core.constant.integer(
						ll_ty,
						lu.enum_values.data[idx cast usize],
						false
					);
				}
			}
			if lu != null && lu.kind == middle.types.TypeKind.Array && std.str.eq(e.member, "len") {
				let usize_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
					&cg.lc.ctx,
					&cg.lc.td,
					cg.sema.tx.usize_t
				);
				return bind.llvm.core.constant.integer(usize_ll, lu.array_len cast u64, false);
			}
			if lu != null && lu.kind == middle.types.TypeKind.Slice {
				let sv: bind.llvm.core.Value = emit_expr(cg, e.lhs, lhs_ty);
				if std.str.eq(e.member, "ptr") {
					return bind.llvm.ir.extract_value(&cg.lc.builder, sv, 0, c"sptr");
				}
				return bind.llvm.ir.extract_value(&cg.lc.builder, sv, 1, c"slen");
			}
			let mut fld_ty: *mut middle.types.StType = null;
			let fptr: bind.llvm.core.Value = emit_lvalue(cg, e, &fld_ty);
			if fptr.handle != null && fld_ty != null {
				let fld_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
					&cg.lc.ctx,
					&cg.lc.td,
					fld_ty
				);
				return bind.llvm.ir.load(&cg.lc.builder, fld_ll, fptr, c"fldld");
			}
			if lu != null && lu.kind == middle.types.TypeKind.Struct {
				let fidx: isize = middle.types.field_index(lu, e.member);
				if fidx >= 0 {
					let agg: bind.llvm.core.Value = emit_expr(cg, e.lhs, lhs_ty);
					if agg.handle != null {
						return bind.llvm.ir.extract_value(
							&cg.lc.builder,
							agg,
							fidx cast u32,
							c"rfld"
						);
					}
				}
			}
			return bind.llvm.core.wrap_value(null);
		}
		.Index => {
			if e.index_low != null {
				let base_ty: *mut middle.types.StType = expr_type(cg, e.lhs, null);
				let bv: bind.llvm.core.Value = emit_expr(cg, e.lhs, base_ty);
				let lv_raw: bind.llvm.core.Value = emit_expr(cg, e.index_low, cg.sema.tx.usize_t);
				let lv: bind.llvm.core.Value = emit_cast(
					cg,
					lv_raw,
					expr_type(cg, e.index_low, cg.sema.tx.usize_t),
					base_ty,
					false
				);
				let shifted: bind.llvm.core.Value = bind.llvm.ir.lshr(
					&cg.lc.builder,
					bv,
					lv,
					c"bsh"
				);
				let res_ty: *mut middle.types.StType = expr_type(cg, e, expected);
				let res_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
					&cg.lc.ctx,
					&cg.lc.td,
					res_ty
				);
				let bu: *mut middle.types.StType = middle.types.underlying_type(base_ty);
				let ru: *mut middle.types.StType = middle.types.underlying_type(res_ty);
				if bu != null && ru != null && ru.width < bu.width {
					return bind.llvm.ir.trunc(&cg.lc.builder, shifted, res_ll, c"btr");
				}
				return shifted;
			}
			let mut elem_ty: *mut middle.types.StType = null;
			let eptr: bind.llvm.core.Value = emit_lvalue(cg, e, &elem_ty);
			if eptr.handle != null && elem_ty != null {
				let elem_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
					&cg.lc.ctx,
					&cg.lc.td,
					elem_ty
				);
				return bind.llvm.ir.load(&cg.lc.builder, elem_ll, eptr, c"idxld");
			}
			return bind.llvm.core.wrap_value(null);
		}
		.StructLit => {
			let ty: *mut middle.types.StType = expected != null ? expected : cg.sema.tx.void_t;
			let u: *mut middle.types.StType = middle.types.underlying_type(ty);
			let ll_ty: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
				&cg.lc.ctx,
				&cg.lc.td,
				u
			);
			let mut agg: bind.llvm.core.Value = bind.llvm.core.constant.null_value(ll_ty);
			if u != null && u.kind == middle.types.TypeKind.Union && e.field_names.len > 0 {
				let fidx: isize = middle.types.field_index(u, e.field_names.data[0]);
				if fidx >= 0 {
					let utmp: bind.llvm.core.Value = alloca_in_entry(cg, ll_ty, c"utmp");
					bind.llvm.ir.store(&cg.lc.builder, agg, utmp);
					let fty: *mut middle.types.StType = u.fields.data[fidx cast usize];
					let fval: bind.llvm.core.Value = emit_expr(cg, e.args.data[0], fty);
					bind.llvm.ir.store(&cg.lc.builder, fval, utmp);
					return bind.llvm.ir.load(&cg.lc.builder, ll_ty, utmp, c"uninit");
				}
			}
			if u != null && u.kind == middle.types.TypeKind.Struct {
				for let mut i: usize = 0; i < e.field_names.len; i += 1 {
					let fidx: isize = middle.types.field_index(u, e.field_names.data[i]);
					if fidx >= 0 {
						let fty: *mut middle.types.StType = u.fields.data[fidx cast usize];
						let fval: bind.llvm.core.Value = emit_expr(cg, e.args.data[i], fty);
						agg = bind.llvm.ir.insert_value(
							&cg.lc.builder,
							agg,
							fval,
							fidx cast u32,
							c"stinit"
						);
					}
				}
			}
			return agg;
		}
		.VariantInit => {
			let ety: *mut middle.types.StType = expr_type(cg, e, expected);
			let eu: *mut middle.types.StType = middle.types.underlying_type(ety);
			let ll_ty: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
				&cg.lc.ctx,
				&cg.lc.td,
				eu
			);
			if eu != null && eu.kind == middle.types.TypeKind.Enum {
				let vidx: isize = middle.types.field_index(eu, e.member);
				if vidx >= 0 && (vidx cast usize) < eu.enum_variants.len {
					let tag_ll: bind.llvm.core.Type = eu.base != null
						? back.codegen.types.to_llvm_type(&cg.lc.ctx, &cg.lc.td, eu.base)
						: bind.llvm.core.type.int32(&cg.lc.ctx);
					let tag_v: bind.llvm.core.Value = bind.llvm.core.constant.integer(
						tag_ll,
						eu.enum_values.data[vidx cast usize],
						false
					);
					let slot: bind.llvm.core.Value = alloca_in_entry(cg, ll_ty, c"evtmp");
					bind.llvm.ir.store(
						&cg.lc.builder,
						bind.llvm.core.constant.null_value(ll_ty),
						slot
					);
					let tag_ptr: bind.llvm.core.Value = bind.llvm.ir.struct_gep(
						&cg.lc.builder,
						ll_ty,
						slot,
						0,
						c"evtag"
					);
					bind.llvm.ir.store(&cg.lc.builder, tag_v, tag_ptr);
					let vi: middle.types.EnumVariantInfo = eu.enum_variants.data[vidx cast usize];
					if e.args.len > 0 && vi.field_types.len > 0 {
						let pay_st: bind.llvm.core.Type =
							back.codegen.types.tagged_enum_payload_struct(
								&cg.lc.ctx,
								&cg.lc.td,
								&vi
							);
						let pay_ptr: bind.llvm.core.Value = bind.llvm.ir.struct_gep(
							&cg.lc.builder,
							ll_ty,
							slot,
							1,
							c"evpay"
						);
						for let mut i: usize = 0; i < e.field_names.len; i += 1 {
							let mut fidx: isize = -1;
							for let mut k: usize = 0; k < vi.field_names.len; k += 1 {
								if std.str.eq(vi.field_names.data[k], e.field_names.data[i]) {
									fidx = k cast isize;
									break;
								}
							}
							if fidx >= 0 && (fidx cast usize) < vi.field_types.len {
								let fty: *mut middle.types.StType =
									vi.field_types.data[fidx cast usize];
								let fval: bind.llvm.core.Value = emit_expr(cg, e.args.data[i], fty);
								let fptr: bind.llvm.core.Value = bind.llvm.ir.struct_gep(
									&cg.lc.builder,
									pay_st,
									pay_ptr,
									fidx cast u32,
									c"evfld"
								);
								bind.llvm.ir.store(&cg.lc.builder, fval, fptr);
							}
						}
					}
					return bind.llvm.ir.load(&cg.lc.builder, ll_ty, slot, c"evld");
				}
			}
			return bind.llvm.core.constant.null_value(ll_ty);
		}
		.Block => {
			let ty: *mut middle.types.StType = expr_type(cg, e, expected);
			let u: *mut middle.types.StType = middle.types.underlying_type(ty);
			let is_void: bool = u == null || u.kind == middle.types.TypeKind.Void;
			let ll_ty: bind.llvm.core.Type = is_void ? bind.llvm.core.type.void_type(&cg.lc.ctx)
				: back.codegen.types.to_llvm_type(&cg.lc.ctx, &cg.lc.td, ty);
			let prev_slot: bind.llvm.core.Value = cg.yield_slot;
			let prev_ty: *mut middle.types.StType = cg.yield_ty;
			let prev_end: *void = cg.yield_end_bb;
			let prev_yd: u32 = cg.yield_scope_depth;
			let res_slot: bind.llvm.core.Value = is_void ? bind.llvm.core.wrap_value(null)
				: alloca_in_entry(cg, ll_ty, c"blk.tmp");
			let end_bb: *void = bind.llvm.core.append_basic_block(
				&cg.lc.ctx,
				cg.current_fn,
				c"blk.end"
			);
			cg.yield_slot = res_slot;
			cg.yield_ty = ty;
			cg.yield_end_bb = end_bb;
			cg.yield_scope_depth = cg.scope_depth;
			if e.block != null && cg.has_emit_stmt_cb {
				cg.emit_stmt_cb(cg, e.block);
			}
			if !block_has_terminator(cg) {
				bind.llvm.ir.branch(&cg.lc.builder, end_bb);
			}
			bind.llvm.ir.position_at_end(&cg.lc.builder, end_bb);
			cg.yield_slot = prev_slot;
			cg.yield_ty = prev_ty;
			cg.yield_end_bb = prev_end;
			cg.yield_scope_depth = prev_yd;
			if is_void {
				return bind.llvm.core.wrap_value(null);
			}
			return bind.llvm.ir.load(&cg.lc.builder, ll_ty, res_slot, c"blk");
		}
		.ArrayLit => {
			let ty: *mut middle.types.StType = expr_type(cg, e, expected);
			let ll_ty: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
				&cg.lc.ctx,
				&cg.lc.td,
				ty
			);
			let u: *mut middle.types.StType = middle.types.underlying_type(ty);
			let elem_ty: *mut middle.types.StType = u != null ? u.base : null;
			let mut agg: bind.llvm.core.Value = bind.llvm.core.constant.null_value(ll_ty);
			for let mut i: usize = 0; i < e.args.len; i += 1 {
				let v: bind.llvm.core.Value = emit_expr(cg, e.args.data[i], elem_ty);
				agg = bind.llvm.ir.insert_value(&cg.lc.builder, agg, v, i cast u32, c"arrinit");
			}
			return agg;
		}
		.Slice => {
			let usize_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
				&cg.lc.ctx,
				&cg.lc.td,
				cg.sema.tx.usize_t
			);
			// Macro variadic splice: ([mapper(...)])[..]
			if cg.macro_varargs != null && e.lhs != null && e.lhs.kind
				== front.ast.ExprKind.ArrayLit && e.lhs.args.len == 1 {
				let elem0: *front.ast.Expr = e.lhs.args.data[0];
				if elem0 != null && elem0.kind == front.ast.ExprKind.Call && elem0.args.len == 1
					&& elem0.args.data[0] != null && elem0.args.data[0].kind
					== front.ast.ExprKind.VariadicSplice {
					let map_ty: *mut middle.types.StType = expr_type(cg, elem0, null);
					let sl_st: *mut middle.types.StType = cg.sema.tx.slice(map_ty, false, false);
					let sl_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
						&cg.lc.ctx,
						&cg.lc.td,
						sl_st
					);
					let n_va: usize = cg.macro_varargs.len > cg.macro_fixed_argc
						? (cg.macro_varargs.len - cg.macro_fixed_argc) : 0;
					if n_va == 0 {
						return bind.llvm.core.constant.null_value(sl_ll);
					}
					let elem_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
						&cg.lc.ctx,
						&cg.lc.td,
						map_ty
					);
					let arr_ll: bind.llvm.core.Type = bind.llvm.core.type.array(
						elem_ll,
						n_va cast u64
					);
					let arr_ptr: bind.llvm.core.Value = alloca_in_entry(cg, arr_ll, c"msplice");
					let m_callee_ty: *mut middle.types.StType = expr_type(cg, elem0.lhs, null);
					let m_u: *mut middle.types.StType = middle.types.underlying_type(m_callee_ty);
					let m_fn_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_fn_type(
						&cg.lc.ctx,
						&cg.lc.td,
						m_u
					);
					let m_callee: bind.llvm.core.Value = emit_expr(cg, elem0.lhs, m_callee_ty);
					let m_pty: *mut middle.types.StType = (m_u != null && m_u.fn_params.len > 0)
						? m_u.fn_params.data[0] : null;
					let mut m_pfx: []u8 = "";
					if elem0.lhs != null && elem0.lhs.sema_sym != null {
						let msym: *middle.symbol.Symbol =
							elem0.lhs.sema_sym cast *middle.symbol.Symbol;
						let mut plen: usize = (msym.mangled.len >= 3
							&& std.str.eq(msym.mangled[0..3], "st$")) ? 3 : 0;
						for plen < msym.mangled.len && msym.mangled[plen] != '$'
							&& msym.mangled[plen] != '(' && msym.mangled[plen] != '<' {
							plen += 1;
						}
						m_pfx = msym.mangled[0..plen];
					}
					for let mut vi: usize = 0; vi < n_va; vi += 1 {
						let va_e: *front.ast.Expr = cg.macro_varargs.data[cg.macro_fixed_argc + vi];
						let saved_loc_len: usize = cg.locals.len;
						cg.locals.len = cg.macro_caller_locals_len;
						let av_raw: bind.llvm.core.Value = emit_expr(cg, va_e, null);
						cg.locals.len = saved_loc_len;
						let av_ty: *mut middle.types.StType = expr_type(cg, va_e, null);
						let mut call_fn_ll: bind.llvm.core.Type = m_fn_ll;
						let mut call_callee: bind.llvm.core.Value = m_callee;
						let mut call_pty: *mut middle.types.StType = m_pty;
						let mut call_abi_stella: bool = m_u == null
							|| m_u.fn_abi == middle.types.AbiKind.Stella;
						let mut matched_fn: bool = false;
						if elem0.lhs != null && elem0.lhs.sema_sym != null && av_ty != null {
							let msym_g: *middle.symbol.Symbol =
								elem0.lhs.sema_sym cast *middle.symbol.Symbol;
							for let mut gi: usize = 0; gi < cg.sema.generic_fns.len; gi += 1 {
								let ginst: middle.sema.validation.GenericFnInst =
									cg.sema.generic_fns.data[gi];
								if ginst.origin_fn != null
									&& std.str.eq(ginst.origin_fn.name, msym_g.simple)
									&& ginst.args.len == 1
									&& middle.types.eq_type(ginst.args.data[0], av_ty)
									&& ginst.sym != null {
									let fslot: *mut FnSlot = find_function(cg, ginst.sym.mangled);
									if fslot != null {
										call_fn_ll = fslot.fn_ll_ty;
										call_callee = fslot.fn_val;
										call_pty = (fslot.st_ty != null
											&& fslot.st_ty.fn_params.len > 0)
											? fslot.st_ty.fn_params.data[0] : av_ty;
										call_abi_stella = fslot.st_ty == null
											|| fslot.st_ty.fn_abi == middle.types.AbiKind.Stella;
										matched_fn = true;
									}
									break;
								}
							}
						}
						if !matched_fn && m_pfx.len > 0 && av_ty != null {
							for let mut fi: usize = 0; fi < cg.functions.len; fi += 1 {
								let fslot: *mut FnSlot = &cg.functions.data[fi];
								let pfx_match: bool = fslot.name.len >= m_pfx.len
									&& std.str.eq(fslot.name[0..m_pfx.len], m_pfx)
									&& (fslot.name.len == m_pfx.len
									|| fslot.name[m_pfx.len] == '$'
									|| fslot.name[m_pfx.len] == '('
									|| fslot.name[m_pfx.len] == '<');
								if pfx_match && fslot.st_ty != null
									&& fslot.st_ty.fn_params.len == 1
									&& middle.types.eq_type(fslot.st_ty.fn_params.data[0], av_ty) {
									call_fn_ll = fslot.fn_ll_ty;
									call_callee = fslot.fn_val;
									call_pty = fslot.st_ty.fn_params.data[0];
									call_abi_stella = fslot.st_ty.fn_abi
										== middle.types.AbiKind.Stella;
									break;
								}
							}
						}
						let av: bind.llvm.core.Value = (call_pty != null
							&& !middle.types.eq_type(av_ty, call_pty))
							? emit_cast(cg, av_raw, av_ty, call_pty, false)
							: av_raw;
						let mut farg: [1]*void;
						farg[0] = av.handle;
						let mv: bind.llvm.core.Value = bind.llvm.ir.call(
							&cg.lc.builder,
							call_fn_ll,
							call_callee,
							&farg[0],
							1,
							c"mcall"
						);
						if call_abi_stella {
							bind.llvm.core.set_instr_call_conv(mv, 8);
						}
						let mut gidx: [2]*void;
						gidx[0] = bind.llvm.core.constant.integer(usize_ll, 0, false).handle;
						gidx[1] = bind.llvm.core.constant.integer(
							usize_ll,
							vi cast u64,
							false
						).handle;
						let ep: bind.llvm.core.Value = bind.llvm.ir.gep(
							&cg.lc.builder,
							arr_ll,
							arr_ptr,
							&gidx[0],
							2,
							c"msp"
						);
						bind.llvm.ir.store(&cg.lc.builder, mv, ep);
					}
					let mut agg: bind.llvm.core.Value = bind.llvm.core.constant.null_value(sl_ll);
					agg = bind.llvm.ir.insert_value(&cg.lc.builder, agg, arr_ptr, 0, c"sl0");
					agg = bind.llvm.ir.insert_value(
						&cg.lc.builder,
						agg,
						bind.llvm.core.constant.integer(usize_ll, n_va cast u64, false),
						1,
						c"sl1"
					);
					return agg;
				}
			}
			let base_ty: *mut middle.types.StType = expr_type(cg, e.lhs, null);
			let u: *mut middle.types.StType = middle.types.underlying_type(base_ty);
			let mut base_ptr: bind.llvm.core.Value = bind.llvm.core.wrap_value(null);
			let mut base_len: bind.llvm.core.Value = bind.llvm.core.constant.integer(
				usize_ll,
				0,
				false
			);
			if u != null && u.kind == middle.types.TypeKind.Pointer {
				base_ptr = emit_expr(cg, e.lhs, base_ty);
			} else if u != null && u.kind == middle.types.TypeKind.Array {
				base_ptr = emit_lvalue(cg, e.lhs, null);
				if base_ptr.handle == null {
					let arr_ll2: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
						&cg.lc.ctx,
						&cg.lc.td,
						u
					);
					let tmp_a: bind.llvm.core.Value = alloca_in_entry(cg, arr_ll2, c"arrtmp");
					let av2: bind.llvm.core.Value = emit_expr(cg, e.lhs, base_ty);
					bind.llvm.ir.store(&cg.lc.builder, av2, tmp_a);
					base_ptr = tmp_a;
				}
				base_len = bind.llvm.core.constant.integer(usize_ll, u.array_len cast u64, false);
			} else if u != null && u.kind == middle.types.TypeKind.Slice {
				let sv: bind.llvm.core.Value = emit_expr(cg, e.lhs, base_ty);
				base_ptr = bind.llvm.ir.extract_value(&cg.lc.builder, sv, 0, c"sptr");
				base_len = bind.llvm.ir.extract_value(&cg.lc.builder, sv, 1, c"slen");
			}
			let low: bind.llvm.core.Value = e.rhs != null
				? emit_expr(cg, e.rhs, cg.sema.tx.usize_t)
				: bind.llvm.core.constant.integer(usize_ll, 0, false);
			let high: bind.llvm.core.Value = e.index_low != null
				? emit_expr(cg, e.index_low, cg.sema.tx.usize_t)
				: base_len;
			let elem_ty: *mut middle.types.StType = u != null ? u.base : cg.sema.tx.uint(8);
			let elem_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
				&cg.lc.ctx,
				&cg.lc.td,
				elem_ty
			);
			let mut idxs: [1]*void;
			idxs[0] = low.handle;
			let ptr_out: bind.llvm.core.Value = bind.llvm.ir.gep(
				&cg.lc.builder,
				elem_ll,
				base_ptr,
				&idxs[0],
				1,
				c"slptr"
			);
			let len_out: bind.llvm.core.Value = bind.llvm.ir.sub(
				&cg.lc.builder,
				high,
				low,
				c"sllen"
			);
			let sl_st: *mut middle.types.StType = cg.sema.tx.slice(
				elem_ty,
				u != null ? u.is_mutable : false,
				false
			);
			let sl_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
				&cg.lc.ctx,
				&cg.lc.td,
				sl_st
			);
			let mut agg: bind.llvm.core.Value = bind.llvm.core.constant.null_value(sl_ll);
			agg = bind.llvm.ir.insert_value(&cg.lc.builder, agg, ptr_out, 0, c"sl0");
			agg = bind.llvm.ir.insert_value(&cg.lc.builder, agg, len_out, 1, c"sl1");
			return agg;
		}
		.VaStart => {
			if e.args.len > 0 {
				let addr: bind.llvm.core.Value = emit_lvalue(cg, e.args.data[0], null);
				let ptr_ty: bind.llvm.core.Type = bind.llvm.core.type.pointer(&cg.lc.ctx, 0);
				let mut pt: [1]*void;
				pt[0] = ptr_ty.handle;
				let fn_ty: bind.llvm.core.Type = bind.llvm.core.type.function(
					bind.llvm.core.type.void_type(&cg.lc.ctx),
					&pt[0],
					1,
					false
				);
				let mut intr: bind.llvm.core.Value = bind.llvm.core.named_function(
					&cg.lc.mod_ref,
					c"llvm.va_start.p0"
				);
				if intr.handle == null {
					intr = bind.llvm.core.add_function(&cg.lc.mod_ref, c"llvm.va_start.p0", fn_ty);
				}
				let mut ca: [1]*void;
				ca[0] = addr.handle;
				bind.llvm.ir.call(&cg.lc.builder, fn_ty, intr, &ca[0], 1, c"");
			}
			return bind.llvm.core.wrap_value(null);
		}
		.VaCopy => {
			if e.args.len >= 2 {
				let dst: bind.llvm.core.Value = emit_lvalue(cg, e.args.data[0], null);
				let src_ty: *mut middle.types.StType = expr_type(cg, e.args.data[1], null);
				let src_u: *mut middle.types.StType = middle.types.underlying_type(src_ty);
				let src: bind.llvm.core.Value = (src_u != null && src_u.kind
					== middle.types.TypeKind.Pointer)
					? emit_expr(cg, e.args.data[1], src_ty)
					: emit_lvalue(cg, e.args.data[1], null);
				let ptr_ty: bind.llvm.core.Type = bind.llvm.core.type.pointer(&cg.lc.ctx, 0);
				let mut pt: [2]*void;
				pt[0] = ptr_ty.handle;
				pt[1] = ptr_ty.handle;
				let fn_ty: bind.llvm.core.Type = bind.llvm.core.type.function(
					bind.llvm.core.type.void_type(&cg.lc.ctx),
					&pt[0],
					2,
					false
				);
				let mut intr: bind.llvm.core.Value = bind.llvm.core.named_function(
					&cg.lc.mod_ref,
					c"llvm.va_copy.p0"
				);
				if intr.handle == null {
					intr = bind.llvm.core.add_function(&cg.lc.mod_ref, c"llvm.va_copy.p0", fn_ty);
				}
				let mut ca: [2]*void;
				ca[0] = dst.handle;
				ca[1] = src.handle;
				bind.llvm.ir.call(&cg.lc.builder, fn_ty, intr, &ca[0], 2, c"");
			}
			return bind.llvm.core.wrap_value(null);
		}
		.VaEnd => {
			if e.args.len > 0 {
				let arg_ty: *mut middle.types.StType = expr_type(cg, e.args.data[0], null);
				let arg_u: *mut middle.types.StType = middle.types.underlying_type(arg_ty);
				let addr: bind.llvm.core.Value = (arg_u != null && arg_u.kind
					== middle.types.TypeKind.Pointer)
					? emit_expr(cg, e.args.data[0], arg_ty)
					: emit_lvalue(cg, e.args.data[0], null);
				let ptr_ty: bind.llvm.core.Type = bind.llvm.core.type.pointer(&cg.lc.ctx, 0);
				let mut pt: [1]*void;
				pt[0] = ptr_ty.handle;
				let fn_ty: bind.llvm.core.Type = bind.llvm.core.type.function(
					bind.llvm.core.type.void_type(&cg.lc.ctx),
					&pt[0],
					1,
					false
				);
				let mut intr: bind.llvm.core.Value = bind.llvm.core.named_function(
					&cg.lc.mod_ref,
					c"llvm.va_end.p0"
				);
				if intr.handle == null {
					intr = bind.llvm.core.add_function(&cg.lc.mod_ref, c"llvm.va_end.p0", fn_ty);
				}
				let mut ca: [1]*void;
				ca[0] = addr.handle;
				bind.llvm.ir.call(&cg.lc.builder, fn_ty, intr, &ca[0], 1, c"");
			}
			return bind.llvm.core.wrap_value(null);
		}
		.VaArg => {
			let arg_ty: *mut middle.types.StType = e.va_arg_ty != null
				? cg.sema.resolve_type(e.va_arg_ty) : expected;
			let val_u: *mut middle.types.StType = middle.types.underlying_type(arg_ty);
			let val_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
				&cg.lc.ctx,
				&cg.lc.td,
				arg_ty
			);
			let cur_ty: *mut middle.types.StType = expr_type(cg, e.args.data[0], null);
			let cur_u: *mut middle.types.StType = middle.types.underlying_type(cur_ty);
			let cursor: bind.llvm.core.Value = (cur_u != null && cur_u.kind
				== middle.types.TypeKind.Pointer)
				? emit_expr(cg, e.args.data[0], cur_ty)
				: emit_lvalue(cg, e.args.data[0], null);
			let layout: bind.llvm.core.Type = back.codegen.types.va_list_llvm_type(&cg.lc.ctx);
			let ptr_ty: bind.llvm.core.Type = bind.llvm.core.type.pointer(&cg.lc.ctx, 0);
			let i8_ty: bind.llvm.core.Type = bind.llvm.core.type.int8(&cg.lc.ctx);
			let i32_ty: bind.llvm.core.Type = bind.llvm.core.type.int32(&cg.lc.ctx);
			let i64_ty: bind.llvm.core.Type = bind.llvm.core.type.int64(&cg.lc.ctx);
			let sz: u64 = bind.llvm.target.data.abi_size_of(&cg.lc.td, val_ll);
			let align: u64 = bind.llvm.target.data.abi_alignment_of(&cg.lc.td, val_ll) cast u64;
			let sz_rounded: u64 = (sz + 7) & (~(7 cast u64));
			let floating: bool = val_u != null && val_u.kind == middle.types.TypeKind.Float;
			let arch: u8 = back.codegen.types.get_va_list_arch();
			if arch == 2 {
				// riscv64: { ptr }
				let slot: bind.llvm.core.Value = bind.llvm.ir.struct_gep(
					&cg.lc.builder,
					layout,
					cursor,
					0,
					c"va.slot"
				);
				let mut p: bind.llvm.core.Value = bind.llvm.ir.load(
					&cg.lc.builder,
					ptr_ty,
					slot,
					c"va.p"
				);
				if align > 8 {
					let pi: bind.llvm.core.Value = bind.llvm.ir.ptrtoint(
						&cg.lc.builder,
						p,
						i64_ty,
						c"va.pi"
					);
					let pa: bind.llvm.core.Value = bind.llvm.ir.add(
						&cg.lc.builder,
						pi,
						bind.llvm.core.constant.integer(i64_ty, align - 1, false),
						c"va.pa"
					);
					let pm: bind.llvm.core.Value = bind.llvm.ir.bit_and(
						&cg.lc.builder,
						pa,
						bind.llvm.core.constant.integer(i64_ty, ~(align - 1), false),
						c"va.pm"
					);
					p = bind.llvm.ir.inttoptr(&cg.lc.builder, pm, ptr_ty, c"va.ap");
				}
				let mut gidx: [1]*void;
				gidx[0] = bind.llvm.core.constant.integer(i64_ty, sz_rounded, false).handle;
				let nxt: bind.llvm.core.Value = bind.llvm.ir.gep(
					&cg.lc.builder,
					i8_ty,
					p,
					&gidx[0],
					1,
					c"va.nxt"
				);
				bind.llvm.ir.store(&cg.lc.builder, nxt, slot);
				let mut ld: bind.llvm.core.Value = bind.llvm.ir.load(
					&cg.lc.builder,
					val_ll,
					p,
					c"va.ld"
				);
				bind.llvm.core.set_alignment(&ld, 1);
				return ld;
			}
			let reg_bb: *void = bind.llvm.core.append_basic_block(
				&cg.lc.ctx,
				cg.current_fn,
				c"va.reg"
			);
			let stk_bb: *void = bind.llvm.core.append_basic_block(
				&cg.lc.ctx,
				cg.current_fn,
				c"va.stk"
			);
			let mrg_bb: *void = bind.llvm.core.append_basic_block(
				&cg.lc.ctx,
				cg.current_fn,
				c"va.mrg"
			);
			let mut off_slot: bind.llvm.core.Value = bind.llvm.core.wrap_value(null);
			let mut off: bind.llvm.core.Value = bind.llvm.core.wrap_value(null);
			let mut next_off: bind.llvm.core.Value = bind.llvm.core.wrap_value(null);
			let mut top_idx: u32 = 3;
			let mut stk_idx: u32 = 2;
			if arch == 1 {
				// aarch64: { ptr stack, ptr gr_top, ptr vr_top, i32 gr_offs, i32 vr_offs }
				off_slot = bind.llvm.ir.struct_gep(
					&cg.lc.builder,
					layout,
					cursor,
					floating ? (4 cast u32) : (3 cast u32),
					c"va.os"
				);
				off = bind.llvm.ir.load(&cg.lc.builder, i32_ty, off_slot, c"va.off");
				if !floating && align > 8 {
					let oa: bind.llvm.core.Value = bind.llvm.ir.add(
						&cg.lc.builder,
						off,
						bind.llvm.core.constant.integer(i32_ty, 15, false),
						c"va.oa"
					);
					off = bind.llvm.ir.bit_and(
						&cg.lc.builder,
						oa,
						bind.llvm.core.constant.integer(i32_ty, 0xFFFFFFF0, false),
						c"va.om"
					);
				}
				let step: u64 = floating ? (16 cast u64) : sz_rounded;
				next_off = bind.llvm.ir.add(
					&cg.lc.builder,
					off,
					bind.llvm.core.constant.integer(i32_ty, step, false),
					c"va.no"
				);
				bind.llvm.ir.store(&cg.lc.builder, next_off, off_slot);
				let cond: bind.llvm.core.Value = bind.llvm.ir.integer_compare(
					&cg.lc.builder,
					bind.llvm.IntPredicate.SignedLessOrEqual,
					next_off,
					bind.llvm.core.constant.integer(i32_ty, 0, false),
					c"va.inreg"
				);
				bind.llvm.ir.cond_branch(&cg.lc.builder, cond, reg_bb, stk_bb);
				top_idx = floating ? (2 cast u32) : (1 cast u32);
				stk_idx = 0;
			} else {
				// x86_64: { i32 gp_offset, i32 fp_offset, ptr overflow_arg_area, ptr reg_save_area
				// }
				off_slot = bind.llvm.ir.struct_gep(
					&cg.lc.builder,
					layout,
					cursor,
					floating ? (1 cast u32) : (0 cast u32),
					c"va.os"
				);
				off = bind.llvm.ir.load(&cg.lc.builder, i32_ty, off_slot, c"va.off");
				let step: u64 = floating ? (16 cast u64) : sz_rounded;
				next_off = bind.llvm.ir.add(
					&cg.lc.builder,
					off,
					bind.llvm.core.constant.integer(i32_ty, step, false),
					c"va.no"
				);
				let limit: u64 = (floating ? (176 cast u64) : (48 cast u64)) - step;
				let cond: bind.llvm.core.Value = bind.llvm.ir.integer_compare(
					&cg.lc.builder,
					bind.llvm.IntPredicate.UnsignedLessOrEqual,
					off,
					bind.llvm.core.constant.integer(i32_ty, limit, false),
					c"va.inreg"
				);
				bind.llvm.ir.cond_branch(&cg.lc.builder, cond, reg_bb, stk_bb);
				top_idx = 3;
				stk_idx = 2;
			}
			bind.llvm.ir.position_at_end(&cg.lc.builder, reg_bb);
			let top_slot: bind.llvm.core.Value = bind.llvm.ir.struct_gep(
				&cg.lc.builder,
				layout,
				cursor,
				top_idx,
				c"va.ts"
			);
			let top: bind.llvm.core.Value = bind.llvm.ir.load(
				&cg.lc.builder,
				ptr_ty,
				top_slot,
				c"va.top"
			);
			let wide_off: bind.llvm.core.Value = arch == 1
				? bind.llvm.ir.sext(&cg.lc.builder, off, i64_ty, c"va.wo")
				: bind.llvm.ir.zext(&cg.lc.builder, off, i64_ty, c"va.wo");
			let mut ridx: [1]*void;
			ridx[0] = wide_off.handle;
			let reg_ptr: bind.llvm.core.Value = bind.llvm.ir.gep(
				&cg.lc.builder,
				i8_ty,
				top,
				&ridx[0],
				1,
				c"va.rp"
			);
			if arch == 0 {
				bind.llvm.ir.store(&cg.lc.builder, next_off, off_slot);
			}
			bind.llvm.ir.branch(&cg.lc.builder, mrg_bb);
			bind.llvm.ir.position_at_end(&cg.lc.builder, stk_bb);
			let s_slot: bind.llvm.core.Value = bind.llvm.ir.struct_gep(
				&cg.lc.builder,
				layout,
				cursor,
				stk_idx,
				c"va.ss"
			);
			let mut stk_ptr: bind.llvm.core.Value = bind.llvm.ir.load(
				&cg.lc.builder,
				ptr_ty,
				s_slot,
				c"va.sp"
			);
			if align > 8 {
				let pi: bind.llvm.core.Value = bind.llvm.ir.ptrtoint(
					&cg.lc.builder,
					stk_ptr,
					i64_ty,
					c"va.pi"
				);
				let pa: bind.llvm.core.Value = bind.llvm.ir.add(
					&cg.lc.builder,
					pi,
					bind.llvm.core.constant.integer(i64_ty, align - 1, false),
					c"va.pa"
				);
				let pm: bind.llvm.core.Value = bind.llvm.ir.bit_and(
					&cg.lc.builder,
					pa,
					bind.llvm.core.constant.integer(i64_ty, ~(align - 1), false),
					c"va.pm"
				);
				stk_ptr = bind.llvm.ir.inttoptr(&cg.lc.builder, pm, ptr_ty, c"va.ap");
			}
			let mut sidx: [1]*void;
			sidx[0] = bind.llvm.core.constant.integer(i64_ty, sz_rounded, false).handle;
			let nxt_s: bind.llvm.core.Value = bind.llvm.ir.gep(
				&cg.lc.builder,
				i8_ty,
				stk_ptr,
				&sidx[0],
				1,
				c"va.ns"
			);
			bind.llvm.ir.store(&cg.lc.builder, nxt_s, s_slot);
			bind.llvm.ir.branch(&cg.lc.builder, mrg_bb);
			bind.llvm.ir.position_at_end(&cg.lc.builder, mrg_bb);
			let phi: bind.llvm.core.Value = bind.llvm.ir.phi(&cg.lc.builder, ptr_ty, c"va.arg");
			let mut pvals: [2]*void;
			let mut pblks: [2]*void;
			pvals[0] = reg_ptr.handle;
			pvals[1] = stk_ptr.handle;
			pblks[0] = reg_bb;
			pblks[1] = stk_bb;
			bind.llvm.ir.add_incoming(phi, &pvals[0], &pblks[0], 2);
			let mut ld: bind.llvm.core.Value = bind.llvm.ir.load(
				&cg.lc.builder,
				val_ll,
				phi,
				c"va.ld"
			);
			bind.llvm.core.set_alignment(&ld, 1);
			return ld;
		}
		.Offsetof => {
			let op_ty: *mut middle.types.StType = (e.lhs != null && e.lhs.sema_ty != null)
				? (e.lhs.sema_ty cast *mut middle.types.StType)
				: ((e.lhs != null && e.lhs.kind == front.ast.ExprKind.TypeValue)
					? cg.sema.resolve_type(e.lhs.layout_type)
					: expr_type(cg, e.lhs, null));
			let op_u: *mut middle.types.StType = middle.types.underlying_type(op_ty);
			let mut res_val: u64 = 0;
			if op_u != null && op_u.kind == middle.types.TypeKind.Struct {
				let fidx: isize = middle.types.field_index(op_u, e.offsetof_member);
				if fidx >= 0 {
					let ll_ty: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
						&cg.lc.ctx,
						&cg.lc.td,
						op_u
					);
					res_val = bind.llvm.target.data.offset_of_element(
						&cg.lc.td,
						ll_ty,
						fidx cast u32
					);
				}
			}
			let usize_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
				&cg.lc.ctx,
				&cg.lc.td,
				cg.sema.tx.usize_t
			);
			return bind.llvm.core.constant.integer(usize_ll, res_val, false);
		}
		.Sizeof | .Alignof | .Bitsof => {
			let op_ty: *mut middle.types.StType = (e.lhs != null && e.lhs.sema_ty != null)
				? (e.lhs.sema_ty cast *mut middle.types.StType)
				: ((e.lhs != null && e.lhs.kind == front.ast.ExprKind.TypeValue)
					? cg.sema.resolve_type(e.lhs.layout_type)
					: expr_type(cg, e.lhs, null));
			let op_u: *mut middle.types.StType = middle.types.underlying_type(op_ty);
			let mut res_val: u64 = 0;
			if op_u != null && op_u.kind != middle.types.TypeKind.Void {
				let ll_ty: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
					&cg.lc.ctx,
					&cg.lc.td,
					op_u
				);
				if e.kind == front.ast.ExprKind.Sizeof {
					res_val = bind.llvm.target.data.abi_size_of(&cg.lc.td, ll_ty);
				} else if e.kind == front.ast.ExprKind.Alignof {
					res_val = bind.llvm.target.data.abi_alignment_of(&cg.lc.td, ll_ty) cast u64;
					if (op_u.explicit_align cast u64) > res_val {
						res_val = op_u.explicit_align cast u64;
					}
				} else {
					res_val = bind.llvm.target.data.abi_size_of(&cg.lc.td, ll_ty) * 8;
				}
			}
			let usize_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
				&cg.lc.ctx,
				&cg.lc.td,
				cg.sema.tx.usize_t
			);
			return bind.llvm.core.constant.integer(usize_ll, res_val, false);
		}
		_ => {
			let ty: *mut middle.types.StType = expected != null ? expected : cg.sema.tx.void_t;
			return bind.llvm.core.constant.null_value(
				back.codegen.types.to_llvm_type(&cg.lc.ctx, &cg.lc.td, ty)
			);
		}
	}
}
