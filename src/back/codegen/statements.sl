mod back.codegen.statements;
import "back/codegen/expressions.sl";
import "back/codegen/types.sl";
import "front/ast.sl";
import "llvm/core.sl";
import "llvm/ir.sl";
import "llvm/llvm.sl";
import "llvm/target.sl";
import "middle/sema/validation.sl";
import "middle/types.sl";
import "std/mem.sl";
import "std/str.sl";

fn append_str_buf(buf: *mut *mut u8, len: *mut usize, cap: *mut usize, s: []u8) -> void {
	for *len + s.len + 1 > *cap {
		let nc: usize = *cap * 2;
		let nb: *mut u8 = front.ast.arena_alloc(nc);
		if nb == null {
			return;
		}
		std.mem.copy(nb, *buf, *len);
		*buf = nb;
		*cap = nc;
	}
	if s.len > 0 {
		std.mem.copy(&((*buf)[*len]), s.ptr, s.len);
		*len += s.len;
	}
}

fn append_asm_constraint(buf: *mut *mut u8, len: *mut usize, cap: *mut usize, c: []u8) -> void {
	if c.len >= 2 && c[0] == ('=' cast u8) && c[1] != ('{' cast u8) && c.len > 2 {
		append_str_buf(buf, len, cap, "={");
		append_str_buf(buf, len, cap, c[1..c.len]);
		append_str_buf(buf, len, cap, "}");
		return;
	}
	append_str_buf(buf, len, cap, c);
}

fn emit_defers_from_depth(cg: *mut back.codegen.expressions.CodegenState, min_depth: u32) -> void {
	let mut i: usize = cg.defers.len;
	for i > 0 {
		i -= 1;
		if cg.defers.data[i].scope_depth < min_depth {
			break;
		}
		if !back.codegen.expressions.block_has_terminator(cg) {
			emit_stmt(cg, cg.defers.data[i].stmt);
		}
	}
}

fn pop_scope(cg: *mut back.codegen.expressions.CodegenState) -> void {
	emit_defers_from_depth(cg, cg.scope_depth);
	for cg.defers.len > 0 && cg.defers.data[cg.defers.len - 1].scope_depth >= cg.scope_depth {
		cg.defers.len -= 1;
	}
	for cg.locals.len > 0 && cg.locals.data[cg.locals.len - 1].scope_depth >= cg.scope_depth {
		cg.locals.len -= 1;
	}
	if cg.scope_depth > 0 {
		cg.scope_depth -= 1;
	}
}

