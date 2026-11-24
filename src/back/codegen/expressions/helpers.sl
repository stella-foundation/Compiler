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

/// Executes `emit_cast`.
pub fn emit_cast(
	cg: *mut CodegenState,
	val: bind.llvm.core.Value,
	src_ty: *mut middle.types.StType,
	dst_ty: *mut middle.types.StType,
	is_bitcast: bool
) -> bind.llvm.core.Value {
	let su: *mut middle.types.StType = middle.types.underlying_type(src_ty);
	let du: *mut middle.types.StType = middle.types.underlying_type(dst_ty);
	let dst_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(&cg.lc.ctx, &cg.lc.td, du);
	if su == null || du == null || middle.types.eq_type(su, du) {
		return val;
	}
	if is_bitcast {
		return bind.llvm.ir.bit_cast(&cg.lc.builder, val, dst_ll, c"bcast");
	}
	let s_int: bool = su.kind == middle.types.TypeKind.UInt || su.kind == middle.types.TypeKind.SInt
		|| su.kind == middle.types.TypeKind.Bool || su.kind == middle.types.TypeKind.Enum;
	let d_int: bool = du.kind == middle.types.TypeKind.UInt || du.kind == middle.types.TypeKind.SInt
		|| du.kind == middle.types.TypeKind.Bool || du.kind == middle.types.TypeKind.Enum;
	let s_signed: bool = su.kind == middle.types.TypeKind.SInt;
	let d_signed: bool = du.kind == middle.types.TypeKind.SInt;
	let s_flt: bool = su.kind == middle.types.TypeKind.Float;
	let d_flt: bool = du.kind == middle.types.TypeKind.Float;

	if s_int && d_int {
		let sw: i32 = su.kind == middle.types.TypeKind.Bool ? 1 : su.width;
		let dw: i32 = du.kind == middle.types.TypeKind.Bool ? 1 : du.width;
		if dw < sw {
			return bind.llvm.ir.trunc(&cg.lc.builder, val, dst_ll, c"trunc");
		}
		if dw > sw {
			if s_signed {
				return bind.llvm.ir.sext(&cg.lc.builder, val, dst_ll, c"sext");
			}
			return bind.llvm.ir.zext(&cg.lc.builder, val, dst_ll, c"zext");
		}
		return val;
	}
	if s_flt && d_flt {
		if du.width < su.width {
			return bind.llvm.ir.fptrunc(&cg.lc.builder, val, dst_ll, c"fptrunc");
		}
		if du.width > su.width {
			return bind.llvm.ir.fpext(&cg.lc.builder, val, dst_ll, c"fpext");
		}
		return val;
	}
	if s_int && d_flt {
		if s_signed {
			return bind.llvm.ir.sitofp(&cg.lc.builder, val, dst_ll, c"sitofp");
		}
		return bind.llvm.ir.uitofp(&cg.lc.builder, val, dst_ll, c"uitofp");
	}
	if s_flt && d_int {
		if d_signed {
			return bind.llvm.ir.fptosi(&cg.lc.builder, val, dst_ll, c"fptosi");
		}
		return bind.llvm.ir.fptoui(&cg.lc.builder, val, dst_ll, c"fptoui");
	}
	if su.kind == middle.types.TypeKind.Pointer && d_int {
		return bind.llvm.ir.ptrtoint(&cg.lc.builder, val, dst_ll, c"ptoi");
	}
	if s_int && du.kind == middle.types.TypeKind.Pointer {
		return bind.llvm.ir.inttoptr(&cg.lc.builder, val, dst_ll, c"itop");
	}
	return bind.llvm.ir.bit_cast(&cg.lc.builder, val, dst_ll, c"cast");
}

