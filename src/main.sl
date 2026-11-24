import "back/codegen/expressions.sl";
import "back/codegen/module.sl";
import "back/codegen/types.sl";
import "back/llvm_ctx.sl";
import "driver/cli.sl";
import "front/ast.sl";
import "front/lexer.sl";
import "front/log.sl";
import "front/parser/expressions.sl";
import "front/parser/module.sl";
import "front/parser/statements.sl";
import "front/token.sl";
import "middle/resolver.sl";
import "middle/sema/validation.sl";
import "middle/symbol.sl";
import "std/err.sl";
import "std/io.sl";
import "std/mem.sl";
import "std/proc.sl";
import "std/str.sl";

fn read_entire_file(path: []u8, out_buf: *mut []u8) -> bool {
	// Create a NUL-terminated copy of path for std.io.file.open.
	let cpath: *mut u8 = front.ast.arena_alloc(path.len + 1);
	if cpath == null {
		return false;
	}
	if path.len > 0 {
		std.mem.copy(cpath, path.ptr, path.len);
	}
	cpath[path.len] = 0;

	let mut file: std.io.file.File;
	match std.io.file.open(cpath, std.io.file.OpenFlags.Read, 0) {
		.Ok(opened) => file = opened,
		.Err(_) => return false
	}

	let mut cap: usize = 4096;
	let mut len: usize = 0;
	let mut buf: *mut u8 = front.ast.arena_alloc(cap);
	if buf == null {
		file.close();
		return false;
	}

	for true {
		if len == cap {
			let new_cap: usize = cap * 2;
			let nb: *mut u8 = front.ast.arena_alloc(new_cap);
			if nb == null {
				file.close();
				return false;
			}
			std.mem.copy(nb, buf, len);
			buf = nb;
			cap = new_cap;
		}
		match file.read(&buf[len], cap - len) {
			.Ok(n) => {
				if n == 0 {
					break;
				}
				len += n;
			}
			.Err(e) => {
				if e == std.err.Code.InterruptedSystemCall {
					continue;
				}
				file.close();
				return false;
			}
		}
	}

	file.close();
	*out_buf = buf[0..len];
	return true;
}

fn dump_tokens(tokens: *front.token.TokenList) -> void {
	for let mut i: usize = 0; i < tokens.len; i += 1 {
		let t: *front.token.Token = &tokens.data[i];
		let kind_str: []u8 = front.token.token_kind_name(t.kind);
		std.io.printf("{}:{} {}", t.loc.line, t.loc.column, kind_str);
		if t.kind == front.token.TokenKind.Operator {
			let base_str: []u8 = front.token.op_text(t.op, front.token.OpVariant.Normal);
			std.io.printf(" base={}", base_str);
			match t.variant {
				.Normal => std.io.print(" var=normal"),
				.Wrap => std.io.print(" var=wrap"),
				.Sat => std.io.print(" var=sat")
			}
			if t.compound_assignment {
				std.io.print(" assign=true");
			}
			std.io.printf(" text={}", t.text);
		} else if t.kind == front.token.TokenKind.IntLit {
			std.io.printf(" text={} val={}", t.text, t.int_val);
		} else if t.kind == front.token.TokenKind.FloatLit {
			std.io.printf(" text={}", t.text);
		} else if t.kind == front.token.TokenKind.StringLit {
			if t.is_cstring {
				std.io.print(" cstr=true");
			}
			std.io.printf(" text=\"{}\"", t.text);
		} else if t.kind == front.token.TokenKind.CharLit {
			std.io.printf(" val={}", t.char_val);
		} else if t.text.len > 0 && (t.kind == front.token.TokenKind.Ident
			|| t.kind == front.token.TokenKind.DefineRef
			|| t.kind == front.token.TokenKind.BuiltinModuleRef) {
			std.io.printf(" text={}", t.text);
		}
		std.io.print("\n");
	}
}

fn default_output_path(input: []u8, suffix: []u8) -> []u8 {
	let mut stem_end: usize = input.len;
	let mut i: usize = input.len;
	for i > 0 {
		i -= 1;
		if input[i] == '/' || input[i] == '\\' {
			break;
		}
		if input[i] == '.' {
			stem_end = i;
			break;
		}
	}
	let total: usize = stem_end + suffix.len;
	let buf: *mut u8 = front.ast.arena_alloc(total + 1);
	if buf == null {
		return "a.out";
	}
	if stem_end > 0 {
		std.mem.copy(buf, input.ptr, stem_end);
	}
	if suffix.len > 0 {
		std.mem.copy(&buf[stem_end], suffix.ptr, suffix.len);
	}
	buf[total] = 0;
	return buf[0..total];
}