fn emit_zero_init(
	cg: *mut back.codegen.expressions.CodegenState,
	ptr: bind.llvm.core.Value,
	ll_ty: bind.llvm.core.Type
) -> void {
	let sz: u64 = bind.llvm.target.data.abi_size_of(&cg.lc.td, ll_ty);
	if sz <= 64 {
		let zero_val: bind.llvm.core.Value = bind.llvm.core.constant.null_value(ll_ty);
		bind.llvm.ir.store(&cg.lc.builder, zero_val, ptr);
		return;
	}
	let align: u32 = bind.llvm.target.data.abi_alignment_of(&cg.lc.td, ll_ty);
	let i64_ty: bind.llvm.core.Type = bind.llvm.core.type.int64(&cg.lc.ctx);
	let i8_ty: bind.llvm.core.Type = bind.llvm.core.type.int8(&cg.lc.ctx);
	let step_sz: u64 = align >= 8 ? 8 : 1;
	let step_ty: bind.llvm.core.Type = align >= 8 ? i64_ty : i8_ty;
	let step_zero: bind.llvm.core.Value = bind.llvm.core.constant.integer(step_ty, 0, false);
	let zero64: bind.llvm.core.Value = bind.llvm.core.constant.integer(i64_ty, 0, false);
	let zero8: bind.llvm.core.Value = bind.llvm.core.constant.integer(i8_ty, 0, false);
	let count: u64 = sz / step_sz;
	let rem: u64 = sz % step_sz;

	if count > 0 {
		let pre_bb: *void = bind.llvm.ir.insert_block(&cg.lc.builder);
		let loop_bb: *void = bind.llvm.core.append_basic_block(
			&cg.lc.ctx,
			cg.current_fn,
			c"zinit.loop"
		);
		let done_bb: *void = bind.llvm.core.append_basic_block(
			&cg.lc.ctx,
			cg.current_fn,
			c"zinit.done"
		);
		bind.llvm.ir.branch(&cg.lc.builder, loop_bb);
		bind.llvm.ir.position_at_end(&cg.lc.builder, loop_bb);
		let idx_phi: bind.llvm.core.Value = bind.llvm.ir.phi(
			&cg.lc.builder,
			i64_ty,
			c"zinit.i"
		);
		let mut idx_arr: [1]*void = [idx_phi.handle];
		let gep_ptr: bind.llvm.core.Value = bind.llvm.ir.gep(
			&cg.lc.builder,
			step_ty,
			ptr,
			&idx_arr[0],
			1,
			c"zinit.p"
		);
		bind.llvm.ir.store(&cg.lc.builder, step_zero, gep_ptr);
		let one64: bind.llvm.core.Value = bind.llvm.core.constant.integer(i64_ty, 1, false);
		let next_idx: bind.llvm.core.Value = bind.llvm.ir.add(
			&cg.lc.builder,
			idx_phi,
			one64,
			c"zinit.next"
		);
		let limit64: bind.llvm.core.Value = bind.llvm.core.constant.integer(
			i64_ty,
			count,
			false
		);
		let cond: bind.llvm.core.Value = bind.llvm.ir.integer_compare(
			&cg.lc.builder,
			bind.llvm.IntPredicate.UnsignedLessThan,
			next_idx,
			limit64,
			c"zinit.cmp"
		);
		let mut in_vals: [2]*void = [zero64.handle, next_idx.handle];
		let mut in_bbs: [2]*void = [pre_bb, loop_bb];
		bind.llvm.ir.add_incoming(idx_phi, &in_vals[0], &in_bbs[0], 2);
		bind.llvm.ir.cond_branch(&cg.lc.builder, cond, loop_bb, done_bb);
		bind.llvm.ir.position_at_end(&cg.lc.builder, done_bb);
	}
	for let mut r: u64 = 0; r < rem; r += 1 {
		let off_v: bind.llvm.core.Value = bind.llvm.core.constant.integer(
			i64_ty,
			count * step_sz + r,
			false
		);
		let mut r_arr: [1]*void = [off_v.handle];
		let bptr: bind.llvm.core.Value = bind.llvm.ir.gep(
			&cg.lc.builder,
			i8_ty,
			ptr,
			&r_arr[0],
			1,
			c"zinit.b"
		);
		bind.llvm.ir.store(&cg.lc.builder, zero8, bptr);
	}
}

