mod middle.types;
import "front/ast.sl";
import "std/str.sl";

/// Enumerates `AbiKind` variants.
pub enum AbiKind: u8 {
	Stella,
	C
}

/// Enumerates `ReprKind` variants.
pub enum ReprKind: u8 {
	Stella,
	C
}

/// Enumerates `TypeKind` variants.
pub enum TypeKind: u8 {
	Void,
	Bool,
	UInt,
	SInt,
	Float,
	Pointer,
	Array,
	Slice,
	Struct,
	Union,
	Function,
	Type,
	TypeBinding,
	Opaque,
	Enum,
	VaList,
	Poison,
	SelfType
}

/// Represents the `EnumVariantInfo` data structure.
pub struct EnumVariantInfo {
	/// Stores the `payload_kind` field (payload kind).
	pub payload_kind: front.ast.EnumPayloadKind,
	/// Stores the `field_types` field (field types).
	pub field_types: front.ast.PtrList<StType>,
	/// Stores the `field_names` field (field names).
	pub field_names: front.ast.ValList<[]u8>
}

/// Represents the `StType` data structure.
pub struct StType {
	/// Stores the `kind` field (kind).
	pub kind: TypeKind,
	/// Stores the `width` field (width).
	pub width: i32,
	/// Stores the `name` field (name).
	pub name: []u8,
	/// Stores the `mangled_name` field (mangled name).
	pub mangled_name: []u8,
	/// Stores the `base` field (base).
	pub base: *mut StType,
	/// Stores the `array_len` field (array len).
	pub array_len: usize,
	/// Stores the `fields` field (fields).
	pub fields: front.ast.PtrList<StType>,
	/// Stores the `field_names` field (field names).
	pub field_names: front.ast.ValList<[]u8>,
	/// Stores the `field_is_pub` field (field is pub).
	pub field_is_pub: front.ast.ValList<bool>,
	/// Stores the `is_mutable` field (is mutable).
	pub is_mutable: bool,
	/// Stores the `is_volatile` field (is volatile).
	pub is_volatile: bool,
	/// Stores the `is_pub` field (is pub).
	pub is_pub: bool,
	/// Stores the `is_foreign` field (is foreign).
	pub is_foreign: bool,
	/// Stores the `is_opaque` field (is opaque).
	pub is_opaque: bool,
	/// Stores the `repr` field (repr).
	pub repr: ReprKind,
	/// Stores the `explicit_align` field (explicit align).
	pub explicit_align: u64,
	/// Stores the `enum_values` field (enum values).
	pub enum_values: front.ast.ValList<u64>,
	/// Stores the `is_tagged_enum` field (is tagged enum).
	pub is_tagged_enum: bool,
	/// Stores the `enum_variants` field (enum variants).
	pub enum_variants: front.ast.ValList<EnumVariantInfo>,
	/// Stores the `fn_params` field (fn params).
	pub fn_params: front.ast.PtrList<StType>,
	/// Stores the `fn_ret` field (fn ret).
	pub fn_ret: *mut StType,
	/// Stores the `fn_variadic` field (fn variadic).
	pub fn_variadic: bool,
	/// Stores the `fn_abi` field (fn abi).
	pub fn_abi: AbiKind,
	/// Stores the `generic_origin_name` field (generic origin name).
	pub generic_origin_name: []u8,
	/// Stores the `generic_args` field (generic args).
	pub generic_args: front.ast.PtrList<StType>,
	/// Stores the `ll_ty` field (ll ty).
	pub ll_ty: *void
}

/// Executes `underlying_type` (underlying type).
pub fn underlying_type(mut t: *mut StType) -> *mut StType {
	let mut guard: i32 = 0;
	for t != null && t.kind == TypeKind.TypeBinding && guard < 64 {
		t = t.base;
		guard += 1;
	}
	return t;
}

/// Executes `is_poison` (is poison).
pub fn is_poison(t: *mut StType) -> bool {
	if t == null {
		return false;
	}
	let u: *mut StType = underlying_type(t);
	return u != null && u.kind == TypeKind.Poison;
}

/// Executes `field_index` (field index).
pub fn field_index(st: *StType, name: []u8) -> isize {
	if st == null {
		return -1;
	}
	for let mut i: usize = 0; i < st.field_names.len; i += 1 {
		if std.str.eq(st.field_names.data[i], name) {
			return i cast isize;
		}
	}
	return -1;
}

