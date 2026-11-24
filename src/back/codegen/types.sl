mod back.codegen.types;
import "front/ast.sl";
import "llvm/core.sl";
import "llvm/target.sl";
import "middle/types.sl";

// 0 = x86_64, 1 = aarch64, 2 = riscv64
let mut g_va_arch: u8 = 0;

/// Executes `set_va_list_arch` (set va list arch).
pub fn set_va_list_arch(arch: u8) -> void {
	g_va_arch = arch;
}

/// Executes `get_va_list_arch` (get va list arch).
pub fn get_va_list_arch() -> u8 {
	return g_va_arch;
}

/// Executes `va_list_llvm_type` (va list llvm type).
pub fn va_list_llvm_type(ctx: *mut bind.llvm.core.Context) -> bind.llvm.core.Type {
	let existing: bind.llvm.core.Type = bind.llvm.core.type.by_name(ctx, c"va_list");
	if existing.handle != null {
		return existing;
	}
	let st: bind.llvm.core.Type = bind.llvm.core.type.struct_create_named(ctx, c"va_list");
	let i32_ty: bind.llvm.core.Type = bind.llvm.core.type.int32(ctx);
	let ptr_ty: bind.llvm.core.Type = bind.llvm.core.type.pointer(ctx, 0);
	if g_va_arch == 1 {
		let mut elems: [5]*void;
		elems[0] = ptr_ty.handle;
		elems[1] = ptr_ty.handle;
		elems[2] = ptr_ty.handle;
		elems[3] = i32_ty.handle;
		elems[4] = i32_ty.handle;
		bind.llvm.core.type.struct_set_body(st, &elems[0], 5, false);
	} else if g_va_arch == 2 {
		let mut elems: [1]*void;
		elems[0] = ptr_ty.handle;
		bind.llvm.core.type.struct_set_body(st, &elems[0], 1, false);
	} else {
		let mut elems: [4]*void;
		elems[0] = i32_ty.handle;
		elems[1] = i32_ty.handle;
		elems[2] = ptr_ty.handle;
		elems[3] = ptr_ty.handle;
		bind.llvm.core.type.struct_set_body(st, &elems[0], 4, false);
	}
	return st;
}

/// Executes `tagged_enum_payload_struct` (tagged enum payload struct).
pub fn tagged_enum_payload_struct(
	ctx: *mut bind.llvm.core.Context,
	td: *bind.llvm.target.TargetData,
	vi: *middle.types.EnumVariantInfo
) -> bind.llvm.core.Type {
	if vi == null || vi.field_types.len == 0 {
		return bind.llvm.core.type.struct_type(ctx, null, 0, false);
	}
	let count: usize = vi.field_types.len;
	let raw: *mut u8 = front.ast.arena_alloc(count * @of.size(usize));
	if raw == null {
		return bind.llvm.core.type.struct_type(ctx, null, 0, false);
	}
	let elems: *mut *void = raw cast *mut *void;
	for let mut i: usize = 0; i < count; i += 1 {
		elems[i] = to_llvm_type(ctx, td, vi.field_types.data[i]).handle;
	}
	return bind.llvm.core.type.struct_type(ctx, elems, count cast u32, false);
}

