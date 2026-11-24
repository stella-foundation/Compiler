mod middle.resolver;
import "driver/cli.sl";
import "front/ast.sl";
import "front/lexer.sl";
import "front/log.sl";
import "front/parser/module.sl";
import "front/token.sl";
import "std/err.sl";
import "std/io.sl";
import "std/mem.sl";
import "std/str.sl";

/// Represents the `LoadedModule` data structure.
pub struct LoadedModule {
	/// Stores the `path` field (path).
	pub path: []u8,
	/// Stores the `source` field (source).
	pub source: []u8,
	/// Stores the `tokens` field (tokens).
	pub tokens: front.token.TokenList,
	/// Stores the `ast` field (ast).
	pub ast: front.ast.Module,
	/// Stores the `in_progress` field (in progress).
	pub in_progress: bool,
	/// Stores the `resolved` field (resolved).
	pub resolved: bool
}

/// Represents the `ModuleTable` data structure.
pub struct ModuleTable {
	/// Stores the `modules` field (modules).
	pub modules: front.ast.PtrList<LoadedModule>,
	/// Stores the `include_roots` field (include roots).
	pub include_roots: *driver.cli.StrList
}

/// Executes `init_module_table` (init module table).
pub fn init_module_table(include_roots: *driver.cli.StrList) -> ModuleTable {
	return {
		.modules = { .data = null, .len = 0, .cap = 0 },
		.include_roots = include_roots
	};
}

