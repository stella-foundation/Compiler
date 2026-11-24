mod front.log;
import "std/env.sl";
import "std/io.sl";
import "std/mem.sl";
import "std/str.sl";

/// Represents the `SourceLoc` data structure.
pub struct SourceLoc {
	/// Stores the `file` field (file).
	pub file: []u8,
	/// Stores the `line` field (line).
	pub line: i32,
	/// Stores the `column` field (column).
	pub column: i32,
	/// Stores the `length` field (length).
	pub length: i32
}

/// Represents the `SourceSpan` data structure.
pub struct SourceSpan {
	/// Stores the `start` field (start).
	pub start: SourceLoc,
	/// Stores the `end` field (end).
	pub end: SourceLoc
}

/// Enumerates `Level` variants.
pub enum Level: u8 {
	Note,
	Error,
	Warning,
	Help
}

/// Enumerates `Phase` variants.
pub enum Phase: u8 {
	Cli,
	Lexer,
	Parser,
	Resolver,
	Semantic,
	Codegen,
	Backend,
	Linker,
	Compiler
}

/// Enumerates `DiagCode` variants.
pub enum DiagCode: u16 {
	General,
	ErrorLimit,

	// Lexer
	LexInvalidCharacter,
	LexInvalidNumber,
	LexUnterminatedString,
	LexUnterminatedChar,

	// Parser
	ParseExpectedToken,
	ParseModuleHeader,

	// Resolver
	ModuleRead,
	ModuleNotFound,
	ModuleRoot,
	SourceNotFound,

	// Semantic
	TypeMismatch,
	UndefinedName,
	UndefinedType,
	UnknownMember,
	PrivateMember,
	InvalidAttribute,
	InvalidRange,
	InvalidControlFlow,
	InvalidAssignment,
	ImmutableAssignment,
	DuplicateDeclaration,
	LayoutMismatch,
	GenericConstraint,
	GenericTypeSet,
	TypeBindingCycle,
	InvalidCall,

	// Backend / Codegen
	CodegenFailure,
	EmitFailed,
	EmitTemp,
	BackendInit,
	TargetUnsupported,
	TargetCpu,
	TargetSysroot,

	// Linker
	LinkFailed,
	LinkCommand,
	LinkTemp,

	// CLI
	CliInvalidOption,
	CliMissingInput,
	InputRead,
	OutputPathCollision,
	DepfilePathCollision,
	DepfileWrite,
	ModuleCompile,
	RuntimeNotFound,

	// Warnings
	NumericOverflow,
	UnusedName,
	LinkFallback,
	WarningGeneral,

	// Notes
	Note
}

/// Enumerates `Format` variants.
pub enum Format: u8 {
	Human,
	Json
}

/// Enumerates `Color` variants.
pub enum Color: u8 {
	Auto,
	Always,
	Never
}

/// Represents the `Diagnostic` data structure.
pub struct Diagnostic {
	/// Stores the `level` field (level).
	pub level: Level,
	/// Stores the `code` field (code).
	pub code: DiagCode,
	/// Stores the `custom_code` field (custom code).
	pub custom_code: []u8,
	/// Stores the `message` field (message).
	pub message: []u8,
	/// Stores the `primary` field (primary).
	pub primary: SourceSpan,
	/// Stores the `help` field (help).
	pub help: []u8,
	/// Stores the `fixit_msg` field (fixit msg).
	pub fixit_msg: []u8,
	/// Stores the `fixit_repl` field (fixit repl).
	pub fixit_repl: []u8,
	/// Stores the `fixit_span` field (fixit span).
	pub fixit_span: SourceSpan,
	/// Stores the `note_msg` field (note msg).
	pub note_msg: []u8,
	/// Stores the `note_loc` field (note loc).
	pub note_loc: SourceLoc,
	/// Stores the `phase` field (phase).
	pub phase: Phase
}

struct RegisteredSource {
	path: []u8,
	content: []u8
}

struct DiagState {
	format: Format,
	color: Color,
	error_limit: i32,
	error_count: i32,
	warning_count: i32,
	warn_error: bool,
	suppressed_count: i32,
	limit_reported: bool,
	current_file: []u8,
	sources: *mut RegisteredSource,
	sources_len: usize,
	sources_cap: usize
}

let mut g_state: DiagState;

/// Executes `empty_loc` (empty loc).
pub fn empty_loc() -> SourceLoc {
	return { .file = "", .line = 0, .column = 0, .length = 0 };
}

