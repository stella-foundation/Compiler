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

fn hash_ptr(p: *void) -> usize {
	let v: usize = p cast usize;
	return ((v >> 4) ^ (v >> 13)) *% 11400714819323198485;
}

impl SemaContext {
	fn rehash_imp_name(self: *mut SemaContext, new_cap: usize) -> void {
		let raw: *mut u8 = front.ast.arena_alloc(new_cap * @of.size(isize));
		if raw == null {
			return;
		}
		let buckets: *mut isize = raw cast *mut isize;
		for let mut i: usize = 0; i < new_cap; i += 1 {
			buckets[i] = -1;
		}
		let mask: usize = new_cap - 1;
		for let mut i: usize = 0; i < self.imported_syms.len; i += 1 {
			let sym: *mut middle.symbol.Symbol = self.imported_syms.data[i].sym;
			let b: usize = (std.hash.fnv1a_32(sym.simple) cast usize) & mask;
			self.imp_name_next.data[i] = buckets[b];
			buckets[b] = i cast isize;
		}
		self.imp_name_buckets = buckets;
		self.imp_name_bucket_cap = new_cap;
	}

	fn rehash_imp_fn(self: *mut SemaContext, new_cap: usize) -> void {
		let raw: *mut u8 = front.ast.arena_alloc(new_cap * @of.size(isize));
		if raw == null {
			return;
		}
		let buckets: *mut isize = raw cast *mut isize;
		for let mut i: usize = 0; i < new_cap; i += 1 {
			buckets[i] = -1;
		}
		let mask: usize = new_cap - 1;
		for let mut i: usize = 0; i < self.imported_syms.len; i += 1 {
			let sym: *mut middle.symbol.Symbol = self.imported_syms.data[i].sym;
			if sym != null && sym.fn_decl != null {
				let b: usize = hash_ptr(sym.fn_decl cast *void) & mask;
				self.imp_fn_next.data[i] = buckets[b];
				buckets[b] = i cast isize;
			} else {
				self.imp_fn_next.data[i] = -1;
			}
		}
		self.imp_fn_buckets = buckets;
		self.imp_fn_bucket_cap = new_cap;
	}

	/// Appends `qs` to `self.imported_syms` and updates hash indices.
	pub fn add_imported_sym(self: *mut SemaContext, qs: QualifiedSym) -> void {
		let idx: usize = self.imported_syms.len;
		self.imported_syms.push(qs);
		self.imp_name_next.push(-1);
		self.imp_fn_next.push(-1);

		if self.imp_name_bucket_cap == 0 || self.imported_syms.len > self.imp_name_bucket_cap {
			let new_cap: usize = self.imp_name_bucket_cap == 0 ? 512 : self.imp_name_bucket_cap * 2;
			self.rehash_imp_name(new_cap);
		} else if self.imp_name_buckets != null && qs.sym != null {
			let mask: usize = self.imp_name_bucket_cap - 1;
			let b: usize = (std.hash.fnv1a_32(qs.sym.simple) cast usize) & mask;
			self.imp_name_next.data[idx] = self.imp_name_buckets[b];
			self.imp_name_buckets[b] = idx cast isize;
		}

		if self.imp_fn_bucket_cap == 0 || self.imported_syms.len > self.imp_fn_bucket_cap {
			let new_cap: usize = self.imp_fn_bucket_cap == 0 ? 512 : self.imp_fn_bucket_cap * 2;
			self.rehash_imp_fn(new_cap);
		} else if self.imp_fn_buckets != null && qs.sym != null && qs.sym.fn_decl != null {
			let mask: usize = self.imp_fn_bucket_cap - 1;
			let b: usize = hash_ptr(qs.sym.fn_decl cast *void) & mask;
			self.imp_fn_next.data[idx] = self.imp_fn_buckets[b];
			self.imp_fn_buckets[b] = idx cast isize;
		}
	}

