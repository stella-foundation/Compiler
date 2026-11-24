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
import "std/hash.sl";
import "std/mem.sl";
import "std/str.sl";

/// Executes `make_type_subst`.
pub fn make_type_subst(
	name: []u8,
	ty: *mut middle.types.StType
) -> middle.sema.generics.GenericSubstEntry {
	return { .name = name, .is_const = false, .ty = ty, .const_val = 0 };
}

/// Represents the `QualifiedSym` data structure.
pub struct QualifiedSym {
	/// Stores the `mod_path` field (mod path).
	pub mod_path: front.ast.ValList<[]u8>,
	/// Stores the `sym` field (sym).
	pub sym: *mut middle.symbol.Symbol
}

/// Represents the `ImplMethodEntry` data structure.
pub struct ImplMethodEntry {
	/// Stores the `target_ty` field (target ty).
	pub target_ty: *mut middle.types.StType,
	/// Stores the `fn_decl` field (fn decl).
	pub fn_decl: *front.ast.FnDecl,
	/// Stores the `sym` field (sym).
	pub sym: *mut middle.symbol.Symbol,
	/// Stores the `mod_path` field (mod path).
	pub mod_path: front.ast.ValList<[]u8>,
	/// Stores the `generic_params` field (generic params).
	pub generic_params: front.ast.ValList<front.ast.GenericParam>
}

/// Represents the `GenericImplEntry` data structure.
pub struct GenericImplEntry {
	/// Stores the `imp` field (imp).
	pub imp: *front.ast.ImplDecl,
	/// Stores the `mod_path` field (mod path).
	pub mod_path: front.ast.ValList<[]u8>
}

/// Represents the `GenericTypeInst` data structure.
pub struct GenericTypeInst {
	/// Stores the `origin_sym` field (origin sym).
	pub origin_sym: *middle.symbol.Symbol,
	/// Stores the `args` field (args).
	pub args: front.ast.PtrList<middle.types.StType>,
	/// Stores the `ty` field (ty).
	pub ty: *mut middle.types.StType
}

/// Represents the `GenericFnInst` data structure.
pub struct GenericFnInst {
	/// Stores the `origin_fn` field (origin fn).
	pub origin_fn: *front.ast.FnDecl,
	/// Stores the `args` field (args).
	pub args: front.ast.PtrList<middle.types.StType>,
	/// Stores the `sym` field (sym).
	pub sym: *mut middle.symbol.Symbol,
	/// Stores the `mod_path` field (mod path).
	pub mod_path: front.ast.ValList<[]u8>,
	/// Stores the `self_ty` field (self ty).
	pub self_ty: *mut middle.types.StType,
	/// Stores the `extra_subst` field (extra subst).
	pub extra_subst: front.ast.ValList<middle.sema.generics.GenericSubstEntry>
}

/// Represents the `TraitImplEntry` data structure.
pub struct TraitImplEntry {
	/// Stores the `trait_name` field (trait name).
	pub trait_name: []u8,
	/// Stores the `target_ty` field (target ty).
	pub target_ty: *mut middle.types.StType
}

/// Represents the `ImplConstEntry` data structure.
pub struct ImplConstEntry {
	/// Stores the `target_ty` field (target ty).
	pub target_ty: *mut middle.types.StType,
	/// Stores the `name` field (name).
	pub name: []u8,
	/// Stores the `sym` field (sym).
	pub sym: *mut middle.symbol.Symbol
}