/// Executes `make_loc` (make loc).
pub fn make_loc(file: []u8, line: i32, column: i32, length: i32) -> SourceLoc {
	return { .file = file, .line = line, .column = column, .length = length };
}

/// Executes `make_span` (make span).
pub fn make_span(loc: SourceLoc) -> SourceSpan {
	let len: i32 = loc.length > 0 ? loc.length : 1;
	let end_loc: SourceLoc = {
		.file = loc.file,
		.line = loc.line,
		.column = loc.column + len,
		.length = 0
	};
	return { .start = loc, .end = end_loc };
}

/// Executes `level_name` (level name).
pub fn level_name(level: Level) -> []u8 {
	match level {
		.Note => return "note",
		.Error => return "error",
		.Warning => return "warning",
		.Help => return "help"
	}
}

/// Executes `phase_str` (phase str).
pub fn phase_str(phase: Phase) -> []u8 {
	match phase {
		.Cli => return "cli",
		.Lexer => return "lexer",
		.Parser => return "parser",
		.Resolver => return "resolver",
		.Semantic => return "semantic",
		.Codegen => return "codegen",
		.Backend => return "backend",
		.Linker => return "linker",
		.Compiler => return "compiler"
	}
}

/// Executes `code_str` (code str).
pub fn code_str(code: DiagCode) -> []u8 {
	match code {
		.General => return "E_GENERAL",
		.ErrorLimit => return "E_ERROR_LIMIT",
		.LexInvalidCharacter => return "E_LEX_INVALID_CHARACTER",
		.LexInvalidNumber => return "E_LEX_INVALID_NUMBER",
		.LexUnterminatedString => return "E_LEX_UNTERMINATED_STRING",
		.LexUnterminatedChar => return "E_LEX_UNTERMINATED_CHAR",
		.ParseExpectedToken => return "E_PARSE_EXPECTED_TOKEN",
		.ParseModuleHeader => return "E_PARSE_MODULE_HEADER",
		.ModuleRead => return "E_MODULE_READ",
		.ModuleNotFound => return "E_MODULE_NOT_FOUND",
		.ModuleRoot => return "E_MODULE_ROOT",
		.SourceNotFound => return "E_SOURCE_NOT_FOUND",
		.TypeMismatch => return "E_TYPE_MISMATCH",
		.UndefinedName => return "E_UNDEFINED_NAME",
		.UndefinedType => return "E_UNDEFINED_TYPE",
		.UnknownMember => return "E_UNKNOWN_MEMBER",
		.PrivateMember => return "E_PRIVATE_MEMBER",
		.InvalidAttribute => return "E_INVALID_ATTRIBUTE",
		.InvalidRange => return "E_INVALID_RANGE",
		.InvalidControlFlow => return "E_INVALID_CONTROL_FLOW",
		.InvalidAssignment => return "E_INVALID_ASSIGNMENT",
		.ImmutableAssignment => return "E_IMMUTABLE_ASSIGNMENT",
		.DuplicateDeclaration => return "E_DUPLICATE_DECLARATION",
		.LayoutMismatch => return "E_LAYOUT_MISMATCH",
		.GenericConstraint => return "E_GENERIC_CONSTRAINT",
		.GenericTypeSet => return "E_GENERIC_TYPE_SET",
		.TypeBindingCycle => return "E_TYPE_BINDING_CYCLE",
		.InvalidCall => return "E_INVALID_CALL",
		.CodegenFailure => return "E_CODEGEN_FAILURE",
		.EmitFailed => return "E_EMIT_FAILED",
		.EmitTemp => return "E_EMIT_TEMP",
		.BackendInit => return "E_BACKEND_INIT",
		.TargetUnsupported => return "E_TARGET_UNSUPPORTED",
		.TargetCpu => return "E_TARGET_CPU",
		.TargetSysroot => return "E_TARGET_SYSROOT",
		.LinkFailed => return "E_LINK_FAILED",
		.LinkCommand => return "E_LINK_COMMAND",
		.LinkTemp => return "E_LINK_TEMP",
		.CliInvalidOption => return "E_CLI_INVALID_OPTION",
		.CliMissingInput => return "E_CLI_MISSING_INPUT",
		.InputRead => return "E_INPUT_READ",
		.OutputPathCollision => return "E_OUTPUT_PATH_COLLISION",
		.DepfilePathCollision => return "E_DEPFILE_PATH_COLLISION",
		.DepfileWrite => return "E_DEPFILE_WRITE",
		.ModuleCompile => return "E_MODULE_COMPILE",
		.RuntimeNotFound => return "E_RUNTIME_NOT_FOUND",
		.NumericOverflow => return "W_NUMERIC_OVERFLOW",
		.UnusedName => return "W_UNUSED_NAME",
		.LinkFallback => return "W_LINK_FALLBACK",
		.WarningGeneral => return "W_GENERAL",
		.Note => return "N_NOTE"
	}
}

