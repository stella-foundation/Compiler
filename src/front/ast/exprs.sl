mod front.ast;
import "front/log.sl";
import "front/token.sl";
import "std/io.sl";
import "std/mem.sl";


pub enum ExprKind: u8 {
	IntLit,
	FloatLit,
	StringLit,
	CharLit,
	BoolLit,
	NullLit,
	Ident,
	EnumMember,
	VariantInit,
	DefineRef,
	Unary,
	Binary,
	Assign,
	Conditional,
	Call,
	Member,
	Index,
	Slice,
	TypeValue,
	StructLit,
	ArrayLit,
	Cast,
	AddrOf,
	Deref,
	Sizeof,
	Alignof,
	Bitsof,
	Offsetof,
	VaStart,
	VaCopy,
	VaEnd,
	VaArg,
	VariadicSplice,
	Block,
	SrcFile,
	SrcLine,
	SrcFn,
	SrcColumn,
	SrcEmbed,
	Stringify,
	DiagWarn,
	DiagErr
}

/// Represents the `Expr` data structure.
pub struct Expr {
	/// Stores the `kind` field (kind).
	pub kind: ExprKind,
	/// Stores the `loc` field (loc).
	pub loc: front.log.SourceLoc,
	/// Stores the `parenthesized` field (parenthesized).
	pub parenthesized: bool,
	/// Stores the `int_val` field (int val).
	pub int_val: u64,
	/// Stores the `flt_val` field (flt val).
	pub flt_val: f64,
	/// Stores the `flt_lossy_ok` field (flt lossy ok).
	pub flt_lossy_ok: bool,
	/// Stores the `str_val` field (str val).
	pub str_val: []u8,
	/// Stores the `is_cstring` field (is cstring).
	pub is_cstring: bool,
	/// Stores the `char_val` field (char val).
	pub char_val: u32,
	/// Stores the `op` field (op).
	pub op: front.token.Op,
	/// Stores the `op_variant` field (op variant).
	pub op_variant: front.token.OpVariant,
	/// Stores the `unary_op` field (unary op).
	pub unary_op: []u8,
	/// Stores the `path` field (path).
	pub path: ValList<[]u8>,
	/// Stores the `member` field (member).
	pub member: []u8,
	/// Stores the `lhs` field (lhs).
	pub lhs: *mut Expr,
	/// Stores the `rhs` field (rhs).
	pub rhs: *mut Expr,
	/// Stores the `index_low` field (index low).
	pub index_low: *mut Expr,
	/// Stores the `is_bit_range` field (is bit range).
	pub is_bit_range: bool,
	/// Stores the `condition` field (condition).
	pub condition: *mut Expr,
	/// Stores the `then_expr` field (then expr).
	pub then_expr: *mut Expr,
	/// Stores the `else_expr` field (else expr).
	pub else_expr: *mut Expr,
	/// Stores the `args` field (args).
	pub args: PtrList<Expr>,
	/// Stores the `field_names` field (field names).
	pub field_names: ValList<[]u8>,
	/// Stores the `generic_args` field (generic args).
	pub generic_args: ValList<GenericArg>,
	/// Stores the `cast_type` field (cast type).
	pub cast_type: *mut TypeRef,
	/// Stores the `layout_type` field (layout type).
	pub layout_type: *mut TypeRef,
	/// Stores the `is_bitcast` field (is bitcast).
	pub is_bitcast: bool,
	/// Stores the `is_compound_assignment` field (is compound assignment).
	pub is_compound_assignment: bool,
	/// Stores the `is_struct_variant` field (is struct variant).
	pub is_struct_variant: bool,
	/// Stores the `offsetof_member` field (offsetof member).
	pub offsetof_member: []u8,
	/// Stores the `va_arg_ty` field (va arg ty).
	pub va_arg_ty: *mut TypeRef,
	/// Stores the `block` field (block).
	pub block: *mut Stmt,
	/// Stores the `sema_ty` field (sema ty).
	pub sema_ty: *void,
	/// Stores the `sema_sym` field (sema sym).
	pub sema_sym: *void,
	/// Stores the `is_method_call` field (is method call).
	pub is_method_call: bool
}

/// Executes `alloc_expr` (alloc expr).
pub fn alloc_expr(kind: ExprKind, loc: front.log.SourceLoc) -> *mut Expr {
	let raw: *mut u8 = arena_alloc(@of.size(Expr));
	if raw == null {
		return null;
	}
	let e: *mut Expr = raw cast *mut Expr;
	*e = {
		.kind = kind,
		.loc = loc,
		.parenthesized = false,
		.int_val = 0,
		.flt_val = 0.0,
		.flt_lossy_ok = false,
		.str_val = "",
		.is_cstring = false,
		.char_val = 0,
		.op = front.token.Op.Add,
		.op_variant = front.token.OpVariant.Normal,
		.unary_op = "",
		.path = { .data = null, .len = 0, .cap = 0 },
		.member = "",
		.lhs = null,
		.rhs = null,
		.index_low = null,
		.is_bit_range = false,
		.condition = null,
		.then_expr = null,
		.else_expr = null,
		.args = { .data = null, .len = 0, .cap = 0 },
		.field_names = { .data = null, .len = 0, .cap = 0 },
		.generic_args = { .data = null, .len = 0, .cap = 0 },
		.cast_type = null,
		.layout_type = null,
		.is_bitcast = false,
		.is_compound_assignment = false,
		.is_struct_variant = false,
		.offsetof_member = "",
		.va_arg_ty = null,
		.block = null,
		.sema_ty = null,
		.sema_sym = null,
		.is_method_call = false
	};
	return e;
}

// Statements

/// Enumerates `StmtKind` variants.