	/// Executes `lookup_fn_by_decl` (lookup fn by decl).
	pub fn lookup_fn_by_decl(
		self: *SemaContext,
		mod_path: *front.ast.ValList<[]u8>,
		fn_d: *front.ast.FnDecl
	) -> *mut middle.symbol.Symbol {
		if fn_d == null {
			return null;
		}
		if self.imp_fn_buckets != null && self.imp_fn_bucket_cap > 0 {
			let mask: usize = self.imp_fn_bucket_cap - 1;
			let b: usize = hash_ptr(fn_d cast *void) & mask;
			let mut cur: isize = self.imp_fn_buckets[b];
			for cur >= 0 {
				let qs: QualifiedSym = self.imported_syms.data[cur];
				if qs.sym != null && qs.sym.fn_decl == fn_d {
					if mod_path == null || qs.mod_path.len == mod_path.len {
						return qs.sym;
					}
				}
				cur = self.imp_fn_next.data[cur];
			}
		} else {
			for let mut i: usize = 0; i < self.imported_syms.len; i += 1 {
				let qs: QualifiedSym = self.imported_syms.data[i];
				if qs.sym != null && qs.sym.fn_decl == fn_d {
					if mod_path == null || qs.mod_path.len == mod_path.len {
						return qs.sym;
					}
				}
			}
		}
		if self.scopes.scopes.len > 0 {
			let root: *middle.symbol.Scope = self.scopes.scopes.data[0];
			for let mut i: usize = 0; i < root.entries.len; i += 1 {
				let es: *mut middle.symbol.Symbol = root.entries.data[i];
				if es != null && es.fn_decl == fn_d {
					return es;
				}
			}
		}
		return null;
	}

	/// Executes `lookup_in_mod` (lookup in mod).
	pub fn lookup_in_mod(
		self: *SemaContext,
		mod_path: *front.ast.ValList<[]u8>,
		name: []u8
	) -> *mut middle.symbol.Symbol {
		if mod_path == null || mod_path.len == 0 {
			return null;
		}
		if self.imp_name_buckets != null && self.imp_name_bucket_cap > 0 {
			let mask: usize = self.imp_name_bucket_cap - 1;
			let b: usize = (std.hash.fnv1a_32(name) cast usize) & mask;
			let mut cur: isize = self.imp_name_buckets[b];
			for cur >= 0 {
				let qs: QualifiedSym = self.imported_syms.data[cur];
				if qs.mod_path.len == mod_path.len && std.str.eq(qs.sym.simple, name) {
					let mut matched: bool = true;
					for let mut j: usize = 0; j < mod_path.len; j += 1 {
						if !std.str.eq(qs.mod_path.data[j], mod_path.data[j]) {
							matched = false;
							break;
						}
					}
					if matched {
						return qs.sym;
					}
				}
				cur = self.imp_name_next.data[cur];
			}
			return null;
		}
		for let mut i: usize = 0; i < self.imported_syms.len; i += 1 {
			let qs: QualifiedSym = self.imported_syms.data[i];
			if !std.str.eq(qs.sym.simple, name) {
				continue;
			}
			if qs.mod_path.len == mod_path.len {
				let mut matched: bool = true;
				for let mut j: usize = 0; j < mod_path.len; j += 1 {
					if !std.str.eq(qs.mod_path.data[j], mod_path.data[j]) {
						matched = false;
						break;
					}
				}
				if matched {
					return qs.sym;
				}
			}
		}
		return null;
	}

