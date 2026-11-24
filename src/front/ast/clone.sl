mod front.ast;
import "front/log.sl";
import "front/token.sl";
import "std/io.sl";
import "std/mem.sl";

pub fn clone_generic_arg(a: GenericArg) -> GenericArg {
	let mut out: GenericArg = {
		.kind = a.kind,
		.ty = null,
		.value = null,
		.loc = a.loc
	};
	if a.ty != null {
		out.ty = clone_typeref(a.ty);
	}
	if a.value != null {
		out.value = clone_expr(a.value);
	}
	return out;
}

/// Executes `clone_typeref` (clone typeref).
pub fn clone_typeref(t: *TypeRef) -> *mut TypeRef {
	if t == null {
		return null;
	}
	let c: *mut TypeRef = alloc_typeref(t.kind, t.loc);
	if c == null {
		return null;
	}
	c.name = t.name;
	c.single = t.single;
	for let mut i: usize = 0; i < t.path.len; i += 1 {
		c.path.push(t.path.data[i]);
	}
	c.base = clone_typeref(t.base);
	c.array_len = t.array_len;
	c.array_len_expr = clone_expr(t.array_len_expr);
	c.array_len_inferred = t.array_len_inferred;
	c.is_mutable = t.is_mutable;
	c.is_volatile = t.is_volatile;
	for let mut i: usize = 0; i < t.fn_params.len; i += 1 {
		c.fn_params.push(clone_typeref(t.fn_params.data[i]));
	}
	c.fn_ret = clone_typeref(t.fn_ret);
	c.fn_variadic = t.fn_variadic;
	for let mut i: usize = 0; i < t.generic_args.len; i += 1 {
		c.generic_args.push(clone_generic_arg(t.generic_args.data[i]));
	}
	c.typeof_expr = clone_expr(t.typeof_expr);
	return c;
}

/// Executes `clone_expr` (clone expr).
pub fn clone_expr(e: *Expr) -> *mut Expr {
	if e == null {
		return null;
	}
	let c: *mut Expr = alloc_expr(e.kind, e.loc);
	if c == null {
		return null;
	}
	c.parenthesized = e.parenthesized;
	c.int_val = e.int_val;
	c.flt_val = e.flt_val;
	c.str_val = e.str_val;
	c.is_cstring = e.is_cstring;
	c.char_val = e.char_val;
	c.op = e.op;
	c.op_variant = e.op_variant;
	c.unary_op = e.unary_op;
	for let mut i: usize = 0; i < e.path.len; i += 1 {
		c.path.push(e.path.data[i]);
	}
	c.member = e.member;
	c.lhs = clone_expr(e.lhs);
	c.rhs = clone_expr(e.rhs);
	c.index_low = clone_expr(e.index_low);
	c.is_bit_range = e.is_bit_range;
	c.condition = clone_expr(e.condition);
	c.then_expr = clone_expr(e.then_expr);
	c.else_expr = clone_expr(e.else_expr);
	for let mut i: usize = 0; i < e.args.len; i += 1 {
		c.args.push(clone_expr(e.args.data[i]));
	}
	for let mut i: usize = 0; i < e.field_names.len; i += 1 {
		c.field_names.push(e.field_names.data[i]);
	}
	for let mut i: usize = 0; i < e.generic_args.len; i += 1 {
		c.generic_args.push(clone_generic_arg(e.generic_args.data[i]));
	}
	c.cast_type = clone_typeref(e.cast_type);
	c.layout_type = clone_typeref(e.layout_type);
	c.is_bitcast = e.is_bitcast;
	c.is_compound_assignment = e.is_compound_assignment;
	c.is_struct_variant = e.is_struct_variant;
	c.offsetof_member = e.offsetof_member;
	c.va_arg_ty = clone_typeref(e.va_arg_ty);
	return c;
}