/// Executes `eq_type` (eq type).
pub fn eq_type(a: *mut StType, b: *mut StType) -> bool {
	let ua: *mut StType = underlying_type(a);
	let ub: *mut StType = underlying_type(b);
	if ua == ub {
		return true;
	}
	if ua == null || ub == null {
		return false;
	}
	if ua.kind == TypeKind.Poison || ub.kind == TypeKind.Poison {
		return true;
	}
	if ua.kind != ub.kind {
		return false;
	}
	match ua.kind {
		.Void | .Bool | .Type | .VaList | .SelfType => return true,
		.UInt | .SInt | .Float => return ua.width == ub.width,
		.Pointer => {
			return ua.is_mutable == ub.is_mutable
				&& ua.is_volatile == ub.is_volatile
				&& eq_type(ua.base, ub.base);
		}
		.Slice => {
			return ua.is_mutable == ub.is_mutable
				&& ua.is_volatile == ub.is_volatile
				&& eq_type(ua.base, ub.base);
		}
		.Array => {
			return ua.array_len == ub.array_len && eq_type(ua.base, ub.base);
		}
		.Function => {
			if ua.fn_variadic != ub.fn_variadic || ua.fn_abi != ub.fn_abi
				|| ua.fn_params.len != ub.fn_params.len || !eq_type(ua.fn_ret, ub.fn_ret) {
				return false;
			}
			for let mut i: usize = 0; i < ua.fn_params.len; i += 1 {
				if !eq_type(ua.fn_params.data[i], ub.fn_params.data[i]) {
					return false;
				}
			}
			return true;
		}
		_ => return ua == ub
	}
}

/// Executes `is_assignable_type` (is assignable type).
pub fn is_assignable_type(expected: *mut StType, actual: *mut StType) -> bool {
	if eq_type(expected, actual) {
		return true;
	}
	let ue: *mut StType = underlying_type(expected);
	let ua: *mut StType = underlying_type(actual);
	if ue == null || ua == null {
		return false;
	}
	if ue.kind == TypeKind.Function && ua.kind == TypeKind.Pointer {
		let ab: *mut StType = underlying_type(ua.base);
		if ab != null && ab.kind == TypeKind.Void {
			return true;
		}
	}
	if ue.kind == TypeKind.Pointer && ua.kind == TypeKind.Pointer {
		if ue.is_mutable && !ua.is_mutable {
			return false;
		}
		if !ue.is_volatile && ua.is_volatile {
			return false;
		}
		let eb: *mut StType = underlying_type(ue.base);
		if eb != null && eb.kind == TypeKind.Void {
			return true;
		}
		return eq_type(ue.base, ua.base);
	}
	if ue.kind == TypeKind.Slice && ua.kind == TypeKind.Slice {
		if ue.is_mutable && !ua.is_mutable {
			return false;
		}
		if !ue.is_volatile && ua.is_volatile {
			return false;
		}
		return eq_type(ue.base, ua.base);
	}
	if ue.kind == TypeKind.Slice && ua.kind == TypeKind.Pointer {
		if ue.is_mutable && !ua.is_mutable {
			return false;
		}
		if !ue.is_volatile && ua.is_volatile {
			return false;
		}
		let ab: *mut StType = underlying_type(ua.base);
		if ab != null && ab.kind == TypeKind.Array {
			return eq_type(ue.base, ab.base);
		}
	}
	return false;
}

/// Represents the `TypeContext` data structure.
pub struct TypeContext {
	/// Stores the `pool` field (pool).
	pub pool: front.ast.PtrList<StType>,
	/// Stores the `void_t` field (void t).
	pub void_t: *mut StType,
	/// Stores the `bool_t` field (bool t).
	pub bool_t: *mut StType,
	/// Stores the `usize_t` field (usize t).
	pub usize_t: *mut StType,
	/// Stores the `isize_t` field (isize t).
	pub isize_t: *mut StType,
	/// Stores the `va_list_t` field (va list t).
	pub va_list_t: *mut StType,
	/// Stores the `type_t` field (type t).
	pub type_t: *mut StType,
	/// Stores the `poison_t` field (poison t).
	pub poison_t: *mut StType,
	/// Stores the `self_t` field (self t).
	pub self_t: *mut StType,
	/// Stores the `pointer_width` field (pointer width).
	pub pointer_width: i32
}