/// Represents the `SemaContext` data structure.
pub struct SemaContext {
	/// Stores the `tx` field (tx).
	pub tx: middle.types.TypeContext,
	/// Stores the `scopes` field (scopes).
	pub scopes: middle.symbol.ScopeStack,
	/// Stores the `current_ret_ty` field (current ret ty).
	pub current_ret_ty: *mut middle.types.StType,
	/// Stores the `current_yield_ty` field (current yield ty).
	pub current_yield_ty: *mut middle.types.StType,
	/// Stores the `current_self_ty` field (current self ty).
	pub current_self_ty: *mut middle.types.StType,
	/// Stores the `current_fn_must_tail` field (current fn must tail).
	pub current_fn_must_tail: bool,
	/// Stores the `current_fn_abi` field (current fn abi).
	pub current_fn_abi: middle.types.AbiKind,
	/// Stores the `in_imported_mod` field (in imported mod).
	pub in_imported_mod: bool,
	/// Stores the `current_mod_path` field (current mod path).
	pub current_mod_path: *front.ast.ValList<[]u8>,
	/// Stores the `generic_subst` field (generic subst).
	pub generic_subst: front.ast.ValList<middle.sema.generics.GenericSubstEntry>,
	/// Stores the `imported_syms` field (imported syms).
	pub imported_syms: front.ast.ValList<QualifiedSym>,
	/// Separate-chaining buckets for `imported_syms` by `sym.simple`.
	pub imp_name_buckets: *mut isize,
	/// Capacity of `imp_name_buckets` (power of 2).
	pub imp_name_bucket_cap: usize,
	/// Next index chain for `imp_name_buckets` (-1 = end).
	pub imp_name_next: front.ast.ValList<isize>,
	/// Separate-chaining buckets for `imported_syms` by `sym.fn_decl` pointer.
	pub imp_fn_buckets: *mut isize,
	/// Capacity of `imp_fn_buckets` (power of 2).
	pub imp_fn_bucket_cap: usize,
	/// Next index chain for `imp_fn_buckets` (-1 = end).
	pub imp_fn_next: front.ast.ValList<isize>,
	/// Stores the `impl_methods` field (impl methods).
	pub impl_methods: front.ast.ValList<ImplMethodEntry>,
	/// Stores the `impl_consts` field (impl consts).
	pub impl_consts: front.ast.ValList<ImplConstEntry>,
	/// Stores the `generic_impls` field (generic impls).
	pub generic_impls: front.ast.ValList<GenericImplEntry>,
	/// Stores the `trait_impls` field (trait impls).
	pub trait_impls: front.ast.ValList<TraitImplEntry>,
	/// Stores the `traits` field (traits).
	pub traits: front.ast.PtrList<front.ast.TraitDecl>,
	/// Stores the `foreign_traits` field (foreign traits).
	pub foreign_traits: front.ast.ValList<[]u8>,
	/// Stores the `mod_names` field (mod names).
	pub mod_names: front.ast.ValList<[]u8>,
	/// Stores the `generic_types` field (generic types).
	pub generic_types: front.ast.ValList<GenericTypeInst>,
	/// Stores the `generic_fns` field (generic fns).
	pub generic_fns: front.ast.ValList<GenericFnInst>,
	/// Stores the `embed_files` field (embed files).
	pub embed_files: front.ast.ValList<[]u8>
}

/// Executes `init_sema` (init sema).
pub fn init_sema(pointer_width: i32) -> SemaContext {
	let mut scopes: middle.symbol.ScopeStack = middle.symbol.init_scope_stack();
	scopes.enter();
	return {
		.tx = middle.types.init_type_context(pointer_width),
		.scopes = scopes,
		.current_ret_ty = null,
		.current_yield_ty = null,
		.current_self_ty = null,
		.current_fn_must_tail = false,
		.current_fn_abi = middle.types.AbiKind.Stella,
		.in_imported_mod = false,
		.current_mod_path = null,
		.generic_subst = { .data = null, .len = 0, .cap = 0 },
		.imported_syms = { .data = null, .len = 0, .cap = 0 },
		.imp_name_buckets = null,
		.imp_name_bucket_cap = 0,
		.imp_name_next = { .data = null, .len = 0, .cap = 0 },
		.imp_fn_buckets = null,
		.imp_fn_bucket_cap = 0,
		.imp_fn_next = { .data = null, .len = 0, .cap = 0 },
		.impl_methods = { .data = null, .len = 0, .cap = 0 },
		.impl_consts = { .data = null, .len = 0, .cap = 0 },
		.generic_impls = { .data = null, .len = 0, .cap = 0 },
		.trait_impls = { .data = null, .len = 0, .cap = 0 },
		.traits = { .data = null, .len = 0, .cap = 0 },
		.foreign_traits = { .data = null, .len = 0, .cap = 0 },
		.mod_names = { .data = null, .len = 0, .cap = 0 },
		.generic_types = { .data = null, .len = 0, .cap = 0 },
		.generic_fns = { .data = null, .len = 0, .cap = 0 },
		.embed_files = { .data = null, .len = 0, .cap = 0 }
	};
}