/// Executes `to_llvm_type` (to llvm type).
pub fn to_llvm_type(
	ctx: *mut bind.llvm.core.Context,
	td: *bind.llvm.target.TargetData,
	st: *mut middle.types.StType
) -> bind.llvm.core.Type {
	if st == null {
		return bind.llvm.core.type.void_type(ctx);
	}
	let u: *mut middle.types.StType = middle.types.underlying_type(st);
	if u == null {
		return bind.llvm.core.type.void_type(ctx);
	}
	if u.ll_ty != null {
		return bind.llvm.core.wrap_type(u.ll_ty);
	}
	match u.kind {
		.Void => return bind.llvm.core.type.void_type(ctx),
		.Bool => return bind.llvm.core.type.int1(ctx),
		.UInt | .SInt => {
			let w: u32 = u.width > 0 ? (u.width cast u32) : 64;
			return bind.llvm.core.type.integer(ctx, w);
		}
		.Float => {
			if u.width == 16 {
				return bind.llvm.core.type.half(ctx);
			}
			if u.width == 32 {
				return bind.llvm.core.type.float(ctx);
			}
			if u.width == 128 {
				return bind.llvm.core.type.fp128(ctx);
			}
			return bind.llvm.core.type.double(ctx);
		}
		.Pointer => return bind.llvm.core.type.pointer(ctx, 0),
		.VaList => return va_list_llvm_type(ctx),
		.Array => {
			let elem: bind.llvm.core.Type = to_llvm_type(ctx, td, u.base);
			return bind.llvm.core.type.array(elem, u.array_len cast u64);
		}
		.Slice => {
			let ptr_bits: u32 = td.handle != null ? (bind.llvm.target.data.pointer_size(td) * 8)
				: 64;
			let mut elems: [2]*void;
			elems[0] = bind.llvm.core.type.pointer(ctx, 0).handle;
			elems[1] = bind.llvm.core.type.integer(ctx, ptr_bits).handle;
			return bind.llvm.core.type.struct_type(ctx, &elems[0], 2, false);
		}
		.Enum => {
			let tag_ll: bind.llvm.core.Type = u.base != null ? to_llvm_type(ctx, td, u.base)
				: bind.llvm.core.type.int32(ctx);
			if !u.is_tagged_enum {
				return tag_ll;
			}
			let mut max_bytes: u64 = 0;
			let mut max_align: u64 = (u.explicit_align > 1) ? (u.explicit_align cast u64) : 1;
			for let mut i: usize = 0; i < u.enum_variants.len; i += 1 {
				if u.enum_variants.data[i].field_types.len > 0 {
					let pay_st: bind.llvm.core.Type = tagged_enum_payload_struct(
						ctx,
						td,
						&u.enum_variants.data[i]
					);
					let sz: u64 = bind.llvm.target.data.abi_size_of(td, pay_st);
					let al: u64 = bind.llvm.target.data.abi_alignment_of(td, pay_st) cast u64;
					if sz > max_bytes {
						max_bytes = sz;
					}
					if al > max_align {
						max_align = al;
					}
					for let mut fi: usize = 0; fi
						< u.enum_variants.data[i].field_types.len; fi += 1 {
						let fu: *mut middle.types.StType = middle.types.underlying_type(
							u.enum_variants.data[i].field_types.data[fi]
						);
						if fu != null && (fu.explicit_align cast u64) > max_align {
							max_align = fu.explicit_align cast u64;
						}
					}
				}
			}
			if max_bytes == 0 {
				return tag_ll;
			}
			let mut unit_ty: bind.llvm.core.Type = bind.llvm.core.type.int8(ctx);
			let mut unit_sz: u64 = 1;
			if max_align >= 16 {
				unit_ty = bind.llvm.core.type.vector(
					bind.llvm.core.type.int8(ctx),
					max_align cast u32
				);
				unit_sz = max_align;
			} else if max_align >= 8 {
				unit_ty = bind.llvm.core.type.int64(ctx);
				unit_sz = 8;
			} else if max_align >= 4 {
				unit_ty = bind.llvm.core.type.int32(ctx);
				unit_sz = 4;
			} else if max_align >= 2 {
				unit_ty = bind.llvm.core.type.int16(ctx);
				unit_sz = 2;
			}
			let count: u64 = (max_bytes + unit_sz - 1) / unit_sz;
			let pay_arr: bind.llvm.core.Type = bind.llvm.core.type.array(unit_ty, count);
			let mut elems: [2]*void;
			elems[0] = tag_ll.handle;
			elems[1] = pay_arr.handle;
			return bind.llvm.core.type.struct_type(ctx, &elems[0], 2, false);
		}
		.Struct => {
			if u.is_opaque || u.fields.len == 0 {
				return bind.llvm.core.type.struct_type(ctx, null, 0, false);
			}
			let count: usize = u.fields.len;
			let raw: *mut u8 = front.ast.arena_alloc(count * @of.size(usize));
			if raw == null {
				return bind.llvm.core.type.struct_type(ctx, null, 0, false);
			}
			let elems: *mut *void = raw cast *mut *void;
			for let mut i: usize = 0; i < count; i += 1 {
				elems[i] = to_llvm_type(ctx, td, u.fields.data[i]).handle;
			}
			let res: bind.llvm.core.Type = bind.llvm.core.type.struct_type(
				ctx,
				elems,
				count cast u32,
				false
			);
			u.ll_ty = res.handle;
			return res;
		}
		.Union => {
			let ptr_bytes: usize = td.handle != null
				? (bind.llvm.target.data.pointer_size(td) cast usize) : 8;
			let sz: usize = middle.types.type_size_bytes(u, ptr_bytes);
			let elem: bind.llvm.core.Type = bind.llvm.core.type.int8(ctx);
			return bind.llvm.core.type.array(elem, (sz > 0 ? sz : (1 cast usize)) cast u64);
		}
		.Function => return bind.llvm.core.type.pointer(ctx, 0),
		_ => return bind.llvm.core.type.pointer(ctx, 0)
	}
}