/// Executes `code_phase` (code phase).
pub fn code_phase(code: DiagCode) -> Phase {
	match code {
		.LexInvalidCharacter | .LexInvalidNumber | .LexUnterminatedString
			| .LexUnterminatedChar => {
			return Phase.Lexer;
		}
		.ParseExpectedToken | .ParseModuleHeader => return Phase.Parser,
		.ModuleRead | .ModuleNotFound | .ModuleRoot | .SourceNotFound => return Phase.Resolver,
		.TypeMismatch | .UndefinedName | .UndefinedType | .UnknownMember | .PrivateMember
		| .InvalidAttribute | .InvalidRange | .InvalidControlFlow | .InvalidAssignment
		| .ImmutableAssignment | .DuplicateDeclaration | .LayoutMismatch | .GenericConstraint
		| .GenericTypeSet | .TypeBindingCycle | .InvalidCall | .NumericOverflow | .UnusedName => {
			return Phase.Semantic;
		}
		.CodegenFailure | .EmitFailed | .EmitTemp => return Phase.Codegen,
		.BackendInit | .TargetUnsupported | .TargetCpu | .TargetSysroot => return Phase.Backend,
		.LinkFailed | .LinkCommand | .LinkTemp | .LinkFallback => return Phase.Linker,
		.CliInvalidOption | .CliMissingInput | .InputRead | .OutputPathCollision
		| .DepfilePathCollision | .DepfileWrite | .ModuleCompile | .RuntimeNotFound => {
			return Phase.Cli;
		}
		_ => return Phase.Compiler
	}
}

/// Executes `reset` (reset).
pub fn reset() -> void {
	g_state.format = Format.Human;
	g_state.color = Color.Auto;
	g_state.error_limit = 20;
	g_state.error_count = 0;
	g_state.warning_count = 0;
	g_state.warn_error = false;
	g_state.suppressed_count = 0;
	g_state.limit_reported = false;
	g_state.current_file = "";
	if g_state.sources != null {
		let mut pa: std.mem.PageAllocator = std.mem.PageAllocator.init();
		pa.free(
			g_state.sources cast *u8,
			g_state.sources_cap * @of.size(RegisteredSource),
			@of.align(RegisteredSource)
		);
		g_state.sources = null;
	}
	g_state.sources_len = 0;
	g_state.sources_cap = 0;
}

/// Executes `configure` (configure).
pub fn configure(fmt: Format, col: Color, err_limit: i32) -> void {
	g_state.format = fmt;
	g_state.color = col;
	g_state.error_limit = err_limit;
}

/// Executes `set_warn_error` (set warn error).
pub fn set_warn_error(enabled: bool) -> void {
	g_state.warn_error = enabled;
}

/// Executes `set_current_file` (set current file).
pub fn set_current_file(path: []u8) -> void {
	g_state.current_file = path;
}

/// Executes `format` (format).
pub fn format() -> Format {
	return g_state.format;
}

/// Executes `color` (color).
pub fn color() -> Color {
	return g_state.color;
}

/// Executes `has_error` (has error).
pub fn has_error() -> bool {
	return g_state.error_count > 0;
}

/// Executes `error_count` (error count).
pub fn error_count() -> i32 {
	return g_state.error_count;
}

/// Executes `warning_count` (warning count).
pub fn warning_count() -> i32 {
	return g_state.warning_count;
}

