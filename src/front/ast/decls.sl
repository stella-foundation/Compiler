mod front.ast;
import "front/log.sl";
import "front/token.sl";
import "std/io.sl";
import "std/mem.sl";

pub struct Param {
	/// Stores the `name` field (name).
	pub name: []u8,
	/// Stores the `ty` field (ty).
	pub ty: *mut TypeRef,
	/// Stores the `loc` field (loc).
	pub loc: front.log.SourceLoc,
	/// Stores the `attrs` field (attrs).
	pub attrs: AttributeList,
	/// Stores the `is_comptime` field (is comptime).
	pub is_comptime: bool,
	/// Stores the `is_mutable` field (is mutable).
	pub is_mutable: bool
}

/// Enumerates `TopKind` variants.
pub enum TopKind: u8 {
	Error,
	Mod,
	Fn,
	Struct,
	Union,
	TypeBinding,
	Var,
	Const,
	Import,
	Enum,
	Conditional,
	Trait,
	Impl
}

/// Represents the `ModDecl` data structure.
pub struct ModDecl {
	/// Stores the `name` field (name).
	pub name: []u8,
	/// Stores the `body` field (body).
	pub body: PtrList<TopDecl>,
	/// Stores the `is_pub` field (is pub).
	pub is_pub: bool,
	/// Stores the `loc` field (loc).
	pub loc: front.log.SourceLoc,
	/// Stores the `attrs` field (attrs).
	pub attrs: AttributeList
}

/// Represents the `FnDecl` data structure.
pub struct FnDecl {
	/// Stores the `is_macro` field (is macro).
	pub is_macro: bool,
	/// Stores the `name` field (name).
	pub name: []u8,
	/// Stores the `params` field (params).
	pub params: ValList<Param>,
	/// Stores the `ret` field (ret).
	pub ret: *mut TypeRef,
	/// Stores the `body` field (body).
	pub body: *mut Stmt,
	/// Stores the `is_pub` field (is pub).
	pub is_pub: bool,
	/// Stores the `is_variadic` field (is variadic).
	pub is_variadic: bool,
	/// Stores the `is_extern` field (is extern).
	pub is_extern: bool,
	/// Stores the `loc` field (loc).
	pub loc: front.log.SourceLoc,
	/// Stores the `attrs` field (attrs).
	pub attrs: AttributeList,
	/// Stores the `generic_params` field (generic params).
	pub generic_params: ValList<GenericParam>
}

/// Represents the `StructDecl` data structure.
pub struct StructDecl {
	/// Stores the `name` field (name).
	pub name: []u8,
	/// Stores the `field_names` field (field names).
	pub field_names: ValList<[]u8>,
	/// Stores the `field_types` field (field types).
	pub field_types: PtrList<TypeRef>,
	/// Stores the `field_is_pub` field (field is pub).
	pub field_is_pub: ValList<bool>,
	/// Stores the `is_pub` field (is pub).
	pub is_pub: bool,
	/// Stores the `is_opaque` field (is opaque).
	pub is_opaque: bool,
	/// Stores the `loc` field (loc).
	pub loc: front.log.SourceLoc,
	/// Stores the `attrs` field (attrs).
	pub attrs: AttributeList,
	/// Stores the `generic_params` field (generic params).
	pub generic_params: ValList<GenericParam>
}

/// Represents the `UnionDecl` data structure.
pub struct UnionDecl {
	/// Stores the `name` field (name).
	pub name: []u8,
	/// Stores the `field_names` field (field names).
	pub field_names: ValList<[]u8>,
	/// Stores the `field_types` field (field types).
	pub field_types: PtrList<TypeRef>,
	/// Stores the `field_is_pub` field (field is pub).
	pub field_is_pub: ValList<bool>,
	/// Stores the `is_pub` field (is pub).
	pub is_pub: bool,
	/// Stores the `loc` field (loc).
	pub loc: front.log.SourceLoc,
	/// Stores the `attrs` field (attrs).
	pub attrs: AttributeList,
	/// Stores the `generic_params` field (generic params).
	pub generic_params: ValList<GenericParam>
}

