mod back.codegen.expressions;
import "back/codegen/types.sl";
import "back/llvm_ctx.sl";
import "front/ast.sl";
import "front/token.sl";
import "llvm/core.sl";
import "llvm/ir.sl";
import "llvm/llvm.sl";
import "llvm/target.sl";
import "middle/sema/validation.sl";
import "middle/symbol.sl";
import "middle/types.sl";
import "std/hash.sl";
import "std/mem.sl";
import "std/str.sl";

/// Represents the `LocalSlot` data structure.

pub struct LocalSlot {
	/// Stores the `name` field (name).
	pub name: []u8,
	/// Stores the `ptr` field (ptr).
	pub ptr: bind.llvm.core.Value,
	/// Stores the `st_ty` field (st ty).
	pub st_ty: *mut middle.types.StType,
	/// Stores the `ll_ty` field (ll ty).
	pub ll_ty: bind.llvm.core.Type,
	/// Stores the `scope_depth` field (scope depth).
	pub scope_depth: u32
}

/// Represents the `GlobalSlot` data structure.
pub struct GlobalSlot {
	/// Stores the `name` field (name).
	pub name: []u8,
	/// Stores the `ptr` field (ptr).
	pub ptr: bind.llvm.core.Value,
	/// Stores the `st_ty` field (st ty).
	pub st_ty: *mut middle.types.StType,
	/// Stores the `ll_ty` field (ll ty).
	pub ll_ty: bind.llvm.core.Type
}

/// Represents the `FnSlot` data structure.
pub struct FnSlot {
	/// Stores the `name` field (name).
	pub name: []u8,
	/// Stores the `fn_val` field (fn val).
	pub fn_val: bind.llvm.core.Value,
	/// Stores the `fn_ll_ty` field (fn ll ty).
	pub fn_ll_ty: bind.llvm.core.Type,
	/// Stores the `st_ty` field (st ty).
	pub st_ty: *mut middle.types.StType
}

/// Represents the `LoopTarget` data structure.
pub struct LoopTarget {
	/// Stores the `break_bb` field (break bb).
	pub break_bb: *void,
	/// Stores the `continue_bb` field (continue bb).
	pub continue_bb: *void,
	/// Stores the `scope_depth` field (scope depth).
	pub scope_depth: u32
}

/// Represents the `DeferEntry` data structure.
pub struct DeferEntry {
	/// Stores the `stmt` field (stmt).
	pub stmt: *front.ast.Stmt,
	/// Stores the `scope_depth` field (scope depth).
	pub scope_depth: u32
}