/// Executes `emit_stmt` (emit stmt).
pub fn emit_stmt(cg: *mut back.codegen.expressions.CodegenState, s: *front.ast.Stmt) -> void {
	if s == null || back.codegen.expressions.block_has_terminator(cg) {
		return;
	}
	match s.kind {
		.Block => {
			cg.scope_depth += 1;
			for let mut i: usize = 0; i < s.body.len; i += 1 {
				if back.codegen.expressions.block_has_terminator(cg) {
					break;
				}
				emit_stmt(cg, s.body.data[i]);
			}
			pop_scope(cg);
		}
		.ExprStmt => {
			back.codegen.expressions.emit_expr(cg, s.expr, null);
		}
		.VarDecl | .ConstDecl => {
			for let mut i: usize = 0; i < s.vars.len; i += 1 {
				let v: front.ast.VarDeclInfo = s.vars.data[i];
				let mut st_ty: *mut middle.types.StType = cg.sema.resolve_type(v.ty);
				if v.ty != null && v.ty.array_len_inferred && v.init != null && v.init.sema_ty
					!= null {
					st_ty = v.init.sema_ty cast *mut middle.types.StType;
				}
				let ll_ty: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
					&cg.lc.ctx,
					&cg.lc.td,
					st_ty
				);
				let cname: *mut u8 = back.codegen.expressions.cstr_from_slice(v.name);
				let ptr: bind.llvm.core.Value = back.codegen.expressions.alloca_in_entry(
					cg,
					ll_ty,
					cname != null ? (cname cast *u8) : c"var"
				);
				if v.init != null {
					let init_val: bind.llvm.core.Value = back.codegen.expressions.emit_expr(
						cg,
						v.init,
						st_ty
					);
					let coerced: bind.llvm.core.Value = back.codegen.expressions.coerce_value(
						cg, init_val, back.codegen.expressions.expr_type(cg, v.init, st_ty), st_ty
					);
					bind.llvm.ir.store(&cg.lc.builder, coerced, ptr);
				} else {
					emit_zero_init(cg, ptr, ll_ty);
				}
				let slot: back.codegen.expressions.LocalSlot = {
					.name = v.name,
					.ptr = ptr,
					.st_ty = st_ty,
					.ll_ty = ll_ty,
					.scope_depth = cg.scope_depth
				};
				cg.locals.push(slot);
			}
		}
		.If => {
			let cond_val: bind.llvm.core.Value = back.codegen.expressions.emit_expr(
				cg,
				s.cond,
				cg.sema.tx.bool_t
			);
			let then_bb: *void = bind.llvm.core.append_basic_block(
				&cg.lc.ctx,
				cg.current_fn,
				c"if.then"
			);
			let else_bb: *void = s.else_block != null
				? bind.llvm.core.append_basic_block(&cg.lc.ctx, cg.current_fn, c"if.else")
				: null;
			let merge_bb: *void = bind.llvm.core.append_basic_block(
				&cg.lc.ctx,
				cg.current_fn,
				c"if.end"
			);

			bind.llvm.ir.cond_branch(
				&cg.lc.builder,
				cond_val,
				then_bb,
				else_bb != null ? else_bb : merge_bb
			);

			bind.llvm.ir.position_at_end(&cg.lc.builder, then_bb);
			emit_stmt(cg, s.then_block);
			if !back.codegen.expressions.block_has_terminator(cg) {
				bind.llvm.ir.branch(&cg.lc.builder, merge_bb);
			}

			if else_bb != null {
				bind.llvm.ir.position_at_end(&cg.lc.builder, else_bb);
				emit_stmt(cg, s.else_block);
				if !back.codegen.expressions.block_has_terminator(cg) {
					bind.llvm.ir.branch(&cg.lc.builder, merge_bb);
				}
			}

			bind.llvm.ir.position_at_end(&cg.lc.builder, merge_bb);
		}
		.For => {
			cg.scope_depth += 1;
			if s.for_init != null {
				emit_stmt(cg, s.for_init);
			}
			let cond_bb: *void = bind.llvm.core.append_basic_block(
				&cg.lc.ctx,
				cg.current_fn,
				c"for.cond"
			);
			let body_bb: *void = bind.llvm.core.append_basic_block(
				&cg.lc.ctx,
				cg.current_fn,
				c"for.body"
			);
			let step_bb: *void = bind.llvm.core.append_basic_block(
				&cg.lc.ctx,
				cg.current_fn,
				c"for.step"
			);
			let exit_bb: *void = bind.llvm.core.append_basic_block(
				&cg.lc.ctx,
				cg.current_fn,
				c"for.end"
			);

			bind.llvm.ir.branch(&cg.lc.builder, cond_bb);
			bind.llvm.ir.position_at_end(&cg.lc.builder, cond_bb);
			if s.for_cond != null {
				let cv: bind.llvm.core.Value = back.codegen.expressions.emit_expr(
					cg,
					s.for_cond,
					cg.sema.tx.bool_t
				);
				bind.llvm.ir.cond_branch(&cg.lc.builder, cv, body_bb, exit_bb);
			} else {
				bind.llvm.ir.branch(&cg.lc.builder, body_bb);
			}

			let lt: back.codegen.expressions.LoopTarget = {
				.break_bb = exit_bb,
				.continue_bb = step_bb,
				.scope_depth = cg.scope_depth
			};
			cg.loop_stack.push(lt);

			bind.llvm.ir.position_at_end(&cg.lc.builder, body_bb);
			emit_stmt(cg, s.loop_body);
			if !back.codegen.expressions.block_has_terminator(cg) {
				bind.llvm.ir.branch(&cg.lc.builder, step_bb);
			}

			bind.llvm.ir.position_at_end(&cg.lc.builder, step_bb);
			if s.for_step != null {
				back.codegen.expressions.emit_expr(cg, s.for_step, null);
			}
			bind.llvm.ir.branch(&cg.lc.builder, cond_bb);

			cg.loop_stack.len -= 1;
			bind.llvm.ir.position_at_end(&cg.lc.builder, exit_bb);
			pop_scope(cg);
		}
		.Match => {
			let scr_ty: *mut middle.types.StType = back.codegen.expressions.expr_type(
				cg,
				s.scrutinee,
				null
			);
			let scr_u: *mut middle.types.StType = middle.types.underlying_type(scr_ty);
			let scr_is_ptr: bool = scr_u != null && scr_u.kind == middle.types.TypeKind.Pointer;
			let scr_is_mut: bool = scr_is_ptr && scr_u.is_mutable;
			let enum_u: *mut middle.types.StType = scr_is_ptr
				? middle.types.underlying_type(scr_u.base) : scr_u;
			let scr_val: bind.llvm.core.Value = back.codegen.expressions.emit_expr(
				cg,
				s.scrutinee,
				scr_ty
			);
			let is_tagged: bool = enum_u != null && enum_u.kind == middle.types.TypeKind.Enum
				&& enum_u.is_tagged_enum;
			let mut scr_ll_ty: bind.llvm.core.Type = bind.llvm.core.wrap_type(null);
			let mut scr_ptr: bind.llvm.core.Value = bind.llvm.core.wrap_value(null);
			let mut scr_tag: bind.llvm.core.Value = scr_val;
			let mut tag_ll: bind.llvm.core.Type = bind.llvm.core.wrap_type(null);
			if is_tagged {
				scr_ll_ty = back.codegen.types.to_llvm_type(&cg.lc.ctx, &cg.lc.td, enum_u);
				tag_ll = enum_u.base != null
					? back.codegen.types.to_llvm_type(&cg.lc.ctx, &cg.lc.td, enum_u.base)
					: bind.llvm.core.type.int32(&cg.lc.ctx);
				if scr_is_ptr {
					scr_ptr = scr_val;
					let tag_ptr: bind.llvm.core.Value = bind.llvm.ir.struct_gep(
						&cg.lc.builder,
						scr_ll_ty,
						scr_ptr,
						0,
						c"mtagp"
					);
					scr_tag = bind.llvm.ir.load(&cg.lc.builder, tag_ll, tag_ptr, c"mtag");
				} else {
					scr_ptr = back.codegen.expressions.alloca_in_entry(cg, scr_ll_ty, c"mscr");
					bind.llvm.ir.store(&cg.lc.builder, scr_val, scr_ptr);
					scr_tag = bind.llvm.ir.extract_value(&cg.lc.builder, scr_val, 0, c"mtag");
				}
			}
			let merge_bb: *void = bind.llvm.core.append_basic_block(
				&cg.lc.ctx,
				cg.current_fn,
				c"match.end"
			);
			let can_switch: bool = !is_tagged && scr_u != null
				&& (scr_u.kind == middle.types.TypeKind.UInt || scr_u.kind
				== middle.types.TypeKind.SInt
				|| scr_u.kind == middle.types.TypeKind.Bool || scr_u.kind
				== middle.types.TypeKind.Enum);
			if can_switch {
				let mut default_idx: isize = -1;
				let mut num_cases: u32 = 0;
				for let mut i: usize = 0; i < s.arms.len; i += 1 {
					let arm: front.ast.MatchArm = s.arms.data[i];
					let mut is_wild: bool = false;
					for let mut j: usize = 0; j < arm.patterns.len; j += 1 {
						if arm.patterns.data[j].kind == front.ast.MatchPatternKind.Wildcard {
							is_wild = true;
							break;
						}
					}
					if is_wild && default_idx < 0 {
						default_idx = i cast isize;
					} else {
						num_cases += arm.patterns.len cast u32;
					}
				}
				let default_bb: *void = bind.llvm.core.append_basic_block(
					&cg.lc.ctx, cg.current_fn, default_idx >= 0 ? c"match.default"
						: c"match.unreach"
				);
				let sw: bind.llvm.core.Value = bind.llvm.ir.switch_inst(
					&cg.lc.builder,
					scr_val,
					default_bb,
					num_cases
				);
				for let mut i: usize = 0; i < s.arms.len; i += 1 {
					let arm: front.ast.MatchArm = s.arms.data[i];
					let arm_bb: *void = (i cast isize == default_idx)
						? default_bb
						: bind.llvm.core.append_basic_block(
							&cg.lc.ctx,
							cg.current_fn,
							c"match.arm"
						);
					if i cast isize != default_idx {
						for let mut j: usize = 0; j < arm.patterns.len; j += 1 {
							let pat: front.ast.MatchPattern = arm.patterns.data[j];
							if pat.expr != null {
								let pv: bind.llvm.core.Value = back.codegen.expressions.emit_expr(
									cg,
									pat.expr,
									scr_ty
								);
								bind.llvm.ir.add_case(sw, pv, arm_bb);
							}
						}
					}
					let cur_bb: *void = bind.llvm.ir.insert_block(&cg.lc.builder);
					bind.llvm.ir.position_at_end(&cg.lc.builder, arm_bb);
					emit_stmt(cg, arm.body);
					if !back.codegen.expressions.block_has_terminator(cg) {
						bind.llvm.ir.branch(&cg.lc.builder, merge_bb);
					}
					if cur_bb != null {
						bind.llvm.ir.position_at_end(&cg.lc.builder, cur_bb);
					}
				}
				if default_idx < 0 {
					bind.llvm.ir.position_at_end(&cg.lc.builder, default_bb);
					bind.llvm.ir.unreachable_inst(&cg.lc.builder);
				}
				bind.llvm.ir.position_at_end(&cg.lc.builder, merge_bb);
				return;
			}
			for let mut i: usize = 0; i < s.arms.len; i += 1 {
				let arm: front.ast.MatchArm = s.arms.data[i];
				let arm_bb: *void = bind.llvm.core.append_basic_block(
					&cg.lc.ctx,
					cg.current_fn,
					c"match.arm"
				);
				let next_bb: *void = bind.llvm.core.append_basic_block(
					&cg.lc.ctx,
					cg.current_fn,
					c"match.next"
				);
				let mut has_wildcard: bool = false;
				let mut cond_val: bind.llvm.core.Value = bind.llvm.core.wrap_value(null);
				let mut matched_vidx: isize = -1;
				for let mut j: usize = 0; j < arm.patterns.len; j += 1 {
					let pat: front.ast.MatchPattern = arm.patterns.data[j];
					if pat.kind == front.ast.MatchPatternKind.Wildcard {
						has_wildcard = true;
						break;
					}
					if is_tagged && pat.expr != null
						&& (pat.kind == front.ast.MatchPatternKind.Variant || pat.expr.kind
						== front.ast.ExprKind.EnumMember) {
						let vidx: isize = middle.types.field_index(enum_u, pat.expr.member);
						if vidx >= 0 {
							matched_vidx = vidx;
							let tv: bind.llvm.core.Value = bind.llvm.core.constant.integer(
								tag_ll,
								enum_u.enum_values.data[vidx cast usize],
								false
							);
							let cmp: bind.llvm.core.Value = bind.llvm.ir.integer_compare(
								&cg.lc.builder,
								bind.llvm.IntPredicate.Equal,
								scr_tag,
								tv,
								c"mcmp"
							);
							cond_val = cond_val.handle == null ? cmp
								: bind.llvm.ir.bit_or(&cg.lc.builder, cond_val, cmp, c"mor");
						}
					} else if pat.expr != null {
						let pv: bind.llvm.core.Value = back.codegen.expressions.emit_expr(
							cg,
							pat.expr,
							scr_ty
						);
						let cmp: bind.llvm.core.Value = bind.llvm.ir.integer_compare(
							&cg.lc.builder,
							bind.llvm.IntPredicate.Equal,
							scr_val,
							pv,
							c"mcmp"
						);
						cond_val = cond_val.handle == null ? cmp
							: bind.llvm.ir.bit_or(&cg.lc.builder, cond_val, cmp, c"mor");
					}
				}
				if has_wildcard {
					bind.llvm.ir.branch(&cg.lc.builder, arm_bb);
				} else {
					if cond_val.handle == null {
						cond_val = bind.llvm.core.constant.integer(
							bind.llvm.core.type.int1(&cg.lc.ctx),
							0,
							false
						);
					}
					bind.llvm.ir.cond_branch(&cg.lc.builder, cond_val, arm_bb, next_bb);
				}
				bind.llvm.ir.position_at_end(&cg.lc.builder, arm_bb);
				let prev_locals: usize = cg.locals.len;
				cg.scope_depth += 1;
				if is_tagged && matched_vidx >= 0 && (matched_vidx cast usize)
					< enum_u.enum_variants.len && arm.patterns.len > 0 {
					let pat0: front.ast.MatchPattern = arm.patterns.data[0];
					let vi: middle.types.EnumVariantInfo =
						enum_u.enum_variants.data[matched_vidx cast usize];
					if pat0.bindings.len > 0 && vi.field_types.len > 0 {
						let pay_st: bind.llvm.core.Type =
							back.codegen.types.tagged_enum_payload_struct(
								&cg.lc.ctx,
								&cg.lc.td,
								&vi
							);
						let pay_ptr: bind.llvm.core.Value = bind.llvm.ir.struct_gep(
							&cg.lc.builder,
							scr_ll_ty,
							scr_ptr,
							1,
							c"mpay"
						);
						for let mut k: usize = 0; k < pat0.bindings.len; k += 1 {
							let b: front.ast.MatchBinding = pat0.bindings.data[k];
							let mut fidx: usize = k;
							if b.field_name.len > 0 {
								for let mut fi: usize = 0; fi < vi.field_names.len; fi += 1 {
									if std.str.eq(vi.field_names.data[fi], b.field_name) {
										fidx = fi;
										break;
									}
								}
							}
							if !std.str.eq(b.name, "_") && fidx < vi.field_types.len {
								let fty: *mut middle.types.StType = vi.field_types.data[fidx];
								let fptr: bind.llvm.core.Value = bind.llvm.ir.struct_gep(
									&cg.lc.builder,
									pay_st,
									pay_ptr,
									fidx cast u32,
									c"mfld"
								);
								let bind_ty: *mut middle.types.StType = scr_is_ptr
									? cg.sema.tx.pointer(fty, scr_is_mut, false) : fty;
								let bind_ll: bind.llvm.core.Type = back.codegen.types.to_llvm_type(
									&cg.lc.ctx,
									&cg.lc.td,
									bind_ty
								);
								let cname: *mut u8 = back.codegen.expressions.cstr_from_slice(
									b.name
								);
								let slot_ptr: bind.llvm.core.Value =
									back.codegen.expressions.alloca_in_entry(cg, bind_ll, cname
									!= null ? (cname cast *u8) : c"bind");
								if scr_is_ptr {
									bind.llvm.ir.store(&cg.lc.builder, fptr, slot_ptr);
								} else {
									let fval: bind.llvm.core.Value = bind.llvm.ir.load(
										&cg.lc.builder,
										bind_ll,
										fptr,
										c"mld"
									);
									bind.llvm.ir.store(&cg.lc.builder, fval, slot_ptr);
								}
								let ls: back.codegen.expressions.LocalSlot = {
									.name = b.name,
									.ptr = slot_ptr,
									.st_ty = bind_ty,
									.ll_ty = bind_ll,
									.scope_depth = cg.scope_depth
								};
								cg.locals.push(ls);
							}
						}
					}
				}
				emit_stmt(cg, arm.body);
				cg.locals.len = prev_locals;
				cg.scope_depth -= 1;
				if !back.codegen.expressions.block_has_terminator(cg) {
					bind.llvm.ir.branch(&cg.lc.builder, merge_bb);
				}
				bind.llvm.ir.position_at_end(&cg.lc.builder, next_bb);
			}
			if !back.codegen.expressions.block_has_terminator(cg) {
				bind.llvm.ir.branch(&cg.lc.builder, merge_bb);
			}
			bind.llvm.ir.position_at_end(&cg.lc.builder, merge_bb);
		}
		.Return => {
			let mut ret_val: bind.llvm.core.Value = bind.llvm.core.wrap_value(null);
			let has_ret: bool = s.ret_val != null && cg.current_fn_ret != null
				&& middle.types.underlying_type(cg.current_fn_ret).kind
				!= middle.types.TypeKind.Void;
			if has_ret {
				ret_val = back.codegen.expressions.emit_expr(cg, s.ret_val, cg.current_fn_ret);
			}
			emit_defers_from_depth(cg, 0);
			if has_ret {
				bind.llvm.ir.ret(&cg.lc.builder, ret_val);
			} else {
				bind.llvm.ir.ret_void(&cg.lc.builder);
			}
		}
		.Yield => {
			if s.ret_val != null && cg.yield_slot.handle != null && cg.yield_ty != null {
				let yv: bind.llvm.core.Value = back.codegen.expressions.emit_expr(
					cg,
					s.ret_val,
					cg.yield_ty
				);
				bind.llvm.ir.store(&cg.lc.builder, yv, cg.yield_slot);
			}
			emit_defers_from_depth(cg, cg.yield_scope_depth + 1);
			if cg.yield_end_bb != null {
				bind.llvm.ir.branch(&cg.lc.builder, cg.yield_end_bb);
			}
		}
		.Break => {
			if cg.loop_stack.len > 0 {
				let lt: back.codegen.expressions.LoopTarget =
					cg.loop_stack.data[cg.loop_stack.len - 1];
				emit_defers_from_depth(cg, lt.scope_depth);
				bind.llvm.ir.branch(&cg.lc.builder, lt.break_bb);
			}
		}
		.Continue => {
			if cg.loop_stack.len > 0 {
				let lt: back.codegen.expressions.LoopTarget =
					cg.loop_stack.data[cg.loop_stack.len - 1];
				emit_defers_from_depth(cg, lt.scope_depth);
				bind.llvm.ir.branch(&cg.lc.builder, lt.continue_bb);
			}
		}
		.Unreachable => {
			bind.llvm.ir.unreachable_inst(&cg.lc.builder);
		}
		.Defer => {
			let de: back.codegen.expressions.DeferEntry = {
				.stmt = s.defer_body,
				.scope_depth = cg.scope_depth
			};
			cg.defers.push(de);
		}
		.Asm => {
			let mut ccap: usize = 256;
			let mut cbuf: *mut u8 = front.ast.arena_alloc(ccap);
			if cbuf == null {
				return;
			}
			let mut clen: usize = 0;
			let mut first: bool = true;

			let out_n: usize = s.asm_outputs.len;
			let in_n: usize = s.asm_inputs.len;
			let mut ret_ll: bind.llvm.core.Type = bind.llvm.core.type.void_type(&cg.lc.ctx);
			if out_n == 1 {
				let mut oty: *mut middle.types.StType = null;
				back.codegen.expressions.emit_lvalue(cg, s.asm_outputs.data[0].operand, &oty);
				if oty == null {
					oty = back.codegen.expressions.expr_type(
						cg,
						s.asm_outputs.data[0].operand,
						cg.sema.tx.usize_t
					);
				}
				ret_ll = back.codegen.types.to_llvm_type(&cg.lc.ctx, &cg.lc.td, oty);
			} else if out_n > 1 {
				let raw: *mut u8 = front.ast.arena_alloc(out_n * @of.size(usize));
				if raw != null {
					let oelems: *mut *void = raw cast *mut *void;
					for let mut i: usize = 0; i < out_n; i += 1 {
						let oty: *mut middle.types.StType = back.codegen.expressions.expr_type(
							cg,
							s.asm_outputs.data[i].operand,
							cg.sema.tx.usize_t
						);
						oelems[i] = back.codegen.types.to_llvm_type(
							&cg.lc.ctx,
							&cg.lc.td,
							oty
						).handle;
					}
					ret_ll = bind.llvm.core.type.struct_type(
						&cg.lc.ctx,
						oelems,
						out_n cast u32,
						false
					);
				}
			}

			for let mut i: usize = 0; i < out_n; i += 1 {
				if !first {
					append_str_buf(&cbuf, &clen, &ccap, ",");
				}
				first = false;
				append_asm_constraint(&cbuf, &clen, &ccap, s.asm_outputs.data[i].constraint);
			}
			for let mut i: usize = 0; i < in_n; i += 1 {
				if !first {
					append_str_buf(&cbuf, &clen, &ccap, ",");
				}
				first = false;
				append_asm_constraint(&cbuf, &clen, &ccap, s.asm_inputs.data[i].constraint);
			}
			for let mut i: usize = 0; i < s.asm_clobbers.len; i += 1 {
				if !first {
					append_str_buf(&cbuf, &clen, &ccap, ",");
				}
				first = false;
				append_str_buf(&cbuf, &clen, &ccap, "~{");
				append_str_buf(&cbuf, &clen, &ccap, s.asm_clobbers.data[i]);
				append_str_buf(&cbuf, &clen, &ccap, "}");
			}
			cbuf[clen] = 0;

			let mut fn_ll: bind.llvm.core.Type = bind.llvm.core.type.function(
				ret_ll,
				null,
				0,
				false
			);
			let mut arg_ptrs: *mut *void = null;
			if in_n > 0 {
				let p1: *mut u8 = front.ast.arena_alloc(in_n * @of.size(usize));
				let p2: *mut u8 = front.ast.arena_alloc(in_n * @of.size(usize));
				if p1 != null && p2 != null {
					let ptypes: *mut *void = p1 cast *mut *void;
					arg_ptrs = p2 cast *mut *void;
					for let mut i: usize = 0; i < in_n; i += 1 {
						let ity: *mut middle.types.StType =
							back.codegen.expressions.expr_type(
								cg,
								s.asm_inputs.data[i].operand,
								cg.sema.tx.usize_t
							);
						let iv: bind.llvm.core.Value =
							back.codegen.expressions.emit_expr(
								cg,
								s.asm_inputs.data[i].operand,
								ity
							);
						arg_ptrs[i] = iv.handle;
						ptypes[i] = bind.llvm.core.type_of(&iv).handle;
					}
					fn_ll = bind.llvm.core.type.function(
						ret_ll,
						ptypes,
						in_n cast u32,
						false
					);
				}
			}

			let asm_val: bind.llvm.core.Value = bind.llvm.core.inline_asm(
				fn_ll,
				s.asm_code.ptr,
				s.asm_code.len,
				cbuf,
				clen,
				s.asm_volatile,
				false,
				0,
				false
			);
			let res: bind.llvm.core.Value = bind.llvm.ir.call(
				&cg.lc.builder,
				fn_ll,
				asm_val,
				arg_ptrs,
				in_n cast u32,
				out_n > 0 ? c"asm" : c""
			);

			if out_n == 1 {
				let lptr: bind.llvm.core.Value = back.codegen.expressions.emit_lvalue(
					cg,
					s.asm_outputs.data[0].operand,
					null
				);
				if lptr.handle != null {
					bind.llvm.ir.store(&cg.lc.builder, res, lptr);
				}
			} else if out_n > 1 {
				for let mut i: usize = 0; i < out_n; i += 1 {
					let lptr: bind.llvm.core.Value = back.codegen.expressions.emit_lvalue(
						cg,
						s.asm_outputs.data[i].operand,
						null
					);
					if lptr.handle != null {
						let ev: bind.llvm.core.Value = bind.llvm.ir.extract_value(
							&cg.lc.builder,
							res,
							i cast u32,
							c"asmout"
						);
						bind.llvm.ir.store(&cg.lc.builder, ev, lptr);
					}
				}
			}
		}
		_ => {}
	}
}