/// Represents the `TypeBindingDecl` data structure.
pub struct TypeBindingDecl {
	/// Stores the `name` field (name).
	pub name: []u8,
	/// Stores the `target` field (target).
	pub target: *mut TypeRef,
	/// Stores the `is_pub` field (is pub).
	pub is_pub: bool,
	/// Stores the `loc` field (loc).
	pub loc: front.log.SourceLoc,
	/// Stores the `attrs` field (attrs).
	pub attrs: AttributeList,
	/// Stores the `generic_params` field (generic params).
	pub generic_params: ValList<GenericParam>
}

/// Represents the `GlobalDecl` data structure.
pub struct GlobalDecl {
	/// Stores the `name` field (name).
	pub name: []u8,
	/// Stores the `ty` field (ty).
	pub ty: *mut TypeRef,
	/// Stores the `init` field (init).
	pub init: *mut Expr,
	/// Stores the `is_const` field (is const).
	pub is_const: bool,
	/// Stores the `is_mutable` field (is mutable).
	pub is_mutable: bool,
	/// Stores the `is_static` field (is static).
	pub is_static: bool,
	/// Stores the `is_thread_local` field (is thread local).
	pub is_thread_local: bool,
	/// Stores the `is_pub` field (is pub).
	pub is_pub: bool,
	/// Stores the `is_extern` field (is extern).
	pub is_extern: bool,
	/// Stores the `loc` field (loc).
	pub loc: front.log.SourceLoc,
	/// Stores the `attrs` field (attrs).
	pub attrs: AttributeList
}

/// Represents the `ImportDecl` data structure.
pub struct ImportDecl {
	/// Stores the `written_path` field (written path).
	pub written_path: []u8,
	/// Stores the `path` field (path).
	pub path: ValList<[]u8>,
	/// Stores the `is_pub` field (is pub).
	pub is_pub: bool,
	/// Stores the `loc` field (loc).
	pub loc: front.log.SourceLoc,
	/// Stores the `attrs` field (attrs).
	pub attrs: AttributeList
}

/// Enumerates `EnumPayloadKind` variants.
pub enum EnumPayloadKind: u8 {
	Unit,
	Tuple,
	Struct
}

/// Represents the `EnumVariantField` data structure.
pub struct EnumVariantField {
	/// Stores the `name` field (name).
	pub name: []u8,
	/// Stores the `ty` field (ty).
	pub ty: *mut TypeRef,
	/// Stores the `loc` field (loc).
	pub loc: front.log.SourceLoc
}

/// Represents the `EnumMember` data structure.
pub struct EnumMember {
	/// Stores the `name` field (name).
	pub name: []u8,
	/// Stores the `payload_kind` field (payload kind).
	pub payload_kind: EnumPayloadKind,
	/// Stores the `payload_fields` field (payload fields).
	pub payload_fields: ValList<EnumVariantField>,
	/// Stores the `value` field (value).
	pub value: *mut Expr,
	/// Stores the `loc` field (loc).
	pub loc: front.log.SourceLoc
}

/// Represents the `EnumDecl` data structure.
pub struct EnumDecl {
	/// Stores the `name` field (name).
	pub name: []u8,
	/// Stores the `members` field (members).
	pub members: ValList<EnumMember>,
	/// Stores the `is_pub` field (is pub).
	pub is_pub: bool,
	/// Stores the `loc` field (loc).
	pub loc: front.log.SourceLoc,
	/// Stores the `attrs` field (attrs).
	pub attrs: AttributeList,
	/// Stores the `backing` field (backing).
	pub backing: *mut TypeRef,
	/// Stores the `generic_params` field (generic params).
	pub generic_params: ValList<GenericParam>
}

/// Represents the `ConditionalArm` data structure.
pub struct ConditionalArm {
	/// Stores the `cond` field (cond).
	pub cond: *mut Expr,
	/// Stores the `body` field (body).
	pub body: PtrList<TopDecl>,
	/// Stores the `loc` field (loc).
	pub loc: front.log.SourceLoc
}

/// Represents the `ConditionalDecl` data structure.
pub struct ConditionalDecl {
	/// Stores the `arms` field (arms).
	pub arms: ValList<ConditionalArm>,
	/// Stores the `loc` field (loc).
	pub loc: front.log.SourceLoc
}

