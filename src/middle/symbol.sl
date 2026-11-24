mod middle.symbol;
import "front/ast.sl";
import "front/log.sl";
import "middle/types.sl";
import "std/hash.sl";
import "std/mem.sl";
import "std/str.sl";

/// Enumerates `SymKind` variants.
pub enum SymKind: u8 {
	Mod,
	Var,
	Const,
	Fn,
	Struct,
	Union,
	TypeBinding,
	Param,
	Enum,
	Trait
}

/// Represents the `Symbol` data structure.
pub struct Symbol {
	/// Stores the `kind` field (kind).
	pub kind: SymKind,
	/// Stores the `simple` field (simple).
	pub simple: []u8,
	/// Stores the `mangled` field (mangled).
	pub mangled: []u8,
	/// Stores the `mod_path` field (mod path).
	pub mod_path: front.ast.ValList<[]u8>,
	/// Stores the `ty` field (ty).
	pub ty: *mut middle.types.StType,
	/// Stores the `mod_decl` field (mod decl).
	pub mod_decl: *front.ast.ModDecl,
	/// Stores the `fn_decl` field (fn decl).
	pub fn_decl: *front.ast.FnDecl,
	/// Stores the `st` field (st).
	pub st: *front.ast.StructDecl,
	/// Stores the `un` field (un).
	pub un: *front.ast.UnionDecl,
	/// Stores the `tb` field (tb).
	pub tb: *front.ast.TypeBindingDecl,
	/// Stores the `en` field (en).
	pub en: *front.ast.EnumDecl,
	/// Stores the `trait_decl` field (trait decl).
	pub trait_decl: *front.ast.TraitDecl,
	/// Stores the `glob` field (glob).
	pub glob: *front.ast.GlobalDecl,
	/// Stores the `is_pub` field (is pub).
	pub is_pub: bool,
	/// Stores the `is_imported` field (is imported).
	pub is_imported: bool,
	/// Stores the `is_mutable` field (is mutable).
	pub is_mutable: bool,
	/// Stores the `used` field (used).
	pub used: bool,
	/// Stores the `loc` field (loc).
	pub loc: front.log.SourceLoc,
	/// Stores the `has_const_value` field (has const value).
	pub has_const_value: bool,
	/// Stores the `const_value_is_float` field (const value is float).
	pub const_value_is_float: bool,
	/// Stores the `const_bool_val` field (const bool val).
	pub const_bool_val: bool,
	/// Stores the `const_int_val` field (const int val).
	pub const_int_val: u64,
	/// Stores the `const_flt_val` field (const flt val).
	pub const_flt_val: f64,
	/// Stores the `comptime_str_val` field (comptime str val).
	pub comptime_str_val: []u8,
	/// Stores the `comptime_type_value` field (comptime type value).
	pub comptime_type_value: *mut middle.types.StType
}

/// Executes `mangle_symbol_name` (mangle symbol name).
pub fn mangle_symbol_name(
	mod_path: *front.ast.ValList<[]u8>,
	name: []u8,
	attrs: *front.ast.AttributeList
) -> []u8 {
	if attrs != null {
		for let mut i: usize = 0; i < attrs.attrs.len; i += 1 {
			let a: front.ast.Attribute = attrs.attrs.data[i];
			if !a.negated && std.str.eq(a.name, "link_name") {
				if a.args.len > 0 {
					return a.args.data[0];
				}
				return name;
			}
		}
	}
	if mod_path == null || mod_path.len == 0 {
		return name;
	}
	let mut total: usize = 3 + name.len;
	for let mut i: usize = 0; i < mod_path.len; i += 1 {
		total += mod_path.data[i].len + 1;
	}
	let buf: *mut u8 = front.ast.arena_alloc(total);
	if buf == null {
		return name;
	}
	buf[0] = 's' cast u8;
	buf[1] = 't' cast u8;
	buf[2] = '$' cast u8;
	let mut pos: usize = 3;
	for let mut i: usize = 0; i < mod_path.len; i += 1 {
		let seg: []u8 = mod_path.data[i];
		if seg.len > 0 {
			std.mem.copy(&buf[pos], seg.ptr, seg.len);
			pos += seg.len;
		}
		buf[pos] = '.' cast u8;
		pos += 1;
	}
	if name.len > 0 {
		std.mem.copy(&buf[pos], name.ptr, name.len);
	}
	return buf[0..total];
}