/// Represents the `CodegenState` data structure.
pub struct CodegenState {
	/// Stores the `lc` field (lc).
	pub lc: *mut back.llvm_ctx.LLVMCtx,
	/// Stores the `sema` field (sema).
	pub sema: *mut middle.sema.validation.SemaContext,
	/// Stores the `current_fn` field (current fn).
	pub current_fn: bind.llvm.core.Value,
	/// Stores the `current_fn_ret` field (current fn ret).
	pub current_fn_ret: *mut middle.types.StType,
	/// Stores the `scope_depth` field (scope depth).
	pub scope_depth: u32,
	/// Stores the `locals` field (locals).
	pub locals: front.ast.ValList<LocalSlot>,
	/// Stores the `globals` field (globals).
	pub globals: front.ast.ValList<GlobalSlot>,
	/// Stores the `functions` field (functions).
	pub functions: front.ast.ValList<FnSlot>,
	/// Stores the `loop_stack` field (loop stack).
	pub loop_stack: front.ast.ValList<LoopTarget>,
	/// Stores the `defers` field (defers).
	pub defers: front.ast.ValList<DeferEntry>,
	/// Stores the `str_counter` field (str counter).
	pub str_counter: u32,
	/// Stores the `yield_slot` field (yield slot).
	pub yield_slot: bind.llvm.core.Value,
	/// Stores the `yield_ty` field (yield ty).
	pub yield_ty: *mut middle.types.StType,
	/// Stores the `yield_end_bb` field (yield end bb).
	pub yield_end_bb: *void,
	/// Stores the `yield_scope_depth` field (yield scope depth).
	pub yield_scope_depth: u32,
	/// Stores the `has_emit_stmt_cb` field (has emit stmt cb).
	pub has_emit_stmt_cb: bool,
	/// Stores the `emit_stmt_cb` field (emit stmt cb).
	pub emit_stmt_cb: fn(*mut CodegenState, *front.ast.Stmt) -> void,
	/// Stores the `macro_varargs` field (macro varargs).
	pub macro_varargs: *front.ast.PtrList<front.ast.Expr>,
	/// Stores the `macro_fixed_argc` field (macro fixed argc).
	pub macro_fixed_argc: usize,
	/// Stores the `macro_caller_locals_len` field (macro caller locals len).
	pub macro_caller_locals_len: usize,
	/// Reusable builder for entry-block allocas.
	pub alloca_builder: bind.llvm.ir.Builder,
	/// Open-addressing hash table for `functions` (stores index + 1; 0 = empty).
	pub fn_buckets: *mut usize,
	/// Capacity of `fn_buckets` (power of 2).
	pub fn_bucket_cap: usize,
	/// Open-addressing hash table for `globals` (stores index + 1; 0 = empty).
	pub glob_buckets: *mut usize,
	/// Capacity of `glob_buckets` (power of 2).
	pub glob_bucket_cap: usize
}

/// Executes `init_codegen` (init codegen).
pub fn init_codegen(
	lc: *mut back.llvm_ctx.LLVMCtx,
	sema: *mut middle.sema.validation.SemaContext
) -> CodegenState {
	let mut cs: CodegenState;
	cs.lc = lc;
	cs.sema = sema;
	cs.current_fn = bind.llvm.core.wrap_value(null);
	cs.current_fn_ret = null;
	cs.scope_depth = 0;
	cs.locals = { .data = null, .len = 0, .cap = 0 };
	cs.globals = { .data = null, .len = 0, .cap = 0 };
	cs.functions = { .data = null, .len = 0, .cap = 0 };
	cs.loop_stack = { .data = null, .len = 0, .cap = 0 };
	cs.defers = { .data = null, .len = 0, .cap = 0 };
	cs.str_counter = 0;
	cs.yield_slot = bind.llvm.core.wrap_value(null);
	cs.yield_ty = null;
	cs.yield_end_bb = null;
	cs.yield_scope_depth = 0;
	cs.has_emit_stmt_cb = false;
	cs.macro_varargs = null;
	cs.macro_fixed_argc = 0;
	cs.macro_caller_locals_len = 0;
	cs.alloca_builder = bind.llvm.ir.builder.create(&lc.ctx);
	cs.fn_buckets = null;
	cs.fn_bucket_cap = 0;
	cs.glob_buckets = null;
	cs.glob_bucket_cap = 0;
	return cs;
}

/// Disposes resources owned by `CodegenState`.
pub fn dispose_codegen(cg: *mut CodegenState) -> void {
	if cg != null && cg.alloca_builder.handle != null {
		bind.llvm.dispose(&cg.alloca_builder);
		cg.alloca_builder.handle = null;
	}
}

/// Executes `cstr_from_slice` (cstr from slice).
pub fn cstr_from_slice(s: []u8) -> *mut u8 {
	let buf: *mut u8 = front.ast.arena_alloc(s.len + 1);
	if buf == null {
		return null;
	}
	if s.len > 0 {
		std.mem.copy(buf, s.ptr, s.len);
	}
	buf[s.len] = 0;
	return buf;
}