fn alloc_st_type(
	pool: *mut front.ast.PtrList<StType>,
	kind: TypeKind,
	width: i32,
	name: []u8
) -> *mut StType {
	let raw: *mut u8 = front.ast.arena_alloc(@of.size(StType));
	if raw == null {
		return null;
	}
	let t: *mut StType = raw cast *mut StType;
	*t = {
		.kind = kind,
		.width = width,
		.name = name,
		.mangled_name = "",
		.base = null,
		.array_len = 0,
		.fields = { .data = null, .len = 0, .cap = 0 },
		.field_names = { .data = null, .len = 0, .cap = 0 },
		.field_is_pub = { .data = null, .len = 0, .cap = 0 },
		.is_mutable = false,
		.is_volatile = false,
		.is_pub = false,
		.is_foreign = false,
		.is_opaque = false,
		.repr = ReprKind.Stella,
		.explicit_align = 0,
		.enum_values = { .data = null, .len = 0, .cap = 0 },
		.is_tagged_enum = false,
		.enum_variants = { .data = null, .len = 0, .cap = 0 },
		.fn_params = { .data = null, .len = 0, .cap = 0 },
		.fn_ret = null,
		.fn_variadic = false,
		.fn_abi = AbiKind.Stella,
		.generic_origin_name = "",
		.generic_args = { .data = null, .len = 0, .cap = 0 },
		.ll_ty = null
	};
	pool.push(t);
	return t;
}

/// Executes `init_type_context` (init type context).
pub fn init_type_context(pointer_width: i32) -> TypeContext {
	let mut pool: front.ast.PtrList<StType> = { .data = null, .len = 0, .cap = 0 };
	let void_t: *mut StType = alloc_st_type(&pool, TypeKind.Void, 0, "void");
	let bool_t: *mut StType = alloc_st_type(&pool, TypeKind.Bool, 1, "bool");
	let usize_t: *mut StType = alloc_st_type(&pool, TypeKind.UInt, pointer_width, "usize");
	let isize_t: *mut StType = alloc_st_type(&pool, TypeKind.SInt, pointer_width, "isize");
	let va_list_t: *mut StType = alloc_st_type(&pool, TypeKind.VaList, 0, "va_list");
	let type_t: *mut StType = alloc_st_type(&pool, TypeKind.Type, 0, "type");
	let poison_t: *mut StType = alloc_st_type(&pool, TypeKind.Poison, 0, "<poison>");
	let self_t: *mut StType = alloc_st_type(&pool, TypeKind.SelfType, 0, "Self");
	return {
		.pool = pool,
		.void_t = void_t,
		.bool_t = bool_t,
		.usize_t = usize_t,
		.isize_t = isize_t,
		.va_list_t = va_list_t,
		.type_t = type_t,
		.poison_t = poison_t,
		.self_t = self_t,
		.pointer_width = pointer_width
	};
}

impl TypeContext {
	/// Executes `uint` (uint).
	pub fn uint(self: *mut TypeContext, width: i32) -> *mut StType {
		for let mut i: usize = 0; i < self.pool.len; i += 1 {
			let t: *mut StType = self.pool.data[i];
			if t.kind == TypeKind.UInt && t.width == width && t != self.usize_t {
				return t;
			}
		}
		return alloc_st_type(&self.pool, TypeKind.UInt, width, "uint");
	}

	/// Executes `sint` (sint).
	pub fn sint(self: *mut TypeContext, width: i32) -> *mut StType {
		for let mut i: usize = 0; i < self.pool.len; i += 1 {
			let t: *mut StType = self.pool.data[i];
			if t.kind == TypeKind.SInt && t.width == width && t != self.isize_t {
				return t;
			}
		}
		return alloc_st_type(&self.pool, TypeKind.SInt, width, "sint");
	}

	/// Executes `float_ty` (float ty).
	pub fn float_ty(self: *mut TypeContext, width: i32) -> *mut StType {
		for let mut i: usize = 0; i < self.pool.len; i += 1 {
			let t: *mut StType = self.pool.data[i];
			if t.kind == TypeKind.Float && t.width == width {
				return t;
			}
		}
		return alloc_st_type(&self.pool, TypeKind.Float, width, "float");
	}