/// Executes `mangle_private_global_name` (mangle private global name).
pub fn mangle_private_global_name(base: []u8, file_path: []u8) -> []u8 {
	// Extract basename so symbol identity is invariant to directory relocation
	let mut start: usize = 0;
	for let mut i: usize = 0; i < file_path.len; i += 1 {
		if file_path[i] == ('/' cast u8) || file_path[i] == ('\\' cast u8) {
			start = i + 1;
		}
	}
	let h: u32 = std.hash.fnv1a_32(file_path[start..file_path.len]);
	let total: usize = base.len + 6 + 8;
	let buf: *mut u8 = front.ast.arena_alloc(total);
	if buf == null {
		return base;
	}
	if base.len > 0 {
		std.mem.copy(buf, base.ptr, base.len);
	}
	let mut pos: usize = base.len;
	buf[pos] = '#' cast u8;
	pos += 1;
	buf[pos] = 'p' cast u8;
	pos += 1;
	buf[pos] = 'r' cast u8;
	pos += 1;
	buf[pos] = 'i' cast u8;
	pos += 1;
	buf[pos] = 'v' cast u8;
	pos += 1;
	buf[pos] = ':' cast u8;
	pos += 1;
	for let mut d: u32 = 0; d < 8; d += 1 {
		let nib: u8 = ((h >> ((7 - d) * 4)) & 0xF) cast u8;
		buf[pos] = nib < 10 ? (('0' cast u8) + nib) : (('a' cast u8) + (nib - 10));
		pos += 1;
	}
	return buf[0..total];
}

fn mbuf_push(b: *mut *mut u8, l: *mut usize, c: *mut usize, s: []u8) -> void {
	if s.len == 0 {
		return;
	}
	for *l + s.len > *c {
		let nc: usize = *c == 0 ? 64 : *c * 2;
		let nb: *mut u8 = front.ast.arena_alloc(nc);
		if nb == null {
			return;
		}
		if *b != null && *l > 0 {
			std.mem.copy(nb, *b, *l);
		}
		*b = nb;
		*c = nc;
	}
	std.mem.copy(&((*b)[*l]), s.ptr, s.len);
	*l += s.len;
}

fn mbuf_push_u64(b: *mut *mut u8, l: *mut usize, c: *mut usize, mut v: u64) -> void {
	let mut tmp: [24]u8;
	let mut tp: usize = 0;
	if v == 0 {
		tmp[0] = '0' cast u8;
		tp = 1;
	} else {
		for v > 0 {
			tmp[tp] = ('0' cast u64 + (v % 10)) cast u8;
			tp += 1;
			v /= 10;
		}
	}
	for tp > 0 {
		tp -= 1;
		mbuf_push(b, l, c, tmp[tp..(tp + 1)]);
	}
}

