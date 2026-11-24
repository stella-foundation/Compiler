mod middle.sema.generics;
import "front/ast.sl";
import "front/log.sl";
import "middle/types.sl";
import "std/str.sl";

/// Represents the `GenericSubstEntry` data structure.
pub struct GenericSubstEntry {
	/// Stores the `name` field (name).
	pub name: []u8,
	/// Stores the `is_const` field (is const).
	pub is_const: bool,
	/// Stores the `ty` field (ty).
	pub ty: *mut middle.types.StType,
	/// Stores the `const_val` field (const val).
	pub const_val: i64
}

/// Executes `matches_type_set_constraint` (matches type set constraint).
pub fn matches_type_set_constraint(
	gp: *front.ast.GenericParam,
	arg_ty: *mut middle.types.StType
) -> bool {
	if gp == null || arg_ty == null || gp.type_set.len == 0 {
		return true;
	}
	let u: *mut middle.types.StType = middle.types.underlying_type(arg_ty);
	if u == null || u.kind == middle.types.TypeKind.Poison {
		return true;
	}
	for let mut i: usize = 0; i < gp.type_set.len; i += 1 {
		let m: front.ast.TypeSetMember = gp.type_set.data[i];
		match m.kind {
			.Sint => { if u.kind == middle.types.TypeKind.SInt { return true; } }
			.Uint => { if u.kind == middle.types.TypeKind.UInt { return true; } }
			.Float => { if u.kind == middle.types.TypeKind.Float { return true; } }
			.Exact => { if std.str.eq(u.name, m.name) { return true; } }
		}
	}
	return false;
}

/// Executes `check_type_set_constraint` (check type set constraint).
pub fn check_type_set_constraint(
	gp: *front.ast.GenericParam,
	arg_ty: *mut middle.types.StType,
	loc: front.log.SourceLoc
) -> bool {
	if gp == null || arg_ty == null {
		return true;
	}
	if gp.type_set.len == 0 {
		return true;
	}
	let u: *mut middle.types.StType = middle.types.underlying_type(arg_ty);
	if u == null || u.kind == middle.types.TypeKind.Poison {
		return true;
	}
	for let mut i: usize = 0; i < gp.type_set.len; i += 1 {
		let m: front.ast.TypeSetMember = gp.type_set.data[i];
		match m.kind {
			.Sint => {
				if u.kind == middle.types.TypeKind.SInt {
					return true;
				}
			}
			.Uint => {
				if u.kind == middle.types.TypeKind.UInt {
					return true;
				}
			}
			.Float => {
				if u.kind == middle.types.TypeKind.Float {
					return true;
				}
			}
			.Exact => {
				if std.str.eq(u.name, m.name) {
					return true;
				}
			}
		}
	}
	front.log.report(
		front.log.Level.Error,
		loc,
		"type argument does not satisfy generic type-set constraint",
		front.log.DiagCode.GenericConstraint
	);
	return false;
}

/// Executes `lookup_generic_subst` (lookup generic subst).
pub fn lookup_generic_subst(
	subst: *front.ast.ValList<GenericSubstEntry>,
	name: []u8
) -> *mut middle.types.StType {
	if subst == null {
		return null;
	}
	let mut i: usize = subst.len;
	for i > 0 {
		i -= 1;
		if !subst.data[i].is_const && std.str.eq(subst.data[i].name, name) {
			return subst.data[i].ty;
		}
	}
	return null;
}