/// Enumerates `CAbiKind` variants.
pub enum CAbiKind: u8 {
	Direct,
	Coerce,
	ByVal,
	SRet
}

/// Represents the `CAbiArg` data structure.
pub struct CAbiArg {
	/// Stores the `kind` field (kind).
	pub kind: CAbiKind,
	/// Stores the `storage_ty` field (storage ty).
	pub storage_ty: bind.llvm.core.Type,
	/// Stores the `coerced_ty` field (coerced ty).
	pub coerced_ty: bind.llvm.core.Type
}

fn c_abi_int_for_bytes(ctx: *mut bind.llvm.core.Context, nbytes: u64) -> bind.llvm.core.Type {
	if nbytes <= 1 {
		return bind.llvm.core.type.int8(ctx);
	}
	if nbytes <= 2 {
		return bind.llvm.core.type.int16(ctx);
	}
	if nbytes <= 4 {
		return bind.llvm.core.type.int32(ctx);
	}
	return bind.llvm.core.type.int64(ctx);
}

fn sysv_check_float_only(
	st: *mut middle.types.StType,
	ptr_bytes: usize,
	off: usize,
	lo: usize,
	hi: usize,
	has_int: *mut bool,
	has_flt: *mut bool
) -> void {
	let u: *mut middle.types.StType = middle.types.underlying_type(st);
	if u == null {
		return;
	}
	match u.kind {
		.Float => {
			let sz: usize = ((u.width + 7) / 8) cast usize;
			if off + sz > lo && off < hi {
				*has_flt = true;
			}
		}
		.Struct => {
			let mut cur: usize = off;
			for let mut i: usize = 0; i < u.fields.len; i += 1 {
				let fa: usize = middle.types.type_align_bytes(u.fields.data[i], ptr_bytes);
				if fa > 1 && (cur % fa) != 0 {
					cur += fa - (cur % fa);
				}
				sysv_check_float_only(u.fields.data[i], ptr_bytes, cur, lo, hi, has_int, has_flt);
				cur += middle.types.type_size_bytes(u.fields.data[i], ptr_bytes);
			}
		}
		.Array => {
			let esz: usize = middle.types.type_size_bytes(u.base, ptr_bytes);
			for let mut i: usize = 0; i < u.array_len; i += 1 {
				sysv_check_float_only(u.base, ptr_bytes, off + i * esz, lo, hi, has_int, has_flt);
			}
		}
		_ => {
			let sz: usize = middle.types.type_size_bytes(u, ptr_bytes);
			if sz > 0 && off + sz > lo && off < hi {
				*has_int = true;
			}
		}
	}
}