	/// Executes `lookup_in_mod_or_parents` (lookup in mod or parents).
	pub fn lookup_in_mod_or_parents(
		self: *SemaContext,
		mod_path: *front.ast.ValList<[]u8>,
		name: []u8
	) -> *mut middle.symbol.Symbol {
		if mod_path == null || mod_path.len == 0 {
			return null;
		}
		if self.imp_name_buckets != null && self.imp_name_bucket_cap > 0 {
			let mask: usize = self.imp_name_bucket_cap - 1;
			let b: usize = (std.hash.fnv1a_32(name) cast usize) & mask;
			let mut plen: usize = mod_path.len;
			for plen > 0 {
				let mut cur: isize = self.imp_name_buckets[b];
				for cur >= 0 {
					let qs: QualifiedSym = self.imported_syms.data[cur];
					if qs.mod_path.len == plen && std.str.eq(qs.sym.simple, name) {
						let mut matched: bool = true;
						for let mut j: usize = 0; j < plen; j += 1 {
							if !std.str.eq(qs.mod_path.data[j], mod_path.data[j]) {
								matched = false;
								break;
							}
						}
						if matched {
							return qs.sym;
						}
					}
					cur = self.imp_name_next.data[cur];
				}
				plen -= 1;
			}
			return null;
		}
		let mut plen: usize = mod_path.len;
		for plen > 0 {
			for let mut i: usize = 0; i < self.imported_syms.len; i += 1 {
				let qs: QualifiedSym = self.imported_syms.data[i];
				if !std.str.eq(qs.sym.simple, name) || qs.mod_path.len != plen {
					continue;
				}
				let mut matched: bool = true;
				for let mut j: usize = 0; j < plen; j += 1 {
					if !std.str.eq(qs.mod_path.data[j], mod_path.data[j]) {
						matched = false;
						break;
					}
				}
				if matched {
					return qs.sym;
				}
			}
			plen -= 1;
		}
		return null;
	}

	/// Executes `lookup_qualified` (lookup qualified).
	pub fn lookup_qualified(
		self: *SemaContext,
		path: *front.ast.ValList<[]u8>,
		len: usize
	) -> *mut middle.symbol.Symbol {
		if len == 0 {
			return null;
		}
		if len == 1 {
			return self.scopes.lookup(path.data[0]);
		}
		let target_name: []u8 = path.data[len - 1];
		let mod_len: usize = len - 1;
		if self.imp_name_buckets != null && self.imp_name_bucket_cap > 0 {
			let mask: usize = self.imp_name_bucket_cap - 1;
			let b: usize = (std.hash.fnv1a_32(target_name) cast usize) & mask;
			let mut cur: isize = self.imp_name_buckets[b];
			for cur >= 0 {
				let qs: QualifiedSym = self.imported_syms.data[cur];
				if qs.mod_path.len == mod_len && std.str.eq(qs.sym.simple, target_name) {
					let mut matched: bool = true;
					for let mut j: usize = 0; j < mod_len; j += 1 {
						if !std.str.eq(qs.mod_path.data[j], path.data[j]) {
							matched = false;
							break;
						}
					}
					if matched {
						return qs.sym;
					}
				}
				cur = self.imp_name_next.data[cur];
			}
			return null;
		}
		for let mut i: usize = 0; i < self.imported_syms.len; i += 1 {
			let qs: QualifiedSym = self.imported_syms.data[i];
			if !std.str.eq(qs.sym.simple, target_name) {
				continue;
			}
			if qs.mod_path.len == mod_len {
				let mut matched: bool = true;
				for let mut j: usize = 0; j < mod_len; j += 1 {
					if !std.str.eq(qs.mod_path.data[j], path.data[j]) {
						matched = false;
						break;
					}
				}
				if matched {
					return qs.sym;
				}
			}
		}
		return null;
	}

