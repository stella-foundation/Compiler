mod driver.cli;
import "front/log.sl";
import "std/io.sl";
import "std/mem.sl";
import "std/str.sl";

/// Enumerates `OptLevel` variants.
pub enum OptLevel: u8 {
	None,
	Low,
	Medium,
	High,
	Size
}

/// Enumerates `LtoMode` variants.
pub enum LtoMode: u8 {
	None,
	Full,
	Thin
}

/// Enumerates `RelocModel` variants.
pub enum RelocModel: u8 {
	Static,
	Pic
}

/// Enumerates `CodeModel` variants.
pub enum CodeModel: u8 {
	Tiny,
	Small,
	Kernel,
	Medium,
	Large
}

/// Enumerates `RelroMode` variants.
pub enum RelroMode: u8 {
	None,
	Partial,
	Full
}

/// Enumerates `IcfMode` variants.
pub enum IcfMode: u8 {
	None,
	Safe,
	All
}

/// Represents the `StrList` data structure.
pub struct StrList {
	/// Stores the `data` field (data).
	pub data: *mut []u8,
	/// Stores the `len` field (len).
	pub len: usize,
	/// Stores the `cap` field (cap).
	pub cap: usize
}

impl StrList {
	/// Executes `init` (init).
	pub fn init(self: *mut Self) -> void {
		self.data = null;
		self.len = 0;
		self.cap = 0;
	}

	/// Executes `push` (push).
	pub fn push(self: *mut Self, s: []u8) -> bool {
		if self.len == self.cap {
			let new_cap: usize = self.cap == 0 ? 8 : self.cap * 2;
			let mut pa: std.mem.PageAllocator = std.mem.PageAllocator.init();
			match pa.alloc(new_cap * @of.size([]u8), @of.align([]u8)) {
				.Ok(raw) => {
					let next_buf: *mut []u8 = raw cast *mut []u8;
					if self.data != null {
						std.mem.copy(raw, self.data cast *u8, self.len * @of.size([]u8));
						pa.free(
							self.data cast *u8,
							self.cap * @of.size([]u8),
							@of.align([]u8)
						);
					}
					self.data = next_buf;
					self.cap = new_cap;
				}
				.Err(_) => return false
			}
		}
		self.data[self.len] = s;
		self.len += 1;
		return true;
	}

	/// Executes `free` (free).
	pub fn free(self: *mut Self) -> void {
		if self.data != null {
			let mut pa: std.mem.PageAllocator = std.mem.PageAllocator.init();
			pa.free(self.data cast *u8, self.cap * @of.size([]u8), @of.align([]u8));
			self.data = null;
		}
		self.len = 0;
		self.cap = 0;
	}
}

/// Represents the `CliOptions` data structure.
pub struct CliOptions {
	/// Stores the `show_help` field (show help).
	pub show_help: bool,
	/// Stores the `input` field (input).
	pub input: []u8,
	/// Stores the `output` field (output).
	pub output: []u8,
	/// Stores the `compile_only` field (compile only).
	pub compile_only: bool,
	/// Stores the `emit_ir` field (emit ir).
	pub emit_ir: bool,
	/// Stores the `emit_tokens` field (emit tokens).
	pub emit_tokens: bool,
	/// Stores the `emit_ast` field (emit ast).
	pub emit_ast: bool,
	/// Stores the `emit_depfile` field (emit depfile).
	pub emit_depfile: bool,
	/// Stores the `depfile_path` field (depfile path).
	pub depfile_path: []u8,
	/// Stores the `opt_level` field (opt level).
	pub opt_level: OptLevel,
	/// Stores the `lto` field (lto).
	pub lto: LtoMode,
	/// Stores the `function_sections` field (function sections).
	pub function_sections: bool,
	/// Stores the `target_triple` field (target triple).
	pub target_triple: []u8,
	/// Stores the `cpu_specific` field (cpu specific).
	pub cpu_specific: []u8,
	/// Stores the `cpu_tune` field (cpu tune).
	pub cpu_tune: []u8,
	/// Stores the `relocation` field (relocation).
	pub relocation: RelocModel,
	/// Stores the `code_model` field (code model).
	pub code_model: CodeModel,
	/// Stores the `target_sysroot` field (target sysroot).
	pub target_sysroot: []u8,
	/// Stores the `libraries` field (libraries).
	pub libraries: StrList,
	/// Stores the `link_mode` field (link mode).
	pub link_mode: []u8,
	/// Stores the `relro_mode` field (relro mode).
	pub relro_mode: RelroMode,
	/// Stores the `icf_mode` field (icf mode).
	pub icf_mode: IcfMode,
	/// Stores the `linker` field (linker).
	pub linker: []u8,
	/// Stores the `raw_linker` field (raw linker).
	pub raw_linker: []u8,
	/// Stores the `dynamic_linker` field (dynamic linker).
	pub dynamic_linker: []u8,
	/// Stores the `startup` field (startup).
	pub startup: []u8,
	/// Stores the `user_defines` field (user defines).
	pub user_defines: StrList,
	/// Stores the `import_roots` field (import roots).
	pub import_roots: StrList,
	/// Stores the `auto_include_packages` field (auto include packages).
	pub auto_include_packages: bool,
	/// Stores the `warn_error` field (warn error).
	pub warn_error: bool,
	/// Stores the `diag_format` field (diag format).
	pub diag_format: front.log.Format,
	/// Stores the `diag_color` field (diag color).
	pub diag_color: front.log.Color,
	/// Stores the `error_limit` field (error limit).
	pub error_limit: i32
}