	/// Executes `pointer` (pointer).
	pub fn pointer(
		self: *mut TypeContext,
		base: *mut StType,
		is_mutable: bool,
		is_volatile: bool
	) -> *mut StType {
		for let mut i: usize = 0; i < self.pool.len; i += 1 {
			let t: *mut StType = self.pool.data[i];
			if t.kind == TypeKind.Pointer && t.base == base
				&& t.is_mutable == is_mutable && t.is_volatile == is_volatile {
				return t;
			}
		}
		let t: *mut StType = alloc_st_type(&self.pool, TypeKind.Pointer, self.pointer_width, "*");
		t.base = base;
		t.is_mutable = is_mutable;
		t.is_volatile = is_volatile;
		return t;
	}

	/// Executes `array_of` (array of).
	pub fn array_of(self: *mut TypeContext, elem: *mut StType, len: usize) -> *mut StType {
		for let mut i: usize = 0; i < self.pool.len; i += 1 {
			let t: *mut StType = self.pool.data[i];
			if t.kind == TypeKind.Array && t.base == elem && t.array_len == len {
				return t;
			}
		}
		let t: *mut StType = alloc_st_type(&self.pool, TypeKind.Array, 0, "[]");
		t.base = elem;
		t.array_len = len;
		return t;
	}

	/// Executes `slice` (slice).
	pub fn slice(
		self: *mut TypeContext,
		elem: *mut StType,
		is_mutable: bool,
		is_volatile: bool
	) -> *mut StType {
		for let mut i: usize = 0; i < self.pool.len; i += 1 {
			let t: *mut StType = self.pool.data[i];
			if t.kind == TypeKind.Slice && t.base == elem
				&& t.is_mutable == is_mutable && t.is_volatile == is_volatile {
				return t;
			}
		}
		let t: *mut StType = alloc_st_type(
			&self.pool,
			TypeKind.Slice,
			self.pointer_width * 2,
			"[]"
		);
		t.base = elem;
		t.is_mutable = is_mutable;
		t.is_volatile = is_volatile;
		return t;
	}

	/// Executes `function_of` (function of).
	pub fn function_of(
		self: *mut TypeContext,
		params: front.ast.PtrList<StType>,
		ret: *mut StType,
		variadic: bool,
		abi: AbiKind
	) -> *mut StType {
		let t: *mut StType = alloc_st_type(&self.pool, TypeKind.Function, self.pointer_width, "fn");
		for let mut i: usize = 0; i < params.len; i += 1 {
			t.fn_params.push(params.data[i]);
		}
		t.fn_ret = ret;
		t.fn_variadic = variadic;
		t.fn_abi = abi;
		return t;
	}

	/// Executes `struct_of` (struct of).
	pub fn struct_of(self: *mut TypeContext, name: []u8, is_pub: bool) -> *mut StType {
		let t: *mut StType = alloc_st_type(&self.pool, TypeKind.Struct, 0, name);
		t.is_pub = is_pub;
		return t;
	}

	/// Executes `union_of` (union of).
	pub fn union_of(self: *mut TypeContext, name: []u8, is_pub: bool) -> *mut StType {
		let t: *mut StType = alloc_st_type(&self.pool, TypeKind.Union, 0, name);
		t.is_pub = is_pub;
		return t;
	}

	/// Executes `enum_of` (enum of).
	pub fn enum_of(
		self: *mut TypeContext,
		name: []u8,
		backing: *mut StType,
		is_pub: bool
	) -> *mut StType {
		let bw: i32 = backing != null ? backing.width : (0 cast i32);
		let t: *mut StType = alloc_st_type(&self.pool, TypeKind.Enum, bw, name);
		t.base = backing;
		t.is_pub = is_pub;
		return t;
	}

	/// Executes `type_binding_of` (type binding of).
	pub fn type_binding_of(
		self: *mut TypeContext,
		name: []u8,
		target: *mut StType,
		is_pub: bool
	) -> *mut StType {
		let t: *mut StType = alloc_st_type(&self.pool, TypeKind.TypeBinding, 0, name);
		t.base = target;
		t.is_pub = is_pub;
		return t;
	}

	/// Executes `is_int_like` (is int like).
	pub fn is_int_like(_self: *TypeContext, t: *mut StType) -> bool {
		let u: *mut StType = underlying_type(t);
		if u == null {
			return false;
		}
		return u.kind == TypeKind.UInt || u.kind == TypeKind.SInt || u.kind == TypeKind.Enum;
	}

