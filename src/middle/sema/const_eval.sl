mod middle.sema.const_eval;
import "front/ast.sl";
import "front/log.sl";
import "middle/symbol.sl";
import "middle/types.sl";
import "std/str.sl";

/// Enumerates `ConstKind` variants.
pub enum ConstKind: u8 {
	Invalid,
	Int,
	Float,
	Bool
}

/// Represents the `ConstVal` data structure.
pub struct ConstVal {
	/// Stores the `kind` field (kind).
	pub kind: ConstKind,
	/// Stores the `int_val` field (int val).
	pub int_val: u64,
	/// Stores the `flt_val` field (flt val).
	pub flt_val: f64,
	/// Stores the `bool_val` field (bool val).
	pub bool_val: bool
}

/// Executes `invalid_const` (invalid const).
pub fn invalid_const() -> ConstVal {
	return { .kind = ConstKind.Invalid, .int_val = 0, .flt_val = 0.0, .bool_val = false };
}

/// Executes `eval_const_expr_depth` (eval const expr depth).
pub fn eval_const_expr_depth(
	e: *front.ast.Expr,
	scopes: *middle.symbol.ScopeStack,
	tx: *mut middle.types.TypeContext,
	depth: i32
) -> ConstVal {
	if e == null {
		return invalid_const();
	}
	if depth > 32 {
		front.log.report(
			front.log.Level.Error,
			e.loc,
			"circular dependency in constant definition",
			front.log.DiagCode.General
		);
		return invalid_const();
	}
	match e.kind {
		.IntLit => {
			return {
				.kind = ConstKind.Int,
				.int_val = e.int_val,
				.flt_val = 0.0,
				.bool_val = false
			};
		}
		.FloatLit => {
			return {
				.kind = ConstKind.Float,
				.int_val = 0,
				.flt_val = e.flt_val,
				.bool_val = false
			};
		}
		.BoolLit => {
			return {
				.kind = ConstKind.Bool,
				.int_val = 0,
				.flt_val = 0.0,
				.bool_val = e.int_val != 0
			};
		}
		.CharLit => {
			return {
				.kind = ConstKind.Int,
				.int_val = e.char_val cast u64,
				.flt_val = 0.0,
				.bool_val = false
			};
		}
		.Ident => {
			if e.path.len == 1 && scopes != null {
				let sym: *middle.symbol.Symbol = scopes.lookup(e.path.data[0]);
				if sym != null && sym.has_const_value {
					if sym.const_value_is_float {
						return {
							.kind = ConstKind.Float,
							.int_val = 0,
							.flt_val = sym.const_flt_val,
							.bool_val = false
						};
					}
					if sym.ty != null && sym.ty.kind == middle.types.TypeKind.Bool {
						return {
							.kind = ConstKind.Bool,
							.int_val = 0,
							.flt_val = 0.0,
							.bool_val = sym.const_bool_val
						};
					}
					return {
						.kind = ConstKind.Int,
						.int_val = sym.const_int_val,
						.flt_val = 0.0,
						.bool_val = false
					};
				}
				if sym != null && sym.kind == middle.symbol.SymKind.Const && sym.glob != null
					&& sym.glob.init != null {
					return eval_const_expr_depth(sym.glob.init, scopes, tx, depth + 1);
				}
			}
			return invalid_const();
		}
		.Member => {
			if e.lhs != null && e.lhs.kind == front.ast.ExprKind.Ident && e.lhs.path.len == 1
				&& scopes != null {
				let sym: *middle.symbol.Symbol = scopes.lookup(e.lhs.path.data[0]);
				if sym != null && sym.ty != null {
					let u: *mut middle.types.StType = middle.types.underlying_type(sym.ty);
					if u != null && u.kind == middle.types.TypeKind.Enum {
						let midx: isize = middle.types.field_index(u, e.member);
						if midx >= 0 && (midx cast usize) < u.enum_values.len {
							return {
								.kind = ConstKind.Int,
								.int_val = u.enum_values.data[midx cast usize],
								.flt_val = 0.0,
								.bool_val = false
							};
						}
					}
				}
			}
			return invalid_const();
		}
		.Unary => {
			let v: ConstVal = eval_const_expr_depth(e.lhs, scopes, tx, depth + 1);
			if v.kind == ConstKind.Invalid {
				return v;
			}
			if std.str.eq(e.unary_op, "-") {
				if v.kind == ConstKind.Int {
					let zero: u64 = 0;
					return {
						.kind = ConstKind.Int,
						.int_val = zero -% v.int_val,
						.flt_val = 0.0,
						.bool_val = false
					};
				}
				if v.kind == ConstKind.Float {
					return {
						.kind = ConstKind.Float,
						.int_val = 0,
						.flt_val = -v.flt_val,
						.bool_val = false
					};
				}
			} else if std.str.eq(e.unary_op, "!") && v.kind == ConstKind.Bool {
				return {
					.kind = ConstKind.Bool,
					.int_val = 0,
					.flt_val = 0.0,
					.bool_val = !v.bool_val
				};
			} else if std.str.eq(e.unary_op, "~") && v.kind == ConstKind.Int {
				return {
					.kind = ConstKind.Int,
					.int_val = ~v.int_val,
					.flt_val = 0.0,
					.bool_val = false
				};
			}
			return invalid_const();
		}
		.Binary => {
			let lv: ConstVal = eval_const_expr_depth(e.lhs, scopes, tx, depth + 1);
			let rv: ConstVal = eval_const_expr_depth(e.rhs, scopes, tx, depth + 1);
			if lv.kind == ConstKind.Invalid || rv.kind == ConstKind.Invalid {
				return invalid_const();
			}
			if lv.kind == ConstKind.Int && rv.kind == ConstKind.Int {
				let a: u64 = lv.int_val;
				let b: u64 = rv.int_val;
				match e.op {
					.Add => {
						return {
							.kind = ConstKind.Int,
							.int_val = a +% b,
							.flt_val = 0.0,
							.bool_val = false
						};
					}
					.Sub => {
						return {
							.kind = ConstKind.Int,
							.int_val = a -% b,
							.flt_val = 0.0,
							.bool_val = false
						};
					}
					.Mul => {
						return {
							.kind = ConstKind.Int,
							.int_val = a *% b,
							.flt_val = 0.0,
							.bool_val = false
						};
					}
					.Div => {
						if b == 0 {
							return invalid_const();
						}
						return {
							.kind = ConstKind.Int,
							.int_val = a / b,
							.flt_val = 0.0,
							.bool_val = false
						};
					}
					.Mod => {
						if b == 0 {
							return invalid_const();
						}
						return {
							.kind = ConstKind.Int,
							.int_val = a % b,
							.flt_val = 0.0,
							.bool_val = false
						};
					}
					.BitAnd => {
						return {
							.kind = ConstKind.Int,
							.int_val = a & b,
							.flt_val = 0.0,
							.bool_val = false
						};
					}
					.BitOr => {
						return {
							.kind = ConstKind.Int,
							.int_val = a | b,
							.flt_val = 0.0,
							.bool_val = false
						};
					}
					.BitXor => {
						return {
							.kind = ConstKind.Int,
							.int_val = a ^ b,
							.flt_val = 0.0,
							.bool_val = false
						};
					}
					.Shl => {
						if b >= 64 {
							return {
								.kind = ConstKind.Int,
								.int_val = 0,
								.flt_val = 0.0,
								.bool_val = false
							};
						}
						return {
							.kind = ConstKind.Int,
							.int_val = a << b,
							.flt_val = 0.0,
							.bool_val = false
						};
					}
					.Shr => {
						if b >= 64 {
							return {
								.kind = ConstKind.Int,
								.int_val = 0,
								.flt_val = 0.0,
								.bool_val = false
							};
						}
						return {
							.kind = ConstKind.Int,
							.int_val = a >> b,
							.flt_val = 0.0,
							.bool_val = false
						};
					}
					.Eq => {
						return {
							.kind = ConstKind.Bool,
							.int_val = 0,
							.flt_val = 0.0,
							.bool_val = a == b
						};
					}
					.Ne => {
						return {
							.kind = ConstKind.Bool,
							.int_val = 0,
							.flt_val = 0.0,
							.bool_val = a != b
						};
					}
					.Lt => {
						return {
							.kind = ConstKind.Bool,
							.int_val = 0,
							.flt_val = 0.0,
							.bool_val = a < b
						};
					}
					.Le => {
						return {
							.kind = ConstKind.Bool,
							.int_val = 0,
							.flt_val = 0.0,
							.bool_val = a <= b
						};
					}
					.Gt => {
						return {
							.kind = ConstKind.Bool,
							.int_val = 0,
							.flt_val = 0.0,
							.bool_val = a > b
						};
					}
					.Ge => {
						return {
							.kind = ConstKind.Bool,
							.int_val = 0,
							.flt_val = 0.0,
							.bool_val = a >= b
						};
					}
					_ => return invalid_const()
				}
			}
			if lv.kind == ConstKind.Bool && rv.kind == ConstKind.Bool {
				match e.op {
					.LogicalAnd => {
						return {
							.kind = ConstKind.Bool,
							.int_val = 0,
							.flt_val = 0.0,
							.bool_val = lv.bool_val && rv.bool_val
						};
					}
					.LogicalOr => {
						return {
							.kind = ConstKind.Bool,
							.int_val = 0,
							.flt_val = 0.0,
							.bool_val = lv.bool_val || rv.bool_val
						};
					}
					.Eq => {
						return {
							.kind = ConstKind.Bool,
							.int_val = 0,
							.flt_val = 0.0,
							.bool_val = lv.bool_val == rv.bool_val
						};
					}
					.Ne => {
						return {
							.kind = ConstKind.Bool,
							.int_val = 0,
							.flt_val = 0.0,
							.bool_val = lv.bool_val != rv.bool_val
						};
					}
					_ => return invalid_const()
				}
			}
			return invalid_const();
		}
		.Conditional => {
			let cv: ConstVal = eval_const_expr(e.condition, scopes, tx);
			if cv.kind != ConstKind.Bool {
				return invalid_const();
			}
			return eval_const_expr(cv.bool_val ? e.then_expr : e.else_expr, scopes, tx);
		}
		.Cast => {
			let v: ConstVal = eval_const_expr(e.lhs, scopes, tx);
			if v.kind == ConstKind.Invalid {
				return v;
			}
			return v;
		}
		_ => return invalid_const()
	}
}

/// Executes `eval_const_expr` (eval const expr).
pub fn eval_const_expr(
	e: *front.ast.Expr,
	scopes: *middle.symbol.ScopeStack,
	tx: *mut middle.types.TypeContext
) -> ConstVal {
	return eval_const_expr_depth(e, scopes, tx, 0);
}