/// Executes `register_source` (register source).
pub fn register_source(path: []u8, content: []u8) -> void {
	for let mut i: usize = 0; i < g_state.sources_len; i += 1 {
		if std.str.eq(g_state.sources[i].path, path) {
			g_state.sources[i].content = content;
			return;
		}
	}
	if g_state.sources_len == g_state.sources_cap {
		let new_cap: usize = g_state.sources_cap == 0 ? 8 : g_state.sources_cap * 2;
		let byte_size: usize = new_cap * @of.size(RegisteredSource);
		let mut pa: std.mem.PageAllocator = std.mem.PageAllocator.init();
		match pa.alloc(byte_size, @of.align(RegisteredSource)) {
			.Ok(raw) => {
				let next_buf: *mut RegisteredSource = raw cast *mut RegisteredSource;
				if g_state.sources != null {
					std.mem.copy(
						raw,
						g_state.sources cast *u8,
						g_state.sources_len * @of.size(RegisteredSource)
					);
					pa.free(
						g_state.sources cast *u8,
						g_state.sources_cap * @of.size(RegisteredSource),
						@of.align(RegisteredSource)
					);
				}
				g_state.sources = next_buf;
				g_state.sources_cap = new_cap;
			}
			.Err(_) => return
		}
	}
	g_state.sources[g_state.sources_len] = { .path = path, .content = content };
	g_state.sources_len += 1;
}

fn find_source(path: []u8) -> []u8 {
	for let mut i: usize = 0; i < g_state.sources_len; i += 1 {
		if std.str.eq(g_state.sources[i].path, path) {
			return g_state.sources[i].content;
		}
	}
	return "";
}

fn line_text(content: []u8, target_line: i32) -> []u8 {
	if content.len == 0 || target_line <= 0 {
		return "";
	}
	let mut cur_line: i32 = 1;
	let mut start: usize = 0;
	let mut i: usize = 0;
	for i < content.len {
		if cur_line == target_line {
			start = i;
			for i < content.len && content[i] != '\n' && content[i] != '\r' {
				i += 1;
			}
			return content[start..i];
		}
		if content[i] == '\n' {
			cur_line += 1;
		}
		i += 1;
	}
	return "";
}

fn count_digits(mut n: i32) -> i32 {
	if n <= 0 {
		return 1;
	}
	let mut d: i32 = 0;
	for n > 0 {
		d += 1;
		n /= 10;
	}
	return d;
}

fn use_color() -> bool {
	if g_state.format == Format.Json || g_state.color == Color.Never {
		return false;
	}
	if g_state.color == Color.Always {
		return true;
	}
	if std.env.has("NO_COLOR") {
		return false;
	}
	let stderr_fd: std.io.fd.Descriptor = std.io.fd.err();
	return stderr_fd.is_tty();
}

fn level_ansi_color(level: Level) -> []u8 {
	match level {
		.Error => return "\x1b[31m",
		.Warning => return "\x1b[33m",
		.Note => return "\x1b[36m",
		.Help => return "\x1b[32m"
	}
}

fn eprint_spaces(n: i32) -> void {
	for let mut i: i32 = 0; i < n; i += 1 {
		std.io.eprint(" ");
	}
}

fn eprint_json_escaped(s: []u8) -> void {
	for let mut i: usize = 0; i < s.len; i += 1 {
		let c: u8 = s[i];
		if c == '"' {
			std.io.eprint("\\\"");
		} else if c == '\\' {
			std.io.eprint("\\\\");
		} else if c == '\n' {
			std.io.eprint("\\n");
		} else if c == '\r' {
			std.io.eprint("\\r");
		} else if c == '\t' {
			std.io.eprint("\\t");
		} else if c < 32 {
			std.io.eprintf("\\u00{}{}", (c >> 4) & 15, c & 15);
		} else {
			std.io.eprintf("{c}", c);
		}
	}
}

fn print_json(diag: *Diagnostic) -> void {
	let code_name: []u8 = diag.custom_code.len > 0 ? diag.custom_code : code_str(diag.code);
	let ph_name: []u8 = phase_str(diag.phase);
	let sev_name: []u8 = level_name(diag.level);

	std.io.eprint("{\"severity\":\"");
	eprint_json_escaped(sev_name);
	std.io.eprint("\",\"code\":\"");
	eprint_json_escaped(code_name);
	std.io.eprint("\",\"message\":\"");
	eprint_json_escaped(diag.message);
	std.io.eprint("\",\"phase\":\"");
	eprint_json_escaped(ph_name);
	std.io.eprint("\",\"primary\":{\"file\":\"");
	eprint_json_escaped(diag.primary.start.file);
	std.io.eprintf("\",\"start\":{\"line\":{},\"column\":{}},\"end\":{\"line\":{},\"column\":{}}}",
		diag.primary.start.line,
		diag.primary.start.column,
		diag.primary.end.line,
		diag.primary.end.column);
	std.io.eprint(",\"related\":[");
	if diag.note_msg.len > 0 {
		std.io.eprint("{\"message\":\"");
		eprint_json_escaped(diag.note_msg);
		std.io.eprint("\"}");
	}
	std.io.eprint("],\"help\":");
	if diag.help.len == 0 {
		std.io.eprint("null");
	} else {
		std.io.eprint("\"");
		eprint_json_escaped(diag.help);
		std.io.eprint("\"");
	}
	std.io.eprint(",\"fixits\":[");
	if diag.fixit_repl.len > 0 {
		std.io.eprint("{");
		if diag.fixit_span.start.line > 0 {
			std.io.eprint("\"span\":{\"file\":\"");
			eprint_json_escaped(diag.fixit_span.start.file);
			std.io.eprintf(
				"\",\"start\":{{\"line\":{},\"column\":{}}},",
				diag.fixit_span.start.line,
				diag.fixit_span.start.column
			);
			std.io.eprintf(
				"\"end\":{{\"line\":{},\"column\":{}}}}},",
				diag.fixit_span.end.line,
				diag.fixit_span.end.column
			);
		}
		std.io.eprint("\"message\":\"");
		eprint_json_escaped(diag.fixit_msg);
		std.io.eprint("\",\"replacement\":\"");
		eprint_json_escaped(diag.fixit_repl);
		std.io.eprint("\"}");
	}
	std.io.eprint("],\"attachments\":[]}\n");
}