/// Executes `default_options` (default options).
pub fn default_options() -> CliOptions {
	let mut opts: CliOptions = {
		.show_help = false,
		.input = "",
		.output = "",
		.compile_only = false,
		.emit_ir = false,
		.emit_tokens = false,
		.emit_ast = false,
		.emit_depfile = false,
		.depfile_path = "",
		.opt_level = OptLevel.None,
		.lto = LtoMode.None,
		.function_sections = false,
		.target_triple = "",
		.cpu_specific = "generic",
		.cpu_tune = "generic",
		.relocation = RelocModel.Static,
		.code_model = CodeModel.Small,
		.target_sysroot = "",
		.libraries = { .data = null, .len = 0, .cap = 0 },
		.link_mode = "dynamic",
		.relro_mode = RelroMode.None,
		.icf_mode = IcfMode.None,
		.linker = "cc",
		.raw_linker = "ld.lld",
		.dynamic_linker = "",
		.startup = "stella",
		.user_defines = { .data = null, .len = 0, .cap = 0 },
		.import_roots = { .data = null, .len = 0, .cap = 0 },
		.auto_include_packages = true,
		.warn_error = false,
		.diag_format = front.log.Format.Human,
		.diag_color = front.log.Color.Auto,
		.error_limit = 20
	};
	return opts;
}

/// Executes `free_options` (free options).
pub fn free_options(opts: *mut CliOptions) -> void {
	opts.libraries.free();
	opts.user_defines.free();
	opts.import_roots.free();
}

/// Executes `print_usage` (print usage).
pub fn print_usage() -> void {
	std.io.eprint(
		"Usage: stellac <input.sl> [--build.output=<path>] [--build.compile-only]\n"
	);
	std.io.eprint(
		"                     [--emit.ir] [--emit.depfile[=<path>]] [--emit.tokens] [--emit.ast]\n"
	);
	std.io.eprint(
		"                     [--opt.level=<none*|low|medium|high|size>]\n"
	);
	std.io.eprint(
		"                     [--opt.lto=<none*|thin|full>]\n"
	);
	std.io.eprint(
		"                     [--opt.function-sections]\n"
	);
	std.io.eprint(
		"                     [--tar.triple=<triple>]\n"
	);
	std.io.eprint(
		"                     [--tar.cpu=<generic*|cpu|native>]\n"
	);
	std.io.eprint(
		"                     [--tar.tune=<generic*|cpu|native>]\n"
	);
	std.io.eprint(
		"                     [--tar.relocation=<static*|pic>]\n"
	);
	std.io.eprint(
		"                     [--tar.code-model=<tiny|small*|kernel|medium|large>]\n"
	);
	std.io.eprint(
		"                     [--tar.sysroot=<path>]\n"
	);
	std.io.eprint(
		"                     [--link.lib=<name> ...]\n"
	);
	std.io.eprint(
		"                     [--link.mode=<dynamic*|static>]\n"
	);
	std.io.eprint(
		"                     [--link.relro=<none*|partial|full>]\n"
	);
	std.io.eprint(
		"                     [--link.icf=<none*|safe|all>]\n"
	);
	std.io.eprint(
		"                     [--link.driver=<driver>]\n"
	);
	std.io.eprint(
		"                     [--link.program=<linker>]\n"
	);
	std.io.eprint(
		"                     [--link.dynamic-loader=<path>]\n"
	);
	std.io.eprint(
		"                     [--rt.start=<stella*|crt>]\n"
	);
	std.io.eprint(
		"                     [--src.define=<flag> ...]\n"
	);
	std.io.eprint(
		"                     [--src.include=<dir>]\n"
	);
	std.io.eprint(
		"                     [--src.no-auto-include]\n"
	);
	std.io.eprint(
		"                     [--diag.warn-error]\n"
	);
	std.io.eprint(
		"                     [--diag.format=<human*|json>]\n"
	);
	std.io.eprint(
		"                     [--diag.color=<auto*|always|never>]\n"
	);
	std.io.eprint(
		"                     [--diag.error-limit=<n>]\n"
	);
}