/// Executes `coerce_value` (coerce value).
pub fn coerce_value(
	cg: *mut CodegenState,
	val: bind.llvm.core.Value,
	src_ty: *mut middle.types.StType,
	dst_ty: *mut middle.types.StType
) -> bind.llvm.core.Value {
	let du: *mut middle.types.StType = middle.types.underlying_type(dst_ty);
	let su: *mut middle.types.StType = middle.types.underlying_type(src_ty);
	if du != null && su != null && du.kind == middle.types.TypeKind.Slice && su.kind
		== middle.types.TypeKind.Pointer {
		let sb: *mut middle.types.StType = middle.types.underlying_type(su.base);
		if sb != null && sb.kind == middle.types.TypeKind.Array {
			let slice_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
				&cg.lc.ctx,
				&cg.lc.td,
				du
			);
			let len_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
				&cg.lc.ctx,
				&cg.lc.td,
				cg.sema.tx.usize_t
			);
			let len_val: bind.llvm.core.Value = bind.llvm.core.constant.integer(
				len_ll,
				sb.array_len cast u64,
				false
			);
			let mut agg: bind.llvm.core.Value = bind.llvm.core.constant.undef(slice_ll);
			agg = bind.llvm.ir.insert_value(&cg.lc.builder, agg, val, 0, c"as0");
			agg = bind.llvm.ir.insert_value(&cg.lc.builder, agg, len_val, 1, c"as1");
			return agg;
		}
	}
	return val;
}

/// Executes `const_int_val`.
pub fn const_int_val(e: *front.ast.Expr, out_v: *mut i64) -> bool {
	if e == null {
		return false;
	}
	if e.kind == front.ast.ExprKind.IntLit {
		*out_v = e.int_val cast i64;
		return true;
	}
	if e.kind == front.ast.ExprKind.Unary && std.str.eq(e.unary_op, "-") && e.lhs != null
		&& e.lhs.kind == front.ast.ExprKind.IntLit {
		*out_v = -(e.lhs.int_val cast i64);
		return true;
	}
	return false;
}

/// Executes `emit_sat_intrinsic`.
pub fn emit_sat_intrinsic(
	cg: *mut CodegenState,
	is_sub: bool,
	is_signed: bool,
	width: i32,
	ty_ll: bind.llvm.core.Type,
	lv: bind.llvm.core.Value,
	rv: bind.llvm.core.Value
) -> bind.llvm.core.Value {
	let mut buf: [64]u8;
	let pfx: []u8 = is_sub ? (is_signed ? "llvm.ssub.sat.i" : "llvm.usub.sat.i")
		: (is_signed ? "llvm.sadd.sat.i" : "llvm.uadd.sat.i");
	std.mem.copy(&buf[0], pfx.ptr, pfx.len);
	let mut pos: usize = pfx.len;
	let mut w: i32 = width > 0 ? width : 32;
	let mut digits: [16]u8;
	let mut dlen: usize = 0;
	for w > 0 {
		digits[dlen] = ('0' cast u8) + ((w % 10) cast u8);
		dlen += 1;
		w /= 10;
	}
	for dlen > 0 {
		dlen -= 1;
		buf[pos] = digits[dlen];
		pos += 1;
	}
	buf[pos] = 0;
	let mut ptys: [2]*void;
	ptys[0] = ty_ll.handle;
	ptys[1] = ty_ll.handle;
	let fn_ty: bind.llvm.core.Type = bind.llvm.core.type.function(ty_ll, &ptys[0], 2, false);
	let existing: bind.llvm.core.Value = bind.llvm.core.named_function(&cg.lc.mod_ref, &buf[0]);
	let fn_v: bind.llvm.core.Value = existing.handle != null
		? existing
		: bind.llvm.core.add_function(&cg.lc.mod_ref, &buf[0], fn_ty);
	let mut args: [2]*void;
	args[0] = lv.handle;
	args[1] = rv.handle;
	return bind.llvm.ir.call(&cg.lc.builder, fn_ty, fn_v, &args[0], 2, c"sat");
}