	/// Executes `populate_enum_type` (populate enum type).
	pub fn populate_enum_type(
		self: *mut SemaContext,
		en: *front.ast.EnumDecl,
		ty: *mut middle.types.StType
	) -> void {
		if en == null || ty == null {
			return;
		}
		let mut next_val: u64 = 0;
		for let mut i: usize = 0; i < en.members.len; i += 1 {
			let m: front.ast.EnumMember = en.members.data[i];
			ty.field_names.push(m.name);
			if m.value != null {
				let cv: middle.sema.const_eval.ConstVal = middle.sema.const_eval.eval_const_expr(
					m.value, &self.scopes, &self.tx
				);
				if cv.kind == middle.sema.const_eval.ConstKind.Int {
					next_val = cv.int_val;
				}
			}
			let bu: *mut middle.types.StType = ty.base != null
				? middle.types.underlying_type(ty.base) : null;
			if bu != null && bu.kind == middle.types.TypeKind.UInt && bu.width > 0 && bu.width
				< 64 {
				let max_v: u64 = ((1 cast u64) << (bu.width cast u64)) - 1;
				if next_val > max_v {
					front.log.report(
						front.log.Level.Error,
						m.loc,
						"enum discriminant does not fit backing type",
						front.log.DiagCode.TypeMismatch
					);
				}
			}
			for let mut di: usize = 0; di < ty.enum_values.len; di += 1 {
				if ty.enum_values.data[di] == next_val {
					front.log.report(
						front.log.Level.Error,
						m.loc,
						"duplicate enum discriminant value",
						front.log.DiagCode.DuplicateDeclaration
					);
					break;
				}
			}
			ty.enum_values.push(next_val);
			next_val += 1;

			if m.payload_kind != front.ast.EnumPayloadKind.Unit || m.payload_fields.len > 0 {
				ty.is_tagged_enum = true;
			}
			let mut vinfo: middle.types.EnumVariantInfo = {
				.payload_kind = m.payload_kind,
				.field_types = { .data = null, .len = 0, .cap = 0 },
				.field_names = { .data = null, .len = 0, .cap = 0 }
			};
			for let mut j: usize = 0; j < m.payload_fields.len; j += 1 {
				let pf: front.ast.EnumVariantField = m.payload_fields.data[j];
				let pty: *mut middle.types.StType = self.resolve_type(pf.ty);
				if middle.types.eq_type(pty, ty) {
					front.log.report(
						front.log.Level.Error,
						pf.loc,
						"by-value recursive aggregate cycle",
						front.log.DiagCode.TypeMismatch
					);
				}
				vinfo.field_types.push(pty);
				vinfo.field_names.push(pf.name);
			}
			ty.enum_variants.push(vinfo);
		}
	}

	/// Executes `check_trait_bounds` (check trait bounds).
	pub fn check_trait_bounds(
		self: *SemaContext,
		gp: *front.ast.GenericParam,
		arg_ty: *mut middle.types.StType,
		loc: front.log.SourceLoc
	) -> bool {
		if gp == null || arg_ty == null || gp.trait_bounds.len == 0 {
			return true;
		}
		let u: *mut middle.types.StType = middle.types.underlying_type(arg_ty);
		if u == null || u.kind == middle.types.TypeKind.Poison {
			return true;
		}
		for let mut b: usize = 0; b < gp.trait_bounds.len; b += 1 {
			let tr: *front.ast.TypeRef = gp.trait_bounds.data[b];
			if tr == null || tr.path.len == 0 {
				continue;
			}
			let tname: []u8 = tr.path.data[tr.path.len - 1];
			let mut found: bool = false;
			for let mut i: usize = 0; i < self.trait_impls.len; i += 1 {
				let ti: TraitImplEntry = self.trait_impls.data[i];
				if std.str.eq(ti.trait_name, tname) && middle.types.eq_type(ti.target_ty, u) {
					found = true;
					break;
				}
			}
			if !found && u.generic_origin_name.len > 0 {
				for let mut gi: usize = 0; gi < self.generic_impls.len; gi += 1 {
					let ge: GenericImplEntry = self.generic_impls.data[gi];
					let imp: *front.ast.ImplDecl = ge.imp;
					if imp != null && !imp.is_inherent && std.str.eq(imp.trait_name, tname)
						&& imp.target_type != null {
						let tbase: []u8 = imp.target_type.path.len > 0
							? imp.target_type.path.data[imp.target_type.path.len - 1]
							: imp.target_type.name;
						if std.str.eq(tbase, u.generic_origin_name) {
							let mut args_ok: bool = true;
							let gcnt: usize = imp.generic_params.len < u.generic_args.len
								? imp.generic_params.len : u.generic_args.len;
							for let mut gk: usize = 0; gk < gcnt; gk += 1 {
								if !self.check_trait_bounds(
									&imp.generic_params.data[gk],
									u.generic_args.data[gk],
									loc
								) {
									args_ok = false;
									break;
								}
							}
							if args_ok {
								found = true;
								break;
							}
						}
					}
				}
			}
			if !found {
				front.log.report(
					front.log.Level.Error,
					loc,
					"type argument does not satisfy generic trait constraint",
					front.log.DiagCode.GenericConstraint
				);
				return false;
			}
		}
		return true;
	}

