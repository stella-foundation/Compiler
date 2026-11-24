mod back.llvm_ctx;
import "driver/cli.sl";
import "front/log.sl";
import "llvm/analysis.sl";
import "llvm/bitcode.sl";
import "llvm/core.sl";
import "llvm/ir.sl";
import "llvm/llvm.sl";
import "llvm/target.sl";
import "std/mem.sl";
import "std/str.sl";

/// Represents the `LLVMCtx` data structure.
pub struct LLVMCtx {
	/// Stores the `ctx` field (ctx).
	pub ctx: bind.llvm.core.Context,
	/// Stores the `mod_ref` field (mod ref).
	pub mod_ref: bind.llvm.core.Module,
	/// Stores the `builder` field (builder).
	pub builder: bind.llvm.ir.Builder,
	/// Stores the `tm` field (tm).
	pub tm: bind.llvm.target.TargetMachine,
	/// Stores the `td` field (td).
	pub td: bind.llvm.target.TargetData,
	/// Stores the `opt_level` field (opt level).
	pub opt_level: driver.cli.OptLevel,
	/// Stores the `ok` field (ok).
	pub ok: bool
}

fn to_cstr(s: []u8) -> *mut u8 {
	let mut pa: std.mem.PageAllocator = std.mem.PageAllocator.init();
	match pa.alloc(s.len + 1, 1) {
		.Ok(buf) => {
			if s.len > 0 {
				std.mem.copy(buf, s.ptr, s.len);
			}
			buf[s.len] = 0;
			return buf;
		}
		.Err(_) => return null
	}
}

fn map_opt_level(opt: driver.cli.OptLevel) -> bind.llvm.CodeGenOptLevel {
	match opt {
		.None => return bind.llvm.CodeGenOptLevel.None,
		.Low => return bind.llvm.CodeGenOptLevel.Less,
		.Medium | .Size => return bind.llvm.CodeGenOptLevel.Default,
		.High => return bind.llvm.CodeGenOptLevel.Aggressive
	}
}

fn map_reloc(r: driver.cli.RelocModel) -> bind.llvm.RelocMode {
	match r {
		.Static => return bind.llvm.RelocMode.Static,
		.Pic => return bind.llvm.RelocMode.PIC
	}
}

fn map_code_model(cm: driver.cli.CodeModel) -> bind.llvm.CodeModel {
	match cm {
		.Tiny => return bind.llvm.CodeModel.Tiny,
		.Small => return bind.llvm.CodeModel.Small,
		.Kernel => return bind.llvm.CodeModel.Kernel,
		.Medium => return bind.llvm.CodeModel.Medium,
		.Large => return bind.llvm.CodeModel.Large
	}
}