fn mangle_type_into(b: *mut *mut u8, l: *mut usize, c: *mut usize, mut t: *mut middle.types.StType) -> void {
	t = middle.types.underlying_type(t);
	if t == null {
		mbuf_push(b, l, c, "unk");
		return;
	}
	match t.kind {
		.Void => mbuf_push(b, l, c, "void"),
		.Bool => mbuf_push(b, l, c, "bool"),
		.UInt => {
			if std.str.eq(t.name, "usize") {
				mbuf_push(b, l, c, "usize");
			} else {
				mbuf_push(b, l, c, "u");
				mbuf_push_u64(b, l, c, t.width cast u64);
			}
		}
		.SInt => {
			if std.str.eq(t.name, "isize") {
				mbuf_push(b, l, c, "isize");
			} else {
				mbuf_push(b, l, c, "i");
				mbuf_push_u64(b, l, c, t.width cast u64);
			}
		}
		.Float => {
			mbuf_push(b, l, c, "f");
			mbuf_push_u64(b, l, c, t.width cast u64);
		}
		.Pointer => {
			mbuf_push(b, l, c, "*");
			if t.is_mutable || t.is_volatile {
				if t.is_mutable {
					mbuf_push(b, l, c, "m");
				}
				if t.is_volatile {
					mbuf_push(b, l, c, "v");
				}
				mbuf_push(b, l, c, ":");
			}
			mangle_type_into(b, l, c, t.base);
		}
		.Array => {
			mbuf_push(b, l, c, "[");
			mbuf_push_u64(b, l, c, t.array_len cast u64);
			mbuf_push(b, l, c, "]");
			mangle_type_into(b, l, c, t.base);
		}
		.Slice => {
			mbuf_push(b, l, c, "[]");
			if t.is_mutable || t.is_volatile {
				if t.is_mutable {
					mbuf_push(b, l, c, "m");
				}
				if t.is_volatile {
					mbuf_push(b, l, c, "v");
				}
				mbuf_push(b, l, c, ":");
			}
			mangle_type_into(b, l, c, t.base);
		}
		.Struct | .Union | .Enum | .Opaque => {
			let n: []u8 = t.mangled_name.len > 0 ? t.mangled_name : t.name;
			if n.len >= 3 && n[0] == 's' && n[1] == 't' && n[2] == '$' {
				mbuf_push(b, l, c, n[3..n.len]);
			} else {
				mbuf_push(b, l, c, n);
			}
		}
		.Function => {
			mbuf_push(b, l, c, t.fn_abi == middle.types.AbiKind.C ? "abi(C)fn(" : "fn(");
			for let mut i: usize = 0; i < t.fn_params.len; i += 1 {
				if i > 0 {
					mbuf_push(b, l, c, ",");
				}
				mangle_type_into(b, l, c, t.fn_params.data[i]);
			}
			if t.fn_variadic {
				if t.fn_params.len > 0 {
					mbuf_push(b, l, c, ",");
				}
				mbuf_push(b, l, c, "...");
			}
			mbuf_push(b, l, c, ")->");
			mangle_type_into(b, l, c, t.fn_ret);
		}
		.VaList => mbuf_push(b, l, c, "@va.list"),
		.Poison => mbuf_push(b, l, c, "poison"),
		.Type => mbuf_push(b, l, c, "type"),
		.SelfType => mbuf_push(b, l, c, "Self"),
		_ => mbuf_push(b, l, c, "unk")
	}
}

/// Mangels a function symbol with its parameter signature (`st$mod.fn(t1,t2)`).
pub fn mangle_fn_with_sig(
	mod_path: *front.ast.ValList<[]u8>,
	name: []u8,
	fn_ty: *mut middle.types.StType,
	attrs: *front.ast.AttributeList
) -> []u8 {
	if attrs != null {
		for let mut i: usize = 0; i < attrs.attrs.len; i += 1 {
			let a: front.ast.Attribute = attrs.attrs.data[i];
			if !a.negated && std.str.eq(a.name, "link_name") {
				return mangle_symbol_name(mod_path, name, attrs);
			}
		}
	}
	let base: []u8 = mangle_symbol_name(mod_path, name, attrs);
	let mut buf: *mut u8 = null;
	let mut len: usize = 0;
	let mut cap: usize = 0;
	mbuf_push(&buf, &len, &cap, base);
	mbuf_push(&buf, &len, &cap, "(");
	let fu: *mut middle.types.StType = middle.types.underlying_type(fn_ty);
	if fu != null && fu.kind == middle.types.TypeKind.Function {
		for let mut i: usize = 0; i < fu.fn_params.len; i += 1 {
			if i > 0 {
				mbuf_push(&buf, &len, &cap, ",");
			}
			mangle_type_into(&buf, &len, &cap, fu.fn_params.data[i]);
		}
		if fu.fn_variadic {
			if fu.fn_params.len > 0 {
				mbuf_push(&buf, &len, &cap, ",");
			}
			mbuf_push(&buf, &len, &cap, "...");
		}
	}
	mbuf_push(&buf, &len, &cap, ")");
	if buf != null {
		return buf[0..len];
	}
	return base;
}