/// Represents the `TraitDecl` data structure.
pub struct TraitDecl {
	/// Stores the `name` field (name).
	pub name: []u8,
	/// Stores the `is_pub` field (is pub).
	pub is_pub: bool,
	/// Stores the `loc` field (loc).
	pub loc: front.log.SourceLoc,
	/// Stores the `attrs` field (attrs).
	pub attrs: AttributeList,
	/// Stores the `methods` field (methods).
	pub methods: PtrList<FnDecl>
}

/// Represents the `ImplDecl` data structure.
pub struct ImplDecl {
	/// Stores the `is_inherent` field (is inherent).
	pub is_inherent: bool,
	/// Stores the `trait_name` field (trait name).
	pub trait_name: []u8,
	/// Stores the `trait_path` field (trait path).
	pub trait_path: ValList<[]u8>,
	/// Stores the `generic_params` field (generic params).
	pub generic_params: ValList<GenericParam>,
	/// Stores the `target_type` field (target type).
	pub target_type: *mut TypeRef,
	/// Stores the `loc` field (loc).
	pub loc: front.log.SourceLoc,
	/// Stores the `attrs` field (attrs).
	pub attrs: AttributeList,
	/// Stores the `methods` field (methods).
	pub methods: PtrList<FnDecl>,
	/// Stores the `consts` field (consts).
	pub consts: PtrList<GlobalDecl>
}

/// Represents the `TopDecl` data structure.
pub struct TopDecl {
	/// Stores the `kind` field (kind).
	pub kind: TopKind,
	/// Stores the `mod_decl` field (mod decl).
	pub mod_decl: *mut ModDecl,
	/// Stores the `fn_decl` field (fn decl).
	pub fn_decl: *mut FnDecl,
	/// Stores the `st` field (st).
	pub st: *mut StructDecl,
	/// Stores the `un` field (un).
	pub un: *mut UnionDecl,
	/// Stores the `tb` field (tb).
	pub tb: *mut TypeBindingDecl,
	/// Stores the `glob` field (glob).
	pub glob: *mut GlobalDecl,
	/// Stores the `imp` field (imp).
	pub imp: *mut ImportDecl,
	/// Stores the `en` field (en).
	pub en: *mut EnumDecl,
	/// Stores the `conditional` field (conditional).
	pub conditional: *mut ConditionalDecl,
	/// Stores the `trait_decl` field (trait decl).
	pub trait_decl: *mut TraitDecl,
	/// Stores the `impl_decl` field (impl decl).
	pub impl_decl: *mut ImplDecl
}

/// Executes `alloc_top_decl` (alloc top decl).
pub fn alloc_top_decl(kind: TopKind) -> *mut TopDecl {
	let raw: *mut u8 = arena_alloc(@of.size(TopDecl));
	if raw == null {
		return null;
	}
	let d: *mut TopDecl = raw cast *mut TopDecl;
	*d = {
		.kind = kind,
		.mod_decl = null,
		.fn_decl = null,
		.st = null,
		.un = null,
		.tb = null,
		.glob = null,
		.imp = null,
		.en = null,
		.conditional = null,
		.trait_decl = null,
		.impl_decl = null
	};
	return d;
}

/// Represents the `Module` data structure.
pub struct Module {
	/// Stores the `fpath` field (fpath).
	pub fpath: []u8,
	/// Stores the `mod_path` field (mod path).
	pub mod_path: ValList<[]u8>,
	/// Stores the `file_attrs` field (file attrs).
	pub file_attrs: AttributeList,
	/// Stores the `mod_loc` field (mod loc).
	pub mod_loc: front.log.SourceLoc,
	/// Stores the `decls` field (decls).
	pub decls: PtrList<TopDecl>
}

/// Executes `init_module` (init module).
pub fn init_module(fpath: []u8) -> Module {
	return {
		.fpath = fpath,
		.mod_path = { .data = null, .len = 0, .cap = 0 },
		.file_attrs = make_attr_list(),
		.mod_loc = front.log.empty_loc(),
		.decls = { .data = null, .len = 0, .cap = 0 }
	};
}

// Cloning helpers (for compound assignment desugaring)

/// Executes `clone_generic_arg` (clone generic arg).