/// Executes `read_file_bytes` (read file bytes).
pub fn read_file_bytes(path: []u8, out_buf: *mut []u8) -> bool {
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

/// Executes `dir_of` (dir of).
pub fn dir_of(path: []u8) -> []u8 {
	let mut i: usize = path.len;
	for i > 0 {
		i -= 1;
		if path[i] == '/' {
			return path[0..i];
		}
	}
	return ".";
}

/// Executes `join_path` (join path).
pub fn join_path(base: []u8, rel: []u8) -> []u8 {
	let clean_rel: []u8 = (rel.len >= 2 && rel[0] == '.' && rel[1] == '/') ? rel[2..rel.len] : rel;
	if base.len == 0 || std.str.eq(base, ".") {
		return clean_rel;
	}
	let need_slash: bool = base[base.len - 1] != '/';
	let total: usize = base.len + (need_slash ? 1 : 0) + clean_rel.len;
	let buf: *mut u8 = front.ast.arena_alloc(total);
	if buf == null {
		return clean_rel;
	}
	std.mem.copy(buf, base.ptr, base.len);
	let mut off: usize = base.len;
	if need_slash {
		buf[off] = '/';
		off += 1;
	}
	std.mem.copy(&buf[off], clean_rel.ptr, clean_rel.len);
	return buf[0..total];
}

/// Executes `file_exists` (file exists).
pub fn file_exists(path: []u8) -> bool {
	let cpath: *mut u8 = front.ast.arena_alloc(path.len + 1);
	if cpath == null {
		return false;
	}
	if path.len > 0 {
		std.mem.copy(cpath, path.ptr, path.len);
	}
	cpath[path.len] = 0;
	let mut ok: bool = false;
	match std.io.file.open(cpath, std.io.file.OpenFlags.Read, 0) {
		.Ok(mut f_handle) => {
			f_handle.close();
			ok = true;
		}
		.Err(_) => ok = false
	}
	return ok;
}

fn dir_exists(path: []u8) -> bool {
	let cpath: *mut u8 = front.ast.arena_alloc(path.len + 1);
	if cpath == null {
		return false;
	}
	if path.len > 0 {
		std.mem.copy(cpath, path.ptr, path.len);
	}
	cpath[path.len] = 0;
	let mut ok: bool = false;
	match std.io.dir.open(cpath) {
		.Ok(mut d_handle) => {
			d_handle.close();
			ok = true;
		}
		.Err(_) => ok = false
	}
	return ok;
}

fn ends_with(s: []u8, suffix: []u8) -> bool {
	if s.len < suffix.len {
		return false;
	}
	return std.str.eq(s[(s.len - suffix.len)..s.len], suffix);
}

fn load_and_resolve_file(
	table: *mut ModuleTable,
	resolved: []u8,
	loc: front.log.SourceLoc
) -> bool {
	if table.find(resolved) != null {
		return true;
	}
	let mut src: []u8 = "";
	if !read_file_bytes(resolved, &src) {
		front.log.report(
			front.log.Level.Error,
			loc,
			"could not read imported source file",
			front.log.DiagCode.ModuleRead
		);
		return false;
	}
	front.log.register_source(resolved, src);
	let mut tokens: front.token.TokenList;
	tokens.init(src.len >= 16 ? src.len / 4 : (16 cast usize));
	let mut lex: front.lexer.Lexer = front.lexer.init_lexer(src, resolved, true, &tokens);
	if !lex.tokenize() {
		tokens.free();
		return false;
	}
	let mut mod_ast: front.ast.Module = front.ast.init_module(resolved);
	let mut p: front.parser.Parser = front.parser.init_parser(&tokens, resolved);
	if !front.parser.parse_module(&p, &mod_ast) {
		tokens.free();
		return false;
	}
	let child: *mut LoadedModule = table.register_parsed(resolved, src, tokens, mod_ast);
	return table.resolve_module_imports(child);
}

fn base_of(path: []u8) -> []u8 {
	let mut i: usize = path.len;
	for i > 0 {
		i -= 1;
		if path[i] == '/' {
			return path[(i + 1)..path.len];
		}
	}
	return path;
}

fn stat_file(path: []u8, out: *mut std.io.fs.Info) -> bool {
	let cpath: *mut u8 = front.ast.arena_alloc(path.len + 1);
	if cpath == null {
		return false;
	}
	if path.len > 0 {
		std.mem.copy(cpath, path.ptr, path.len);
	}
	cpath[path.len] = 0;
	match std.io.dir.stat(cpath, true) {
		.Ok(info) => {
			*out = info;
			return true;
		}
		.Err(_) => return false
	}
}

fn same_file(a: []u8, b: []u8) -> bool {
	if !std.str.eq(base_of(a), base_of(b)) {
		return false;
	}
	let mut ia: std.io.fs.Info;
	let mut ib: std.io.fs.Info;
	if !stat_file(a, &ia) || !stat_file(b, &ib) {
		return false;
	}
	return ia.size == ib.size && ia.modified_ns == ib.modified_ns
		&& ia.permissions == ib.permissions && ia.links == ib.links;
}

impl ModuleTable {
	/// Executes `find` (find).
	pub fn find(self: *ModuleTable, path: []u8) -> *mut LoadedModule {
		for let mut i: usize = 0; i < self.modules.len; i += 1 {
			if std.str.eq(self.modules.data[i].path, path) {
				return self.modules.data[i];
			}
		}
		for let mut i: usize = 0; i < self.modules.len; i += 1 {
			if same_file(self.modules.data[i].path, path) {
				return self.modules.data[i];
			}
		}
		return null;
	}

	/// Executes `resolve_dir_path` (resolve dir path).
	pub fn resolve_dir_path(self: *ModuleTable, from_file: []u8, written_dir: []u8) -> []u8 {
		if written_dir.len == 0 {
			return "";
		}
		if written_dir[0] == '/' {
			return dir_exists(written_dir) ? written_dir : "";
		}
		if written_dir.len >= 2 && written_dir[0] == '.' && written_dir[1] == '/' {
			let candidate: []u8 = join_path(dir_of(from_file), written_dir);
			if dir_exists(candidate) {
				return candidate;
			}
		}
		if self.include_roots != null {
			for let mut i: usize = 0; i < self.include_roots.len; i += 1 {
				let candidate: []u8 = join_path(self.include_roots.data[i], written_dir);
				if dir_exists(candidate) {
					return candidate;
				}
			}
		}
		let rel_cand: []u8 = join_path(dir_of(from_file), written_dir);
		if dir_exists(rel_cand) {
			return rel_cand;
		}
		return "";
	}

	/// Executes `resolve_import_path` (resolve import path).
	pub fn resolve_import_path(self: *ModuleTable, from_file: []u8, written: []u8) -> []u8 {
		if written.len == 0 {
			return "";
		}
		if written[0] == '/' {
			return file_exists(written) ? written : "";
		}
		if written.len >= 2 && written[0] == '.' && written[1] == '/' {
			let candidate: []u8 = join_path(dir_of(from_file), written);
			if file_exists(candidate) {
				return candidate;
			}
		}
		if self.include_roots != null {
			for let mut i: usize = 0; i < self.include_roots.len; i += 1 {
				let candidate: []u8 = join_path(self.include_roots.data[i], written);
				if file_exists(candidate) {
					return candidate;
				}
			}
		}
		let rel_cand: []u8 = join_path(dir_of(from_file), written);
		if file_exists(rel_cand) {
			return rel_cand;
		}
		if file_exists(written) {
			return written;
		}
		return "";
	}

	/// Executes `register_parsed` (register parsed).
	pub fn register_parsed(
		self: *mut ModuleTable,
		path: []u8,
		source: []u8,
		tokens: front.token.TokenList,
		ast: front.ast.Module
	) -> *mut LoadedModule {
		let raw: *mut u8 = front.ast.arena_alloc(@of.size(LoadedModule));
		if raw == null {
			return null;
		}
		let lm: *mut LoadedModule = raw cast *mut LoadedModule;
		*lm = {
			.path = path,
			.source = source,
			.tokens = tokens,
			.ast = ast,
			.in_progress = false,
			.resolved = false
		};
		self.modules.push(lm);
		return lm;
	}

	/// Executes `resolve_module_imports` (resolve module imports).
	pub fn resolve_module_imports(self: *mut ModuleTable, lm: *mut LoadedModule) -> bool {
		if lm == null || lm.resolved {
			return true;
		}
		if lm.in_progress {
			return true;
		}
		lm.in_progress = true;
		let mut all_ok: bool = true;
		for let mut i: usize = 0; i < lm.ast.decls.len; i += 1 {
			let td: *front.ast.TopDecl = lm.ast.decls.data[i];
			if td.kind != front.ast.TopKind.Import || td.imp == null {
				continue;
			}
			if td.imp.written_path.len == 0 {
				continue;
			}
			let wp: []u8 = td.imp.written_path;
			if ends_with(wp, "/*.sl") || ends_with(wp, "/*") {
				let dir_rel: []u8 = ends_with(wp, "/*.sl") ? wp[0..(wp.len - 5)]
					: wp[0..(wp.len - 2)];
				let dir_path: []u8 = self.resolve_dir_path(lm.path, dir_rel);
				if dir_path.len == 0 {
					front.log.report(
						front.log.Level.Error,
						td.imp.loc,
						"imported directory could not be found",
						front.log.DiagCode.SourceNotFound
					);
					all_ok = false;
					continue;
				}
				let cdir: *mut u8 = front.ast.arena_alloc(dir_path.len + 1);
				if cdir == null {
					all_ok = false;
					continue;
				}
				std.mem.copy(cdir, dir_path.ptr, dir_path.len);
				cdir[dir_path.len] = 0;
				match std.io.dir.open(cdir) {
					.Ok(mut d_handle) => {
						let mut name_buf: [512]u8;
						for true {
							let mut ent: std.io.dir.Entry;
							let code: std.err.Code = std.io.dir.next(
								&d_handle,
								&name_buf[0],
								512,
								&ent
							);
							if code != std.err.Code.Success || ent.name_length == 0 {
								break;
							}
							let ename: []u8 = name_buf[0..ent.name_length];
							if ends_with(ename, ".sl") {
								let full_file: []u8 = join_path(dir_path, ename);
								if !load_and_resolve_file(self, full_file, td.imp.loc) {
									all_ok = false;
								}
							}
						}
						d_handle.close();
					}
					.Err(_) => {
						front.log.report(
							front.log.Level.Error,
							td.imp.loc,
							"could not open imported directory",
							front.log.DiagCode.ModuleRead
						);
						all_ok = false;
					}
				}
				continue;
			}
			let resolved: []u8 = self.resolve_import_path(lm.path, wp);
			if resolved.len == 0 {
				front.log.report(
					front.log.Level.Error,
					td.imp.loc,
					"imported source file could not be found",
					front.log.DiagCode.SourceNotFound
				);
				all_ok = false;
				continue;
			}
			if !load_and_resolve_file(self, resolved, td.imp.loc) {
				all_ok = false;
			}
		}
		lm.in_progress = false;
		lm.resolved = true;
		return all_ok;
	}
}