/// Executes `make_symbol` (make symbol).
pub fn make_symbol(kind: SymKind, name: []u8, loc: front.log.SourceLoc) -> Symbol {
	return {
		.kind = kind,
		.simple = name,
		.mangled = name,
		.mod_path = { .data = null, .len = 0, .cap = 0 },
		.ty = null,
		.mod_decl = null,
		.fn_decl = null,
		.st = null,
		.un = null,
		.tb = null,
		.en = null,
		.trait_decl = null,
		.glob = null,
		.is_pub = false,
		.is_imported = false,
		.is_mutable = true,
		.used = false,
		.loc = loc,
		.has_const_value = false,
		.const_value_is_float = false,
		.const_bool_val = false,
		.const_int_val = 0,
		.const_flt_val = 0.0,
		.comptime_str_val = "",
		.comptime_type_value = null
	};
}

/// Represents the `Scope` data structure.
pub struct Scope {
	/// Stores the `entries` field (entries).
	pub entries: front.ast.PtrList<Symbol>,
	/// Open-addressing hash index for `entries` (stores index + 1; 0 = empty).
	pub buckets: *mut usize,
	/// Capacity of `buckets` (power of 2).
	pub bucket_cap: usize
}

fn scope_rehash(s: *mut Scope, new_cap: usize) -> void {
	let raw: *mut u8 = front.ast.arena_alloc(new_cap * @of.size(usize));
	if raw == null {
		return;
	}
	std.mem.set(raw, 0, new_cap * @of.size(usize));
	let buckets: *mut usize = raw cast *mut usize;
	let mask: usize = new_cap - 1;
	for let mut i: usize = 0; i < s.entries.len; i += 1 {
		let sym: *mut Symbol = s.entries.data[i];
		let mut idx: usize = (std.hash.fnv1a_32(sym.simple) cast usize) & mask;
		let mut found: bool = false;
		for buckets[idx] != 0 {
			let existing: *mut Symbol = s.entries.data[buckets[idx] - 1];
			if std.str.eq(existing.simple, sym.simple) {
				found = true;
				break;
			}
			idx = (idx + 1) & mask;
		}
		if !found {
			buckets[idx] = i + 1;
		}
	}
	s.buckets = buckets;
	s.bucket_cap = new_cap;
}

fn scope_index_push(s: *mut Scope, sym: *mut Symbol, slot_idx: usize) -> void {
	if s.buckets == null {
		if s.entries.len < 16 {
			return;
		}
		scope_rehash(s, 64);
		return;
	}
	if (s.entries.len * 2) > s.bucket_cap {
		scope_rehash(s, s.bucket_cap * 2);
		return;
	}
	let mask: usize = s.bucket_cap - 1;
	let mut idx: usize = (std.hash.fnv1a_32(sym.simple) cast usize) & mask;
	for s.buckets[idx] != 0 {
		let existing: *mut Symbol = s.entries.data[s.buckets[idx] - 1];
		if std.str.eq(existing.simple, sym.simple) {
			return;
		}
		idx = (idx + 1) & mask;
	}
	s.buckets[idx] = slot_idx + 1;
}

fn scope_lookup_in(s: *Scope, name: []u8) -> *mut Symbol {
	if s.buckets != null && s.bucket_cap > 0 {
		let mask: usize = s.bucket_cap - 1;
		let mut idx: usize = (std.hash.fnv1a_32(name) cast usize) & mask;
		for s.buckets[idx] != 0 {
			let sym: *mut Symbol = s.entries.data[s.buckets[idx] - 1];
			if std.str.eq(sym.simple, name) {
				return sym;
			}
			idx = (idx + 1) & mask;
		}
		return null;
	}
	for let mut i: usize = 0; i < s.entries.len; i += 1 {
		let sym: *mut Symbol = s.entries.data[i];
		if std.str.eq(sym.simple, name) {
			return sym;
		}
	}
	return null;
}

/// Represents the `ScopeStack` data structure.
pub struct ScopeStack {
	/// Stores the `scopes` field (scopes).
	pub scopes: front.ast.PtrList<Scope>
}

/// Executes `init_scope_stack` (init scope stack).
pub fn init_scope_stack() -> ScopeStack {
	return {
		.scopes = { .data = null, .len = 0, .cap = 0 }
	};
}

impl ScopeStack {
	/// Executes `enter` (enter).
	pub fn enter(self: *mut ScopeStack) -> bool {
		let raw: *mut u8 = front.ast.arena_alloc(@of.size(Scope));
		if raw == null {
			return false;
		}
		let s: *mut Scope = raw cast *mut Scope;
		*s = { .entries = { .data = null, .len = 0, .cap = 0 }, .buckets = null, .bucket_cap = 0 };
		self.scopes.push(s);
		return true;
	}

