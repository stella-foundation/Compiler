mod front.ast;
import "front/log.sl";
import "front/token.sl";
import "std/io.sl";
import "std/mem.sl";

pub enum StmtKind: u8 {
	Block,
	ExprStmt,
	VarDecl,
	ConstDecl,
	If,
	For,
	Match,
	Return,
	Unreachable,
	Break,
	Continue,
	Defer,
	Yield,
	Asm,
	Import
}

/// Enumerates `MatchPatternKind` variants.
pub enum MatchPatternKind: u8 {
	Wildcard,
	Value,
	Variant
}

/// Represents the `MatchBinding` data structure.
pub struct MatchBinding {
	/// Stores the `name` field (name).
	pub name: []u8,
	/// Stores the `field_name` field (field name).
	pub field_name: []u8,
	/// Stores the `is_mut` field (is mut).
	pub is_mut: bool,
	/// Stores the `loc` field (loc).
	pub loc: front.log.SourceLoc
}

/// Represents the `MatchPattern` data structure.
pub struct MatchPattern {
	/// Stores the `kind` field (kind).
	pub kind: MatchPatternKind,
	/// Stores the `expr` field (expr).
	pub expr: *mut Expr,
	/// Stores the `bindings` field (bindings).
	pub bindings: ValList<MatchBinding>,
	/// Stores the `is_struct_pattern` field (is struct pattern).
	pub is_struct_pattern: bool,
	/// Stores the `loc` field (loc).
	pub loc: front.log.SourceLoc
}

/// Represents the `MatchArm` data structure.
pub struct MatchArm {
	/// Stores the `patterns` field (patterns).
	pub patterns: ValList<MatchPattern>,
	/// Stores the `body` field (body).
	pub body: *mut Stmt,
	/// Stores the `loc` field (loc).
	pub loc: front.log.SourceLoc
}

/// Represents the `VarDeclInfo` data structure.
pub struct VarDeclInfo {
	/// Stores the `name` field (name).
	pub name: []u8,
	/// Stores the `ty` field (ty).
	pub ty: *mut TypeRef,
	/// Stores the `init` field (init).
	pub init: *mut Expr,
	/// Stores the `loc` field (loc).
	pub loc: front.log.SourceLoc,
	/// Stores the `is_const` field (is const).
	pub is_const: bool,
	/// Stores the `is_mutable` field (is mutable).
	pub is_mutable: bool,
	/// Stores the `is_static` field (is static).
	pub is_static: bool,
	/// Stores the `is_thread_local` field (is thread local).
	pub is_thread_local: bool,
	/// Stores the `attrs` field (attrs).
	pub attrs: AttributeList
}

/// Represents the `AsmOperand` data structure.
pub struct AsmOperand {
	/// Stores the `constraint` field (constraint).
	pub constraint: []u8,
	/// Stores the `operand` field (operand).
	pub operand: *mut Expr,
	/// Stores the `is_clobber` field (is clobber).
	pub is_clobber: bool
}

/// Represents the `Stmt` data structure.
pub struct Stmt {
	/// Stores the `kind` field (kind).
	pub kind: StmtKind,
	/// Stores the `loc` field (loc).
	pub loc: front.log.SourceLoc,
	/// Stores the `body` field (body).
	pub body: PtrList<Stmt>,
	/// Stores the `expr` field (expr).
	pub expr: *mut Expr,
	/// Stores the `vars` field (vars).
	pub vars: ValList<VarDeclInfo>,
	/// Stores the `cond` field (cond).
	pub cond: *mut Expr,
	/// Stores the `then_block` field (then block).
	pub then_block: *mut Stmt,
	/// Stores the `else_block` field (else block).
	pub else_block: *mut Stmt,
	/// Stores the `for_init` field (for init).
	pub for_init: *mut Stmt,
	/// Stores the `for_cond` field (for cond).
	pub for_cond: *mut Expr,
	/// Stores the `for_step` field (for step).
	pub for_step: *mut Expr,
	/// Stores the `loop_body` field (loop body).
	pub loop_body: *mut Stmt,
	/// Stores the `scrutinee` field (scrutinee).
	pub scrutinee: *mut Expr,
	/// Stores the `arms` field (arms).
	pub arms: ValList<MatchArm>,
	/// Stores the `ret_val` field (ret val).
	pub ret_val: *mut Expr,
	/// Stores the `defer_body` field (defer body).
	pub defer_body: *mut Stmt,
	/// Stores the `asm_code` field (asm code).
	pub asm_code: []u8,
	/// Stores the `asm_outputs` field (asm outputs).
	pub asm_outputs: ValList<AsmOperand>,
	/// Stores the `asm_inputs` field (asm inputs).
	pub asm_inputs: ValList<AsmOperand>,
	/// Stores the `asm_clobbers` field (asm clobbers).
	pub asm_clobbers: ValList<[]u8>,
	/// Stores the `asm_volatile` field (asm volatile).
	pub asm_volatile: bool
}

/// Executes `alloc_stmt` (alloc stmt).
pub fn alloc_stmt(kind: StmtKind, loc: front.log.SourceLoc) -> *mut Stmt {
	let raw: *mut u8 = arena_alloc(@of.size(Stmt));
	if raw == null {
		return null;
	}
	let s: *mut Stmt = raw cast *mut Stmt;
	*s = {
		.kind = kind,
		.loc = loc,
		.body = { .data = null, .len = 0, .cap = 0 },
		.expr = null,
		.vars = { .data = null, .len = 0, .cap = 0 },
		.cond = null,
		.then_block = null,
		.else_block = null,
		.for_init = null,
		.for_cond = null,
		.for_step = null,
		.loop_body = null,
		.scrutinee = null,
		.arms = { .data = null, .len = 0, .cap = 0 },
		.ret_val = null,
		.defer_body = null,
		.asm_code = "",
		.asm_outputs = { .data = null, .len = 0, .cap = 0 },
		.asm_inputs = { .data = null, .len = 0, .cap = 0 },
		.asm_clobbers = { .data = null, .len = 0, .cap = 0 },
		.asm_volatile = false
	};
	return s;
}