/// Executes `is_exact_float_lit`.
pub fn is_exact_float_lit(text: []u8) -> bool {
	let mut dot: usize = text.len;
	for let mut i: usize = 0; i < text.len; i += 1 {
		if text[i] == ('e' cast u8) || text[i] == ('E' cast u8) {
			return false;
		}
		if text[i] == ('.' cast u8) {
			dot = i;
		}
	}
	if dot >= text.len {
		return true;
	}
	let mut end: usize = text.len;
	for end > dot + 1 && text[end - 1] == ('0' cast u8) {
		end -= 1;
	}
	if end == dot + 1 {
		return true;
	}
	let flen: usize = end - (dot + 1);
	if flen > 15 {
		return false;
	}
	let mut num: u64 = 0;
	let mut den: u64 = 1;
	for let mut i: usize = dot + 1; i < end; i += 1 {
		let c: u8 = text[i];
		if c < '0' || c > '9' {
			continue;
		}
		num = num * 10 + ((c - '0') cast u64);
		den = den * 10;
	}
	// Reduce by gcd(num, den)
	let mut a: u64 = num;
	let mut b: u64 = den;
	for b != 0 {
		let t: u64 = a % b;
		a = b;
		b = t;
	}
	if a > 0 {
		den /= a;
	}
	// Exact in binary float iff reduced denominator is a power of 2
	return den > 0 && (den & (den - 1)) == 0;
}

/// Executes `unwrap_float_lit`.
pub fn unwrap_float_lit(e: *front.ast.Expr) -> *front.ast.Expr {
	if e == null {
		return null;
	}
	if e.kind == front.ast.ExprKind.FloatLit {
		return e;
	}
	if e.kind == front.ast.ExprKind.Unary && std.str.eq(e.unary_op, "-") && e.lhs != null
		&& e.lhs.kind == front.ast.ExprKind.FloatLit {
		return e.lhs;
	}
	return null;
}

/// Executes `extract_align_attr`.
pub fn extract_align_attr(attrs: *front.ast.AttributeList) -> u64 {
	if attrs == null {
		return 0;
	}
	for let mut i: usize = 0; i < attrs.attrs.len; i += 1 {
		let a: front.ast.Attribute = attrs.attrs.data[i];
		if !a.negated && std.str.eq(a.name, "align") && a.args.len > 0 {
			let s: []u8 = a.args.data[0];
			let mut val: u64 = 0;
			for let mut j: usize = 0; j < s.len; j += 1 {
				let c: u8 = s[j];
				if c >= '0' && c <= '9' {
					val = val * 10 + ((c - '0') cast u64);
				}
			}
			return val;
		}
	}
	return 0;
}

/// Executes `has_attr`.
pub fn has_attr(attrs: *front.ast.AttributeList, name: []u8) -> bool {
	if attrs == null {
		return false;
	}
	for let mut i: usize = 0; i < attrs.attrs.len; i += 1 {
		let a: front.ast.Attribute = attrs.attrs.data[i];
		if !a.negated && std.str.eq(a.name, name) {
			return true;
		}
	}
	return false;
}

/// Executes `extract_abi_attr` (extract abi attr).
pub fn extract_abi_attr(
	attrs: *front.ast.AttributeList,
	loc: front.log.SourceLoc,
	report_err: bool
) -> middle.types.AbiKind {
	if attrs == null {
		return middle.types.AbiKind.Stella;
	}
	for let mut i: usize = 0; i < attrs.attrs.len; i += 1 {
		let a: front.ast.Attribute = attrs.attrs.data[i];
		if !a.negated && std.str.eq(a.name, "abi") {
			if a.args.len == 1 && std.str.eq(a.args.data[0], "C") {
				return middle.types.AbiKind.C;
			}
			if a.args.len == 1 && std.str.eq(a.args.data[0], "Stella") {
				return middle.types.AbiKind.Stella;
			}
			if report_err {
				front.log.report(
					front.log.Level.Error,
					loc,
					"unsupported ABI in #[abi(...)] attribute",
					front.log.DiagCode.InvalidAttribute
				);
			}
			return middle.types.AbiKind.Stella;
		}
	}
	return middle.types.AbiKind.Stella;
}

/// Executes `extract_repr_attr`.
pub fn extract_repr_attr(
	attrs: *front.ast.AttributeList,
	loc: front.log.SourceLoc
) -> middle.types.ReprKind {
	if attrs == null {
		return middle.types.ReprKind.Stella;
	}
	for let mut i: usize = 0; i < attrs.attrs.len; i += 1 {
		let a: front.ast.Attribute = attrs.attrs.data[i];
		if !a.negated && std.str.eq(a.name, "repr") {
			if a.args.len == 1 && std.str.eq(a.args.data[0], "C") {
				return middle.types.ReprKind.C;
			}
			if a.args.len == 1 && std.str.eq(a.args.data[0], "Stella") {
				return middle.types.ReprKind.Stella;
			}
			front.log.report(
				front.log.Level.Error,
				loc,
				"unsupported representation in #[repr(...)] attribute",
				front.log.DiagCode.InvalidAttribute
			);
			return middle.types.ReprKind.Stella;
		}
	}
	return middle.types.ReprKind.Stella;
}