	/// Executes `leave` (leave).
	pub fn leave(self: *mut ScopeStack) -> void {
		if self.scopes.len == 0 {
			return;
		}
		self.scopes.len -= 1;
		let s: *mut Scope = self.scopes.data[self.scopes.len];
		if s != null {
			// Keep Symbol allocations alive because AST nodes retain sema_sym pointers for codegen.
			s.entries.free_array();
			s.buckets = null;
			s.bucket_cap = 0;
		}
	}

	/// Executes `lookup_current` (lookup current).
	pub fn lookup_current(self: *ScopeStack, name: []u8) -> *mut Symbol {
		if self.scopes.len == 0 {
			return null;
		}
		return scope_lookup_in(self.scopes.data[self.scopes.len - 1], name);
	}

	/// Executes `lookup_local` (lookup local).
	pub fn lookup_local(self: *ScopeStack, name: []u8, min_depth: usize) -> *mut Symbol {
		let mut i: usize = self.scopes.len;
		for i > min_depth {
			i -= 1;
			let sym: *mut Symbol = scope_lookup_in(self.scopes.data[i], name);
			if sym != null {
				return sym;
			}
		}
		return null;
	}

	/// Executes `lookup` (lookup).
	pub fn lookup(self: *ScopeStack, name: []u8) -> *mut Symbol {
		let mut i: usize = self.scopes.len;
		for i > 0 {
			i -= 1;
			let sym: *mut Symbol = scope_lookup_in(self.scopes.data[i], name);
			if sym != null {
				return sym;
			}
		}
		return null;
	}

	/// Defines `sym` in the current scope, replacing an imported symbol of the same name.
	pub fn define_or_replace_imported(self: *mut ScopeStack, sym: Symbol) -> *mut Symbol {
		if self.scopes.len == 0 {
			return null;
		}
		let s: *mut Scope = self.scopes.data[self.scopes.len - 1];
		for let mut i: usize = 0; i < s.entries.len; i += 1 {
			let existing: *mut Symbol = s.entries.data[i];
			if std.str.eq(existing.simple, sym.simple) {
				if !existing.is_imported {
					return null;
				}
				let raw: *mut u8 = front.ast.arena_alloc(@of.size(Symbol));
				if raw == null {
					return null;
				}
				let ptr: *mut Symbol = raw cast *mut Symbol;
				*ptr = sym;
				s.entries.data[i] = ptr;
				return ptr;
			}
		}
		return self.define(sym);
	}

	/// Executes `define_overload` (define overload).
	pub fn define_overload(self: *mut ScopeStack, sym: Symbol) -> *mut Symbol {
		if self.scopes.len == 0 {
			return null;
		}
		let raw: *mut u8 = front.ast.arena_alloc(@of.size(Symbol));
		if raw == null {
			return null;
		}
		let ptr: *mut Symbol = raw cast *mut Symbol;
		*ptr = sym;
		let s: *mut Scope = self.scopes.data[self.scopes.len - 1];
		let idx: usize = s.entries.len;
		s.entries.push(ptr);
		scope_index_push(s, ptr, idx);
		return ptr;
	}

	/// Executes `define` (define).
	pub fn define(self: *mut ScopeStack, sym: Symbol) -> *mut Symbol {
		if self.scopes.len == 0 {
			return null;
		}
		if self.lookup_current(sym.simple) != null {
			return null;
		}
		let raw: *mut u8 = front.ast.arena_alloc(@of.size(Symbol));
		if raw == null {
			return null;
		}
		let ptr: *mut Symbol = raw cast *mut Symbol;
		*ptr = sym;
		let s: *mut Scope = self.scopes.data[self.scopes.len - 1];
		let idx: usize = s.entries.len;
		s.entries.push(ptr);
		scope_index_push(s, ptr, idx);
		return ptr;
	}

	/// Executes `free` (free).
	pub fn free(self: *mut ScopeStack) -> void {
		for self.scopes.len > 0 {
			self.leave();
		}
		self.scopes.free_array();
	}
}