	/// Executes `instantiate_generic_type` (instantiate generic type).
	pub fn instantiate_generic_type(
		self: *mut SemaContext,
		sym: *middle.symbol.Symbol,
		args: *front.ast.ValList<front.ast.GenericArg>,
		loc: front.log.SourceLoc
	) -> *mut middle.types.StType {
		if sym == null {
			return self.tx.poison_t;
		}
		let mut gparams: *front.ast.ValList<front.ast.GenericParam> = null;
		if sym.kind == middle.symbol.SymKind.Struct && sym.st != null {
			gparams = &sym.st.generic_params;
		} else if sym.kind == middle.symbol.SymKind.Union && sym.un != null {
			gparams = &sym.un.generic_params;
		} else if sym.kind == middle.symbol.SymKind.Enum && sym.en != null {
			gparams = &sym.en.generic_params;
		}
		let mut resolved: front.ast.PtrList<middle.types.StType> = {
			.data = null,
			.len = 0,
			.cap = 0
		};
		for let mut i: usize = 0; i < args.len; i += 1 {
			if gparams != null && i < gparams.len && gparams.data[i].kind
				== front.ast.GenericParamKind.Const {
				let mut cval: u64 = 0;
				let ga: front.ast.GenericArg = args.data[i];
				if ga.value != null {
					let cv: middle.sema.const_eval.ConstVal =
						middle.sema.const_eval.eval_const_expr(ga.value, &self.scopes, &self.tx);
					if cv.kind == middle.sema.const_eval.ConstKind.Int {
						cval = cv.int_val;
					}
				} else if ga.ty != null && ga.ty.kind == front.ast.TypeRefKind.Named
					&& ga.ty.path.len == 1 {
					let aname: []u8 = ga.ty.path.data[0];
					let mut found_s: bool = false;
					for let mut si: usize = self.generic_subst.len; si > 0; {
						si -= 1;
						if self.generic_subst.data[si].is_const
							&& std.str.eq(self.generic_subst.data[si].name, aname) {
							cval = self.generic_subst.data[si].const_val cast u64;
							found_s = true;
							break;
						}
					}
					if !found_s {
						let csym: *middle.symbol.Symbol = self.scopes.lookup(aname);
						if csym != null && csym.has_const_value {
							cval = csym.const_int_val;
						}
					}
				}
				let cw: i32 = cval > 0 ? (cval cast i32) : 1;
				resolved.push(self.tx.uint(cw));
			} else {
				resolved.push(self.resolve_type(args.data[i].ty));
			}
		}
		for let mut i: usize = 0; i < self.generic_types.len; i += 1 {
			let inst: GenericTypeInst = self.generic_types.data[i];
			let same_origin: bool = inst.origin_sym == sym
				|| (inst.origin_sym != null
				&& ((sym.st != null && inst.origin_sym.st == sym.st)
				|| (sym.un != null && inst.origin_sym.un == sym.un)
				|| (sym.en != null && inst.origin_sym.en == sym.en)));
			if same_origin && inst.args.len == resolved.len {
				let mut all_eq: bool = true;
				for let mut j: usize = 0; j < resolved.len; j += 1 {
					if !middle.types.eq_type(inst.args.data[j], resolved.data[j]) {
						all_eq = false;
						break;
					}
				}
				if all_eq {
					resolved.free_array();
					return inst.ty;
				}
			}
		}

		let mut ty: *mut middle.types.StType = null;
		if sym.kind == middle.symbol.SymKind.Struct && sym.st != null {
			ty = self.tx.struct_of(sym.st.name, sym.st.is_pub);
			ty.is_foreign = sym.ty != null ? sym.ty.is_foreign : false;
			ty.is_opaque = sym.st.is_opaque;
			gparams = &sym.st.generic_params;
		} else if sym.kind == middle.symbol.SymKind.Union && sym.un != null {
			ty = self.tx.union_of(sym.un.name, sym.un.is_pub);
			ty.is_foreign = sym.ty != null ? sym.ty.is_foreign : false;
			gparams = &sym.un.generic_params;
		} else if sym.kind == middle.symbol.SymKind.Enum && sym.en != null {
			let backing: *mut middle.types.StType = sym.en.backing != null
				? self.resolve_type(sym.en.backing) : self.tx.uint(32);
			ty = self.tx.enum_of(sym.en.name, backing, sym.en.is_pub);
			gparams = &sym.en.generic_params;
		} else {
			resolved.free_array();
			return sym.ty != null ? sym.ty : self.tx.poison_t;
		}

		ty.generic_origin_name = sym.simple;
		ty.generic_args = resolved;
		let entry: GenericTypeInst = {
			.origin_sym = sym,
			.args = resolved,
			.ty = ty
		};
		self.generic_types.push(entry);

		let prev_len: usize = self.generic_subst.len;
		if gparams != null {
			let count: usize = gparams.len < resolved.len ? gparams.len : resolved.len;
			for let mut i: usize = 0; i < count; i += 1 {
				if gparams.data[i].kind == front.ast.GenericParamKind.Const {
					let mut cval: u64 = 0;
					if i < args.len {
						let ga: front.ast.GenericArg = args.data[i];
						if ga.value != null {
							let cv: middle.sema.const_eval.ConstVal =
								middle.sema.const_eval.eval_const_expr(
									ga.value,
									&self.scopes,
									&self.tx
								);
							if cv.kind == middle.sema.const_eval.ConstKind.Int {
								cval = cv.int_val;
							}
						} else if ga.ty != null && ga.ty.kind == front.ast.TypeRefKind.Named
							&& ga.ty.path.len == 1 {
							let aname: []u8 = ga.ty.path.data[0];
							let mut found_s: bool = false;
							for let mut si: usize = self.generic_subst.len; si > 0; {
								si -= 1;
								if self.generic_subst.data[si].is_const
									&& std.str.eq(self.generic_subst.data[si].name, aname) {
									cval = self.generic_subst.data[si].const_val cast u64;
									found_s = true;
									break;
								}
							}
							if !found_s {
								let csym: *middle.symbol.Symbol = self.scopes.lookup(aname);
								if csym != null && csym.has_const_value {
									cval = csym.const_int_val;
								}
							}
						}
					}
					let ge: middle.sema.generics.GenericSubstEntry = {
						.name = gparams.data[i].name,
						.is_const = true,
						.ty = self.tx.usize_t,
						.const_val = cval cast i64
					};
					self.generic_subst.push(ge);
				} else {
					middle.sema.generics.check_type_set_constraint(
						&gparams.data[i],
						resolved.data[i],
						loc
					);
					self.check_trait_bounds(&gparams.data[i], resolved.data[i], loc);
					let ge: middle.sema.generics.GenericSubstEntry = {
						.name = gparams.data[i].name,
						.is_const = false,
						.ty = resolved.data[i],
						.const_val = 0
					};
					self.generic_subst.push(ge);
				}
			}
		}

		let prev_mod: *front.ast.ValList<[]u8> = self.current_mod_path;
		if sym.mod_path.len > 0 {
			self.current_mod_path = &sym.mod_path;
		}
		if sym.kind == middle.symbol.SymKind.Struct && sym.st != null {
			for let mut i: usize = 0; i < sym.st.field_names.len; i += 1 {
				ty.field_names.push(sym.st.field_names.data[i]);
				ty.fields.push(self.resolve_type(sym.st.field_types.data[i]));
				ty.field_is_pub.push(sym.st.field_is_pub.data[i]);
			}
			check_layout_attr(&sym.st.attrs, ty, (self.tx.pointer_width / 8) cast usize, loc);
		} else if sym.kind == middle.symbol.SymKind.Union && sym.un != null {
			for let mut i: usize = 0; i < sym.un.field_names.len; i += 1 {
				ty.field_names.push(sym.un.field_names.data[i]);
				ty.fields.push(self.resolve_type(sym.un.field_types.data[i]));
				ty.field_is_pub.push(sym.un.field_is_pub.data[i]);
			}
		} else if sym.kind == middle.symbol.SymKind.Enum && sym.en != null {
			self.populate_enum_type(sym.en, ty);
		}
		self.current_mod_path = prev_mod;

		self.generic_subst.len = prev_len;
		return ty;
	}