/// Executes `is_stella_repr_aggregate`.
pub fn is_stella_repr_aggregate(t: *mut middle.types.StType) -> bool {
	let u: *mut middle.types.StType = middle.types.underlying_type(t);
	if u == null {
		return false;
	}
	if u.kind == middle.types.TypeKind.Struct {
		return u.repr == middle.types.ReprKind.Stella && !u.is_opaque;
	}
	if u.kind == middle.types.TypeKind.Array {
		return is_stella_repr_aggregate(u.base);
	}
	return false;
}

/// Executes `finalize_struct_layout`.
pub fn finalize_struct_layout(
	st: *mut middle.types.StType,
	attrs: *front.ast.AttributeList,
	ptr_bytes: usize,
	loc: front.log.SourceLoc
) -> void {
	if st == null {
		return;
	}
	st.repr = extract_repr_attr(attrs, loc);
	if st.repr == middle.types.ReprKind.C {
		for let mut i: usize = 0; i < st.fields.len; i += 1 {
			if is_stella_repr_aggregate(st.fields.data[i]) {
				front.log.report(
					front.log.Level.Error,
					loc,
					"#[repr(\"C\")] struct cannot contain #[repr(\"Stella\")] field",
					front.log.DiagCode.InvalidAttribute
				);
			}
		}
	} else if st.repr == middle.types.ReprKind.Stella && !st.is_opaque && st.fields.len > 1 {
		// Stable insertion sort by descending field alignment
		for let mut i: usize = 1; i < st.fields.len; i += 1 {
			let f_ty: *mut middle.types.StType = st.fields.data[i];
			let f_name: []u8 = st.field_names.data[i];
			let f_pub: bool = st.field_is_pub.data[i];
			let f_al: usize = middle.types.type_align_bytes(f_ty, ptr_bytes);
			let mut j: usize = i;
			for j > 0 {
				let prev_al: usize = middle.types.type_align_bytes(
					st.fields.data[j - 1],
					ptr_bytes
				);
				if prev_al >= f_al {
					break;
				}
				st.fields.data[j] = st.fields.data[j - 1];
				st.field_names.data[j] = st.field_names.data[j - 1];
				st.field_is_pub.data[j] = st.field_is_pub.data[j - 1];
				j -= 1;
			}
			st.fields.data[j] = f_ty;
			st.field_names.data[j] = f_name;
			st.field_is_pub.data[j] = f_pub;
		}
	}
	check_layout_attr(attrs, st, ptr_bytes, loc);
}

/// Executes `parse_u64_str`.
pub fn parse_u64_str(s: []u8, out_v: *mut u64) -> bool {
	if s.len == 0 {
		return false;
	}
	let mut val: u64 = 0;
	for let mut j: usize = 0; j < s.len; j += 1 {
		let c: u8 = s[j];
		if c < '0' || c > '9' {
			return false;
		}
		val = val * 10 + ((c - '0') cast u64);
	}
	*out_v = val;
	return true;
}

/// Executes `put_str_buf`.
pub fn put_str_buf(buf: *mut u8, pos: *mut usize, cap: usize, s: []u8) -> void {
	for let mut i: usize = 0; i < s.len && *pos < cap; i += 1 {
		buf[*pos] = s.ptr[i];
		*pos += 1;
	}
}