/// Executes `classify_c_abi` (classify c abi).
pub fn classify_c_abi(
	ctx: *mut bind.llvm.core.Context,
	td: *bind.llvm.target.TargetData,
	st: *mut middle.types.StType,
	is_return: bool
) -> CAbiArg {
	let u: *mut middle.types.StType = middle.types.underlying_type(st);
	if u == null || u.kind == middle.types.TypeKind.Void {
		let vt: bind.llvm.core.Type = bind.llvm.core.type.void_type(ctx);
		return { .kind = CAbiKind.Direct, .storage_ty = vt, .coerced_ty = vt };
	}
	let storage_ty: bind.llvm.core.Type = to_llvm_type(ctx, td, u);
	if u.kind != middle.types.TypeKind.Struct && u.kind != middle.types.TypeKind.Union && u.kind
		!= middle.types.TypeKind.Array
		&& !(u.kind == middle.types.TypeKind.Enum && u.is_tagged_enum) {
		return { .kind = CAbiKind.Direct, .storage_ty = storage_ty, .coerced_ty = storage_ty };
	}
	let sz: u64 = bind.llvm.target.data.abi_size_of(td, storage_ty);
	if sz == 0 {
		return { .kind = CAbiKind.Direct, .storage_ty = storage_ty, .coerced_ty = storage_ty };
	}
	if sz > 16 {
		let ptr_ty: bind.llvm.core.Type = bind.llvm.core.type.pointer(ctx, 0);
		return {
			.kind = is_return ? CAbiKind.SRet : CAbiKind.ByVal,
			.storage_ty = storage_ty,
			.coerced_ty = ptr_ty
		};
	}
	let ptr_bytes: usize = 8;
	let mut hi0: bool = false;
	let mut hf0: bool = false;
	sysv_check_float_only(u, ptr_bytes, 0, 0, 8, &hi0, &hf0);
	let sz0: u64 = sz < 8 ? sz : (8 cast u64);
	let t0: bind.llvm.core.Type = (!hi0 && hf0)
		? (sz <= 4 ? bind.llvm.core.type.float(ctx) : bind.llvm.core.type.double(ctx))
		: c_abi_int_for_bytes(ctx, sz0);
	if sz <= 8 {
		return { .kind = CAbiKind.Coerce, .storage_ty = storage_ty, .coerced_ty = t0 };
	}
	let mut hi1: bool = false;
	let mut hf1: bool = false;
	sysv_check_float_only(u, ptr_bytes, 0, 8, 16, &hi1, &hf1);
	let rem: u64 = sz - 8;
	let t1: bind.llvm.core.Type = (!hi1 && hf1)
		? (rem <= 4 ? bind.llvm.core.type.float(ctx) : bind.llvm.core.type.double(ctx))
		: c_abi_int_for_bytes(ctx, rem);
	let mut pair: [2]*void;
	pair[0] = t0.handle;
	pair[1] = t1.handle;
	let pair_ty: bind.llvm.core.Type = bind.llvm.core.type.struct_type(ctx, &pair[0], 2, false);
	return { .kind = CAbiKind.Coerce, .storage_ty = storage_ty, .coerced_ty = pair_ty };
}

/// Executes `to_llvm_fn_type` (to llvm fn type).
pub fn to_llvm_fn_type(
	ctx: *mut bind.llvm.core.Context,
	td: *bind.llvm.target.TargetData,
	st: *mut middle.types.StType
) -> bind.llvm.core.Type {
	let u: *mut middle.types.StType = middle.types.underlying_type(st);
	if u == null || u.kind != middle.types.TypeKind.Function {
		return bind.llvm.core.type.function(bind.llvm.core.type.void_type(ctx), null, 0, false);
	}
	if u.fn_abi == middle.types.AbiKind.C {
		let ret_abi: CAbiArg = classify_c_abi(ctx, td, u.fn_ret, true);
		let has_sret: bool = ret_abi.kind == CAbiKind.SRet;
		let llvm_ret: bind.llvm.core.Type = has_sret ? bind.llvm.core.type.void_type(ctx)
			: ret_abi.coerced_ty;
		let total: usize = u.fn_params.len + (has_sret ? 1 : 0);
		if total == 0 {
			return bind.llvm.core.type.function(llvm_ret, null, 0, u.fn_variadic);
		}
		let raw: *mut u8 = front.ast.arena_alloc(total * @of.size(usize));
		if raw == null {
			return bind.llvm.core.type.function(llvm_ret, null, 0, u.fn_variadic);
		}
		let params: *mut *void = raw cast *mut *void;
		let mut out_i: usize = 0;
		if has_sret {
			params[out_i] = bind.llvm.core.type.pointer(ctx, 0).handle;
			out_i += 1;
		}
		for let mut i: usize = 0; i < u.fn_params.len; i += 1 {
			let pa: CAbiArg = classify_c_abi(ctx, td, u.fn_params.data[i], false);
			params[out_i] = pa.coerced_ty.handle;
			out_i += 1;
		}
		return bind.llvm.core.type.function(
			llvm_ret,
			params,
			total cast u32,
			u.fn_variadic
		);
	}
	let ret: bind.llvm.core.Type = to_llvm_type(ctx, td, u.fn_ret);
	let count: usize = u.fn_params.len;
	if count == 0 {
		return bind.llvm.core.type.function(ret, null, 0, u.fn_variadic);
	}
	let raw: *mut u8 = front.ast.arena_alloc(count * @of.size(usize));
	if raw == null {
		return bind.llvm.core.type.function(ret, null, 0, u.fn_variadic);
	}
	let params: *mut *void = raw cast *mut *void;
	for let mut i: usize = 0; i < count; i += 1 {
		params[i] = to_llvm_type(ctx, td, u.fn_params.data[i]).handle;
	}
	return bind.llvm.core.type.function(ret, params, count cast u32, u.fn_variadic);
}