/// Executes `init_llvm_ctx` (init llvm ctx).
pub fn init_llvm_ctx(
	mod_name: []u8,
	triple: []u8,
	cpu: []u8,
	opt_level: driver.cli.OptLevel,
	reloc: driver.cli.RelocModel,
	code_model: driver.cli.CodeModel
) -> LLVMCtx {
	bind.llvm.target.host.init_all();

	let ctx: bind.llvm.core.Context = bind.llvm.core.context.create();
	let cname: *mut u8 = to_cstr(mod_name);
	let mut mod_ref: bind.llvm.core.Module = bind.llvm.core.module.create(cname, &ctx);
	let builder: bind.llvm.ir.Builder = bind.llvm.ir.builder.create(&ctx);

	let mut ctriple: *u8 = null;
	let mut owned_triple: *mut u8 = null;
	if triple.len > 0 {
		owned_triple = to_cstr(triple);
		ctriple = owned_triple;
	} else {
		ctriple = bind.llvm.target.host.default_triple();
	}

	let mut target: bind.llvm.target.Target;
	let mut err_msg: *u8 = null;
	if bind.llvm.target.discover.from_triple(ctriple, &target, &err_msg) != 0 {
		if err_msg != null {
			bind.llvm.core.module.dispose_message(err_msg);
		}
		front.log.report(
			front.log.Level.Error,
			front.log.empty_loc(),
			"unsupported target triple",
			front.log.DiagCode.TargetUnsupported
		);
		return {
			.ctx = ctx,
			.mod_ref = mod_ref,
			.builder = builder,
			.tm = bind.llvm.target.wrap_machine(null),
			.td = bind.llvm.target.wrap_data(null),
			.opt_level = opt_level,
			.ok = false
		};
	}

	let mut ccpu: *u8 = c"generic";
	let mut owned_cpu: *mut u8 = null;
	if std.str.eq(cpu, "native") {
		ccpu = bind.llvm.target.host.cpu_name();
	} else if cpu.len > 0 && !std.str.eq(cpu, "generic") && !std.str.eq(cpu, "cpu") {
		owned_cpu = to_cstr(cpu);
		ccpu = owned_cpu;
	}

	let mut tm: bind.llvm.target.TargetMachine = bind.llvm.target.machine.create(
		&target,
		ctriple,
		ccpu,
		c"",
		map_opt_level(opt_level),
		map_reloc(reloc),
		map_code_model(code_model)
	);
	let mut td: bind.llvm.target.TargetData = bind.llvm.target.machine.data_layout(&tm);
	bind.llvm.core.set_target(&mod_ref, ctriple);
	bind.llvm.target.data.set_module(&mod_ref, &td);

	return {
		.ctx = ctx,
		.mod_ref = mod_ref,
		.builder = builder,
		.tm = tm,
		.td = td,
		.opt_level = opt_level,
		.ok = true
	};
}

/// Executes `optimize_module` (optimize module).
pub fn optimize_module(lc: *mut LLVMCtx) -> bool {
	if lc == null || lc.mod_ref.handle == null || lc.tm.handle == null {
		return false;
	}
	let mut passes: *u8 = c"default<O0>";
	match lc.opt_level {
		.None => passes = c"globaldce",
		.Low => passes = c"default<O1>",
		.Medium => passes = c"default<O2>",
		.High => passes = c"default<O3>",
		.Size => passes = c"default<Os>"
	}
	let mut msg: *mut u8 = null;
	if bind.llvm.target.passes.run(&lc.mod_ref, passes, &lc.tm, &msg) != 0 {
		if msg != null {
			front.log.report(
				front.log.Level.Error,
				front.log.empty_loc(),
				std.str.from_cstr(msg),
				front.log.DiagCode.CodegenFailure
			);
			bind.llvm.target.passes.dispose_error_message(msg);
		}
		return false;
	}
	return true;
}

/// Executes `verify_module` (verify module).
pub fn verify_module(lc: *mut LLVMCtx) -> bool {
	let mut err_msg: *u8 = null;
	if bind.llvm.analysis.verify.module(
		&lc.mod_ref,
		bind.llvm.VerifierFailureAction.ReturnStatus,
		&err_msg
	)
		!= 0 {
		if err_msg != null {
			front.log.report(
				front.log.Level.Error,
				front.log.empty_loc(),
				std.str.from_cstr(err_msg),
				front.log.DiagCode.CodegenFailure
			);
			bind.llvm.core.module.dispose_message(err_msg);
		} else {
			front.log.report(
				front.log.Level.Error,
				front.log.empty_loc(),
				"LLVM module verification failed",
				front.log.DiagCode.CodegenFailure
			);
		}
		return false;
	}
	return true;
}

/// Executes `emit_ir_to_file` (emit ir to file).
pub fn emit_ir_to_file(lc: *mut LLVMCtx, path: []u8) -> bool {
	let cpath: *mut u8 = to_cstr(path);
	if cpath == null {
		return false;
	}
	let mut err_msg: *u8 = null;
	let rc: i32 = bind.llvm.core.print_to_file(&lc.mod_ref, cpath, &err_msg);
	if rc != 0 {
		if err_msg != null {
			bind.llvm.core.module.dispose_message(err_msg);
		}
		front.log.report(
			front.log.Level.Error,
			front.log.empty_loc(),
			"failed to write LLVM IR file",
			front.log.DiagCode.EmitFailed
		);
		return false;
	}
	return true;
}