	/// Executes `mangle_method_name` (mangle method name).
	pub fn mangle_method_name(
		self: *mut SemaContext,
		mod_path: *front.ast.ValList<[]u8>,
		target_ty: *mut middle.types.StType,
		mname: []u8
	) -> []u8 {
		let base: []u8 = middle.symbol.mangle_symbol_name(
			mod_path,
			target_ty != null ? target_ty.name : "Self",
			null
		);
		let idx: usize = self.impl_methods.len;
		// Unique suffix using method name + index to avoid generic specialization collisions
		let total: usize = base.len + 2 + mname.len + 8;
		let buf: *mut u8 = front.ast.arena_alloc(total);
		if buf != null {
			std.mem.copy(buf, base.ptr, base.len);
			let mut pos: usize = base.len;
			buf[pos] = '$' cast u8;
			pos += 1;
			std.mem.copy(&buf[pos], mname.ptr, mname.len);
			pos += mname.len;
			buf[pos] = '$' cast u8;
			pos += 1;
			// Encode idx in hex
			let mut v: usize = idx;
			for let mut d: usize = 0; d < 4; d += 1 {
				let nib: u8 = ((v >> ((3 - d) * 4)) & 0xF) cast u8;
				buf[pos] = nib < 10 ? ('0' cast u8 + nib) : ('a' cast u8 + (nib - 10));
				pos += 1;
			}
			return buf[0..pos];
		}
		return mname;
	}