fn to_cstr(s: []u8) -> *u8 {
	let p: *mut u8 = front.ast.arena_alloc(s.len + 1);
	if p == null {
		return null;
	}
	if s.len > 0 {
		std.mem.copy(p, s.ptr, s.len);
	}
	p[s.len] = 0;
	return p;
}

fn make_lib_arg(lib: []u8) -> *u8 {
	let p: *mut u8 = front.ast.arena_alloc(2 + lib.len + 1);
	if p == null {
		return null;
	}
	p[0] = '-' cast u8;
	p[1] = 'l' cast u8;
	if lib.len > 0 {
		std.mem.copy(&p[2], lib.ptr, lib.len);
	}
	p[2 + lib.len] = 0;
	return p;
}

fn link_executable(obj_path: []u8, out_path: []u8, opts: *driver.cli.CliOptions) -> bool {
	let use_crt: bool = std.str.eq(opts.startup, "crt");
	let prog: []u8 = use_crt
		? opts.linker
		: (std.str.eq(opts.raw_linker, "lld") ? "ld.lld" : opts.raw_linker);
	let c_prog: *u8 = to_cstr(prog);
	let c_obj: *u8 = to_cstr(obj_path);
	let c_out: *u8 = to_cstr(out_path);
	if c_prog == null || c_obj == null || c_out == null {
		return false;
	}

	let mut argv: [128]*u8;
	let mut argc: usize = 0;
	argv[argc] = c_prog;
	argc += 1;

	if use_crt {
		argv[argc] = c"-no-pie";
		argc += 1;
		argv[argc] = c_obj;
		argc += 1;
		argv[argc] = c"-o";
		argc += 1;
		argv[argc] = c_out;
		argc += 1;
	} else {
		let use_dynamic: bool = std.str.eq(opts.link_mode, "dynamic");
		if use_dynamic || opts.libraries.len > 0 {
			let dloader: *u8 = opts.dynamic_linker.len > 0
				? to_cstr(opts.dynamic_linker)
				: c"/lib64/ld-linux-x86-64.so.2";
			if dloader == null {
				return false;
			}
			argv[argc] = c"-L/usr/lib";
			argc += 1;
			argv[argc] = c"-L/usr/local/lib";
			argc += 1;
			argv[argc] = c"-dynamic-linker";
			argc += 1;
			argv[argc] = dloader;
			argc += 1;
		}
		if use_dynamic {
			argv[argc] = c"-L/usr/local/lib/stella";
			argc += 1;
			argv[argc] = c"-rpath";
			argc += 1;
			argv[argc] = c"/usr/local/lib/stella";
			argc += 1;
		}
		argv[argc] = c"/usr/local/lib/stella/start.o";
		argc += 1;
		argv[argc] = c_obj;
		argc += 1;
		if use_dynamic {
			argv[argc] = c"--as-needed";
			argc += 1;
			argv[argc] = c"-l:stellalib.so";
			argc += 1;
			argv[argc] = c"--no-as-needed";
			argc += 1;
		} else {
			argv[argc] = c"/usr/local/lib/stella/stellalib.a";
			argc += 1;
		}
		argv[argc] = c"-o";
		argc += 1;
		argv[argc] = c_out;
		argc += 1;
	}
	for let mut i: usize = 0; i < opts.libraries.len; i += 1 {
		if argc + 8 >= 128 {
			return false;
		}
		let lib_arg: *u8 = make_lib_arg(opts.libraries.data[i]);
		if lib_arg == null {
			return false;
		}
		argv[argc] = lib_arg;
		argc += 1;
	}
	if opts.lto == driver.cli.LtoMode.Thin {
		argv[argc] = use_crt ? c"-Wl,--lto=thin" : c"--lto=thin";
		argc += 1;
	}
	if opts.opt_level != driver.cli.OptLevel.None {
		let mut lto_o: *u8 = c"--lto-O2";
		match opts.opt_level {
			.Low => lto_o = use_crt ? c"-Wl,--lto-O1" : c"--lto-O1",
			.Medium | .Size => lto_o = use_crt ? c"-Wl,--lto-O2" : c"--lto-O2",
			.High => lto_o = use_crt ? c"-Wl,--lto-O3" : c"--lto-O3",
			.None => {}
		}
		argv[argc] = lto_o;
		argc += 1;
	}
	if opts.function_sections {
		argv[argc] = use_crt ? c"-Wl,--gc-sections" : c"--gc-sections";
		argc += 1;
	}
	if opts.icf_mode == driver.cli.IcfMode.Safe {
		argv[argc] = use_crt ? c"-Wl,--icf=safe" : c"--icf=safe";
		argc += 1;
	} else if opts.icf_mode == driver.cli.IcfMode.All {
		argv[argc] = use_crt ? c"-Wl,--icf=all" : c"--icf=all";
		argc += 1;
	}
	argv[argc] = null;

	let status: isize = std.proc.exec_in_path(prog, &argv[0]);
	if status != 0 {
		front.log.report(
			front.log.Level.Error,
			front.log.empty_loc(),
			"linking failed",
			front.log.DiagCode.LinkFailed
		);
		return false;
	}
	std.io.dir.remove(c_obj);
	return true;
}