/// Executes `emit_obj_to_file` (emit obj to file).
pub fn emit_obj_to_file(lc: *mut LLVMCtx, path: []u8) -> bool {
	let cpath: *mut u8 = to_cstr(path);
	if cpath == null {
		return false;
	}
	let mut err_msg: *u8 = null;
	let rc: i32 = bind.llvm.target.machine.emit_to_file(
		&lc.tm,
		&lc.mod_ref,
		cpath,
		bind.llvm.CodeGenFileType.Object,
		&err_msg
	);
	if rc != 0 {
		if err_msg != null {
			bind.llvm.core.module.dispose_message(err_msg);
		}
		front.log.report(
			front.log.Level.Error,
			front.log.empty_loc(),
			"failed to emit object file",
			front.log.DiagCode.EmitFailed
		);
		return false;
	}
	return true;
}

/// Executes `apply_target_attrs` (apply target attrs).
pub fn apply_target_attrs(lc: *mut LLVMCtx, cpu: []u8) -> void {
	if lc == null || lc.mod_ref.handle == null || lc.tm.handle == null {
		return;
	}
	let tm_cpu: *u8 = bind.llvm.target.machine.cpu(&lc.tm);
	let tm_feats: *u8 = std.str.eq(cpu, "native")
		? bind.llvm.target.host.cpu_features()
		: bind.llvm.target.machine.feature_string(&lc.tm);
	let nw_kind: u32 = bind.llvm.core.enum_attr_kind(c"nounwind", 8);
	let nw_attr: *void = bind.llvm.core.create_enum_attr(&lc.ctx, nw_kind, 0);
	let mut fn_val: bind.llvm.core.Value = bind.llvm.core.first_function(&lc.mod_ref);
	for fn_val.handle != null {
		bind.llvm.core.add_target_dependent_fn_attr(fn_val, c"no-builtins", c"");
		bind.llvm.core.add_fn_attr_at_index(fn_val, (~(0 cast u32)), nw_attr);
		if tm_cpu != null && tm_cpu[0] != 0 {
			bind.llvm.core.add_target_dependent_fn_attr(fn_val, c"target-cpu", tm_cpu);
		}
		if tm_feats != null && tm_feats[0] != 0 {
			bind.llvm.core.add_target_dependent_fn_attr(fn_val, c"target-features", tm_feats);
		}
		fn_val = bind.llvm.core.next_function(fn_val);
	}
	if std.str.eq(cpu, "native") && tm_feats != null {
		bind.llvm.core.module.dispose_message(tm_feats);
	}
	if tm_cpu != null {
		bind.llvm.core.module.dispose_message(tm_cpu);
	}
	if !std.str.eq(cpu, "native") && tm_feats != null {
		bind.llvm.core.module.dispose_message(tm_feats);
	}
}

/// Executes `emit_bc_to_file` (emit bc to file).
pub fn emit_bc_to_file(lc: *mut LLVMCtx, path: []u8) -> bool {
	let cpath: *mut u8 = to_cstr(path);
	if cpath == null {
		return false;
	}
	let rc: i32 = bind.llvm.bitcode.write.to_file(&lc.mod_ref, cpath);
	if rc != 0 {
		front.log.report(
			front.log.Level.Error,
			front.log.empty_loc(),
			"failed to write LLVM bitcode file",
			front.log.DiagCode.EmitFailed
		);
		return false;
	}
	return true;
}

/// Executes `dispose_llvm_ctx` (dispose llvm ctx).
pub fn dispose_llvm_ctx(lc: *mut LLVMCtx) -> void {
	if lc.td.handle != null {
		bind.llvm.dispose(&lc.td);
		lc.td.handle = null;
	}
	if lc.tm.handle != null {
		bind.llvm.dispose(&lc.tm);
		lc.tm.handle = null;
	}
	if lc.builder.handle != null {
		bind.llvm.dispose(&lc.builder);
		lc.builder.handle = null;
	}
	if lc.mod_ref.handle != null {
		bind.llvm.dispose(&lc.mod_ref);
		lc.mod_ref.handle = null;
	}
	if lc.ctx.handle != null {
		bind.llvm.dispose(&lc.ctx);
		lc.ctx.handle = null;
	}
}