fn print_human(diag: *Diagnostic) -> void {
	let ansi: bool = use_color();
	let code_name: []u8 = diag.custom_code.len > 0 ? diag.custom_code : code_str(diag.code);
	let sev_name: []u8 = level_name(diag.level);
	let mut file: []u8 = diag.primary.start.file;
	if file.len == 0 {
		file = g_state.current_file.len > 0 ? g_state.current_file : "<input>";
	}

	if ansi {
		std.io.eprint("\x1b[1m");
		std.io.eprint(level_ansi_color(diag.level));
	}
	std.io.eprintf("{}[{}]", sev_name, code_name);
	if ansi {
		std.io.eprint("\x1b[0m");
	}
	std.io.eprintf(": {}\n", diag.message);

	if diag.primary.start.line > 0 {
		std.io.eprintf(" --> {}:{}:{}\n", file, diag.primary.start.line, diag.primary.start.column);
		let content: []u8 = find_source(file);
		let text: []u8 = line_text(content, diag.primary.start.line);
		if text.len > 0 {
			let width: i32 = count_digits(diag.primary.start.line);
			eprint_spaces(width);
			std.io.eprint(" |\n");
			if ansi {
				std.io.eprint("\x1b[2m");
			}
			std.io.eprintf("{} | {}\n", diag.primary.start.line, text);
			if ansi {
				std.io.eprint("\x1b[0m");
			}
			eprint_spaces(width);
			std.io.eprint(" | ");
			for let mut i: i32 = 1; i < diag.primary.start.column; i += 1 {
				let idx: usize = (i - 1) cast usize;
				if idx < text.len && text[idx] == '\t' {
					std.io.eprint("\t");
				} else {
					std.io.eprint(" ");
				}
			}
			if ansi {
				std.io.eprint(level_ansi_color(diag.level));
			}
			std.io.eprint("^");
			let span_len: i32 = diag.primary.start.length > 0 ? diag.primary.start.length : 1;
			for let mut i: i32 = 1; i < span_len; i += 1 {
				std.io.eprint("~");
			}
			if ansi {
				std.io.eprint("\x1b[0m");
			}
			std.io.eprint("\n");
		}
	}

	if diag.note_msg.len > 0 {
		std.io.eprintf(" = note: {}\n", diag.note_msg);
	}
	if diag.help.len > 0 {
		std.io.eprintf(" = help: {}\n", diag.help);
	}
	if diag.fixit_msg.len > 0 {
		std.io.eprintf(" = help: {}\n", diag.fixit_msg);
	}
}

/// Executes `emit` (emit).
pub fn emit(mut diag: Diagnostic) -> void {
	if diag.level == Level.Warning && g_state.warn_error {
		diag.level = Level.Error;
	}
	if diag.level == Level.Error {
		if g_state.error_limit > 0 && g_state.error_count >= g_state.error_limit {
			g_state.suppressed_count += 1;
			if !g_state.limit_reported {
				g_state.limit_reported = true;
				let limit_diag: Diagnostic = {
					.level = Level.Error,
					.code = DiagCode.ErrorLimit,
					.custom_code = "",
					.message = "error limit reached; suppressing further errors",
					.primary = make_span(empty_loc()),
					.help = "",
					.fixit_msg = "",
					.fixit_repl = "",
					.fixit_span = make_span(empty_loc()),
					.note_msg = "",
					.note_loc = empty_loc(),
					.phase = Phase.Compiler
				};
				if g_state.format == Format.Json {
					print_json(&limit_diag);
				} else {
					print_human(&limit_diag);
				}
			}
			g_state.error_count += 1;
			return;
		}
		g_state.error_count += 1;
	} else if diag.level == Level.Warning {
		g_state.warning_count += 1;
	}

	if g_state.format == Format.Json {
		print_json(&diag);
	} else {
		print_human(&diag);
	}
}

