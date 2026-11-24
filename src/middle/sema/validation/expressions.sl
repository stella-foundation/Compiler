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
import "std/mem.sl";
import "std/str.sl";

impl SemaContext {
	pub fn check_expr(
		self: *mut SemaContext,
		e: *mut front.ast.Expr,
		expected: *mut middle.types.StType
	) -> *mut middle.types.StType {
		if e == null {
			return self.tx.void_t;
		}
		let ty: *mut middle.types.StType = self.check_expr_inner(e, expected);
		e.sema_ty = ty cast *void;
		return ty;
	}

	/// Executes `check_expr_inner` (check expr inner).
	pub fn check_expr_inner(
		self: *mut SemaContext,
		e: *mut front.ast.Expr,
		expected: *mut middle.types.StType
	) -> *mut middle.types.StType {
		if e == null {
			return self.tx.void_t;
		}
		match e.kind {
			.IntLit => {
				if is_numeric_compatible(expected, false) {
					return expected;
				}
				return self.tx.sint(64);
			}
			.FloatLit => {
				if is_numeric_compatible(expected, true) {
					return expected;
				}
				return self.tx.float_ty(64);
			}
			.BoolLit => return self.tx.bool_t,
			.CharLit => return self.tx.uint(8),
			.StringLit => {
				if expected != null {
					let eu: *mut middle.types.StType = middle.types.underlying_type(expected);
					if eu != null && eu.kind == middle.types.TypeKind.Array {
						let eb: *mut middle.types.StType = middle.types.underlying_type(eu.base);
						if eb != null && eb.kind == middle.types.TypeKind.UInt && eb.width == 8 {
							let slen: usize = e.is_cstring ? (e.str_val.len + 1) : e.str_val.len;
							if slen == eu.array_len {
								e.sema_ty = expected cast *void;
								return expected;
							}
						}
					}
				}
				if e.is_cstring {
					return self.tx.pointer(self.tx.uint(8), false, false);
				}
				return self.tx.slice(self.tx.uint(8), false, false);
			}
			.NullLit => {
				if expected != null && self.tx.is_pointer(expected) {
					return expected;
				}
				return self.tx.pointer(self.tx.void_t, false, false);
			}
			.DefineRef => return self.tx.bool_t,
			.SrcFile | .SrcFn => return self.tx.slice(self.tx.uint(8), false, false),
			.SrcLine | .SrcColumn => return self.tx.usize_t,
			.SrcEmbed => {
				if e.args.len != 1 || e.args.data[0] == null {
					front.log.report(
						front.log.Level.Error,
						e.loc,
						"@src.embed expects one file path argument",
						front.log.DiagCode.InvalidCall
					);
					return self.tx.poison_t;
				}
				let mut rel: []u8 = "";
				let mut base_file: []u8 = e.loc.file;
				if e.args.data[0].kind == front.ast.ExprKind.StringLit
					&& !e.args.data[0].is_cstring {
					rel = e.args.data[0].str_val;
				} else if e.args.data[0].kind == front.ast.ExprKind.Ident && e.args.data[0].path.len
					== 1 {
					let psym: *middle.symbol.Symbol = self.scopes.lookup(
						e.args.data[0].path.data[0]
					);
					if psym != null && psym.comptime_str_val.len > 0 {
						rel = psym.comptime_str_val;
						base_file = psym.loc.file;
					} else {
						front.log.report(
							front.log.Level.Error,
							e.loc,
							"@src.embed path must be a string literal",
							front.log.DiagCode.InvalidCall
						);
						return self.tx.poison_t;
					}
				} else {
					front.log.report(
						front.log.Level.Error,
						e.loc,
						"@src.embed path must be a string literal",
						front.log.DiagCode.InvalidCall
					);
					return self.tx.poison_t;
				}
				if rel.len == 0 {
					front.log.report(
						front.log.Level.Error,
						e.loc,
						"@src.embed path must not be empty",
						front.log.DiagCode.InvalidCall
					);
					return self.tx.poison_t;
				}
				let full: []u8 = (rel.len > 0 && rel[0] == '/')
					? rel
					: middle.resolver.join_path(middle.resolver.dir_of(base_file), rel);
				let mut bytes: []u8 = "";
				if !middle.resolver.read_file_bytes(full, &bytes) {
					if middle.resolver.file_exists(full) {
						front.log.report(
							front.log.Level.Error,
							e.loc,
							"@src.embed: path is a directory",
							front.log.DiagCode.SourceNotFound
						);
					} else {
						front.log.report(
							front.log.Level.Error,
							e.loc,
							"@src.embed: file not found",
							front.log.DiagCode.SourceNotFound
						);
					}
					return self.tx.poison_t;
				}
				self.embed_files.push(full);
				e.str_val = bytes;
				e.is_cstring = false;
				if expected != null {
					let eu: *mut middle.types.StType = middle.types.underlying_type(expected);
					if eu != null && eu.kind == middle.types.TypeKind.Array {
						let eb: *mut middle.types.StType = middle.types.underlying_type(eu.base);
						if eb != null && eb.kind == middle.types.TypeKind.UInt && eb.width == 8
							&& bytes.len == eu.array_len {
							e.sema_ty = expected cast *void;
							return expected;
						}
					}
				}
				return self.tx.slice(self.tx.uint(8), false, false);
			}
			.Sizeof | .Alignof | .Bitsof => {
				if e.lhs != null {
					if e.lhs.kind == front.ast.ExprKind.TypeValue {
						e.lhs.sema_ty = self.resolve_type(e.lhs.layout_type) cast *void;
					} else if e.lhs.kind == front.ast.ExprKind.Ident && e.lhs.path.len == 1 {
						let subst_ty: *mut middle.types.StType =
							middle.sema.generics.lookup_generic_subst(
								&self.generic_subst,
								e.lhs.path.data[0]
							);
						if subst_ty != null {
							e.lhs.sema_ty = subst_ty cast *void;
						} else {
							let prim: *mut middle.types.StType = middle.types.prim_from_name(
								&self.tx,
								e.lhs.path.data[0]
							);
							if prim != null {
								e.lhs.sema_ty = prim cast *void;
							} else {
								let min_d: usize = self.current_mod_path != null ? 2 : 1;
								let mut sym: *mut middle.symbol.Symbol = self.scopes.lookup_local(
									e.lhs.path.data[0],
									min_d
								);
								if sym == null && self.current_mod_path != null {
									sym = self.lookup_in_mod(
										self.current_mod_path,
										e.lhs.path.data[0]
									);
								}
								if sym == null {
									sym = self.scopes.lookup(e.lhs.path.data[0]);
								}
								if sym != null && sym.ty != null {
									e.lhs.sema_ty = sym.ty cast *void;
								} else {
									self.check_expr(e.lhs, null);
								}
							}
						}
					} else {
						self.check_expr(e.lhs, null);
					}
				}
				if e.lhs != null && e.lhs.sema_ty != null {
					let sot: *mut middle.types.StType = e.lhs.sema_ty cast *mut middle.types.StType;
					let sou: *mut middle.types.StType = middle.types.underlying_type(sot);
					if sou != null && sou.is_opaque {
						if e.kind == front.ast.ExprKind.Sizeof {
							front.log.report(
								front.log.Level.Error,
								e.loc,
								"cannot compute @of.size for an incomplete or invalid type",
								front.log.DiagCode.TypeMismatch
							);
						} else if e.kind == front.ast.ExprKind.Alignof {
							front.log.report(
								front.log.Level.Error,
								e.loc,
								"cannot compute @of.align for an incomplete or invalid type",
								front.log.DiagCode.TypeMismatch
							);
						}
					}
				}
				return self.tx.usize_t;
			}
			.DiagWarn | .DiagErr => {
				let is_err: bool = e.kind == front.ast.ExprKind.DiagErr;
				let mut msg: []u8 = "";
				let mut custom_code: []u8 = is_err ? "E_GENERAL" : "W_GENERAL";
				if e.args.len >= 2 {
					if e.args.data[0] != null && e.args.data[0].kind
						== front.ast.ExprKind.StringLit {
						custom_code = e.args.data[0].str_val;
					}
					if e.args.data[1] != null && e.args.data[1].kind
						== front.ast.ExprKind.StringLit {
						msg = e.args.data[1].str_val;
					}
				} else if e.args.len == 1 && e.args.data[0] != null && e.args.data[0].kind
					== front.ast.ExprKind.StringLit {
					msg = e.args.data[0].str_val;
				}
				let mut phase: front.log.Phase = front.log.Phase.Semantic;
				if (custom_code.len >= 9 && std.str.eq(custom_code[0..9], "E_TARGET_"))
					|| (custom_code.len >= 10 && std.str.eq(custom_code[0..10], "E_BACKEND_"))
					|| (custom_code.len >= 7 && std.str.eq(custom_code[0..7], "E_EMIT_")) {
					phase = front.log.Phase.Backend;
				} else if custom_code.len >= 7 && std.str.eq(custom_code[0..7], "E_LINK_") {
					phase = front.log.Phase.Linker;
				} else if custom_code.len >= 6 && std.str.eq(custom_code[0..6], "E_CLI_") {
					phase = front.log.Phase.Cli;
				}
				let mut dloc: front.log.SourceLoc = e.loc;
				dloc.length = is_err ? 9 : 10;
				front.log.report_custom(
					is_err ? front.log.Level.Error : front.log.Level.Warning,
					dloc,
					msg,
					custom_code,
					phase
				);
				return self.tx.void_t;
			}
			.VaStart => {
				if e.args.len > 0 {
					let aty: *mut middle.types.StType = self.check_expr(e.args.data[0], null);
					let au: *mut middle.types.StType = middle.types.underlying_type(aty);
					let mut asym: *middle.symbol.Symbol = null;
					if e.args.data[0] != null && e.args.data[0].kind == front.ast.ExprKind.Ident
						&& e.args.data[0].path.len == 1 {
						asym = self.scopes.lookup(e.args.data[0].path.data[0]);
					}
					if au == null || au.kind != middle.types.TypeKind.VaList {
						front.log.report(
							front.log.Level.Error,
							e.loc,
							"@va.start destination must be a local @va.list variable",
							front.log.DiagCode.TypeMismatch
						);
					} else if asym != null && !asym.is_mutable {
						let kstr: []u8 = asym.kind == middle.symbol.SymKind.Param ? "parameter"
							: "binding";
						let mut mb: [160]u8;
						let mut mp: usize = 0;
						put_str_buf(&mb[0], &mp, 160, "@va.start cannot mutate immutable ");
						put_str_buf(&mb[0], &mp, 160, kstr);
						put_str_buf(&mb[0], &mp, 160, " `");
						put_str_buf(&mb[0], &mp, 160, asym.simple);
						put_str_buf(&mb[0], &mp, 160, "`");
						let mut nb: [64]u8;
						let mut np: usize = 0;
						put_str_buf(&nb[0], &np, 64, kstr);
						put_str_buf(&nb[0], &np, 64, " declared here");
						let mut fb: [96]u8;
						let mut fp: usize = 0;
						put_str_buf(&fb[0], &fp, 96, "replace with `mut ");
						put_str_buf(&fb[0], &fp, 96, asym.simple);
						put_str_buf(&fb[0], &fp, 96, "`");
						let mut rb: [64]u8;
						let mut rp: usize = 0;
						put_str_buf(&rb[0], &rp, 64, "mut ");
						put_str_buf(&rb[0], &rp, 64, asym.simple);
						let mut floc: front.log.SourceLoc = asym.loc;
						floc.length = asym.simple.len cast i32;
						let diag: front.log.Diagnostic = {
							.level =
								front.log.Level.Error, .code =
									front.log.DiagCode.ImmutableAssignment, .custom_code = "",
							.message = mb[0..mp], .primary = front.log.make_span(e.loc), .help = "",
							.fixit_msg =
								fb[0..fp], .fixit_repl =
									rb[0..rp], .fixit_span = front.log.make_span(floc),
							.note_msg =
								nb[0..np], .note_loc = asym.loc, .phase = front.log.Phase.Semantic
						};
						front.log.emit(diag);
					} else if asym != null && asym.kind == middle.symbol.SymKind.Param {
						front.log.report(
							front.log.Level.Error,
							e.loc,
							"@va.start destination must be a local @va.list variable",
							front.log.DiagCode.TypeMismatch
						);
					}
				}
				return self.tx.void_t;
			}
			.VaCopy => {
				if e.args.len > 0 {
					let dty: *mut middle.types.StType = self.check_expr(e.args.data[0], null);
					let du: *mut middle.types.StType = middle.types.underlying_type(dty);
					let mut asym: *middle.symbol.Symbol = null;
					if e.args.data[0] != null && e.args.data[0].kind == front.ast.ExprKind.Ident
						&& e.args.data[0].path.len == 1 {
						asym = self.scopes.lookup(e.args.data[0].path.data[0]);
					}
					if du == null || du.kind != middle.types.TypeKind.VaList {
						front.log.report(
							front.log.Level.Error,
							e.loc,
							"@va.copy destination must be a local @va.list variable",
							front.log.DiagCode.TypeMismatch
						);
					} else if asym != null && !asym.is_mutable {
						let kstr: []u8 = asym.kind == middle.symbol.SymKind.Param ? "parameter"
							: "binding";
						let mut mb: [160]u8;
						let mut mp: usize = 0;
						put_str_buf(&mb[0], &mp, 160, "@va.copy cannot mutate immutable ");
						put_str_buf(&mb[0], &mp, 160, kstr);
						put_str_buf(&mb[0], &mp, 160, " `");
						put_str_buf(&mb[0], &mp, 160, asym.simple);
						put_str_buf(&mb[0], &mp, 160, "`");
						let mut nb: [64]u8;
						let mut np: usize = 0;
						put_str_buf(&nb[0], &np, 64, kstr);
						put_str_buf(&nb[0], &np, 64, " declared here");
						let mut fb: [96]u8;
						let mut fp: usize = 0;
						put_str_buf(&fb[0], &fp, 96, "replace with `mut ");
						put_str_buf(&fb[0], &fp, 96, asym.simple);
						put_str_buf(&fb[0], &fp, 96, "`");
						let mut rb: [64]u8;
						let mut rp: usize = 0;
						put_str_buf(&rb[0], &rp, 64, "mut ");
						put_str_buf(&rb[0], &rp, 64, asym.simple);
						let mut floc: front.log.SourceLoc = asym.loc;
						floc.length = asym.simple.len cast i32;
						let diag: front.log.Diagnostic = {
							.level =
								front.log.Level.Error, .code =
									front.log.DiagCode.ImmutableAssignment, .custom_code = "",
							.message = mb[0..mp], .primary = front.log.make_span(e.loc), .help = "",
							.fixit_msg =
								fb[0..fp], .fixit_repl =
									rb[0..rp], .fixit_span = front.log.make_span(floc),
							.note_msg =
								nb[0..np], .note_loc = asym.loc, .phase = front.log.Phase.Semantic
						};
						front.log.emit(diag);
					} else if asym != null && asym.kind == middle.symbol.SymKind.Param {
						front.log.report(
							front.log.Level.Error,
							e.loc,
							"@va.copy destination must be a local @va.list variable",
							front.log.DiagCode.TypeMismatch
						);
					}
				}
				if e.args.len > 1 {
					self.check_expr(e.args.data[1], null);
				}
				return self.tx.void_t;
			}
			.VaEnd => {
				if e.args.len > 0 {
					let ety: *mut middle.types.StType = self.check_expr(e.args.data[0], null);
					let eu: *mut middle.types.StType = middle.types.underlying_type(ety);
					if (eu == null || eu.kind != middle.types.TypeKind.Pointer) && e.args.data[0]
						!= null && e.args.data[0].kind == front.ast.ExprKind.Ident
						&& e.args.data[0].path.len == 1 {
						let asym: *middle.symbol.Symbol = self.scopes.lookup(
							e.args.data[0].path.data[0]
						);
						if asym != null && !asym.is_mutable {
							let kstr: []u8 = asym.kind == middle.symbol.SymKind.Param ? "parameter"
								: "binding";
							let mut mb: [160]u8;
							let mut mp: usize = 0;
							put_str_buf(&mb[0], &mp, 160, "@va.end cannot mutate immutable ");
							put_str_buf(&mb[0], &mp, 160, kstr);
							put_str_buf(&mb[0], &mp, 160, " `");
							put_str_buf(&mb[0], &mp, 160, asym.simple);
							put_str_buf(&mb[0], &mp, 160, "`");
							let mut nb: [64]u8;
							let mut np: usize = 0;
							put_str_buf(&nb[0], &np, 64, kstr);
							put_str_buf(&nb[0], &np, 64, " declared here");
							let mut fb: [96]u8;
							let mut fp: usize = 0;
							put_str_buf(&fb[0], &fp, 96, "replace with `mut ");
							put_str_buf(&fb[0], &fp, 96, asym.simple);
							put_str_buf(&fb[0], &fp, 96, "`");
							let mut rb: [64]u8;
							let mut rp: usize = 0;
							put_str_buf(&rb[0], &rp, 64, "mut ");
							put_str_buf(&rb[0], &rp, 64, asym.simple);
							let mut floc: front.log.SourceLoc = asym.loc;
							floc.length = asym.simple.len cast i32;
							let diag: front.log.Diagnostic = {
								.level =
									front.log.Level.Error, .code =
										front.log.DiagCode.ImmutableAssignment, .custom_code = "",
								.message = mb[0..mp], .primary = front.log.make_span(
									e.loc
								), .help = "",
								.fixit_msg =
									fb[0..fp], .fixit_repl =
										rb[0..rp], .fixit_span = front.log.make_span(floc),
								.note_msg =
									nb[0..np], .note_loc =
										asym.loc, .phase = front.log.Phase.Semantic
							};
							front.log.emit(diag);
						}
					}
				}
				return self.tx.void_t;
			}
			.VaArg => {
				if e.args.len > 0 {
					let aty: *mut middle.types.StType = self.check_expr(e.args.data[0], null);
					let au: *mut middle.types.StType = middle.types.underlying_type(aty);
					if au != null && au.kind == middle.types.TypeKind.Pointer {
						if !au.is_mutable {
							front.log.report(
								front.log.Level.Error,
								e.loc,
								"@va.arg requires a mutable pointer to @va.list",
								front.log.DiagCode.TypeMismatch
							);
						}
					} else if e.args.data[0] != null && e.args.data[0].kind
						== front.ast.ExprKind.Ident && e.args.data[0].path.len == 1 {
						let asym: *middle.symbol.Symbol = self.scopes.lookup(
							e.args.data[0].path.data[0]
						);
						if asym != null && !asym.is_mutable {
							let kstr: []u8 = asym.kind == middle.symbol.SymKind.Param ? "parameter"
								: "binding";
							let mut mb: [160]u8;
							let mut mp: usize = 0;
							put_str_buf(&mb[0], &mp, 160, "@va.arg cannot mutate immutable ");
							put_str_buf(&mb[0], &mp, 160, kstr);
							put_str_buf(&mb[0], &mp, 160, " `");
							put_str_buf(&mb[0], &mp, 160, asym.simple);
							put_str_buf(&mb[0], &mp, 160, "`");
							let mut nb: [64]u8;
							let mut np: usize = 0;
							put_str_buf(&nb[0], &np, 64, kstr);
							put_str_buf(&nb[0], &np, 64, " declared here");
							let mut fb: [96]u8;
							let mut fp: usize = 0;
							put_str_buf(&fb[0], &fp, 96, "replace with `mut ");
							put_str_buf(&fb[0], &fp, 96, asym.simple);
							put_str_buf(&fb[0], &fp, 96, "`");
							let mut rb: [64]u8;
							let mut rp: usize = 0;
							put_str_buf(&rb[0], &rp, 64, "mut ");
							put_str_buf(&rb[0], &rp, 64, asym.simple);
							let mut floc: front.log.SourceLoc = asym.loc;
							floc.length = asym.simple.len cast i32;
							let diag: front.log.Diagnostic = {
								.level =
									front.log.Level.Error, .code =
										front.log.DiagCode.ImmutableAssignment, .custom_code = "",
								.message = mb[0..mp], .primary = front.log.make_span(
									e.loc
								), .help = "",
								.fixit_msg =
									fb[0..fp], .fixit_repl =
										rb[0..rp], .fixit_span = front.log.make_span(floc),
								.note_msg =
									nb[0..np], .note_loc =
										asym.loc, .phase = front.log.Phase.Semantic
							};
							front.log.emit(diag);
						}
					}
				}
				if e.va_arg_ty != null {
					return self.resolve_type(e.va_arg_ty);
				}
				return self.tx.void_t;
			}
			.Offsetof => {
				if e.lhs != null {
					if e.lhs.kind == front.ast.ExprKind.TypeValue && e.lhs.layout_type != null {
						e.lhs.sema_ty = self.resolve_type(e.lhs.layout_type) cast *void;
					} else {
						e.lhs.sema_ty = self.check_expr(e.lhs, null) cast *void;
					}
					if e.lhs.sema_ty != null {
						let oty: *mut middle.types.StType = e.lhs.sema_ty
							cast *mut middle.types.StType;
						let ou: *mut middle.types.StType = middle.types.underlying_type(oty);
						if ou != null {
							if ou.is_opaque {
								front.log.report(
									front.log.Level.Error,
									e.loc,
									"cannot compute @of.offset for an incomplete or invalid type",
									front.log.DiagCode.TypeMismatch
								);
							} else if !self.in_imported_mod && ou.is_foreign
								&& (ou.kind == middle.types.TypeKind.Struct || ou.kind
								== middle.types.TypeKind.Union) {
								let fidx: isize = middle.types.field_index(ou, e.offsetof_member);
								if fidx >= 0 && (fidx cast usize) < ou.field_is_pub.len
									&& !ou.field_is_pub.data[fidx cast usize] {
									let mut tb: [64]u8;
									let tstr: []u8 = middle.types.format_type(ou, &tb[0], 64);
									let mut mb: [160]u8;
									let mut mp: usize = 0;
									put_str_buf(&mb[0], &mp, 160, "field `");
									put_str_buf(&mb[0], &mp, 160, e.offsetof_member);
									put_str_buf(&mb[0], &mp, 160, "` of `");
									put_str_buf(&mb[0], &mp, 160, tstr);
									put_str_buf(&mb[0], &mp, 160, "` is private");
									front.log.report(
										front.log.Level.Error,
										e.loc,
										mb[0..mp],
										front.log.DiagCode.PrivateMember
									);
								}
							}
						}
					}
				}
				return self.tx.usize_t;
			}
			.Ident => {
				if e.path.len == 1 {
					if std.str.eq(e.path.data[0], "Self") && self.current_self_ty != null {
						return self.current_self_ty;
					}
					let min_d: usize = self.current_mod_path != null ? 2 : 1;
					let local_sym: *mut middle.symbol.Symbol = self.scopes.lookup_local(
						e.path.data[0],
						min_d
					);
					if local_sym != null
						&& (local_sym.kind == middle.symbol.SymKind.Param || local_sym.kind
						== middle.symbol.SymKind.Var) {
						local_sym.used = true;
						if local_sym.ty != null {
							return local_sym.ty;
						}
					}
					if self.current_mod_path != null {
						let msym: *mut middle.symbol.Symbol = self.lookup_in_mod_or_parents(
							self.current_mod_path,
							e.path.data[0]
						);
						if msym != null && msym.ty != null {
							msym.used = true;
							e.sema_sym = msym cast *void;
							if e.generic_args.len > 0
								&& (msym.kind == middle.symbol.SymKind.Struct || msym.kind
								== middle.symbol.SymKind.Union || msym.kind
								== middle.symbol.SymKind.Enum) {
								return self.instantiate_generic_type(msym, &e.generic_args, e.loc);
							}
							return msym.ty;
						}
					}
					let sym: *mut middle.symbol.Symbol = self.scopes.lookup(e.path.data[0]);
					if sym != null && sym.ty != null {
						sym.used = true;
						if local_sym == null {
							e.sema_sym = sym cast *void;
						}
						if e.generic_args.len > 0
							&& (sym.kind == middle.symbol.SymKind.Struct || sym.kind
							== middle.symbol.SymKind.Union || sym.kind
							== middle.symbol.SymKind.Enum) {
							return self.instantiate_generic_type(sym, &e.generic_args, e.loc);
						}
						return sym.ty;
					}
					for let mut mi: usize = 0; mi < self.mod_names.len; mi += 1 {
						if std.str.eq(self.mod_names.data[mi], e.path.data[0]) {
							let mut mb: [160]u8;
							let mut mp: usize = 0;
							put_str_buf(&mb[0], &mp, 160, "module `");
							put_str_buf(&mb[0], &mp, 160, e.path.data[0]);
							put_str_buf(&mb[0], &mp, 160, "` cannot be used as a value");
							front.log.report_custom(
								front.log.Level.Error,
								e.loc,
								mb[0..mp],
								"E_INVALID_EXPR",
								front.log.Phase.Semantic
							);
							return self.tx.poison_t;
						}
					}
					let mut mb: [160]u8;
					let mut mp: usize = 0;
					put_str_buf(&mb[0], &mp, 160, "undefined identifier `");
					put_str_buf(&mb[0], &mp, 160, e.path.data[0]);
					put_str_buf(&mb[0], &mp, 160, "`");
					let mut best: []u8 = "";
					let mut best_d: usize = 3;
					if !std.str.eq(e.path.data[0], "_") {
						for let mut si: usize = 0; si < self.scopes.scopes.len; si += 1 {
							let sc: *middle.symbol.Scope = self.scopes.scopes.data[si];
							if sc == null {
								continue;
							}
							for let mut sj: usize = 0; sj < sc.entries.len; sj += 1 {
								let cand: *middle.symbol.Symbol = sc.entries.data[sj];
								if cand != null && cand.simple.len > 0 {
									let d: usize = front.log.levenshtein(
										e.path.data[0],
										cand.simple
									);
									if d < best_d {
										best_d = d;
										best = cand.simple;
									}
								}
							}
						}
					}
					if best.len > 0 {
						let mut hb: [128]u8;
						let mut hp: usize = 0;
						put_str_buf(&hb[0], &hp, 128, "did you mean `");
						put_str_buf(&hb[0], &hp, 128, best);
						put_str_buf(&hb[0], &hp, 128, "`?");
						let mut fb: [128]u8;
						let mut fp: usize = 0;
						put_str_buf(&fb[0], &fp, 128, "replace with `");
						put_str_buf(&fb[0], &fp, 128, best);
						put_str_buf(&fb[0], &fp, 128, "`");
						front.log.report_with_help(
							front.log.Level.Error,
							e.loc,
							mb[0..mp],
							front.log.DiagCode.UndefinedName,
							hb[0..hp],
							fb[0..fp],
							best
						);
					} else {
						front.log.report(
							front.log.Level.Error,
							e.loc,
							mb[0..mp],
							front.log.DiagCode.UndefinedName
						);
					}
					return self.tx.poison_t;
				}
				let qsym: *mut middle.symbol.Symbol = self.lookup_qualified(&e.path, e.path.len);
				if qsym != null && qsym.ty != null {
					e.sema_sym = qsym cast *void;
					return qsym.ty;
				}
				front.log.report(
					front.log.Level.Error,
					e.loc,
					"undefined identifier",
					front.log.DiagCode.UndefinedName
				);
				return self.tx.poison_t;
			}
			.EnumMember => {
				if expected != null {
					let u: *mut middle.types.StType = middle.types.underlying_type(expected);
					if u != null && u.kind == middle.types.TypeKind.Enum {
						if middle.types.field_index(u, e.member) >= 0 {
							return expected;
						}
						front.log.report(
							front.log.Level.Error,
							e.loc,
							"unknown enum member",
							front.log.DiagCode.UnknownMember
						);
						return self.tx.poison_t;
					}
				}
				return expected != null ? expected : self.tx.poison_t;
			}
			.AddrOf => {
				let inner: *mut middle.types.StType = self.check_expr(e.lhs, null);
				if middle.types.is_poison(inner) {
					return self.tx.poison_t;
				}
				let lval_mut: bool = is_assignable_lvalue(self, e.lhs);
				let mut_ptr: bool = (expected != null && self.tx.is_pointer(expected))
					? (middle.types.underlying_type(expected).is_mutable && lval_mut)
					: lval_mut;
				return self.tx.pointer(inner, mut_ptr, false);
			}
			.Deref => {
				let inner: *mut middle.types.StType = self.check_expr(e.lhs, null);
				if middle.types.is_poison(inner) {
					return self.tx.poison_t;
				}
				let u: *mut middle.types.StType = middle.types.underlying_type(inner);
				if u == null || u.kind != middle.types.TypeKind.Pointer {
					front.log.report(
						front.log.Level.Error,
						e.loc,
						"cannot dereference non-pointer type",
						front.log.DiagCode.TypeMismatch
					);
					return self.tx.poison_t;
				}
				let bu: *mut middle.types.StType = middle.types.underlying_type(u.base);
				if bu != null && (bu.kind == middle.types.TypeKind.Void || bu.is_opaque) {
					let mut tb: [64]u8;
					let tstr: []u8 = middle.types.format_type(bu, &tb[0], 64);
					let mut mb: [160]u8;
					let mut mp: usize = 0;
					put_str_buf(
						&mb[0],
						&mp,
						160,
						"cannot dereference pointer to incomplete type `"
					);
					put_str_buf(&mb[0], &mp, 160, tstr);
					put_str_buf(&mb[0], &mp, 160, "`");
					front.log.report(
						front.log.Level.Error,
						e.loc,
						mb[0..mp],
						front.log.DiagCode.TypeMismatch
					);
					return self.tx.poison_t;
				}
				return u.base;
			}
			.Unary => {
				let inner: *mut middle.types.StType = self.check_expr(e.lhs, expected);
				if middle.types.is_poison(inner) {
					return self.tx.poison_t;
				}
				if std.str.eq(e.unary_op, "!") {
					if middle.types.underlying_type(inner).kind != middle.types.TypeKind.Bool {
						front.log.report(
							front.log.Level.Error,
							e.loc,
							"logical '!' requires bool operand",
							front.log.DiagCode.TypeMismatch
						);
						return self.tx.poison_t;
					}
					return self.tx.bool_t;
				}
				if std.str.eq(e.unary_op, "~") {
					if !self.tx.is_int_like(inner) {
						front.log.report(
							front.log.Level.Error,
							e.loc,
							"bitwise '~' requires integer operand",
							front.log.DiagCode.TypeMismatch
						);
						return self.tx.poison_t;
					}
					return inner;
				}
				if !self.tx.is_arith(inner) {
					front.log.report(
						front.log.Level.Error,
						e.loc,
						"unary '-' requires numeric operand",
						front.log.DiagCode.TypeMismatch
					);
					return self.tx.poison_t;
				}
				return inner;
			}
			.Binary => {
				let mut lt: *mut middle.types.StType = self.check_expr(e.lhs, expected);
				let mut rt: *mut middle.types.StType = self.check_expr(e.rhs, lt);
				if expected == null && e.lhs != null
					&& (e.lhs.kind == front.ast.ExprKind.IntLit || e.lhs.kind
					== front.ast.ExprKind.FloatLit) {
					rt = self.check_expr(e.rhs, null);
					lt = self.check_expr(e.lhs, rt);
				}
				if middle.types.is_poison(lt) || middle.types.is_poison(rt) {
					return self.tx.poison_t;
				}
				match e.op {
					.LogicalAnd | .LogicalOr => {
						if middle.types.underlying_type(lt).kind != middle.types.TypeKind.Bool
							|| middle.types.underlying_type(rt).kind != middle.types.TypeKind.Bool {
							front.log.report(
								front.log.Level.Error,
								e.loc,
								"logical operator requires bool operands",
								front.log.DiagCode.TypeMismatch
							);
							return self.tx.poison_t;
						}
						return self.tx.bool_t;
					}
					.Eq | .Ne | .Lt | .Le | .Gt | .Ge => {
						if !middle.types.eq_type(lt, rt) {
							front.log.report(
								front.log.Level.Error,
								e.loc,
								"comparison operands must have identical types",
								front.log.DiagCode.TypeMismatch
							);
							return self.tx.poison_t;
						}
						let lu: *mut middle.types.StType = middle.types.underlying_type(lt);
						if lu != null
							&& (lu.kind == middle.types.TypeKind.Slice || lu.kind
							== middle.types.TypeKind.Struct || lu.kind
							== middle.types.TypeKind.Union || lu.kind == middle.types.TypeKind.Array
							|| (lu.kind == middle.types.TypeKind.Enum && lu.is_tagged_enum)) {
							let mut mb: [128]u8;
							let mut mp: usize = 0;
							put_str_buf(
								&mb[0],
								&mp,
								128,
								"comparison operator cannot be applied to "
							);
							put_str_buf(&mb[0], &mp, 128, "aggregate, slice, or tagged enum types");
							front.log.report(
								front.log.Level.Error,
								e.loc,
								(&mb[0])[0..mp],
								front.log.DiagCode.TypeMismatch
							);
							return self.tx.poison_t;
						}
						return self.tx.bool_t;
					}
					.Add | .Sub | .Mul | .Div | .Mod | .BitAnd | .BitOr | .BitXor | .Shl | .Shr => {
						let lu: *mut middle.types.StType = middle.types.underlying_type(lt);
						let ru: *mut middle.types.StType = middle.types.underlying_type(rt);
						if (e.op == .Add || e.op == .Sub)
							&& lu != null && lu.kind == middle.types.TypeKind.Pointer
							&& ru != null
							&& (ru.kind == middle.types.TypeKind.UInt || ru.kind
							== middle.types.TypeKind.SInt) {
							return lt;
						}
						if e.op == .Sub
							&& lu != null && lu.kind == middle.types.TypeKind.Pointer
							&& ru != null && ru.kind == middle.types.TypeKind.Pointer {
							return self.tx.isize_t;
						}
						if !middle.types.eq_type(lt, rt) {
							front.log.report(
								front.log.Level.Error,
								e.loc,
								"binary operator requires operands of the same type",
								front.log.DiagCode.TypeMismatch
							);
							return self.tx.poison_t;
						}
						if (e.op == .Add || e.op == .Sub || e.op == .Mul)
							&& (e.op_variant == front.token.OpVariant.Wrap || e.op_variant
							== front.token.OpVariant.Sat) {
							if lu == null
								|| (lu.kind != middle.types.TypeKind.UInt && lu.kind
								!= middle.types.TypeKind.SInt) {
								front.log.report(
									front.log.Level.Error,
									e.loc,
									"operator `+%` requires integer operands",
									front.log.DiagCode.TypeMismatch
								);
								return self.tx.poison_t;
							}
						}
						if (e.op == .Add || e.op == .Sub || e.op == .Mul || e.op == .Div || e.op
							== .Mod)
							&& !self.tx.is_arith(lt) {
							front.log.report(
								front.log.Level.Error,
								e.loc,
								"arithmetic operator requires numeric operands",
								front.log.DiagCode.TypeMismatch
							);
							return self.tx.poison_t;
						}
						if (e.op == .Div || e.op == .Mod) && e.rhs != null && e.rhs.kind
							== front.ast.ExprKind.IntLit && e.rhs.int_val == 0 {
							front.log.report(
								front.log.Level.Error,
								e.loc,
								e.op == .Div ? "division by zero" : "modulo by zero",
								front.log.DiagCode.General
							);
						}
						if (e.op == .Shl || e.op == .Shr) && e.rhs != null && lu != null {
							let is_neg_sh: bool = e.rhs.kind == front.ast.ExprKind.Unary
								&& std.str.eq(e.rhs.unary_op, "-") && e.rhs.lhs != null
								&& e.rhs.lhs.kind == front.ast.ExprKind.IntLit;
							let is_big_sh: bool = e.rhs.kind == front.ast.ExprKind.IntLit
								&& (e.rhs.int_val >= (lu.width cast u64));
							if is_neg_sh || is_big_sh {
								let mut mb: [128]u8;
								let mut mp: usize = 0;
								put_str_buf(&mb[0], &mp, 128, "shift count out of bounds for ");
								put_u64_buf(&mb[0], &mp, 128, lu.width cast u64);
								put_str_buf(&mb[0], &mp, 128, "-bit operand");
								front.log.report(
									front.log.Level.Error,
									e.loc,
									mb[0..mp],
									front.log.DiagCode.General
								);
							}
						}
						return lt;
					}
				}
			}
			.Assign => {
				if !is_assignable_lvalue(self, e.lhs) {
					if e.lhs != null && e.lhs.kind == front.ast.ExprKind.Ident && e.lhs.path.len
						== 1 {
						let asym: *middle.symbol.Symbol = self.scopes.lookup(e.lhs.path.data[0]);
						if asym != null && asym.kind == middle.symbol.SymKind.Param {
							let mut mb: [160]u8;
							let mut mp: usize = 0;
							put_str_buf(&mb[0], &mp, 160, "cannot assign to immutable parameter `");
							put_str_buf(&mb[0], &mp, 160, e.lhs.path.data[0]);
							put_str_buf(&mb[0], &mp, 160, "`");
							let mut fb: [128]u8;
							let mut fp: usize = 0;
							put_str_buf(&fb[0], &fp, 128, "replace with `mut ");
							put_str_buf(&fb[0], &fp, 128, e.lhs.path.data[0]);
							put_str_buf(&fb[0], &fp, 128, "`");
							let mut rb: [96]u8;
							let mut rp: usize = 0;
							put_str_buf(&rb[0], &rp, 96, "mut ");
							put_str_buf(&rb[0], &rp, 96, e.lhs.path.data[0]);
							let diag: front.log.Diagnostic = {
								.level = front.log.Level.Error,
								.code = front.log.DiagCode.ImmutableAssignment,
								.custom_code = "",
								.message = mb[0..mp],
								.primary = front.log.make_span(e.loc),
								.help = "",
								.fixit_msg = fb[0..fp],
								.fixit_repl = rb[0..rp],
								.fixit_span = front.log.make_span(asym.loc),
								.note_msg = "parameter declared here",
								.note_loc = asym.loc,
								.phase = front.log.Phase.Semantic
							};
							front.log.emit(diag);
						} else {
							let mut mb: [160]u8;
							let mut mp: usize = 0;
							put_str_buf(&mb[0], &mp, 160, "cannot assign to immutable binding `");
							put_str_buf(&mb[0], &mp, 160, e.lhs.path.data[0]);
							put_str_buf(&mb[0], &mp, 160, "`");
							front.log.report(
								front.log.Level.Error,
								e.loc,
								mb[0..mp],
								front.log.DiagCode.ImmutableAssignment
							);
						}
					} else {
						front.log.report(
							front.log.Level.Error,
							e.loc,
							"left-hand side of assignment is not a valid lvalue",
							front.log.DiagCode.InvalidAssignment
						);
					}
				}
				let lt: *mut middle.types.StType = self.check_expr(e.lhs, null);
				let rt: *mut middle.types.StType = self.check_expr(e.rhs, lt);
				if e.is_compound_assignment && (e.op == .Div || e.op == .Mod) && e.rhs != null
					&& e.rhs.kind == front.ast.ExprKind.IntLit && e.rhs.int_val == 0 {
					front.log.report(
						front.log.Level.Error,
						e.loc,
						e.op == .Div ? "division by zero" : "modulo by zero",
						front.log.DiagCode.General
					);
				}
				if !middle.types.is_poison(lt) && !middle.types.is_poison(rt)
					&& !middle.types.is_assignable_type(lt, rt) {
					front.log.report(
						front.log.Level.Error,
						e.loc,
						"assignment type mismatch",
						front.log.DiagCode.TypeMismatch
					);
				}
				return lt;
			}
			.Conditional => {
				let ct: *mut middle.types.StType = self.check_expr(e.condition, self.tx.bool_t);
				if !middle.types.is_poison(ct) && middle.types.underlying_type(ct).kind
					!= middle.types.TypeKind.Bool {
					front.log.report(
						front.log.Level.Error,
						e.loc,
						"ternary condition must be bool",
						front.log.DiagCode.TypeMismatch
					);
				}
				let tt: *mut middle.types.StType = self.check_expr(e.then_expr, expected);
				let et: *mut middle.types.StType = self.check_expr(e.else_expr, tt);
				if !middle.types.is_poison(tt) && !middle.types.is_poison(et)
					&& !middle.types.eq_type(tt, et) {
					front.log.report(
						front.log.Level.Error,
						e.loc,
						"conditional expression arms must have identical types",
						front.log.DiagCode.TypeMismatch
					);
					return self.tx.poison_t;
				}
				return tt;
			}
			.Cast => {
				let src_ty: *mut middle.types.StType = self.check_expr(e.lhs, null);
				let dst_ty: *mut middle.types.StType = self.resolve_type(e.cast_type);
				let src_u: *mut middle.types.StType = middle.types.underlying_type(src_ty);
				let dst_u: *mut middle.types.StType = middle.types.underlying_type(dst_ty);
				if !e.is_bitcast && src_u != null && dst_u != null
					&& !middle.types.is_poison(src_ty) && !middle.types.is_poison(dst_ty) {
					let bad_bool: bool = (src_u.kind == middle.types.TypeKind.Bool
						&& (dst_u.kind == middle.types.TypeKind.Pointer || dst_u.kind
						== middle.types.TypeKind.Float || dst_u.kind == middle.types.TypeKind.Enum))
						|| (dst_u.kind == middle.types.TypeKind.Bool
						&& (src_u.kind == middle.types.TypeKind.Pointer || src_u.kind
						== middle.types.TypeKind.Float || src_u.kind
						== middle.types.TypeKind.Enum));
					if bad_bool {
						let mut sb: [64]u8;
						let mut db: [64]u8;
						let sstr: []u8 = middle.types.format_type(src_ty, &sb[0], 64);
						let dstr: []u8 = middle.types.format_type(dst_ty, &db[0], 64);
						let mut mb: [160]u8;
						let mut mp: usize = 0;
						put_str_buf(&mb[0], &mp, 160, "cannot cast between `");
						put_str_buf(&mb[0], &mp, 160, sstr);
						put_str_buf(&mb[0], &mp, 160, "` and `");
						put_str_buf(&mb[0], &mp, 160, dstr);
						put_str_buf(&mb[0], &mp, 160, "`");
						front.log.report(
							front.log.Level.Error,
							e.loc,
							mb[0..mp],
							front.log.DiagCode.TypeMismatch
						);
					}
					if src_u.kind == middle.types.TypeKind.Pointer && dst_u.kind
						== middle.types.TypeKind.Pointer && src_u.is_volatile
						&& !dst_u.is_volatile {
						front.log.report(
							front.log.Level.Error,
							e.loc,
							"cast cannot discard `volatile` qualifier",
							front.log.DiagCode.TypeMismatch
						);
					}
				}
				if !e.is_bitcast && dst_u != null && dst_u.kind == middle.types.TypeKind.Float {
					let fl: *front.ast.Expr = unwrap_float_lit(e.lhs);
					if fl != null && !fl.flt_lossy_ok && !is_exact_float_lit(fl.str_val) {
						let mut tb: [64]u8;
						let tstr: []u8 = middle.types.format_type(dst_ty, &tb[0], 64);
						let mut mb: [200]u8;
						let mut mp: usize = 0;
						put_str_buf(
							&mb[0],
							&mp,
							200,
							"floating-point literal value is not exactly representable in `"
						);
						put_str_buf(&mb[0], &mp, 200, tstr);
						put_str_buf(&mb[0], &mp, 200, "`; append `~` to agree to lossy rounding");
						front.log.report(
							front.log.Level.Error,
							e.loc,
							mb[0..mp],
							front.log.DiagCode.TypeMismatch
						);
					}
				}
				if src_u != null && !middle.types.is_poison(src_ty)
					&& ((src_u.kind == middle.types.TypeKind.Enum && src_u.is_tagged_enum)
					|| src_u.kind == middle.types.TypeKind.Struct || src_u.kind
					== middle.types.TypeKind.Union || src_u.kind == middle.types.TypeKind.Slice
					|| src_u.kind == middle.types.TypeKind.Array) {
					if e.is_bitcast {
						front.log.report(
							front.log.Level.Error,
							e.loc,
							"bitcast requires scalar types",
							front.log.DiagCode.TypeMismatch
						);
					} else {
						front.log.report(
							front.log.Level.Error,
							e.loc,
							"cast operand must be scalar",
							front.log.DiagCode.TypeMismatch
						);
					}
					return self.tx.poison_t;
				}
				if e.is_bitcast && !middle.types.is_poison(src_ty)
					&& !middle.types.is_poison(dst_ty) {
					let ptr_bytes: usize = (self.tx.pointer_width / 8) cast usize;
					if middle.types.type_size_bytes(src_ty, ptr_bytes)
						!= middle.types.type_size_bytes(dst_ty, ptr_bytes) {
						front.log.report(
							front.log.Level.Error,
							e.loc,
							"bitcast requires source and target types of equal size",
							front.log.DiagCode.TypeMismatch
						);
					}
				}
				return dst_ty;
			}
			.Call => {
				if e.lhs != null && e.lhs.kind == front.ast.ExprKind.Ident && e.lhs.path.len == 1 {
					let min_d: usize = self.current_mod_path != null ? 2 : 1;
					let mut sym: *mut middle.symbol.Symbol = self.scopes.lookup_local(
						e.lhs.path.data[0],
						min_d
					);
					if sym == null && self.current_mod_path != null {
						sym = self.lookup_in_mod(self.current_mod_path, e.lhs.path.data[0]);
					}
					if sym == null {
						sym = self.scopes.lookup(e.lhs.path.data[0]);
					}
					if sym != null && sym.kind == middle.symbol.SymKind.Fn && sym.fn_decl != null {
						// Check if multiple overloads exist in root scope (Concrete > Constrained
						// Generic > Unconstrained Generic)
						if self.scopes.scopes.len > 0 {
							let root_sc: *middle.symbol.Scope = self.scopes.scopes.data[0];
							let mut best_sym: *mut middle.symbol.Symbol = sym;
							let mut best_score: isize = -1;
							let mut arg_tys_probe: front.ast.PtrList<middle.types.StType> = {
								.data = null,
								.len = 0,
								.cap = 0
							};
							for let mut ai: usize = 0; ai < e.args.len; ai += 1 {
								arg_tys_probe.push(self.check_expr(e.args.data[ai], null));
							}
							for let mut si: usize = 0; si < root_sc.entries.len; si += 1 {
								let cand: *mut middle.symbol.Symbol = root_sc.entries.data[si];
								if cand != null && cand.kind == middle.symbol.SymKind.Fn
									&& cand.fn_decl != null
									&& std.str.eq(cand.simple, sym.simple)
									&& cand.fn_decl.params.len == e.args.len {
									if cand.fn_decl.generic_params.len == 0 && cand.ty != null {
										let cu: *mut middle.types.StType =
											middle.types.underlying_type(cand.ty);
										if cu != null && cu.kind == middle.types.TypeKind.Function {
											let mut ok_c: bool = true;
											for let mut pi: usize = 0; pi < e.args.len && pi
												< cu.fn_params.len; pi += 1 {
												if !middle.types.is_assignable_type(
													cu.fn_params.data[pi],
													arg_tys_probe.data[pi]
												) {
													ok_c = false;
													break;
												}
											}
											if ok_c && 100 > best_score {
												best_score = 100;
												best_sym = cand;
											}
										}
									} else if cand.fn_decl.generic_params.len > 0 {
										let mut ok_c: bool = true;
										let mut score: isize = 0;
										for let mut gi: usize = 0; gi
											< cand.fn_decl.generic_params.len; gi += 1 {
											let gp: *front.ast.GenericParam =
												&cand.fn_decl.generic_params.data[gi];
											let mut inf: *mut middle.types.StType = null;
											for let mut pi: usize = 0;
												pi < cand.fn_decl.params.len && pi
													< arg_tys_probe.len;
												pi += 1 {
												inf = SemaContext.infer_type_param(
													gp.name,
													cand.fn_decl.params.data[pi].ty,
													arg_tys_probe.data[pi]
												);
												if inf != null {
													break;
												}
											}
											let ts_ok: bool = inf == null
												|| middle.sema.generics.matches_type_set_constraint(
													gp,
													inf
												);
											if !ts_ok {
												ok_c = false;
												break;
											}
											if gp.type_set.len > 0 {
												score += 10;
											}
											if gp.trait_bounds.len > 0 {
												score += 10;
											}
										}
										if ok_c && score > best_score {
											best_score = score;
											best_sym = cand;
										}
									}
								}
							}
							arg_tys_probe.free_array();
							sym = best_sym;
						}
					}
					if sym != null && sym.kind == middle.symbol.SymKind.Fn && sym.fn_decl != null
						&& sym.fn_decl.generic_params.len > 0 {
						let isym: *mut middle.symbol.Symbol = self.instantiate_generic_fn(
							sym,
							&e.args,
							&e.lhs.generic_args
						);
						if isym != null && isym.ty != null {
							e.lhs.sema_sym = isym cast *void;
							e.lhs.sema_ty = isym.ty cast *void;
							let iu: *mut middle.types.StType = middle.types.underlying_type(
								isym.ty
							);
							if iu != null && iu.kind == middle.types.TypeKind.Function {
								for let mut i: usize = 0; i < e.args.len; i += 1 {
									let param_ty: *mut middle.types.StType = i < iu.fn_params.len
										? iu.fn_params.data[i] : null;
									let arg_ty: *mut middle.types.StType = self.check_expr(
										e.args.data[i],
										param_ty
									);
									if param_ty != null && !middle.types.is_poison(arg_ty)
										&& !middle.types.is_assignable_type(param_ty, arg_ty) {
										front.log.report(
											front.log.Level.Error,
											e.args.data[i].loc,
											"argument type mismatch",
											front.log.DiagCode.TypeMismatch
										);
									}
								}
								return iu.fn_ret;
							}
						}
					}
				}
				if e.lhs != null && e.lhs.kind == front.ast.ExprKind.EnumMember {
					if expected != null {
						let eu: *mut middle.types.StType = middle.types.underlying_type(expected);
						if eu != null && eu.kind == middle.types.TypeKind.Enum
							&& eu.is_tagged_enum {
							let vidx: isize = middle.types.field_index(eu, e.lhs.member);
							if vidx >= 0 {
								let vinfo: middle.types.EnumVariantInfo =
									eu.enum_variants.data[vidx cast usize];
								for let mut i: usize = 0; i < e.args.len; i += 1 {
									let pty: *mut middle.types.StType = i < vinfo.field_types.len
										? vinfo.field_types.data[i] : null;
									self.check_expr(e.args.data[i], pty);
								}
								e.lhs.sema_ty = expected cast *void;
								return expected;
							}
						}
					}
				}
				if e.lhs != null && e.lhs.kind == front.ast.ExprKind.Member {
					let mut chain: front.ast.ValList<[]u8> = { .data = null, .len = 0, .cap = 0 };
					let is_chain: bool = extract_member_chain(e.lhs, &chain);
					if is_chain && chain.len >= 2 && self.scopes.lookup(chain.data[0]) == null {
						let mut qsym: *mut middle.symbol.Symbol = self.lookup_qualified(
							&chain,
							chain.len
						);
						if qsym != null && qsym.kind == middle.symbol.SymKind.Fn && qsym.fn_decl
							!= null && qsym.fn_decl.generic_params.len > 0 {
							qsym = self.instantiate_generic_fn(qsym, &e.args, &e.lhs.generic_args);
						}
						if qsym != null && qsym.ty != null {
							let mut qu: *mut middle.types.StType = middle.types.underlying_type(
								qsym.ty
							);
							if qu != null && qu.kind == middle.types.TypeKind.Function && e.args.len
								== qu.fn_params.len {
								// Check if another overload in imported_syms matches arg types
								// better
								let mut exact_match: bool = true;
								for let mut ai: usize = 0; ai < e.args.len; ai += 1 {
									let aty: *mut middle.types.StType = self.check_expr(
										e.args.data[ai],
										qu.fn_params.data[ai]
									);
									if !middle.types.is_assignable_type(
										qu.fn_params.data[ai],
										aty
									) {
										exact_match = false;
										break;
									}
								}
								if !exact_match {
									let target_name: []u8 = chain.data[chain.len - 1];
									let mod_len: usize = chain.len - 1;
									for let mut si: usize = 0; si
										< self.imported_syms.len; si += 1 {
										let qs: QualifiedSym = self.imported_syms.data[si];
										if qs.sym != null && qs.sym.kind == middle.symbol.SymKind.Fn
											&& std.str.eq(qs.sym.simple, target_name)
											&& qs.mod_path.len == mod_len && qs.sym.ty != null {
											let mut mm: bool = true;
											for let mut mj: usize = 0; mj < mod_len; mj += 1 {
												if !std.str.eq(
													qs.mod_path.data[mj],
													chain.data[mj]
												) {
													mm = false;
													break;
												}
											}
											if mm {
												let cqu: *mut middle.types.StType =
													middle.types.underlying_type(qs.sym.ty);
												if cqu != null && cqu.kind
													== middle.types.TypeKind.Function
													&& cqu.fn_params.len == e.args.len {
													let mut ok_ov: bool = true;
													for let mut ai: usize = 0; ai
														< e.args.len; ai += 1 {
														let aty: *mut middle.types.StType =
															self.check_expr(
																e.args.data[ai],
																cqu.fn_params.data[ai]
															);
														if !middle.types.is_assignable_type(
															cqu.fn_params.data[ai],
															aty
														) {
															ok_ov = false;
															break;
														}
													}
													if ok_ov {
														qsym = qs.sym;
														qu = cqu;
														break;
													}
												}
											}
										}
									}
								}
							}
							chain.free_array();
							e.lhs.sema_sym = qsym cast *void;
							e.lhs.sema_ty = qsym.ty cast *void;
							if qu != null && qu.kind == middle.types.TypeKind.Function {
								if qsym.fn_decl != null && qsym.fn_decl.is_macro {
									for let mut i: usize = 0; i < e.args.len; i += 1 {
										self.check_expr(e.args.data[i], null);
									}
									if qsym.fn_decl.body != null {
										self.scopes.enter();
										let prev_ret: *mut middle.types.StType =
											self.current_ret_ty;
										self.current_ret_ty = qu.fn_ret;
										for let mut pi: usize = 0; pi
											< qsym.fn_decl.params.len; pi += 1 {
											let prm: front.ast.Param = qsym.fn_decl.params.data[pi];
											let mut psym: middle.symbol.Symbol =
												middle.symbol.make_symbol(
													middle.symbol.SymKind.Param,
													prm.name,
													prm.loc
												);
											psym.ty = pi < qu.fn_params.len ? qu.fn_params.data[pi]
												: self.tx.void_t;
											if pi < e.args.len && e.args.data[pi] != null
												&& e.args.data[pi].kind
												== front.ast.ExprKind.StringLit {
												psym.comptime_str_val = e.args.data[pi].str_val;
												psym.loc = e.args.data[pi].loc;
											}
											self.scopes.define(psym);
										}
										self.check_stmt(qsym.fn_decl.body);
										self.current_ret_ty = prev_ret;
										self.scopes.leave();
										if e.args.len > qsym.fn_decl.params.len {
											self.instantiate_variadic_mappers_stmt(
												qsym.fn_decl.body,
												e,
												qsym.fn_decl.params.len
											);
										}
									}
									return qu.fn_ret;
								}
								if (!qu.fn_variadic && e.args.len != qu.fn_params.len)
									|| (qu.fn_variadic && e.args.len < qu.fn_params.len) {
									front.log.report(
										front.log.Level.Error,
										e.loc,
										"wrong number of arguments in function call",
										front.log.DiagCode.InvalidCall
									);
									return qu.fn_ret;
								}
								for let mut i: usize = 0; i < e.args.len; i += 1 {
									let param_ty: *mut middle.types.StType = i < qu.fn_params.len
										? qu.fn_params.data[i] : null;
									let arg_ty: *mut middle.types.StType = self.check_expr(
										e.args.data[i],
										param_ty
									);
									if param_ty != null && !middle.types.is_poison(arg_ty)
										&& !middle.types.is_assignable_type(param_ty, arg_ty) {
										front.log.report(
											front.log.Level.Error,
											e.args.data[i].loc,
											"argument type mismatch",
											front.log.DiagCode.TypeMismatch
										);
									}
								}
								return qu.fn_ret;
							}
						}
					}
					chain.free_array();

					let recv_ty: *mut middle.types.StType = self.check_expr(e.lhs.lhs, null);
					if !middle.types.is_poison(recv_ty) {
						let mut base_u: *mut middle.types.StType = middle.types.underlying_type(
							recv_ty
						);
						if base_u != null && base_u.kind == middle.types.TypeKind.Enum
							&& base_u.is_tagged_enum {
							let vidx: isize = middle.types.field_index(base_u, e.lhs.member);
							if vidx >= 0 {
								let vinfo: middle.types.EnumVariantInfo =
									base_u.enum_variants.data[vidx cast usize];
								for let mut i: usize = 0; i < e.args.len; i += 1 {
									let pty: *mut middle.types.StType = i < vinfo.field_types.len
										? vinfo.field_types.data[i] : null;
									self.check_expr(e.args.data[i], pty);
								}
								e.lhs.sema_ty = recv_ty cast *void;
								return recv_ty;
							}
						}
						if base_u != null && base_u.kind == middle.types.TypeKind.Pointer {
							base_u = middle.types.underlying_type(base_u.base);
						}
						if base_u != null && base_u.generic_args.len == 0 && expected != null {
							let eu: *mut middle.types.StType = middle.types.underlying_type(
								expected
							);
							if eu != null && eu.generic_origin_name.len > 0
								&& std.str.eq(eu.generic_origin_name, base_u.name) {
								base_u = eu;
							}
						}
						let mut msym: *mut middle.symbol.Symbol = self.lookup_impl_method(
							base_u,
							e.lhs.member
						);
						if msym == null && base_u != null && base_u.generic_origin_name.len > 0
							&& e.lhs.generic_args.len > 0 {
							for let mut gi: usize = 0; gi < self.generic_impls.len && msym
								== null; gi += 1 {
								let ge: GenericImplEntry = self.generic_impls.data[gi];
								let imp: *front.ast.ImplDecl = ge.imp;
								if imp.target_type != null && imp.target_type.kind
									== front.ast.TypeRefKind.Named {
									let tname: []u8 = imp.target_type.path.len > 0
										? imp.target_type.path.data[imp.target_type.path.len - 1]
										: imp.target_type.name;
									if std.str.eq(tname, base_u.generic_origin_name) {
										for let mut mj: usize = 0; mj < imp.methods.len; mj += 1 {
											let m: *front.ast.FnDecl = imp.methods.data[mj];
											if std.str.eq(m.name, e.lhs.member)
												&& m.generic_params.len > 0 {
												let prev_len: usize = self.generic_subst.len;
												let prev_self: *mut middle.types.StType =
													self.current_self_ty;
												self.current_self_ty = base_u;
												let cnt: usize = imp.generic_params.len > 0
													? imp.generic_params.len
													: imp.target_type.generic_args.len;
												for let mut k: usize = 0; k < cnt && k
													< base_u.generic_args.len; k += 1 {
													let mut gname: []u8 = "";
													if imp.generic_params.len > 0 {
														gname = imp.generic_params.data[k].name;
													} else {
														let ga: *mut front.ast.TypeRef =
															imp.target_type.generic_args.data[k].ty;
														if ga != null && ga.path.len > 0 {
															gname = ga.path.data[0];
														}
													}
													self.generic_subst.push(
														make_type_subst(
															gname,
															base_u.generic_args.data[k]
														)
													);
												}
												let mut osym: middle.symbol.Symbol =
													middle.symbol.make_symbol(
														middle.symbol.SymKind.Fn,
														m.name,
														m.loc
													);
												osym.fn_decl = m;
												osym.mod_path = ge.mod_path;
												msym = self.instantiate_generic_fn(
													&osym,
													&e.args,
													&e.lhs.generic_args
												);
												self.current_self_ty = prev_self;
												self.generic_subst.len = prev_len;
												break;
											}
										}
									}
								}
							}
						}
						let mut used_ufcs: bool = false;
						if msym == null {
							let fidx_c: isize = (base_u != null
								&& (base_u.kind == middle.types.TypeKind.Struct || base_u.kind
								== middle.types.TypeKind.Union))
								? middle.types.field_index(base_u, e.lhs.member)
								: -1;
							let priv_field: bool = fidx_c >= 0 && !self.in_imported_mod
								&& base_u.is_foreign
								&& (fidx_c cast usize) < base_u.field_is_pub.len
								&& !base_u.field_is_pub.data[fidx_c cast usize];
							let has_field: bool = fidx_c >= 0 && !priv_field;
							if !has_field {
							// UFCS fallback: free function in current module or scope
							let mut ufsym: *mut middle.symbol.Symbol = self.current_mod_path != null
								? self.lookup_in_mod(self.current_mod_path, e.lhs.member)
								: null;
							if ufsym == null {
								ufsym = self.scopes.lookup(e.lhs.member);
							}
							if ufsym == null && priv_field {
								let mut tb: [64]u8;
								let tstr: []u8 = middle.types.format_type(base_u, &tb[0], 64);
								let mut mb: [160]u8;
								let mut mp: usize = 0;
								put_str_buf(&mb[0], &mp, 160, "field `");
								put_str_buf(&mb[0], &mp, 160, e.lhs.member);
								put_str_buf(&mb[0], &mp, 160, "` of `");
								put_str_buf(&mb[0], &mp, 160, tstr);
								put_str_buf(&mb[0], &mp, 160, "` is private");
								front.log.report(
									front.log.Level.Error,
									e.loc,
									mb[0..mp],
									front.log.DiagCode.PrivateMember
								);
								return self.tx.poison_t;
							}
							if ufsym != null && ufsym.kind == middle.symbol.SymKind.Fn {
								// Check for UFCS ambiguity among overloads in current scopes
								let mut match_cnt: usize = 0;
								for let mut si: usize = 0; si < self.scopes.scopes.len; si += 1 {
									let sc: *middle.symbol.Scope = self.scopes.scopes.data[si];
									if sc == null {
										continue;
									}
									for let mut sj: usize = 0; sj < sc.entries.len; sj += 1 {
										let cand: *middle.symbol.Symbol = sc.entries.data[sj];
										if cand != null && cand.kind == middle.symbol.SymKind.Fn
											&& std.str.eq(cand.simple, e.lhs.member) && cand.ty
											!= null {
											let cu: *mut middle.types.StType =
												middle.types.underlying_type(cand.ty);
											if cu != null && cu.kind
												== middle.types.TypeKind.Function
												&& cu.fn_params.len == e.args.len + 1 {
												match_cnt += 1;
											}
										}
									}
								}
								if match_cnt >= 2 {
									let mut all_untyped: bool = e.args.len > 0;
									for let mut ai: usize = 0; ai < e.args.len; ai += 1 {
										if e.args.data[ai] == null
											|| (e.args.data[ai].kind != front.ast.ExprKind.IntLit
											&& e.args.data[ai].kind
											!= front.ast.ExprKind.FloatLit) {
											all_untyped = false;
											break;
										}
									}
									if all_untyped {
										let mut mb: [160]u8;
										let mut mp: usize = 0;
										put_str_buf(
											&mb[0],
											&mp,
											160,
											"ambiguous call to overloaded function `"
										);
										put_str_buf(&mb[0], &mp, 160, e.lhs.member);
										put_str_buf(&mb[0], &mp, 160, "` via UFCS");
										front.log.report(
											front.log.Level.Error,
											e.loc,
											mb[0..mp],
											front.log.DiagCode.InvalidCall
										);
										return self.tx.poison_t;
									}
								}
								if ufsym.fn_decl != null && ufsym.fn_decl.generic_params.len > 0 {
									let mut all_args: front.ast.PtrList<front.ast.Expr> = {
										.data = null,
										.len = 0,
										.cap = 0
									};
									all_args.push(e.lhs.lhs);
									for let mut ai: usize = 0; ai < e.args.len; ai += 1 {
										all_args.push(e.args.data[ai]);
									}
									ufsym = self.instantiate_generic_fn(
										ufsym,
										&all_args,
										&e.lhs.generic_args
									);
									all_args.free_array();
								}
								msym = ufsym;
								used_ufcs = true;
							} else if base_u != null
								&& (base_u.kind == middle.types.TypeKind.Struct || base_u.kind
								== middle.types.TypeKind.Union || base_u.kind
								== middle.types.TypeKind.Enum) {
								let mut tb: [64]u8;
								let tstr: []u8 = middle.types.format_type(base_u, &tb[0], 64);
								let mut mb: [200]u8;
								let mut mp: usize = 0;
								put_str_buf(&mb[0], &mp, 200, "no field or method `");
								put_str_buf(&mb[0], &mp, 200, e.lhs.member);
								put_str_buf(&mb[0], &mp, 200, "` found for type `");
								put_str_buf(&mb[0], &mp, 200, tstr);
								put_str_buf(&mb[0], &mp, 200, "`");
								front.log.report(
									front.log.Level.Error,
									e.loc,
									mb[0..mp],
									front.log.DiagCode.InvalidCall
								);
								return self.tx.poison_t;
							}
							}
						}
						if msym != null && msym.ty != null {
							let mu: *mut middle.types.StType = middle.types.underlying_type(
								msym.ty
							);
							if mu != null && mu.kind == middle.types.TypeKind.Function {
								let mut is_assoc: bool = false;
								if e.lhs.lhs.kind == front.ast.ExprKind.Ident && e.lhs.lhs.path.len
									== 1 && std.str.eq(e.lhs.lhs.path.data[0], "Self") {
									is_assoc = true;
								}
								if e.lhs.lhs.sema_sym != null {
									let rsym: *middle.symbol.Symbol = e.lhs.lhs.sema_sym
										cast *middle.symbol.Symbol;
									if rsym.kind == middle.symbol.SymKind.Struct || rsym.kind
										== middle.symbol.SymKind.Union
										|| rsym.kind == middle.symbol.SymKind.Enum || rsym.kind
										== middle.symbol.SymKind.TypeBinding {
										is_assoc = true;
									}
								}
								if used_ufcs && !is_assoc && mu.fn_params.len > 0 {
									let p0u: *mut middle.types.StType =
										middle.types.underlying_type(mu.fn_params.data[0]);
									let rcv_u: *mut middle.types.StType =
										middle.types.underlying_type(recv_ty);
									if p0u != null && p0u.kind == middle.types.TypeKind.Pointer
										&& (rcv_u == null || rcv_u.kind
										!= middle.types.TypeKind.Pointer) {
										let is_lval_kind: bool = e.lhs.lhs.kind
											== front.ast.ExprKind.Ident || e.lhs.lhs.kind
											== front.ast.ExprKind.Member
											|| e.lhs.lhs.kind == front.ast.ExprKind.Deref
											|| e.lhs.lhs.kind == front.ast.ExprKind.Index;
										if !is_lval_kind {
											let mut mb: [160]u8;
											let mut mp: usize = 0;
											put_str_buf(
												&mb[0],
												&mp,
												160,
												"no matching function for UFCS call to `"
											);
											put_str_buf(&mb[0], &mp, 160, e.lhs.member);
											put_str_buf(&mb[0], &mp, 160, "`");
											let mut nb: [128]u8;
											let mut np: usize = 0;
											put_str_buf(
												&nb[0],
												&np,
												128,
												"receiver is an rvalue temporary and "
											);
											put_str_buf(
												&nb[0],
												&np,
												128,
												"cannot be auto-referenced"
											);
											front.log.report_with_note(
												front.log.Level.Error,
												e.loc,
												mb[0..mp],
												front.log.DiagCode.InvalidCall,
												nb[0..np],
												msym.loc
											);
											return self.tx.poison_t;
										}
										if p0u.is_mutable
											&& !is_assignable_lvalue(self, e.lhs.lhs) {
											let mut mb: [160]u8;
											let mut mp: usize = 0;
											put_str_buf(
												&mb[0],
												&mp,
												160,
												"no matching function for UFCS call to `"
											);
											put_str_buf(&mb[0], &mp, 160, e.lhs.member);
											put_str_buf(&mb[0], &mp, 160, "`");
											let mut nb: [128]u8;
											let mut np: usize = 0;
											put_str_buf(
												&nb[0],
												&np,
												128,
												"receiver is immutable and cannot be "
											);
											put_str_buf(
												&nb[0],
												&np,
												128,
												"passed to mutable pointer parameter"
											);
											front.log.report_with_note(
												front.log.Level.Error,
												e.loc,
												mb[0..mp],
												front.log.DiagCode.InvalidCall,
												nb[0..np],
												msym.loc
											);
											return self.tx.poison_t;
										}
									}
								}
								e.is_method_call = !is_assoc;
								e.lhs.sema_sym = msym cast *void;
								e.lhs.sema_ty = msym.ty cast *void;
								let param_off: usize = is_assoc ? 0 : 1;
								let expected_args: usize = mu.fn_params.len >= param_off
									? (mu.fn_params.len - param_off) : 0;
								if (!mu.fn_variadic && e.args.len != expected_args)
									|| (mu.fn_variadic && e.args.len < expected_args) {
									front.log.report(
										front.log.Level.Error,
										e.loc,
										"wrong number of arguments in method call",
										front.log.DiagCode.InvalidCall
									);
									return mu.fn_ret;
								}
								for let mut i: usize = 0; i < e.args.len; i += 1 {
									let pidx: usize = i + param_off;
									let param_ty: *mut middle.types.StType = pidx < mu.fn_params.len
										? mu.fn_params.data[pidx] : null;
									let arg_ty: *mut middle.types.StType = self.check_expr(
										e.args.data[i],
										param_ty
									);
									if param_ty != null && !middle.types.is_poison(arg_ty)
										&& !middle.types.is_assignable_type(param_ty, arg_ty) {
										let pu: *mut middle.types.StType =
											middle.types.underlying_type(param_ty);
										let au: *mut middle.types.StType =
											middle.types.underlying_type(arg_ty);
										if pu != null && au != null && pu.kind
											== middle.types.TypeKind.Pointer && au.kind
											== middle.types.TypeKind.Pointer && pu.is_mutable
											&& !au.is_mutable {
											let mut tb: [64]u8;
											let tname: []u8 = middle.types.format_type(
												base_u,
												&tb[0],
												64
											);
											let mut ab: [64]u8;
											let mut pb: [64]u8;
											let astr: []u8 = middle.types.format_type(
												arg_ty,
												&ab[0],
												64
											);
											let pstr: []u8 = middle.types.format_type(
												param_ty,
												&pb[0],
												64
											);
											let mut mb: [200]u8;
											let mut mp: usize = 0;
											put_str_buf(
												&mb[0],
												&mp,
												200,
												"no matching public function for call to `"
											);
											put_str_buf(&mb[0], &mp, 200, tname);
											put_str_buf(&mb[0], &mp, 200, ".");
											put_str_buf(&mb[0], &mp, 200, e.lhs.member);
											put_str_buf(&mb[0], &mp, 200, "` with ");
											put_u64_buf(&mb[0], &mp, 200, e.args.len cast u64);
											put_str_buf(&mb[0], &mp, 200, " argument(s)");
											let mut nb: [240]u8;
											let mut np: usize = 0;
											put_str_buf(
												&nb[0],
												&np,
												240,
												"candidate function not viable: "
											);
											put_str_buf(
												&nb[0],
												&np,
												240,
												"cannot convert argument "
											);
											put_u64_buf(&nb[0], &np, 240, (i + 1) cast u64);
											put_str_buf(&nb[0], &np, 240, " from '");
											put_str_buf(&nb[0], &np, 240, astr);
											put_str_buf(&nb[0], &np, 240, "' to '");
											put_str_buf(&nb[0], &np, 240, pstr);
											put_str_buf(
												&nb[0],
												&np,
												240,
												"' (cannot convert immutable pointer "
											);
											put_str_buf(&nb[0], &np, 240, "to mutable pointer)");
											front.log.report_with_note(
												front.log.Level.Error,
												e.loc,
												mb[0..mp],
												front.log.DiagCode.InvalidCall,
												nb[0..np],
												msym.loc
											);
										} else {
											front.log.report(
												front.log.Level.Error,
												e.args.data[i].loc,
												"argument type mismatch",
												front.log.DiagCode.TypeMismatch
											);
										}
									}
								}
								return mu.fn_ret;
							}
						}
					}
				}
				let callee_ty: *mut middle.types.StType = self.check_expr(e.lhs, null);
				if middle.types.is_poison(callee_ty) {
					return self.tx.poison_t;
				}
				let u: *mut middle.types.StType = middle.types.underlying_type(callee_ty);
				if u == null || u.kind != middle.types.TypeKind.Function {
					front.log.report(
						front.log.Level.Error,
						e.loc,
						"call of non-function value",
						front.log.DiagCode.InvalidCall
					);
					return self.tx.poison_t;
				}
				if (!u.fn_variadic && e.args.len != u.fn_params.len)
					|| (u.fn_variadic && e.args.len < u.fn_params.len) {
					let cname: []u8 = (e.lhs != null && e.lhs.kind == front.ast.ExprKind.Ident
						&& e.lhs.path.len > 0)
						? e.lhs.path.data[e.lhs.path.len - 1] : "";
					let mut mb: [200]u8;
					let mut mp: usize = 0;
					put_str_buf(&mb[0], &mp, 200, "no matching public function for call to `");
					put_str_buf(&mb[0], &mp, 200, cname);
					put_str_buf(&mb[0], &mp, 200, "` with ");
					put_u64_buf(&mb[0], &mp, 200, e.args.len cast u64);
					put_str_buf(&mb[0], &mp, 200, " argument(s)");
					let mut nb: [200]u8;
					let mut np: usize = 0;
					put_str_buf(&nb[0], &np, 200, "candidate function not viable: expects ");
					put_u64_buf(&nb[0], &np, 200, u.fn_params.len cast u64);
					put_str_buf(&nb[0], &np, 200, " arguments, but ");
					put_u64_buf(&nb[0], &np, 200, e.args.len cast u64);
					put_str_buf(&nb[0], &np, 200, " were supplied");
					front.log.report_with_note(
						front.log.Level.Error,
						e.loc,
						mb[0..mp],
						front.log.DiagCode.InvalidCall,
						nb[0..np],
						e.loc
					);
					return u.fn_ret;
				}
				for let mut i: usize = 0; i < e.args.len; i += 1 {
					let param_ty: *mut middle.types.StType = i < u.fn_params.len
						? u.fn_params.data[i] : null;
					let arg_ty: *mut middle.types.StType = self.check_expr(
						e.args.data[i],
						param_ty
					);
					if param_ty != null {
						let pu: *mut middle.types.StType = middle.types.underlying_type(param_ty);
						if pu != null && pu.kind == middle.types.TypeKind.Float {
							let fl: *front.ast.Expr = unwrap_float_lit(e.args.data[i]);
							if fl != null && !fl.flt_lossy_ok && !is_exact_float_lit(fl.str_val) {
								let mut tb: [64]u8;
								let tstr: []u8 = middle.types.format_type(param_ty, &tb[0], 64);
								let cname: []u8 = (e.lhs != null && e.lhs.kind
									== front.ast.ExprKind.Ident && e.lhs.path.len > 0)
									? e.lhs.path.data[e.lhs.path.len - 1] : "";
								let mut mb: [220]u8;
								let mut mp: usize = 0;
								put_str_buf(&mb[0], &mp, 220, "argument ");
								put_u64_buf(&mb[0], &mp, 220, (i + 1) cast u64);
								put_str_buf(&mb[0], &mp, 220, " of call to `");
								put_str_buf(&mb[0], &mp, 220, cname);
								put_str_buf(
									&mb[0],
									&mp,
									220,
									"` has a value not exactly representable in `"
								);
								put_str_buf(&mb[0], &mp, 220, tstr);
								put_str_buf(
									&mb[0],
									&mp,
									220,
									"`; append `~` to agree to lossy rounding"
								);
								front.log.report(
									front.log.Level.Error,
									e.args.data[i].loc,
									mb[0..mp],
									front.log.DiagCode.TypeMismatch
								);
							}
						}
					}
					if param_ty != null && !middle.types.is_poison(arg_ty)
						&& !middle.types.is_assignable_type(param_ty, arg_ty) {
						let pu2: *mut middle.types.StType = middle.types.underlying_type(param_ty);
						let au2: *mut middle.types.StType = middle.types.underlying_type(arg_ty);
						if pu2 != null && au2 != null && pu2.kind == middle.types.TypeKind.Pointer
							&& au2.kind == middle.types.TypeKind.Pointer && pu2.is_mutable
							&& !au2.is_mutable {
							let mut ab: [64]u8;
							let mut pb: [64]u8;
							let astr: []u8 = middle.types.format_type(arg_ty, &ab[0], 64);
							let pstr: []u8 = middle.types.format_type(param_ty, &pb[0], 64);
							let cname2: []u8 = (e.lhs != null && e.lhs.kind
								== front.ast.ExprKind.Ident && e.lhs.path.len > 0)
								? e.lhs.path.data[e.lhs.path.len - 1] : "";
							let mut mb: [200]u8;
							let mut mp: usize = 0;
							put_str_buf(
								&mb[0],
								&mp,
								200,
								"no matching public function for call to `"
							);
							put_str_buf(&mb[0], &mp, 200, cname2);
							put_str_buf(&mb[0], &mp, 200, "` with ");
							put_u64_buf(&mb[0], &mp, 200, e.args.len cast u64);
							put_str_buf(&mb[0], &mp, 200, " argument(s)");
							let mut nb: [240]u8;
							let mut np: usize = 0;
							put_str_buf(
								&nb[0],
								&np,
								240,
								"candidate function not viable: cannot convert argument "
							);
							put_u64_buf(&nb[0], &np, 240, (i + 1) cast u64);
							put_str_buf(&nb[0], &np, 240, " from '");
							put_str_buf(&nb[0], &np, 240, astr);
							put_str_buf(&nb[0], &np, 240, "' to '");
							put_str_buf(&nb[0], &np, 240, pstr);
							put_str_buf(
								&nb[0],
								&np,
								240,
								"' (cannot convert immutable pointer to mutable pointer)"
							);
							front.log.report_with_note(
								front.log.Level.Error,
								e.loc,
								mb[0..mp],
								front.log.DiagCode.InvalidCall,
								nb[0..np],
								e.loc
							);
						} else {
							front.log.report(
								front.log.Level.Error,
								e.args.data[i].loc,
								"argument type mismatch",
								front.log.DiagCode.TypeMismatch
							);
						}
					}
				}
				if e.lhs != null && e.lhs.sema_sym != null {
					let csym: *middle.symbol.Symbol = e.lhs.sema_sym cast *middle.symbol.Symbol;
					if csym.kind == middle.symbol.SymKind.Fn && csym.fn_decl != null
						&& csym.fn_decl.is_macro && csym.fn_decl.body != null {
						self.scopes.enter();
						let prev_yield: *mut middle.types.StType = self.current_yield_ty;
						let prev_imp_m: bool = self.in_imported_mod;
						if csym.loc.file.len > 0 && !std.str.eq(csym.loc.file, e.loc.file) {
							self.in_imported_mod = true;
						}
						self.current_yield_ty = u.fn_ret;
						for let mut pi: usize = 0; pi < csym.fn_decl.params.len; pi += 1 {
							let prm: front.ast.Param = csym.fn_decl.params.data[pi];
							let mut psym: middle.symbol.Symbol = middle.symbol.make_symbol(
								middle.symbol.SymKind.Param,
								prm.name,
								prm.loc
							);
							psym.ty = pi < u.fn_params.len ? u.fn_params.data[pi] : self.tx.void_t;
							if pi < e.args.len && e.args.data[pi] != null && e.args.data[pi].kind
								== front.ast.ExprKind.StringLit {
								psym.comptime_str_val = e.args.data[pi].str_val;
								psym.loc = e.args.data[pi].loc;
							}
							self.scopes.define(psym);
						}
						self.check_stmt(csym.fn_decl.body);
						self.in_imported_mod = prev_imp_m;
						self.current_yield_ty = prev_yield;
						self.scopes.leave();
					}
				}
				return u.fn_ret;
			}
			.Member => {
				let mut chain: front.ast.ValList<[]u8> = { .data = null, .len = 0, .cap = 0 };
				if extract_member_chain(e, &chain) && chain.len >= 2
					&& self.scopes.lookup(chain.data[0]) == null {
					let qsym: *mut middle.symbol.Symbol = self.lookup_qualified(&chain, chain.len);
					if qsym != null {
						chain.free_array();
						e.sema_sym = qsym cast *void;
						if e.generic_args.len > 0
							&& (qsym.kind == middle.symbol.SymKind.Struct || qsym.kind
							== middle.symbol.SymKind.Union || qsym.kind
							== middle.symbol.SymKind.Enum) {
							return self.instantiate_generic_type(qsym, &e.generic_args, e.loc);
						}
						return qsym.ty != null ? qsym.ty : self.tx.void_t;
					}
				}
				chain.free_array();
				let base_ty: *mut middle.types.StType = self.check_expr(e.lhs, null);
				if middle.types.is_poison(base_ty) {
					return self.tx.poison_t;
				}
				let mut u: *mut middle.types.StType = middle.types.underlying_type(base_ty);
				if u != null && u.kind == middle.types.TypeKind.Pointer {
					u = middle.types.underlying_type(u.base);
				}
				if u != null && u.kind == middle.types.TypeKind.Slice {
					if std.str.eq(e.member, "ptr") {
						return self.tx.pointer(u.base, u.is_mutable, u.is_volatile);
					}
					if std.str.eq(e.member, "len") {
						return self.tx.usize_t;
					}
				}
				if u != null && u.kind == middle.types.TypeKind.Array
					&& std.str.eq(e.member, "len") {
					return self.tx.usize_t;
				}
				if u != null
					&& (u.kind == middle.types.TypeKind.Struct || u.kind
					== middle.types.TypeKind.Union) {
					let fidx: isize = middle.types.field_index(u, e.member);
					if fidx >= 0 {
						let in_own_impl: bool = self.current_self_ty != null
							&& middle.types.eq_type(
								middle.types.underlying_type(self.current_self_ty),
								u
							);
						if !self.in_imported_mod && !in_own_impl && u.is_foreign
							&& (fidx cast usize) < u.field_is_pub.len
							&& !u.field_is_pub.data[fidx cast usize] {
							let mut tb: [64]u8;
							let tstr: []u8 = middle.types.format_type(u, &tb[0], 64);
							let mut mb: [160]u8;
							let mut mp: usize = 0;
							put_str_buf(&mb[0], &mp, 160, "field `");
							put_str_buf(&mb[0], &mp, 160, e.member);
							put_str_buf(&mb[0], &mp, 160, "` of `");
							put_str_buf(&mb[0], &mp, 160, tstr);
							put_str_buf(&mb[0], &mp, 160, "` is private");
							front.log.report(
								front.log.Level.Error,
								e.loc,
								mb[0..mp],
								front.log.DiagCode.PrivateMember
							);
						}
						return u.fields.data[fidx cast usize];
					}
					for let mut ci: usize = 0; ci < self.impl_consts.len; ci += 1 {
						let ice: ImplConstEntry = self.impl_consts.data[ci];
						if middle.types.eq_type(ice.target_ty, u) && std.str.eq(ice.name, e.member)
							&& ice.sym != null {
							e.sema_sym = ice.sym cast *void;
							return ice.sym.ty != null ? ice.sym.ty : self.tx.void_t;
						}
					}
					let mut mb: [160]u8;
					let mut mp: usize = 0;
					put_str_buf(&mb[0], &mp, 160, "no field `");
					put_str_buf(&mb[0], &mp, 160, e.member);
					put_str_buf(&mb[0], &mp, 160, "` on aggregate");
					let mut best: []u8 = "";
					let mut best_d: usize = 3;
					for let mut fi: usize = 0; fi < u.field_names.len; fi += 1 {
						let fn_n: []u8 = u.field_names.data[fi];
						let d: usize = front.log.levenshtein(e.member, fn_n);
						if d < best_d {
							best_d = d;
							best = fn_n;
						}
					}
					if best.len > 0 {
						let mut hb: [128]u8;
						let mut hp: usize = 0;
						put_str_buf(&hb[0], &hp, 128, "did you mean `");
						put_str_buf(&hb[0], &hp, 128, best);
						put_str_buf(&hb[0], &hp, 128, "`?");
						let mut fb: [128]u8;
						let mut fp: usize = 0;
						put_str_buf(&fb[0], &fp, 128, "replace with `");
						put_str_buf(&fb[0], &fp, 128, best);
						put_str_buf(&fb[0], &fp, 128, "`");
						front.log.report_with_help(
							front.log.Level.Error,
							e.loc,
							mb[0..mp],
							front.log.DiagCode.UnknownMember,
							hb[0..hp],
							fb[0..fp],
							best
						);
					} else {
						front.log.report(
							front.log.Level.Error,
							e.loc,
							mb[0..mp],
							front.log.DiagCode.UnknownMember
						);
					}
					return self.tx.poison_t;
				}
				if u != null && u.kind == middle.types.TypeKind.Enum {
					let midx: isize = middle.types.field_index(u, e.member);
					if midx < 0 {
						front.log.report(
							front.log.Level.Error,
							e.loc,
							"unknown enum member",
							front.log.DiagCode.UnknownMember
						);
						return self.tx.poison_t;
					}
					return base_ty;
				}
				front.log.report(
					front.log.Level.Error,
					e.loc,
					"member access on unsupported type",
					front.log.DiagCode.UnknownMember
				);
				return self.tx.poison_t;
			}
			.Index => {
				let base_ty: *mut middle.types.StType = self.check_expr(e.lhs, null);
				self.check_expr(e.rhs, self.tx.usize_t);
				if e.index_low != null {
					self.check_expr(e.index_low, self.tx.usize_t);
					let bu: *mut middle.types.StType = middle.types.underlying_type(base_ty);
					if bu == null
						|| (bu.kind != middle.types.TypeKind.UInt && bu.kind
						!= middle.types.TypeKind.SInt) {
						front.log.report(
							front.log.Level.Error,
							e.loc,
							"bit-slice requires an integer operand",
							front.log.DiagCode.TypeMismatch
						);
						return self.tx.poison_t;
					}
					let cv_h: middle.sema.const_eval.ConstVal =
						middle.sema.const_eval.eval_const_expr(e.rhs, &self.scopes, &self.tx);
					let cv_l: middle.sema.const_eval.ConstVal =
						middle.sema.const_eval.eval_const_expr(e.index_low, &self.scopes, &self.tx);
					if cv_h.kind != middle.sema.const_eval.ConstKind.Int || cv_l.kind
						!= middle.sema.const_eval.ConstKind.Int {
						front.log.report(
							front.log.Level.Error,
							e.loc,
							"bit-slice bound must be a compile-time integer constant",
							front.log.DiagCode.TypeMismatch
						);
						return self.tx.poison_t;
					}
					let hs: i64 = cv_h.int_val cast i64;
					let ls: i64 = cv_l.int_val cast i64;
					if hs < 0 || ls < 0 {
						front.log.report(
							front.log.Level.Error,
							e.loc,
							"bit-slice bound must be nonnegative",
							front.log.DiagCode.TypeMismatch
						);
						return self.tx.poison_t;
					}
					if hs < ls {
						front.log.report(
							front.log.Level.Error,
							e.loc,
							"bit-slice high bound must be greater than or equal to low bound",
							front.log.DiagCode.TypeMismatch
						);
						return self.tx.poison_t;
					}
					if hs >= (bu.width cast i64) {
						front.log.report(
							front.log.Level.Error,
							e.loc,
							"bit-slice bound is outside the integer width",
							front.log.DiagCode.TypeMismatch
						);
						return self.tx.poison_t;
					}
					let w: i32 = ((hs - ls) + 1) cast i32;
					let rty: *mut middle.types.StType = self.tx.uint(w);
					e.sema_ty = rty cast *void;
					return rty;
				}
				let u: *mut middle.types.StType = middle.types.underlying_type(base_ty);
				if u != null
					&& (u.kind == middle.types.TypeKind.Array || u.kind
					== middle.types.TypeKind.Slice)
					&& e.rhs != null {
					let is_neg_idx: bool = e.rhs.kind == front.ast.ExprKind.Unary
						&& std.str.eq(e.rhs.unary_op, "-") && e.rhs.lhs != null && e.rhs.lhs.kind
						== front.ast.ExprKind.IntLit;
					if is_neg_idx {
						front.log.report(
							front.log.Level.Error,
							e.loc,
							u.kind == middle.types.TypeKind.Array ? "array index cannot be negative"
								: "slice index cannot be negative",
							front.log.DiagCode.General
						);
					} else if u.kind == middle.types.TypeKind.Array && e.rhs.kind
						== front.ast.ExprKind.IntLit && (e.rhs.int_val cast usize) >= u.array_len {
						let mut mb: [160]u8;
						let mut mp: usize = 0;
						put_str_buf(&mb[0], &mp, 160, "array index ");
						put_u64_buf(&mb[0], &mp, 160, e.rhs.int_val);
						put_str_buf(&mb[0], &mp, 160, " is out of bounds for array of length ");
						put_u64_buf(&mb[0], &mp, 160, u.array_len cast u64);
						front.log.report(
							front.log.Level.Error,
							e.loc,
							mb[0..mp],
							front.log.DiagCode.General
						);
					}
				}
				if u != null
					&& (u.kind == middle.types.TypeKind.Pointer || u.kind
					== middle.types.TypeKind.Array || u.kind == middle.types.TypeKind.Slice) {
					return u.base;
				}
				return self.tx.poison_t;
			}
			.Slice => {
				let base_ty: *mut middle.types.StType = self.check_expr(e.lhs, null);
				if e.rhs != null {
					self.check_expr(e.rhs, self.tx.usize_t);
				}
				if e.index_low != null {
					self.check_expr(e.index_low, self.tx.usize_t);
				}
				let u: *mut middle.types.StType = middle.types.underlying_type(base_ty);
				if u != null
					&& (u.kind == middle.types.TypeKind.Pointer || u.kind
					== middle.types.TypeKind.Array || u.kind == middle.types.TypeKind.Slice) {
					if u.kind == middle.types.TypeKind.Pointer && e.index_low == null {
						front.log.report(
							front.log.Level.Error,
							e.loc,
							"slicing a pointer requires an explicit end bound",
							front.log.DiagCode.TypeMismatch
						);
						return self.tx.poison_t;
					}
					if u.kind == middle.types.TypeKind.Array {
						let mut has_low: bool = e.rhs == null;
						let mut low_v: u64 = 0;
						if e.rhs != null {
							let cv_l: middle.sema.const_eval.ConstVal =
								middle.sema.const_eval.eval_const_expr(
									e.rhs,
									&self.scopes,
									&self.tx
								);
							if cv_l.kind == middle.sema.const_eval.ConstKind.Int {
								has_low = true;
								low_v = cv_l.int_val;
							}
						}
						let mut has_high: bool = e.index_low == null;
						let mut high_v: u64 = u.array_len cast u64;
						if e.index_low != null {
							let cv_h: middle.sema.const_eval.ConstVal =
								middle.sema.const_eval.eval_const_expr(
									e.index_low,
									&self.scopes,
									&self.tx
								);
							if cv_h.kind == middle.sema.const_eval.ConstKind.Int {
								has_high = true;
								high_v = cv_h.int_val;
							}
						}
						if (has_low && low_v > (u.array_len cast u64))
							|| (has_high && high_v > (u.array_len cast u64)) {
							front.log.report(
								front.log.Level.Error,
								e.loc,
								"slice end bound is out of bounds for array",
								front.log.DiagCode.TypeMismatch
							);
							return self.tx.poison_t;
						}
						if has_low && has_high && low_v > high_v {
							front.log.report(
								front.log.Level.Error,
								e.loc,
								"slice start bound exceeds end bound",
								front.log.DiagCode.TypeMismatch
							);
							return self.tx.poison_t;
						}
					}
					let mut sm: bool = u.is_mutable;
					if u.kind == middle.types.TypeKind.Array {
						sm = is_assignable_lvalue(self, e.lhs);
					}
					return self.tx.slice(u.base, sm, u.is_volatile);
				}
				return self.tx.poison_t;
			}
			.StructLit => {
				if expected != null {
					let u: *mut middle.types.StType = middle.types.underlying_type(expected);
					if u != null && u.kind == middle.types.TypeKind.Union && !self.in_imported_mod
						&& u.is_foreign {
						for let mut i: usize = 0; i < e.field_names.len; i += 1 {
							let fidx: isize = middle.types.field_index(u, e.field_names.data[i]);
							if fidx >= 0 && (fidx cast usize) < u.field_is_pub.len
								&& !u.field_is_pub.data[fidx cast usize] {
								let mut tb: [64]u8;
								let tstr: []u8 = middle.types.format_type(u, &tb[0], 64);
								let mut mb: [160]u8;
								let mut mp: usize = 0;
								put_str_buf(&mb[0], &mp, 160, "union variant `");
								put_str_buf(&mb[0], &mp, 160, e.field_names.data[i]);
								put_str_buf(&mb[0], &mp, 160, "` of `");
								put_str_buf(&mb[0], &mp, 160, tstr);
								put_str_buf(&mb[0], &mp, 160, "` is private");
								front.log.report(
									front.log.Level.Error,
									e.loc,
									mb[0..mp],
									front.log.DiagCode.PrivateMember
								);
							}
						}
					}
					if u != null
						&& (u.kind == middle.types.TypeKind.Struct || u.kind
						== middle.types.TypeKind.Union) {
						if u.kind == middle.types.TypeKind.Struct && !self.in_imported_mod
							&& u.is_foreign {
							for let mut fi: usize = 0; fi < u.field_names.len; fi += 1 {
								if fi < u.field_is_pub.len && !u.field_is_pub.data[fi] {
									let mut tb: [64]u8;
									let tstr: []u8 = middle.types.format_type(u, &tb[0], 64);
									let mut mb: [220]u8;
									let mut mp: usize = 0;
									put_str_buf(&mb[0], &mp, 220, "cannot construct `");
									put_str_buf(&mb[0], &mp, 220, tstr);
									put_str_buf(
										&mb[0],
										&mp,
										220,
										"` with a literal outside its declaring module: field `"
									);
									put_str_buf(&mb[0], &mp, 220, u.field_names.data[fi]);
									put_str_buf(&mb[0], &mp, 220, "` is private");
									front.log.report(
										front.log.Level.Error,
										e.loc,
										mb[0..mp],
										front.log.DiagCode.PrivateMember
									);
								}
							}
						}
						for let mut i: usize = 0; i < e.field_names.len; i += 1 {
							let fidx: isize = middle.types.field_index(u, e.field_names.data[i]);
							if fidx < 0 {
								front.log.report(
									front.log.Level.Error,
									e.loc,
									"unknown field in struct literal",
									front.log.DiagCode.UnknownMember
								);
							} else {
								let fty: *mut middle.types.StType = u.fields.data[fidx cast usize];
								let vty: *mut middle.types.StType = self.check_expr(
									e.args.data[i],
									fty
								);
								if !middle.types.is_poison(vty)
									&& !middle.types.is_assignable_type(fty, vty) {
									front.log.report(
										front.log.Level.Error,
										e.args.data[i].loc,
										"struct field initializer type mismatch",
										front.log.DiagCode.TypeMismatch
									);
								}
							}
						}
						return expected;
					}
				}
				return expected != null ? expected : self.tx.poison_t;
			}
			.VariantInit => {
				let mut ety: *mut middle.types.StType = expected;
				if e.lhs != null {
					let lht: *mut middle.types.StType = self.check_expr(e.lhs, null);
					let lhu: *mut middle.types.StType = middle.types.underlying_type(lht);
					if lhu != null && lhu.kind == middle.types.TypeKind.Enum {
						ety = lht;
					}
				}
				let eu: *mut middle.types.StType = middle.types.underlying_type(ety);
				if eu != null && eu.kind == middle.types.TypeKind.Enum {
					let vidx: isize = middle.types.field_index(eu, e.member);
					if vidx >= 0 && (vidx cast usize) < eu.enum_variants.len {
						let vi: *middle.types.EnumVariantInfo =
							&eu.enum_variants.data[vidx cast usize];
						for let mut i: usize = 0; i < e.field_names.len; i += 1 {
							let mut fidx: isize = -1;
							for let mut k: usize = 0; k < vi.field_names.len; k += 1 {
								if std.str.eq(vi.field_names.data[k], e.field_names.data[i]) {
									fidx = k cast isize;
									break;
								}
							}
							if fidx < 0 {
								front.log.report(
									front.log.Level.Error,
									e.loc,
									"unknown field in enum variant",
									front.log.DiagCode.UnknownMember
								);
							} else {
								let fty: *mut middle.types.StType =
									vi.field_types.data[fidx cast usize];
								let vty: *mut middle.types.StType = self.check_expr(
									e.args.data[i],
									fty
								);
								if !middle.types.is_poison(vty)
									&& !middle.types.is_assignable_type(fty, vty) {
									front.log.report(
										front.log.Level.Error,
										e.args.data[i].loc,
										"variant field initializer type mismatch",
										front.log.DiagCode.TypeMismatch
									);
								}
							}
						}
						e.sema_ty = ety cast *void;
						return ety;
					}
					front.log.report(
						front.log.Level.Error,
						e.loc,
						"unknown enum variant",
						front.log.DiagCode.UnknownMember
					);
					return self.tx.poison_t;
				}
				front.log.report(
					front.log.Level.Error,
					e.loc,
					"cannot infer enum type for variant initializer",
					front.log.DiagCode.TypeMismatch
				);
				return self.tx.poison_t;
			}
			.ArrayLit => {
				if e.args.len == 0 {
					return expected != null ? expected
						: self.tx.slice(self.tx.void_t, false, false);
				}
				let mut elem_expected: *mut middle.types.StType = null;
				if expected != null {
					let u: *mut middle.types.StType = middle.types.underlying_type(expected);
					if u != null
						&& (u.kind == middle.types.TypeKind.Array || u.kind
						== middle.types.TypeKind.Slice) {
						elem_expected = u.base;
					}
				}
				let first_ty: *mut middle.types.StType = self.check_expr(
					e.args.data[0],
					elem_expected
				);
				for let mut i: usize = 1; i < e.args.len; i += 1 {
					self.check_expr(e.args.data[i], first_ty);
				}
				return self.tx.array_of(first_ty, e.args.len);
			}
			.VariadicSplice => return expected != null ? expected : self.tx.void_t,
			.Block => {
				let prev_yield: *mut middle.types.StType = self.current_yield_ty;
				self.current_yield_ty = expected;
				self.check_stmt(e.block);
				let res: *mut middle.types.StType = self.current_yield_ty != null
					? self.current_yield_ty : self.tx.void_t;
				self.current_yield_ty = prev_yield;
				if e.block != null && res != null && middle.types.underlying_type(res).kind
					!= middle.types.TypeKind.Void {
					if e.block.kind == front.ast.StmtKind.If && e.block.else_block == null {
						front.log.report(
							front.log.Level.Error,
							e.loc,
							"block expression does not yield a value on every path",
							front.log.DiagCode.InvalidControlFlow
						);
					} else if e.block.kind == front.ast.StmtKind.For {
						if e.block.for_cond != null
							&& !(e.block.for_cond.kind == front.ast.ExprKind.BoolLit
							&& e.block.for_cond.int_val != 0) {
							front.log.report(
								front.log.Level.Error,
								e.loc,
								"block expression does not yield a value on every path",
								front.log.DiagCode.InvalidControlFlow
							);
						} else if e.block.loop_body != null {
							let mut has_brk: bool = false;
							for let mut si: usize = 0; si < e.block.loop_body.body.len; si += 1 {
								let st_i: *front.ast.Stmt = e.block.loop_body.body.data[si];
								if st_i != null && (st_i.kind == front.ast.StmtKind.Break
									|| (st_i.kind == front.ast.StmtKind.If && st_i.then_block
									!= null && st_i.then_block.body.len > 0
									&& st_i.then_block.body.data[0].kind
									== front.ast.StmtKind.Break)) {
									has_brk = true;
									break;
								}
							}
							if has_brk {
								front.log.report(
									front.log.Level.Error,
									e.loc,
									"block expression does not yield a value on every path",
									front.log.DiagCode.InvalidControlFlow
								);
							}
						}
					}
				}
				return res;
			}
			_ => return self.tx.void_t
		}
	}

	/// Executes `check_stmt` (check stmt).
}