fn cli_error(msg: []u8, code: front.log.DiagCode) -> void {
	front.log.report(front.log.Level.Error, front.log.empty_loc(), msg, code);
}

fn parse_nonneg_i32(s: []u8, out: *mut i32) -> bool {
	if s.len == 0 {
		return false;
	}
	let mut v: i64 = 0;
	for let mut i: usize = 0; i < s.len; i += 1 {
		let c: u8 = s[i];
		if c < '0' || c > '9' {
			return false;
		}
		v = v * 10 + ((c - '0') cast i64);
		if v > 2147483647 {
			return false;
		}
	}
	*out = v cast i32;
	return true;
}

fn find_byte(s: []u8, target: u8) -> isize {
	for let mut i: usize = 0; i < s.len; i += 1 {
		if s[i] == target {
			return i cast isize;
		}
	}
	return -1;
}

fn starts_with(s: []u8, prefix: []u8) -> bool {
	if s.len < prefix.len {
		return false;
	}
	return std.str.eq(s[0..prefix.len], prefix);
}

fn apply_diag_config(opts: *CliOptions) -> void {
	front.log.configure(opts.diag_format, opts.diag_color, opts.error_limit);
	front.log.set_warn_error(opts.warn_error);
}

/// Executes `parse_args` (parse args).
pub fn parse_args(argc: usize, argv: **u8, opts: *mut CliOptions) -> bool {
	apply_diag_config(opts);

	for let mut i: usize = 1; i < argc; i += 1 {
		let a: []u8 = std.str.from_cstr(argv[i]);
		if std.str.eq(a, "--help") || std.str.eq(a, "-h") {
			opts.show_help = true;
			return true;
		}

		if starts_with(a, "--") {
			let eq_idx: isize = find_byte(a, '=');
			let has_value: bool = eq_idx >= 0;
			let key: []u8 = has_value ? a[2..(eq_idx cast usize)] : a[2..a.len];
			let val: []u8 = has_value ? a[((eq_idx cast usize) + 1)..a.len] : "";

			let dot_idx: isize = find_byte(key, '.');
			if dot_idx < 0 {
				cli_error("unknown option", front.log.DiagCode.CliInvalidOption);
				return false;
			}
			let mod_name: []u8 = key[0..(dot_idx cast usize)];
			let opt_name: []u8 = key[((dot_idx cast usize) + 1)..key.len];

			if std.str.eq(mod_name, "build") && std.str.eq(opt_name, "output") {
				if !has_value || val.len == 0 {
					cli_error(
						"--build.output requires a value",
						front.log.DiagCode.CliInvalidOption
					);
					return false;
				}
				opts.output = val;
			} else if std.str.eq(mod_name, "build") && std.str.eq(opt_name, "compile-only") {
				if has_value {
					cli_error(
						"--build.compile-only does not take a value",
						front.log.DiagCode.CliInvalidOption
					);
					return false;
				}
				opts.compile_only = true;
			} else if std.str.eq(mod_name, "emit") && std.str.eq(opt_name, "ir") {
				if has_value {
					cli_error(
						"--emit.ir does not take a value",
						front.log.DiagCode.CliInvalidOption
					);
					return false;
				}
				opts.emit_ir = true;
			} else if std.str.eq(mod_name, "emit") && std.str.eq(opt_name, "tokens") {
				if has_value {
					cli_error(
						"--emit.tokens does not take a value",
						front.log.DiagCode.CliInvalidOption
					);
					return false;
				}
				opts.emit_tokens = true;
			} else if std.str.eq(mod_name, "emit") && std.str.eq(opt_name, "ast") {
				if has_value {
					cli_error(
						"--emit.ast does not take a value",
						front.log.DiagCode.CliInvalidOption
					);
					return false;
				}
				opts.emit_ast = true;
			} else if std.str.eq(mod_name, "emit") && std.str.eq(opt_name, "depfile") {
				if has_value && val.len == 0 {
					cli_error(
						"--emit.depfile requires a path when '=' is used",
						front.log.DiagCode.CliInvalidOption
					);
					return false;
				}
				opts.emit_depfile = true;
				if has_value {
					opts.depfile_path = val;
				}
			} else if std.str.eq(mod_name, "opt") && std.str.eq(opt_name, "level") {
				if !has_value || val.len == 0 {
					cli_error("--opt.level requires a value", front.log.DiagCode.CliInvalidOption);
					return false;
				}
				if std.str.eq(val, "none") {
					opts.opt_level = OptLevel.None;
				} else if std.str.eq(val, "low") {
					opts.opt_level = OptLevel.Low;
				} else if std.str.eq(val, "medium") {
					opts.opt_level = OptLevel.Medium;
				} else if std.str.eq(val, "high") {
					opts.opt_level = OptLevel.High;
				} else if std.str.eq(val, "size") {
					opts.opt_level = OptLevel.Size;
				} else {
					cli_error(
						"--opt.level must be one of: none, low, medium, high, size",
						front.log.DiagCode.CliInvalidOption
					);
					return false;
				}
			} else if std.str.eq(mod_name, "opt") && std.str.eq(opt_name, "lto") {
				if !has_value || val.len == 0 {
					cli_error("--opt.lto requires a value", front.log.DiagCode.CliInvalidOption);
					return false;
				}
				if std.str.eq(val, "none") {
					opts.lto = LtoMode.None;
				} else if std.str.eq(val, "thin") {
					opts.lto = LtoMode.Thin;
				} else if std.str.eq(val, "full") {
					opts.lto = LtoMode.Full;
				} else {
					cli_error(
						"--opt.lto must be one of: none, thin, full",
						front.log.DiagCode.CliInvalidOption
					);
					return false;
				}
			} else if std.str.eq(mod_name, "opt") && std.str.eq(opt_name, "function-sections") {
				if has_value {
					cli_error(
						"--opt.function-sections does not take a value",
						front.log.DiagCode.CliInvalidOption
					);
					return false;
				}
				opts.function_sections = true;
			} else if std.str.eq(mod_name, "tar") && std.str.eq(opt_name, "triple") {
				if !has_value || val.len == 0 {
					cli_error("--tar.triple requires a value", front.log.DiagCode.CliInvalidOption);
					return false;
				}
				opts.target_triple = val;
			} else if std.str.eq(mod_name, "tar") && std.str.eq(opt_name, "cpu") {
				if !has_value || val.len == 0 {
					cli_error("--tar.cpu requires a value", front.log.DiagCode.CliInvalidOption);
					return false;
				}
				opts.cpu_specific = val;
			} else if std.str.eq(mod_name, "tar") && std.str.eq(opt_name, "tune") {
				if !has_value || val.len == 0 {
					cli_error("--tar.tune requires a value", front.log.DiagCode.CliInvalidOption);
					return false;
				}
				opts.cpu_tune = val;
			} else if std.str.eq(mod_name, "tar") && std.str.eq(opt_name, "relocation") {
				if !has_value || val.len == 0 {
					cli_error(
						"--tar.relocation requires a value",
						front.log.DiagCode.CliInvalidOption
					);
					return false;
				}
				if std.str.eq(val, "static") {
					opts.relocation = RelocModel.Static;
				} else if std.str.eq(val, "pic") {
					opts.relocation = RelocModel.Pic;
				} else {
					cli_error(
						"--tar.relocation must be one of: static, pic",
						front.log.DiagCode.CliInvalidOption
					);
					return false;
				}
			} else if std.str.eq(mod_name, "tar") && std.str.eq(opt_name, "code-model") {
				if !has_value || val.len == 0 {
					cli_error(
						"--tar.code-model requires a value",
						front.log.DiagCode.CliInvalidOption
					);
					return false;
				}
				if std.str.eq(val, "tiny") {
					opts.code_model = CodeModel.Tiny;
				} else if std.str.eq(val, "small") {
					opts.code_model = CodeModel.Small;
				} else if std.str.eq(val, "kernel") {
					opts.code_model = CodeModel.Kernel;
				} else if std.str.eq(val, "medium") {
					opts.code_model = CodeModel.Medium;
				} else if std.str.eq(val, "large") {
					opts.code_model = CodeModel.Large;
				} else {
					cli_error(
						"--tar.code-model must be one of: tiny, small, kernel, medium, large",
						front.log.DiagCode.CliInvalidOption
					);
					return false;
				}
			} else if std.str.eq(mod_name, "tar") && std.str.eq(opt_name, "sysroot") {
				if !has_value || val.len == 0 {
					cli_error(
						"--tar.sysroot requires a value",
						front.log.DiagCode.CliInvalidOption
					);
					return false;
				}
				opts.target_sysroot = val;
			} else if std.str.eq(mod_name, "link") && std.str.eq(opt_name, "lib") {
				if !has_value || val.len == 0 {
					cli_error("--link.lib requires a value", front.log.DiagCode.CliInvalidOption);
					return false;
				}
				opts.libraries.push(val);
			} else if std.str.eq(mod_name, "link") && std.str.eq(opt_name, "mode") {
				if !has_value || val.len == 0 {
					cli_error("--link.mode requires a value", front.log.DiagCode.CliInvalidOption);
					return false;
				}
				if !std.str.eq(val, "dynamic") && !std.str.eq(val, "static") {
					cli_error(
						"--link.mode must be one of: dynamic, static",
						front.log.DiagCode.CliInvalidOption
					);
					return false;
				}
				opts.link_mode = val;
			} else if std.str.eq(mod_name, "link") && std.str.eq(opt_name, "relro") {
				if !has_value || val.len == 0 {
					cli_error("--link.relro requires a value", front.log.DiagCode.CliInvalidOption);
					return false;
				}
				if std.str.eq(val, "none") {
					opts.relro_mode = RelroMode.None;
				} else if std.str.eq(val, "partial") {
					opts.relro_mode = RelroMode.Partial;
				} else if std.str.eq(val, "full") {
					opts.relro_mode = RelroMode.Full;
				} else {
					cli_error(
						"--link.relro must be one of: none, partial, full",
						front.log.DiagCode.CliInvalidOption
					);
					return false;
				}
			} else if std.str.eq(mod_name, "link") && std.str.eq(opt_name, "icf") {
				if !has_value || val.len == 0 {
					cli_error("--link.icf requires a value", front.log.DiagCode.CliInvalidOption);
					return false;
				}
				if std.str.eq(val, "none") {
					opts.icf_mode = IcfMode.None;
				} else if std.str.eq(val, "safe") {
					opts.icf_mode = IcfMode.Safe;
				} else if std.str.eq(val, "all") {
					opts.icf_mode = IcfMode.All;
				} else {
					cli_error(
						"--link.icf must be one of: none, safe, all",
						front.log.DiagCode.CliInvalidOption
					);
					return false;
				}
			} else if std.str.eq(mod_name, "link") && std.str.eq(opt_name, "driver") {
				if !has_value || val.len == 0 {
					cli_error(
						"--link.driver requires a value",
						front.log.DiagCode.CliInvalidOption
					);
					return false;
				}
				opts.linker = val;
			} else if std.str.eq(mod_name, "link") && std.str.eq(opt_name, "program") {
				if !has_value || val.len == 0 {
					cli_error(
						"--link.program requires a value",
						front.log.DiagCode.CliInvalidOption
					);
					return false;
				}
				opts.raw_linker = val;
			} else if std.str.eq(mod_name, "link") && std.str.eq(opt_name, "dynamic-loader") {
				if !has_value || val.len == 0 {
					cli_error(
						"--link.dynamic-loader requires a value",
						front.log.DiagCode.CliInvalidOption
					);
					return false;
				}
				opts.dynamic_linker = val;
			} else if std.str.eq(mod_name, "rt") && std.str.eq(opt_name, "start") {
				if !has_value || val.len == 0 {
					cli_error("--rt.start requires a value", front.log.DiagCode.CliInvalidOption);
					return false;
				}
				if !std.str.eq(val, "stella") && !std.str.eq(val, "crt") {
					cli_error(
						"--rt.start must be one of: stella, crt",
						front.log.DiagCode.CliInvalidOption
					);
					return false;
				}
				opts.startup = val;
			} else if std.str.eq(mod_name, "src") && std.str.eq(opt_name, "define") {
				if !has_value || val.len == 0 {
					cli_error("--src.define requires a value", front.log.DiagCode.CliInvalidOption);
					return false;
				}
				opts.user_defines.push(val);
			} else if std.str.eq(mod_name, "src") && std.str.eq(opt_name, "include") {
				if !has_value || val.len == 0 {
					cli_error(
						"--src.include requires a value",
						front.log.DiagCode.CliInvalidOption
					);
					return false;
				}
				opts.import_roots.push(val);
			} else if std.str.eq(mod_name, "src") && std.str.eq(opt_name, "no-auto-include") {
				if has_value {
					cli_error(
						"--src.no-auto-include does not take a value",
						front.log.DiagCode.CliInvalidOption
					);
					return false;
				}
				opts.auto_include_packages = false;
			} else if std.str.eq(mod_name, "diag") && std.str.eq(opt_name, "warn-error") {
				if has_value {
					cli_error(
						"--diag.warn-error does not take a value",
						front.log.DiagCode.CliInvalidOption
					);
					return false;
				}
				opts.warn_error = true;
				apply_diag_config(opts);
			} else if std.str.eq(mod_name, "diag") && std.str.eq(opt_name, "format") {
				if !has_value || val.len == 0 {
					cli_error(
						"--diag.format requires a value",
						front.log.DiagCode.CliInvalidOption
					);
					return false;
				}
				if std.str.eq(val, "human") {
					opts.diag_format = front.log.Format.Human;
				} else if std.str.eq(val, "json") {
					opts.diag_format = front.log.Format.Json;
				} else {
					cli_error(
						"--diag.format must be one of: human, json",
						front.log.DiagCode.CliInvalidOption
					);
					return false;
				}
				apply_diag_config(opts);
			} else if std.str.eq(mod_name, "diag") && std.str.eq(opt_name, "color") {
				if !has_value || val.len == 0 {
					cli_error("--diag.color requires a value", front.log.DiagCode.CliInvalidOption);
					return false;
				}
				if std.str.eq(val, "auto") {
					opts.diag_color = front.log.Color.Auto;
				} else if std.str.eq(val, "always") {
					opts.diag_color = front.log.Color.Always;
				} else if std.str.eq(val, "never") {
					opts.diag_color = front.log.Color.Never;
				} else {
					cli_error(
						"--diag.color must be one of: auto, always, never",
						front.log.DiagCode.CliInvalidOption
					);
					return false;
				}
				apply_diag_config(opts);
			} else if std.str.eq(mod_name, "diag") && std.str.eq(opt_name, "error-limit") {
				if !has_value || val.len == 0 {
					cli_error(
						"--diag.error-limit requires a value",
						front.log.DiagCode.CliInvalidOption
					);
					return false;
				}
				let mut limit: i32 = 0;
				if !parse_nonneg_i32(val, &limit) {
					cli_error(
						"--diag.error-limit requires a non-negative integer",
						front.log.DiagCode.CliInvalidOption
					);
					return false;
				}
				opts.error_limit = limit;
				apply_diag_config(opts);
			} else {
				cli_error("unknown option", front.log.DiagCode.CliInvalidOption);
				return false;
			}
			continue;
		}

		if opts.input.len == 0 {
			opts.input = a;
		} else {
			cli_error("unexpected argument", front.log.DiagCode.CliInvalidOption);
			print_usage();
			return false;
		}
	}

	if opts.input.len == 0 {
		cli_error("an input file is required", front.log.DiagCode.CliMissingInput);
		print_usage();
		return false;
	}
	if opts.opt_level == OptLevel.Size {
		opts.function_sections = true;
	}
	if opts.auto_include_packages {
		add_unique_import_root(&opts.import_roots, "/usr/local/share/stella");
	}
	return true;
}

fn add_unique_import_root(list: *mut StrList, root: []u8) -> void {
	for let mut i: usize = 0; i < list.len; i += 1 {
		if std.str.eq(list.data[i], root) {
			return;
		}
	}
	list.push(root);
}