/// Executes `block_has_terminator` (block has terminator).
pub fn block_has_terminator(cg: *CodegenState) -> bool {
	let bb: *void = bind.llvm.ir.insert_block(&cg.lc.builder);
	if bb == null {
		return true;
	}
	return bind.llvm.core.block_terminator(bb) != null;
}

/// Executes `alloca_in_entry` (alloca in entry).
pub fn alloca_in_entry(
	cg: *mut CodegenState,
	ty: bind.llvm.core.Type,
	name: *u8
) -> bind.llvm.core.Value {
	let entry_bb: *void = bind.llvm.core.entry_basic_block(cg.current_fn);
	let first_inst: *void = bind.llvm.core.first_instruction(entry_bb);
	if first_inst != null {
		bind.llvm.ir.position_before(&cg.alloca_builder, first_inst);
	} else {
		bind.llvm.ir.position_at_end(&cg.alloca_builder, entry_bb);
	}
	return bind.llvm.ir.alloca(&cg.alloca_builder, ty, name);
}

/// Executes `find_local` (find local).
pub fn find_local(cg: *CodegenState, name: []u8) -> *mut LocalSlot {
	let mut i: usize = cg.locals.len;
	for i > 0 {
		i -= 1;
		if std.str.eq(cg.locals.data[i].name, name) {
			return &cg.locals.data[i];
		}
	}
	return null;
}

fn rehash_globals(cg: *mut CodegenState, new_cap: usize) -> void {
	let raw: *mut u8 = front.ast.arena_alloc(new_cap * @of.size(usize));
	if raw == null {
		return;
	}
	std.mem.set(raw, 0, new_cap * @of.size(usize));
	let buckets: *mut usize = raw cast *mut usize;
	let mask: usize = new_cap - 1;
	for let mut i: usize = 0; i < cg.globals.len; i += 1 {
		let mut idx: usize = (std.hash.fnv1a_32(cg.globals.data[i].name) cast usize) & mask;
		for buckets[idx] != 0 {
			idx = (idx + 1) & mask;
		}
		buckets[idx] = i + 1;
	}
	cg.glob_buckets = buckets;
	cg.glob_bucket_cap = new_cap;
}

/// Appends `gs` to `cg.globals` and indexes it for O(1) lookup.
pub fn add_global_slot(cg: *mut CodegenState, gs: GlobalSlot) -> void {
	let slot_idx: usize = cg.globals.len;
	cg.globals.push(gs);
	if cg.glob_bucket_cap == 0 || (cg.globals.len * 2) > cg.glob_bucket_cap {
		let new_cap: usize = cg.glob_bucket_cap == 0 ? 128 : cg.glob_bucket_cap * 2;
		rehash_globals(cg, new_cap);
		return;
	}
	if cg.glob_buckets != null {
		let mask: usize = cg.glob_bucket_cap - 1;
		let mut idx: usize = (std.hash.fnv1a_32(gs.name) cast usize) & mask;
		for cg.glob_buckets[idx] != 0 {
			idx = (idx + 1) & mask;
		}
		cg.glob_buckets[idx] = slot_idx + 1;
	}
}

/// Executes `find_global` (find global).
pub fn find_global(cg: *CodegenState, name: []u8) -> *mut GlobalSlot {
	if cg.glob_buckets != null && cg.glob_bucket_cap > 0 {
		let mask: usize = cg.glob_bucket_cap - 1;
		let mut idx: usize = (std.hash.fnv1a_32(name) cast usize) & mask;
		for cg.glob_buckets[idx] != 0 {
			let entry: usize = cg.glob_buckets[idx] - 1;
			if std.str.eq(cg.globals.data[entry].name, name) {
				return &cg.globals.data[entry];
			}
			idx = (idx + 1) & mask;
		}
		return null;
	}
	for let mut i: usize = 0; i < cg.globals.len; i += 1 {
		if std.str.eq(cg.globals.data[i].name, name) {
			return &cg.globals.data[i];
		}
	}
	return null;
}

