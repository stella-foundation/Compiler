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

pub fn emit_lvalue(
	cg: *mut CodegenState,
	e: *front.ast.Expr,
	out_ty: *mut *mut middle.types.StType
) -> bind.llvm.core.Value {
	if e == null {
		return bind.llvm.core.wrap_value(null);
	}
	match e.kind {
		.Ident => {
			if e.path.len == 1 {
				let loc_slot: *mut LocalSlot = find_local(cg, e.path.data[0]);
				if loc_slot != null {
					if out_ty != null {
						*out_ty = loc_slot.st_ty;
					}
					return loc_slot.ptr;
				}
			}
			if e.sema_sym != null {
				let sym: *middle.symbol.Symbol = e.sema_sym cast *middle.symbol.Symbol;
				if sym.kind == middle.symbol.SymKind.Var || sym.kind
					== middle.symbol.SymKind.Const {
					let glob_slot: *mut GlobalSlot = find_global(cg, sym.mangled);
					if glob_slot != null {
						if out_ty != null {
							*out_ty = glob_slot.st_ty;
						}
						return glob_slot.ptr;
					}
				}
			}
			if e.path.len == 1 {
				let glob_slot: *mut GlobalSlot = find_global(cg, e.path.data[0]);
				if glob_slot != null {
					if out_ty != null {
						*out_ty = glob_slot.st_ty;
					}
					return glob_slot.ptr;
				}
			}
			return bind.llvm.core.wrap_value(null);
		}
		.Deref => {
			let ptr_ty: *mut middle.types.StType = expr_type(cg, e.lhs, null);
			let ptr_val: bind.llvm.core.Value = emit_expr(cg, e.lhs, ptr_ty);
			let u: *mut middle.types.StType = middle.types.underlying_type(ptr_ty);
			if out_ty != null && u != null {
				*out_ty = u.base;
			}
			return ptr_val;
		}
		.Member => {
			let mut base_st: *mut middle.types.StType = null;
			let mut base_ptr: bind.llvm.core.Value = bind.llvm.core.wrap_value(null);
			let lhs_ty: *mut middle.types.StType = expr_type(cg, e.lhs, null);
			let lu: *mut middle.types.StType = middle.types.underlying_type(lhs_ty);
			if lu != null && lu.kind == middle.types.TypeKind.Pointer {
				base_ptr = emit_expr(cg, e.lhs, lhs_ty);
				base_st = middle.types.underlying_type(lu.base);
			} else {
				base_ptr = emit_lvalue(cg, e.lhs, &base_st);
				base_st = middle.types.underlying_type(base_st);
			}
			if base_st != null && base_st.kind == middle.types.TypeKind.Union {
				let fidx: isize = middle.types.field_index(base_st, e.member);
				if fidx >= 0 {
					if out_ty != null {
						*out_ty = base_st.fields.data[fidx cast usize];
					}
					return base_ptr;
				}
			}
			if base_st != null && base_st.kind == middle.types.TypeKind.Struct {
				let fidx: isize = middle.types.field_index(base_st, e.member);
				if fidx >= 0 {
					if out_ty != null {
						*out_ty = base_st.fields.data[fidx cast usize];
					}
					let ll_st: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
						&cg.lc.ctx,
						&cg.lc.td,
						base_st
					);
					return bind.llvm.ir.struct_gep(
						&cg.lc.builder,
						ll_st,
						base_ptr,
						fidx cast u32,
						c"fld"
					);
				}
			}
			return bind.llvm.core.wrap_value(null);
		}
		.Index => {
			let base_ty: *mut middle.types.StType = expr_type(cg, e.lhs, null);
			let idx_val: bind.llvm.core.Value = emit_expr(cg, e.rhs, cg.sema.tx.usize_t);
			let u: *mut middle.types.StType = middle.types.underlying_type(base_ty);
			if u != null && u.kind == middle.types.TypeKind.Pointer {
				let base_ptr: bind.llvm.core.Value = emit_expr(cg, e.lhs, base_ty);
				let elem_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
					&cg.lc.ctx,
					&cg.lc.td,
					u.base
				);
				if out_ty != null {
					*out_ty = u.base;
				}
				let mut idxs: [1]*void;
				idxs[0] = idx_val.handle;
				return bind.llvm.ir.gep(&cg.lc.builder, elem_ll, base_ptr, &idxs[0], 1, c"idx");
			}
			if u != null && u.kind == middle.types.TypeKind.Array {
				let mut arr_ty: *mut middle.types.StType = null;
				let arr_ptr: bind.llvm.core.Value = emit_lvalue(cg, e.lhs, &arr_ty);
				let arr_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
					&cg.lc.ctx,
					&cg.lc.td,
					u
				);
				if out_ty != null {
					*out_ty = u.base;
				}
				let i64_ty: bind.llvm.core.Type = bind.llvm.core.type.int64(&cg.lc.ctx);
				let mut idxs: [2]*void;
				idxs[0] = bind.llvm.core.constant.integer(i64_ty, 0, false).handle;
				idxs[1] = idx_val.handle;
				return bind.llvm.ir.gep(&cg.lc.builder, arr_ll, arr_ptr, &idxs[0], 2, c"aidx");
			}
			if u != null && u.kind == middle.types.TypeKind.Slice {
				let slice_val: bind.llvm.core.Value = emit_expr(cg, e.lhs, base_ty);
				let slice_ptr: bind.llvm.core.Value = bind.llvm.ir.extract_value(
					&cg.lc.builder,
					slice_val,
					0,
					c"sptr"
				);
				let elem_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
					&cg.lc.ctx,
					&cg.lc.td,
					u.base
				);
				if out_ty != null {
					*out_ty = u.base;
				}
				let mut idxs: [1]*void;
				idxs[0] = idx_val.handle;
				return bind.llvm.ir.gep(&cg.lc.builder, elem_ll, slice_ptr, &idxs[0], 1, c"sidx");
			}
			return bind.llvm.core.wrap_value(null);
		}
		_ => return bind.llvm.core.wrap_value(null)
	}
}