	/// Executes `mod_paths_equal`.
	pub fn mod_paths_equal(
		a: *front.ast.ValList<[]u8>,
		b: *front.ast.ValList<[]u8>
	) -> bool {
		if a.len != b.len {
			return false;
		}
		for let mut i: usize = 0; i < a.len; i += 1 {
			if !std.str.eq(a.data[i], b.data[i]) {
				return false;
			}
		}
		return true;
	}

	/// Instantiates generic overloads of a variadic macro mapper for `arg`.

	pub fn lookup_impl_method(
		self: *mut SemaContext,
		target_ty: *mut middle.types.StType,
		name: []u8
	) -> *mut middle.symbol.Symbol {
		if target_ty == null {
			return null;
		}
		let u: *mut middle.types.StType = middle.types.underlying_type(target_ty);
		for let mut i: usize = 0; i < self.impl_methods.len; i += 1 {
			let e: ImplMethodEntry = self.impl_methods.data[i];
			if middle.types.eq_type(e.target_ty, u) && std.str.eq(e.fn_decl.name, name) {
				return e.sym;
			}
		}
		if u != null && u.generic_origin_name.len > 0 {
			for let mut i: usize = 0; i < self.generic_impls.len; i += 1 {
				let ge: GenericImplEntry = self.generic_impls.data[i];
				let imp: *front.ast.ImplDecl = ge.imp;
				if imp.target_type != null && imp.target_type.kind == front.ast.TypeRefKind.Named {
					let tname: []u8 = imp.target_type.path.len > 0
						? imp.target_type.path.data[imp.target_type.path.len - 1]
						: imp.target_type.name;
					if std.str.eq(tname, u.generic_origin_name) {
						let mut m: *front.ast.FnDecl = null;
						for let mut j: usize = 0; j < imp.methods.len; j += 1 {
							let cand: *front.ast.FnDecl = imp.methods.data[j];
							if std.str.eq(cand.name, name) && cand.generic_params.len == 0 {
								m = cand;
								break;
							}
						}
						if m == null && !imp.is_inherent && imp.trait_name.len > 0 {
							for let mut ti: usize = 0; ti < self.traits.len; ti += 1 {
								if std.str.eq(self.traits.data[ti].name, imp.trait_name) {
									let tdecl: *front.ast.TraitDecl = self.traits.data[ti];
									for let mut tm: usize = 0; tm < tdecl.methods.len; tm += 1 {
										let dm: *front.ast.FnDecl = tdecl.methods.data[tm];
										if std.str.eq(dm.name, name) && dm.body != null
											&& dm.generic_params.len == 0 {
											m = dm;
											break;
										}
									}
									break;
								}
							}
						}
						if m != null {
							let prev_len: usize = self.generic_subst.len;
							let mut eff_gparams: front.ast.ValList<front.ast.GenericParam> =
								imp.generic_params;
							if eff_gparams.len == 0 && imp.target_type.generic_args.len > 0 {
								eff_gparams = { .data = null, .len = 0, .cap = 0 };
								for let mut k: usize = 0; k
									< imp.target_type.generic_args.len; k += 1 {
									let atr: *front.ast.TypeRef =
										imp.target_type.generic_args.data[k].ty;
									let aname: []u8 = (atr != null && atr.path.len > 0)
										? atr.path.data[0] : "";
									let gp: front.ast.GenericParam = {
										.kind = front.ast.GenericParamKind.Type,
										.name = aname,
										.const_type = null,
										.type_set = { .data = null, .len = 0, .cap = 0 },
										.trait_bounds = { .data = null, .len = 0, .cap = 0 },
										.loc = imp.loc
									};
									eff_gparams.push(gp);
								}
							}
							let count: usize = eff_gparams.len < u.generic_args.len
								? eff_gparams.len : u.generic_args.len;
							for let mut k: usize = 0; k < count; k += 1 {
								let sub: middle.sema.generics.GenericSubstEntry = {
									.name = eff_gparams.data[k].name,
									.is_const = false,
									.ty = u.generic_args.data[k],
									.const_val = 0
								};
								self.generic_subst.push(sub);
							}
							let msym: *mut middle.symbol.Symbol = self.register_impl_method(
								u,
								m,
								&ge.mod_path
							);
							if msym != null && self.impl_methods.len > 0 {
								self.impl_methods.data[self.impl_methods.len - 1].generic_params =
									eff_gparams;
							}
							let prev_self: *mut middle.types.StType = self.current_self_ty;
							let prev_mod: *front.ast.ValList<[]u8> = self.current_mod_path;
							self.current_self_ty = u;
							self.current_mod_path = &ge.mod_path;
							self.check_fn_body(m);
							self.current_self_ty = prev_self;
							self.current_mod_path = prev_mod;
							self.generic_subst.len = prev_len;
							return msym;
						}
					}
				}
			}
		}
		return null;
	}

	/// Executes `resolve_type` (resolve type).
}