	/// Executes `is_arith` (is arith).
	pub fn is_arith(_self: *TypeContext, t: *mut StType) -> bool {
		let u: *mut StType = underlying_type(t);
		if u == null {
			return false;
		}
		return u.kind == TypeKind.UInt || u.kind == TypeKind.SInt || u.kind == TypeKind.Float;
	}

	/// Executes `is_pointer` (is pointer).
	pub fn is_pointer(_self: *TypeContext, t: *mut StType) -> bool {
		let u: *mut StType = underlying_type(t);
		return u != null && u.kind == TypeKind.Pointer;
	}
}

/// Executes `prim_from_name` (prim from name).
pub fn prim_from_name(tx: *mut TypeContext, n: []u8) -> *mut StType {
	if std.str.eq(n, "void") {
		return tx.void_t;
	}
	if std.str.eq(n, "bool") {
		return tx.bool_t;
	}
	if std.str.eq(n, "usize") {
		return tx.usize_t;
	}
	if std.str.eq(n, "isize") {
		return tx.isize_t;
	}
	if std.str.eq(n, "type") {
		return tx.type_t;
	}
	if std.str.eq(n, "@va.list") {
		return tx.va_list_t;
	}
	if std.str.eq(n, "f16") {
		return tx.float_ty(16);
	}
	if std.str.eq(n, "f32") {
		return tx.float_ty(32);
	}
	if std.str.eq(n, "f64") {
		return tx.float_ty(64);
	}
	if std.str.eq(n, "f128") {
		return tx.float_ty(128);
	}
	if n.len >= 2 && (n[0] == 'u' || n[0] == 'i') {
		let mut w: i32 = 0;
		for let mut i: usize = 1; i < n.len; i += 1 {
			if n[i] < '0' || n[i] > '9' {
				return null;
			}
			w = w * 10 + ((n[i] - '0') cast i32);
			if w > 65535 {
				return null;
			}
		}
		if w <= 0 {
			return null;
		}
		if n[0] == 'u' {
			return tx.uint(w);
		}
		return tx.sint(w);
	}
	return null;
}

/// Executes `type_align_bytes` (type align bytes).
pub fn type_align_bytes(t: *mut StType, ptr_bytes: usize) -> usize {
	let u: *mut StType = underlying_type(t);
	if u == null {
		return 1;
	}
	let mut al: usize = 1;
	match u.kind {
		.Void => al = 1,
		.Bool => al = 1,
		.UInt | .SInt | .Float => {
			let sz: usize = ((u.width + 7) / 8) cast usize;
			al = sz > 0 ? (sz < ptr_bytes ? sz : ptr_bytes) : 1;
		}
		.Pointer | .Function | .Slice => al = ptr_bytes,
		.Array => al = type_align_bytes(u.base, ptr_bytes),
		.Struct | .Union => {
			for let mut i: usize = 0; i < u.fields.len; i += 1 {
				let fa: usize = type_align_bytes(u.fields.data[i], ptr_bytes);
				if fa > al {
					al = fa;
				}
			}
		}
		.Enum => al = u.base != null ? type_align_bytes(u.base, ptr_bytes) : 4,
		_ => al = ptr_bytes
	}
	if (u.explicit_align cast usize) > al {
		al = u.explicit_align cast usize;
	}
	return al;
}

/// Executes `type_size_bytes` (type size bytes).
pub fn type_size_bytes(t: *mut StType, ptr_bytes: usize) -> usize {
	let u: *mut StType = underlying_type(t);
	if u == null {
		return 0;
	}
	match u.kind {
		.Void | .Type | .Poison | .SelfType => return 0,
		.Bool => return 1,
		.UInt | .SInt | .Float => {
			let bits: usize = u.width cast usize;
			return (bits + 7) / 8;
		}
		.Enum => return type_size_bytes(u.base, ptr_bytes),
		.Pointer | .Function => return ptr_bytes,
		.Slice => return ptr_bytes * 2,
		.Array => return u.array_len * type_size_bytes(u.base, ptr_bytes),
		.Struct => {
			let mut total: usize = 0;
			let mut max_al: usize = (u.explicit_align > 1) ? (u.explicit_align cast usize) : 1;
			for let mut i: usize = 0; i < u.fields.len; i += 1 {
				let fsz: usize = type_size_bytes(u.fields.data[i], ptr_bytes);
				let falign: usize = type_align_bytes(u.fields.data[i], ptr_bytes);
				if falign > max_al {
					max_al = falign;
				}
				let rem: usize = total % falign;
				if rem != 0 {
					total += falign - rem;
				}
				total += fsz;
			}
			let tail: usize = total % max_al;
			if tail != 0 {
				total += max_al - tail;
			}
			return total;
		}
		.Union => {
			let mut max_sz: usize = 0;
			for let mut i: usize = 0; i < u.fields.len; i += 1 {
				let fsz: usize = type_size_bytes(u.fields.data[i], ptr_bytes);
				if fsz > max_sz {
					max_sz = fsz;
				}
			}
			return max_sz;
		}
		_ => return ptr_bytes
	}
}