fn rehash_functions(cg: *mut CodegenState, new_cap: usize) -> void {
	let raw: *mut u8 = front.ast.arena_alloc(new_cap * @of.size(usize));
	if raw == null {
		return;
	}
	std.mem.set(raw, 0, new_cap * @of.size(usize));
	let buckets: *mut usize = raw cast *mut usize;
	let mask: usize = new_cap - 1;
	for let mut i: usize = 0; i < cg.functions.len; i += 1 {
		let mut idx: usize = (std.hash.fnv1a_32(cg.functions.data[i].name) cast usize) & mask;
		for buckets[idx] != 0 {
			idx = (idx + 1) & mask;
		}
		buckets[idx] = i + 1;
	}
	cg.fn_buckets = buckets;
	cg.fn_bucket_cap = new_cap;
}

/// Appends `fs` to `cg.functions` and indexes it for O(1) lookup.
pub fn add_function_slot(cg: *mut CodegenState, fs: FnSlot) -> void {
	let slot_idx: usize = cg.functions.len;
	cg.functions.push(fs);
	if cg.fn_bucket_cap == 0 || (cg.functions.len * 2) > cg.fn_bucket_cap {
		let new_cap: usize = cg.fn_bucket_cap == 0 ? 256 : cg.fn_bucket_cap * 2;
		rehash_functions(cg, new_cap);
		return;
	}
	if cg.fn_buckets != null {
		let mask: usize = cg.fn_bucket_cap - 1;
		let mut idx: usize = (std.hash.fnv1a_32(fs.name) cast usize) & mask;
		for cg.fn_buckets[idx] != 0 {
			idx = (idx + 1) & mask;
		}
		cg.fn_buckets[idx] = slot_idx + 1;
	}
}

/// Executes `find_function` (find function).
pub fn find_function(cg: *CodegenState, name: []u8) -> *mut FnSlot {
	if cg.fn_buckets != null && cg.fn_bucket_cap > 0 {
		let mask: usize = cg.fn_bucket_cap - 1;
		let mut idx: usize = (std.hash.fnv1a_32(name) cast usize) & mask;
		for cg.fn_buckets[idx] != 0 {
			let entry: usize = cg.fn_buckets[idx] - 1;
			if std.str.eq(cg.functions.data[entry].name, name) {
				return &cg.functions.data[entry];
			}
			idx = (idx + 1) & mask;
		}
		return null;
	}
	for let mut i: usize = 0; i < cg.functions.len; i += 1 {
		if std.str.eq(cg.functions.data[i].name, name) {
			return &cg.functions.data[i];
		}
	}
	return null;
}

/// Executes `emit_global_string`.
pub fn emit_global_string(cg: *mut CodegenState, text: []u8) -> bind.llvm.core.Value {
	let arr_ty: bind.llvm.core.Type = bind.llvm.core.type.array(
		bind.llvm.core.type.int8(&cg.lc.ctx),
		(text.len + 1) cast u64
	);
	let mut gv: bind.llvm.core.Value = bind.llvm.core.add_global(&cg.lc.mod_ref, arr_ty, c".str");
	let cstr_val: bind.llvm.core.Value = bind.llvm.core.constant.string(
		&cg.lc.ctx,
		text.len > 0 ? text.ptr : c"",
		text.len,
		false
	);
	bind.llvm.core.set_initializer(&gv, cstr_val);
	bind.llvm.core.set_global_constant(&gv, true);
	bind.llvm.core.set_linkage(&gv, bind.llvm.Linkage.Private);
	return gv;
}

/// Executes `expr_type` (expr type).
pub fn expr_type(
	cg: *CodegenState,
	e: *front.ast.Expr,
	expected: *mut middle.types.StType
) -> *mut middle.types.StType {
	if e != null && e.sema_ty != null {
		return e.sema_ty cast *mut middle.types.StType;
	}
	if expected != null {
		return expected;
	}
	return cg.sema.tx.void_t;
}