/// Executes `emit_sat_mul`.
pub fn emit_sat_mul(
	cg: *mut CodegenState,
	is_signed: bool,
	width: i32,
	ty_ll: bind.llvm.core.Type,
	lv: bind.llvm.core.Value,
	rv: bind.llvm.core.Value
) -> bind.llvm.core.Value {
	let mut buf: [64]u8;
	let pfx: []u8 = is_signed ? "llvm.smul.with.overflow.i" : "llvm.umul.with.overflow.i";
	std.mem.copy(&buf[0], pfx.ptr, pfx.len);
	let mut pos: usize = pfx.len;
	let mut w: i32 = width > 0 ? width : 32;
	let mut digits: [16]u8;
	let mut dlen: usize = 0;
	for w > 0 {
		digits[dlen] = ('0' cast u8) + ((w % 10) cast u8);
		dlen += 1;
		w /= 10;
	}
	for dlen > 0 {
		dlen -= 1;
		buf[pos] = digits[dlen];
		pos += 1;
	}
	buf[pos] = 0;
	let i1_t: bind.llvm.core.Type = bind.llvm.core.type.int1(&cg.lc.ctx);
	let mut ret_elems: [2]*void;
	ret_elems[0] = ty_ll.handle;
	ret_elems[1] = i1_t.handle;
	let ret_st: bind.llvm.core.Type = bind.llvm.core.type.struct_type(
		&cg.lc.ctx,
		&ret_elems[0],
		2,
		false
	);
	let mut ptys: [2]*void;
	ptys[0] = ty_ll.handle;
	ptys[1] = ty_ll.handle;
	let fn_ty: bind.llvm.core.Type = bind.llvm.core.type.function(ret_st, &ptys[0], 2, false);
	let existing: bind.llvm.core.Value = bind.llvm.core.named_function(&cg.lc.mod_ref, &buf[0]);
	let fn_v: bind.llvm.core.Value = existing.handle != null
		? existing
		: bind.llvm.core.add_function(&cg.lc.mod_ref, &buf[0], fn_ty);
	let mut args: [2]*void;
	args[0] = lv.handle;
	args[1] = rv.handle;
	let res: bind.llvm.core.Value = bind.llvm.ir.call(
		&cg.lc.builder,
		fn_ty,
		fn_v,
		&args[0],
		2,
		c"smul"
	);
	let prod: bind.llvm.core.Value = bind.llvm.ir.extract_value(&cg.lc.builder, res, 0, c"mprod");
	let ovf: bind.llvm.core.Value = bind.llvm.ir.extract_value(&cg.lc.builder, res, 1, c"movf");
	if !is_signed {
		let max_u: bind.llvm.core.Value = bind.llvm.core.constant.integer(
			ty_ll,
			0xFFFFFFFFFFFFFFFF,
			true
		);
		return bind.llvm.ir.select(&cg.lc.builder, ovf, max_u, prod, c"usatmul");
	}
	let zero: bind.llvm.core.Value = bind.llvm.core.constant.integer(ty_ll, 0, false);
	let xsign: bind.llvm.core.Value = bind.llvm.ir.bit_xor(&cg.lc.builder, lv, rv, c"xsign");
	let is_neg: bind.llvm.core.Value = bind.llvm.ir.integer_compare(
		&cg.lc.builder,
		bind.llvm.IntPredicate.SignedLessThan,
		xsign,
		zero,
		c"isneg"
	);
	let min_u: u64 = (width > 0 && width <= 64) ? ((1 cast u64) << ((width - 1) cast u64))
		: 0x8000000000000000;
	let max_u: u64 = min_u - 1;
	let min_v: bind.llvm.core.Value = bind.llvm.core.constant.integer(ty_ll, min_u, true);
	let max_v: bind.llvm.core.Value = bind.llvm.core.constant.integer(ty_ll, max_u, true);
	let sat_v: bind.llvm.core.Value = bind.llvm.ir.select(
		&cg.lc.builder,
		is_neg,
		min_v,
		max_v,
		c"satlim"
	);
	return bind.llvm.ir.select(&cg.lc.builder, ovf, sat_v, prod, c"ssatmul");
}

/// Executes `emit_expr` (emit expr).