fn buf_put_str(buf: *mut u8, pos: *mut usize, cap: usize, s: []u8) -> void {
	for let mut i: usize = 0; i < s.len && *pos < cap; i += 1 {
		buf[*pos] = s.ptr[i];
		*pos += 1;
	}
}

fn buf_put_uint(buf: *mut u8, pos: *mut usize, cap: usize, mut v: usize) -> void {
	if v == 0 {
		if *pos < cap {
			buf[*pos] = '0' cast u8;
			*pos += 1;
		}
		return;
	}
	let mut tmp: [24]u8;
	let mut n: usize = 0;
	for v > 0 {
		tmp[n] = ('0' cast u8) + ((v % 10) cast u8);
		n += 1;
		v /= 10;
	}
	for n > 0 && *pos < cap {
		n -= 1;
		buf[*pos] = tmp[n];
		*pos += 1;
	}
}

fn format_type_into(t: *mut StType, buf: *mut u8, pos: *mut usize, cap: usize) -> void {
	if t == null {
		buf_put_str(buf, pos, cap, "<null>");
		return;
	}
	let u: *mut StType = underlying_type(t);
	if u == null {
		buf_put_str(buf, pos, cap, "<null>");
		return;
	}
	match u.kind {
		.Void => buf_put_str(buf, pos, cap, "void"),
		.Bool => buf_put_str(buf, pos, cap, "bool"),
		.UInt => {
			buf_put_str(buf, pos, cap, "u");
			buf_put_uint(buf, pos, cap, u.width cast usize);
		}
		.SInt => {
			buf_put_str(buf, pos, cap, "i");
			buf_put_uint(buf, pos, cap, u.width cast usize);
		}
		.Float => {
			buf_put_str(buf, pos, cap, "f");
			buf_put_uint(buf, pos, cap, u.width cast usize);
		}
		.Pointer => {
			buf_put_str(buf, pos, cap, "*");
			if u.is_mutable {
				buf_put_str(buf, pos, cap, "mut ");
			}
			format_type_into(u.base, buf, pos, cap);
		}
		.Array => {
			buf_put_str(buf, pos, cap, "[");
			buf_put_uint(buf, pos, cap, u.array_len);
			buf_put_str(buf, pos, cap, "]");
			format_type_into(u.base, buf, pos, cap);
		}
		.Slice => {
			buf_put_str(buf, pos, cap, "[]");
			if u.is_mutable {
				buf_put_str(buf, pos, cap, "mut ");
			}
			format_type_into(u.base, buf, pos, cap);
		}
		.Struct | .Union | .Enum => {
			if u.generic_origin_name.len > 0 && u.generic_args.len > 0 {
				buf_put_str(buf, pos, cap, u.generic_origin_name);
				buf_put_str(buf, pos, cap, "<");
				for let mut gi: usize = 0; gi < u.generic_args.len; gi += 1 {
					if gi > 0 {
						buf_put_str(buf, pos, cap, ", ");
					}
					format_type_into(u.generic_args.data[gi], buf, pos, cap);
				}
				buf_put_str(buf, pos, cap, ">");
			} else {
				buf_put_str(buf, pos, cap, u.name.len > 0 ? u.name : "<anon>");
			}
		}
		.Function => buf_put_str(buf, pos, cap, "fn(...)"),
		_ => buf_put_str(buf, pos, cap, "<type>")
	}
}

/// Executes `format_type` (format type).
pub fn format_type(t: *mut StType, buf: *mut u8, cap: usize) -> []u8 {
	let mut pos: usize = 0;
	format_type_into(t, buf, &pos, cap);
	return buf[0..pos];
}
