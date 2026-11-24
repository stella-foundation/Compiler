mod front.ast;
import "front/log.sl";
import "front/token.sl";
import "std/io.sl";
import "std/mem.sl";


pub struct Attribute {
	/// Stores the `name` field (name).
	pub name: []u8,
	/// Stores the `negated` field (negated).
	pub negated: bool,
	/// Stores the `args` field (args).
	pub args: ValList<[]u8>,
	/// Stores the `arg_is_string` field (arg is string).
	pub arg_is_string: ValList<bool>,
	/// Stores the `loc` field (loc).
	pub loc: front.log.SourceLoc
}

/// Represents the `AttributeList` data structure.
pub struct AttributeList {
	/// Stores the `attrs` field (attrs).
	pub attrs: ValList<Attribute>,
	/// Stores the `loc` field (loc).
	pub loc: front.log.SourceLoc
}

/// Executes `make_attr_list` (make attr list).
pub fn make_attr_list() -> AttributeList {
	return {
		.attrs = { .data = null, .len = 0, .cap = 0 },
		.loc = front.log.empty_loc()
	};
}

// Generic arguments and parameters

/// Enumerates `GenericArgKind` variants.
pub enum GenericArgKind: u8 {
	Type,
	Value
}

/// Represents the `GenericArg` data structure.
pub struct GenericArg {
	/// Stores the `kind` field (kind).
	pub kind: GenericArgKind,
	/// Stores the `ty` field (ty).
	pub ty: *mut TypeRef,
	/// Stores the `value` field (value).
	pub value: *mut Expr,
	/// Stores the `loc` field (loc).
	pub loc: front.log.SourceLoc
}

/// Enumerates `TypeSetMemberKind` variants.
pub enum TypeSetMemberKind: u8 {
	Exact,
	Sint,
	Uint,
	Float
}

/// Represents the `TypeSetMember` data structure.
pub struct TypeSetMember {
	/// Stores the `kind` field (kind).
	pub kind: TypeSetMemberKind,
	/// Stores the `name` field (name).
	pub name: []u8,
	/// Stores the `loc` field (loc).
	pub loc: front.log.SourceLoc
}

/// Enumerates `GenericParamKind` variants.
pub enum GenericParamKind: u8 {
	Type,
	Const
}

/// Represents the `GenericParam` data structure.
pub struct GenericParam {
	/// Stores the `kind` field (kind).
	pub kind: GenericParamKind,
	/// Stores the `name` field (name).
	pub name: []u8,
	/// Stores the `const_type` field (const type).
	pub const_type: *mut TypeRef,
	/// Stores the `type_set` field (type set).
	pub type_set: ValList<TypeSetMember>,
	/// Stores the `trait_bounds` field (trait bounds).
	pub trait_bounds: PtrList<TypeRef>,
	/// Stores the `loc` field (loc).
	pub loc: front.log.SourceLoc
}

// Type references

/// Enumerates `TypeRefKind` variants.
pub enum TypeRefKind: u8 {
	Named,
	Pointer,
	Array,
	Slice,
	Function,
	TypeOf,
	SelfType
}

/// Represents the `TypeRef` data structure.
pub struct TypeRef {
	/// Stores the `kind` field (kind).
	pub kind: TypeRefKind,
	/// Stores the `name` field (name).
	pub name: []u8,
	/// Stores the `single` field (single).
	pub single: []u8,
	/// Stores the `path` field (path).
	pub path: ValList<[]u8>,
	/// Stores the `base` field (base).
	pub base: *mut TypeRef,
	/// Stores the `array_len` field (array len).
	pub array_len: usize,
	/// Stores the `array_len_expr` field (array len expr).
	pub array_len_expr: *mut Expr,
	/// Stores the `array_len_inferred` field (array len inferred).
	pub array_len_inferred: bool,
	/// Stores the `is_mutable` field (is mutable).
	pub is_mutable: bool,
	/// Stores the `is_volatile` field (is volatile).
	pub is_volatile: bool,
	/// Stores the `fn_params` field (fn params).
	pub fn_params: PtrList<TypeRef>,
	/// Stores the `fn_ret` field (fn ret).
	pub fn_ret: *mut TypeRef,
	/// Stores the `fn_variadic` field (fn variadic).
	pub fn_variadic: bool,
	/// Stores the `fn_attrs` field (fn attrs).
	pub fn_attrs: AttributeList,
	/// Stores the `generic_args` field (generic args).
	pub generic_args: ValList<GenericArg>,
	/// Stores the `typeof_expr` field (typeof expr).
	pub typeof_expr: *mut Expr,
	/// Stores the `loc` field (loc).
	pub loc: front.log.SourceLoc
}

/// Executes `alloc_typeref` (alloc typeref).
pub fn alloc_typeref(kind: TypeRefKind, loc: front.log.SourceLoc) -> *mut TypeRef {
	let raw: *mut u8 = arena_alloc(@of.size(TypeRef));
	if raw == null {
		return null;
	}
	let t: *mut TypeRef = raw cast *mut TypeRef;
	*t = {
		.kind = kind,
		.name = "",
		.single = "",
		.path = { .data = null, .len = 0, .cap = 0 },
		.base = null,
		.array_len = 0,
		.array_len_expr = null,
		.array_len_inferred = false,
		.is_mutable = false,
		.is_volatile = false,
		.fn_params = { .data = null, .len = 0, .cap = 0 },
		.fn_ret = null,
		.fn_variadic = false,
		.fn_attrs = make_attr_list(),
		.generic_args = { .data = null, .len = 0, .cap = 0 },
		.typeof_expr = null,
		.loc = loc
	};
	return t;
}

// Expressions

/// Enumerates `ExprKind` variants.