/// Executes `put_u64_buf`.
pub fn put_u64_buf(buf: *mut u8, pos: *mut usize, cap: usize, mut v: u64) -> void {
	if v == 0 {
		if *pos < cap {
			buf[*pos] = '0' cast u8;
			*pos += 1;
		}return;
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

/// Executes `check_layout_attr`.
pub fn check_layout_attr(
	attrs: *front.ast.AttributeList,
	ty: *mut middle.types.StType,
	ptr_bytes: usize,
	loc: front.log.SourceLoc
) -> void {
	if attrs == null || ty == null {
		return;
	}
	for let mut i: usize = 0; i < attrs.attrs.len; i += 1 {
		let a: front.ast.Attribute = attrs.attrs.data[i];
		if !a.negated && std.str.eq(a.name, "layout") {
			let mut exp_sz: u64 = 0;
			let mut exp_al: u64 = 0;
			if a.args.len != 2 || !parse_u64_str(a.args.data[0], &exp_sz)
				|| !parse_u64_str(a.args.data[1], &exp_al) {
				front.log.report(
					front.log.Level.Error,
					a.loc,
					"#[layout] expects exactly two integer arguments: size and alignment",
					front.log.DiagCode.LayoutMismatch
				);
				continue;
			}
			let act_sz: u64 = middle.types.type_size_bytes(ty, ptr_bytes) cast u64;
			let act_al: u64 = middle.types.type_align_bytes(ty, ptr_bytes) cast u64;
			if act_sz != exp_sz || act_al != exp_al {
				let mut mb: [256]u8;
				let mut mp: usize = 0;
				put_str_buf(&mb[0], &mp, 256, "layout mismatch: ");
				if act_sz != exp_sz {
					put_str_buf(&mb[0], &mp, 256, "expected size ");
					put_u64_buf(&mb[0], &mp, 256, exp_sz);
					put_str_buf(&mb[0], &mp, 256, ", target ABI size is ");
					put_u64_buf(&mb[0], &mp, 256, act_sz);
					if act_al != exp_al {
						put_str_buf(&mb[0], &mp, 256, "; ");
					}
				}
				if act_al != exp_al {
					put_str_buf(&mb[0], &mp, 256, "expected alignment ");
					put_u64_buf(&mb[0], &mp, 256, exp_al);
					put_str_buf(&mb[0], &mp, 256, ", target ABI alignment is ");
					put_u64_buf(&mb[0], &mp, 256, act_al);
				}
				front.log.report(
					front.log.Level.Error,
					loc,
					mb[0..mp],
					front.log.DiagCode.LayoutMismatch
				);
			}
		}
	}
}

/// Executes `is_numeric_compatible`.
pub fn is_numeric_compatible(expected: *mut middle.types.StType, is_float_lit: bool) -> bool {
	if expected == null {
		return false;
	}
	let u: *mut middle.types.StType = middle.types.underlying_type(expected);
	if u == null {
		return false;
	}
	if is_float_lit {
		return u.kind == middle.types.TypeKind.Float;
	}
	return u.kind == middle.types.TypeKind.UInt || u.kind == middle.types.TypeKind.SInt;
}

/// Executes `extract_member_chain`.
pub fn extract_member_chain(e: *front.ast.Expr, out: *mut front.ast.ValList<[]u8>) -> bool {
	if e == null {
		return false;
	}
	if e.kind == front.ast.ExprKind.Ident && e.path.len > 0 {
		for let mut i: usize = 0; i < e.path.len; i += 1 {
			out.push(e.path.data[i]);
		}
		return true;
	}
	if e.kind == front.ast.ExprKind.Member {
		if extract_member_chain(e.lhs, out) {
			out.push(e.member);
			return true;
		}
	}
	return false;
}

/// Executes `is_assignable_lvalue`.
pub fn is_assignable_lvalue(ctx: *mut SemaContext, e: *front.ast.Expr) -> bool {
	if e == null {
		return false;
	}
	match e.kind {
		.Ident => {
			if e.path.len == 1 {
				let sym: *middle.symbol.Symbol = ctx.scopes.lookup(e.path.data[0]);
				if sym != null {
					return sym.is_mutable;
				}
			}
			return true;
		}
		.Deref => {
			let lt: *mut middle.types.StType = ctx.check_expr(e.lhs, null);
			let u: *mut middle.types.StType = middle.types.underlying_type(lt);
			return u != null && u.kind == middle.types.TypeKind.Pointer && u.is_mutable;
		}
		.Index => {
			let lt: *mut middle.types.StType = ctx.check_expr(e.lhs, null);
			let u: *mut middle.types.StType = middle.types.underlying_type(lt);
			if u != null
				&& (u.kind == middle.types.TypeKind.Pointer || u.kind
				== middle.types.TypeKind.Slice) {
				return u.is_mutable;
			}
			return is_assignable_lvalue(ctx, e.lhs);
		}
		.Member => {
			let lt: *mut middle.types.StType = ctx.check_expr(e.lhs, null);
			let u: *mut middle.types.StType = middle.types.underlying_type(lt);
			if u != null && u.kind == middle.types.TypeKind.Pointer {
				return u.is_mutable;
			}
			return is_assignable_lvalue(ctx, e.lhs);
		}
		_ => return false
	}
}