/// Executes `main` (main).
pub fn main(argc: usize, argv: **u8) -> u8 {
	front.log.reset();
	let mut opts: driver.cli.CliOptions = driver.cli.default_options();

	if !driver.cli.parse_args(argc, argv, &opts) {
		driver.cli.free_options(&opts);
		front.log.finish();
		front.log.reset();
		return 1;
	}

	if opts.show_help {
		driver.cli.print_usage();
		driver.cli.free_options(&opts);
		front.log.finish();
		front.log.reset();
		return 0;
	}

	let mut source: []u8 = "";
	if !read_entire_file(opts.input, &source) {
		front.log.report(
			front.log.Level.Error,
			front.log.empty_loc(),
			"could not read input file",
			front.log.DiagCode.InputRead
		);
		driver.cli.free_options(&opts);
		front.log.finish();
		front.log.reset();
		return 1;
	}

	front.log.set_current_file(opts.input);
	front.log.register_source(opts.input, source);

	let mut init_cap: usize = 16;
	if source.len >= 16 {
		init_cap = source.len / 4;
	}
	let mut tokens: front.token.TokenList;
	tokens.init(init_cap);

	let mut lex: front.lexer.Lexer = front.lexer.init_lexer(source, opts.input, true, &tokens);
	let mut ok: bool = lex.tokenize();

	if ok && opts.emit_tokens {
		dump_tokens(&tokens);
	}

	if ok && !opts.emit_tokens {
		let mut mod_ast: front.ast.Module = front.ast.init_module(opts.input);
		let mut parser: front.parser.Parser = front.parser.init_parser(&tokens, opts.input);
		ok = front.parser.parse_module(&parser, &mod_ast);
		if ok && opts.emit_ast {
			front.ast.dump_module(&mod_ast);
		} else if ok {
			let mut mtable: middle.resolver.ModuleTable = middle.resolver.init_module_table(
				&opts.import_roots
			);
			let root_lm: *mut middle.resolver.LoadedModule = mtable.register_parsed(
				opts.input,
				source,
				tokens,
				mod_ast
			);
			ok = mtable.resolve_module_imports(root_lm);
			if ok {
				let mut ptr_bits: i32 = 64;
				let tt: []u8 = opts.target_triple;
				if (tt.len >= 4 && tt[0] == 'i' && (tt[1] == '3' || tt[1] == '6') && tt[2] == '8'
					&& tt[3] == '6')
					|| (tt.len >= 7 && tt[0] == 'r' && tt[5] == '3' && tt[6] == '2')
					|| (tt.len >= 6 && tt[0] == 'w' && tt[4] == '3' && tt[5] == '2') {
					ptr_bits = 32;
				}
				let mut sema: middle.sema.validation.SemaContext = middle.sema.validation.init_sema(
					ptr_bits
				);
				for let mut mi: usize = 1; mi < mtable.modules.len; mi += 1 {
					sema.register_imported_types(&mtable.modules.data[mi].ast);
				}
				for let mut mi: usize = 1; mi < mtable.modules.len; mi += 1 {
					sema.register_imported_module(&mtable.modules.data[mi].ast);
				}
				ok = true;
				let mut mi: usize = mtable.modules.len;
				for mi > 1 && ok {
					mi -= 1;
					ok = sema.check_imported_module(&mtable.modules.data[mi].ast);
				}
				if ok {
					ok = sema.check_module(&root_lm.ast);
				// Warn on unused private imports in root module
				if ok {
					sema.check_unused_imports(&mtable, root_lm);
				}
				}
				if ok {
					let out_path: []u8 = opts.output.len > 0
						? opts.output
						: default_output_path(
							opts.input,
							opts.emit_ir ? ".ll" : (opts.compile_only ? ".o" : "")
						);
					let mut lc: back.llvm_ctx.LLVMCtx = back.llvm_ctx.init_llvm_ctx(
						opts.input,
						opts.target_triple,
						opts.cpu_specific,
						opts.opt_level,
						opts.relocation,
						opts.code_model
					);
					if lc.ok {
						if (opts.target_triple.len >= 7
							&& std.str.eq(opts.target_triple[0..7], "aarch64"))
							|| (opts.target_triple.len >= 5
							&& std.str.eq(opts.target_triple[0..5], "arm64")) {
							back.codegen.types.set_va_list_arch(1);
						} else if opts.target_triple.len >= 7
							&& std.str.eq(opts.target_triple[0..7], "riscv64") {
							back.codegen.types.set_va_list_arch(2);
						} else {
							back.codegen.types.set_va_list_arch(0);
						}
						let mut cg: back.codegen.expressions.CodegenState =
							back.codegen.expressions.init_codegen(&lc, &sema);
						let separate_tu: bool = opts.compile_only || opts.emit_ir;
						for let mut mi: usize = 1; mi < mtable.modules.len; mi += 1 {
							back.codegen.module.declare_imported_module_opts(
								&cg,
								&mtable.modules.data[mi].ast,
								separate_tu
							);
						}
						back.codegen.module.declare_instantiated_fns(&cg);
						let dyn_std: bool = !opts.compile_only && !opts.emit_ir
							&& std.str.eq(opts.link_mode, "dynamic");
						for let mut mi: usize = 1; mi < mtable.modules.len; mi += 1 {
							let imp_m: *front.ast.Module = &mtable.modules.data[mi].ast;
							let is_std: bool = imp_m.mod_path.len > 0
								&& std.str.eq(imp_m.mod_path.data[0], "std");
							if separate_tu || (dyn_std && is_std) {
								if !back.codegen.module.module_has_private_mutable_global(imp_m) {
									back.codegen.module.emit_imported_module_bodies_avail_ext(
										&cg,
										imp_m
									);
								}
							} else {
								back.codegen.module.emit_imported_module_bodies(&cg, imp_m);
							}
						}
						ok = back.codegen.module.emit_module(&cg, &root_lm.ast);
						if ok {
							back.llvm_ctx.apply_target_attrs(&lc, opts.cpu_specific);
							ok = back.llvm_ctx.optimize_module(&lc);
						}
						if ok {
							if opts.emit_ir {
								ok = back.llvm_ctx.emit_ir_to_file(&lc, out_path);
							} else if opts.compile_only {
								if opts.lto != driver.cli.LtoMode.None {
									ok = back.llvm_ctx.emit_bc_to_file(&lc, out_path);
								} else {
									ok = back.llvm_ctx.emit_obj_to_file(&lc, out_path);
								}
							} else {
								let tmp_obj: []u8 = default_output_path(out_path, ".tmp.o");
								if opts.lto != driver.cli.LtoMode.None {
									ok = back.llvm_ctx.emit_bc_to_file(&lc, tmp_obj);
								} else {
									ok = back.llvm_ctx.emit_obj_to_file(&lc, tmp_obj);
								}
								if ok {
									ok = link_executable(tmp_obj, out_path, &opts);
								}
							}
							if ok && opts.emit_depfile {
								let dpath: []u8 = opts.depfile_path.len > 0 ? opts.depfile_path
									: default_output_path(out_path, ".d");
								let cpath: *mut u8 = back.codegen.expressions.cstr_from_slice(
									dpath
								);
								if cpath != null {
									let raw_flags: u32 = (std.io.file.OpenFlags.Write cast u32)
										| (std.io.file.OpenFlags.Create cast u32)
										| (std.io.file.OpenFlags.Truncate cast u32);
									let flags: std.io.file.OpenFlags = raw_flags
										cast std.io.file.OpenFlags;
									match std.io.file.open(cpath, flags, 420) {
										.Ok(mut f) => {
											std.io.write_all(&f, out_path.ptr, out_path.len);
											std.io.write_all(&f, ":".ptr, 1);
											for let mut mi: usize = 0; mi
												< mtable.modules.len; mi += 1 {
												let mp: []u8 = mtable.modules.data[mi].path;
												std.io.write_all(&f, " ".ptr, 1);
												std.io.write_all(&f, mp.ptr, mp.len);
											}
											for let mut ei: usize = 0; ei
												< sema.embed_files.len; ei += 1 {
												let ep: []u8 = sema.embed_files.data[ei];
												std.io.write_all(&f, " ".ptr, 1);
												std.io.write_all(&f, ep.ptr, ep.len);
											}
											std.io.write_all(&f, "\n".ptr, 1);
											f.close();
										}
										.Err(_) => {}
									}
								}
							}
						}
					back.codegen.expressions.dispose_codegen(&cg);
					} else {
						ok = false;
					}
					back.llvm_ctx.dispose_llvm_ctx(&lc);
				}
				sema.scopes.free();
			}
		}
	}

	tokens.free();
	driver.cli.free_options(&opts);
	front.log.finish();
	front.log.reset();

	return ok ? 0 : 1;
}