/// Executes `report` (report).
pub fn report(level: Level, loc: SourceLoc, message: []u8, code: DiagCode) -> void {
	let diag: Diagnostic = {
		.level = level,
		.code = code,
		.custom_code = "",
		.message = message,
		.primary = make_span(loc),
		.help = "",
		.fixit_msg = "",
		.fixit_repl = "",
		.fixit_span = make_span(empty_loc()),
		.note_msg = "",
		.note_loc = empty_loc(),
		.phase = code_phase(code)
	};
	emit(diag);
}

/// Executes `report_with_help` (report with help).
pub fn report_with_help(
	level: Level,
	loc: SourceLoc,
	message: []u8,
	code: DiagCode,
	help: []u8,
	fixit_msg: []u8,
	fixit_repl: []u8
) -> void {
	let diag: Diagnostic = {
		.level = level,
		.code = code,
		.custom_code = "",
		.message = message,
		.primary = make_span(loc),
		.help = help,
		.fixit_msg = fixit_msg,
		.fixit_repl = fixit_repl,
		.fixit_span = make_span(empty_loc()),
		.note_msg = "",
		.note_loc = empty_loc(),
		.phase = code_phase(code)
	};
	emit(diag);
}

/// Executes `report_with_note` (report with note).
pub fn report_with_note(
	level: Level,
	loc: SourceLoc,
	message: []u8,
	code: DiagCode,
	note_msg: []u8,
	note_loc: SourceLoc
) -> void {
	let diag: Diagnostic = {
		.level = level,
		.code = code,
		.custom_code = "",
		.message = message,
		.primary = make_span(loc),
		.help = "",
		.fixit_msg = "",
		.fixit_repl = "",
		.fixit_span = make_span(empty_loc()),
		.note_msg = note_msg,
		.note_loc = note_loc,
		.phase = code_phase(code)
	};
	emit(diag);
}

/// Executes `report_custom` (report custom).
pub fn report_custom(
	level: Level,
	loc: SourceLoc,
	message: []u8,
	custom_code: []u8,
	phase: Phase
) -> void {
	let diag: Diagnostic = {
		.level = level,
		.code = DiagCode.General,
		.custom_code = custom_code,
		.message = message,
		.primary = make_span(loc),
		.help = "",
		.fixit_msg = "",
		.fixit_repl = "",
		.fixit_span = make_span(empty_loc()),
		.note_msg = "",
		.note_loc = empty_loc(),
		.phase = phase
	};
	emit(diag);
}

/// Executes `levenshtein` (levenshtein).
pub fn levenshtein(a: []u8, b: []u8) -> usize {
	if a.len == 0 {
		return b.len;
	}
	if b.len == 0 {
		return a.len;
	}
	if a.len > 63 || b.len > 63 {
		return 99;
	}
	let mut prev: [64]usize;
	let mut curr: [64]usize;
	for let mut j: usize = 0; j <= b.len; j += 1 {
		prev[j] = j;
	}
	for let mut i: usize = 1; i <= a.len; i += 1 {
		curr[0] = i;
		for let mut j: usize = 1; j <= b.len; j += 1 {
			let cost: usize = a[i - 1] == b[j - 1] ? 0 : 1;
			let del: usize = prev[j] + 1;
			let ins: usize = curr[j - 1] + 1;
			let sub: usize = prev[j - 1] + cost;
			let mut m: usize = del < ins ? del : ins;
			if sub < m {
				m = sub;
			}
			curr[j] = m;
		}
		for let mut j: usize = 0; j <= b.len; j += 1 {
			prev[j] = curr[j];
		}
	}
	return prev[b.len];
}

/// Executes `finish` (finish).
pub fn finish() -> void {
	if g_state.suppressed_count > 0 && g_state.format == Format.Human {
		std.io.eprintf("note: {} further error(s) suppressed\n", g_state.suppressed_count);
	}
}
