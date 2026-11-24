mod front.ast;
import "front/log.sl";
import "front/token.sl";
import "std/io.sl";
import "std/mem.sl";


/// Executes `print_indent`.
pub fn print_indent(indent: i32) -> void {
	for let mut i: i32 = 0; i < indent; i += 1 {
		std.io.print("  ");
	}
}

/// Executes `dump_typeref` (dump typeref).
pub fn dump_typeref(t: *TypeRef) -> void {
	if t == null {
		std.io.print("<null-type>");
		return;
	}
	match t.kind {
		.Named => {
			if t.path.len > 0 {
				for let mut i: usize = 0; i < t.path.len; i += 1 {
					if i > 0 {
						std.io.print(".");
					}
					std.io.print(t.path.data[i]);
				}
			} else {
				std.io.print(t.name);
			}
			if t.generic_args.len > 0 {
				std.io.print("<...>");
			}
		}
		.Pointer => {
			std.io.print("*");
			if t.is_mutable {
				std.io.print("mut ");
			}
			if t.is_volatile {
				std.io.print("volatile ");
			}
			dump_typeref(t.base);
		}
		.Array => {
			std.io.print("[");
			if t.array_len_inferred {
				std.io.print("_");
			} else {
				std.io.printf("{}", t.array_len);
			}
			std.io.print("]");
			dump_typeref(t.base);
		}
		.Slice => {
			std.io.print("[]");
			if t.is_mutable {
				std.io.print("mut ");
			}
			if t.is_volatile {
				std.io.print("volatile ");
			}
			dump_typeref(t.base);
		}
		.Function => {
			std.io.print("fn(");
			for let mut i: usize = 0; i < t.fn_params.len; i += 1 {
				if i > 0 {
					std.io.print(", ");
				}
				dump_typeref(t.fn_params.data[i]);
			}
			if t.fn_variadic {
				if t.fn_params.len > 0 {
					std.io.print(", ");
				}
				std.io.print("...");
			}
			std.io.print(") -> ");
			dump_typeref(t.fn_ret);
		}
		.TypeOf => std.io.print("@of.type(...)"),
		.SelfType => std.io.print("Self")
	}
}

/// Executes `dump_expr` (dump expr).
pub fn dump_expr(e: *Expr, indent: i32) -> void {
	if e == null {
		return;
	}
	print_indent(indent);
	match e.kind {
		.IntLit => std.io.printf("IntLit({})\n", e.int_val),
		.FloatLit => std.io.printf("FloatLit({})\n", e.str_val),
		.StringLit => std.io.printf("StringLit(\"{}\")\n", e.str_val),
		.CharLit => std.io.printf("CharLit({})\n", e.char_val),
		.BoolLit => std.io.printf("BoolLit({})\n", e.int_val != 0 ? "true" : "false"),
		.NullLit => std.io.print("NullLit\n"),
		.Ident => {
			std.io.print("Ident(");
			for let mut i: usize = 0; i < e.path.len; i += 1 {
				if i > 0 {
					std.io.print(".");
				}
				std.io.print(e.path.data[i]);
			}
			std.io.print(")\n");
		}
		.EnumMember => std.io.printf("EnumMember(.{})\n", e.member),
		.VariantInit => std.io.printf("VariantInit(.{})\n", e.member),
		.DefineRef => std.io.printf("DefineRef(#{})\n", e.member),
		.Unary => {
			std.io.printf("Unary({})\n", e.unary_op);
			dump_expr(e.lhs, indent + 1);
		}
		.Binary => {
			let op_s: []u8 = front.token.op_text(e.op, e.op_variant);
			std.io.printf("Binary({})\n", op_s);
			dump_expr(e.lhs, indent + 1);
			dump_expr(e.rhs, indent + 1);
		}
		.Assign => {
			std.io.printf("Assign(compound={})\n", e.is_compound_assignment ? "true" : "false");
			dump_expr(e.lhs, indent + 1);
			dump_expr(e.rhs, indent + 1);
		}
		.Conditional => {
			std.io.print("Conditional\n");
			dump_expr(e.condition, indent + 1);
			dump_expr(e.then_expr, indent + 1);
			dump_expr(e.else_expr, indent + 1);
		}
		.Call => {
			std.io.printf("Call(args={})\n", e.args.len);
			dump_expr(e.lhs, indent + 1);
			for let mut i: usize = 0; i < e.args.len; i += 1 {
				dump_expr(e.args.data[i], indent + 1);
			}
		}
		.Member => {
			std.io.printf("Member(.{})\n", e.member);
			dump_expr(e.lhs, indent + 1);
		}
		.Index => {
			std.io.printf("Index(bit_range={})\n", e.is_bit_range ? "true" : "false");
			dump_expr(e.lhs, indent + 1);
			dump_expr(e.rhs, indent + 1);
			if e.index_low != null {
				dump_expr(e.index_low, indent + 1);
			}
		}
		.Slice => {
			std.io.print("Slice\n");
			dump_expr(e.lhs, indent + 1);
			if e.rhs != null {
				dump_expr(e.rhs, indent + 1);
			}
			if e.index_low != null {
				dump_expr(e.index_low, indent + 1);
			}
		}
		.StructLit => std.io.printf("StructLit(fields={})\n", e.field_names.len),
		.ArrayLit => std.io.printf("ArrayLit(elems={})\n", e.args.len),
		.Cast => {
			std.io.printf("{}(", e.is_bitcast ? "Bitcast" : "Cast");
			dump_typeref(e.cast_type);
			std.io.print(")\n");
			dump_expr(e.lhs, indent + 1);
		}
		.AddrOf => {
			std.io.print("AddrOf\n");
			dump_expr(e.lhs, indent + 1);
		}
		.Deref => {
			std.io.print("Deref\n");
			dump_expr(e.lhs, indent + 1);
		}
		.Block => {
			std.io.print("BlockExpr\n");
			dump_stmt(e.block, indent + 1);
		}
		_ => std.io.print("BuiltinOrSpecialExpr\n")
	}
}

/// Executes `dump_stmt` (dump stmt).
pub fn dump_stmt(s: *Stmt, indent: i32) -> void {
	if s == null {
		return;
	}
	print_indent(indent);
	match s.kind {
		.Block => {
			std.io.printf("Block(stmts={})\n", s.body.len);
			for let mut i: usize = 0; i < s.body.len; i += 1 {
				dump_stmt(s.body.data[i], indent + 1);
			}
		}
		.ExprStmt => {
			std.io.print("ExprStmt\n");
			dump_expr(s.expr, indent + 1);
		}
		.VarDecl | .ConstDecl => {
			std.io.printf(
				"{}(vars={})\n",
				s.kind == StmtKind.ConstDecl ? "ConstDecl" : "VarDecl",
				s.vars.len
			);
			for let mut i: usize = 0; i < s.vars.len; i += 1 {
				print_indent(indent + 1);
				std.io.printf("{}: ", s.vars.data[i].name);
				dump_typeref(s.vars.data[i].ty);
				std.io.print("\n");
				if s.vars.data[i].init != null {
					dump_expr(s.vars.data[i].init, indent + 2);
				}
			}
		}
		.If => {
			std.io.print("If\n");
			dump_expr(s.cond, indent + 1);
			dump_stmt(s.then_block, indent + 1);
			if s.else_block != null {
				dump_stmt(s.else_block, indent + 1);
			}
		}
		.For => {
			std.io.print("For\n");
			if s.for_init != null {
				dump_stmt(s.for_init, indent + 1);
			}
			if s.for_cond != null {
				dump_expr(s.for_cond, indent + 1);
			}
			if s.for_step != null {
				dump_expr(s.for_step, indent + 1);
			}
			dump_stmt(s.loop_body, indent + 1);
		}
		.Match => {
			std.io.printf("Match(arms={})\n", s.arms.len);
			dump_expr(s.scrutinee, indent + 1);
			for let mut i: usize = 0; i < s.arms.len; i += 1 {
				dump_stmt(s.arms.data[i].body, indent + 1);
			}
		}
		.Return => {
			std.io.print("Return\n");
			if s.ret_val != null {
				dump_expr(s.ret_val, indent + 1);
			}
		}
		.Defer => {
			std.io.print("Defer\n");
			dump_stmt(s.defer_body, indent + 1);
		}
		.Yield => {
			std.io.print("Yield\n");
			if s.ret_val != null {
				dump_expr(s.ret_val, indent + 1);
			}
		}
		.Break => std.io.print("Break\n"),
		.Continue => std.io.print("Continue\n"),
		.Unreachable => std.io.print("Unreachable\n"),
		.Asm => std.io.print("Asm\n"),
		.Import => std.io.print("Import\n")
	}
}

/// Executes `dump_top_decl`.
pub fn dump_top_decl(d: *TopDecl, indent: i32) -> void {
	if d == null {
		return;
	}
	print_indent(indent);
	match d.kind {
		.Fn => {
			let fn_d: *FnDecl = d.fn_decl;
			std.io.printf(
				"{}(name={}, params={}, ret=",
				fn_d.is_macro ? "Macro" : "Fn",
				fn_d.name,
				fn_d.params.len
			);
			dump_typeref(fn_d.ret);
			std.io.print(")\n");
			if fn_d.body != null {
				dump_stmt(fn_d.body, indent + 1);
			}
		}
		.Struct => std.io.printf("Struct(name={}, fields={})\n", d.st.name, d.st.field_names.len),
		.Union => std.io.printf("Union(name={}, fields={})\n", d.un.name, d.un.field_names.len),
		.Enum => std.io.printf("Enum(name={}, members={})\n", d.en.name, d.en.members.len),
		.TypeBinding => {
			std.io.printf("TypeBinding(name={}, target=", d.tb.name);
			dump_typeref(d.tb.target);
			std.io.print(")\n");
		}
		.Var | .Const => {
			std.io.printf(
				"Global(name={}, const={})\n",
				d.glob.name,
				d.glob.is_const ? "true" : "false"
			);
		}
		.Import => std.io.printf("Import(path={})\n", d.imp.written_path),
		.Trait => {
			std.io.printf(
				"Trait(name={}, methods={})\n",
				d.trait_decl.name,
				d.trait_decl.methods.len
			);
		}
		.Impl => {
			std.io.printf(
				"Impl(trait={}, methods={})\n",
				d.impl_decl.trait_name,
				d.impl_decl.methods.len
			);
		}
		.Mod => {
			std.io.printf("Mod(name={}, decls={})\n", d.mod_decl.name, d.mod_decl.body.len);
			for let mut i: usize = 0; i < d.mod_decl.body.len; i += 1 {
				dump_top_decl(d.mod_decl.body.data[i], indent + 1);
			}
		}
		.Conditional => std.io.printf("Conditional(arms={})\n", d.conditional.arms.len),
		.Error => std.io.print("ErrorDecl\n")
	}
}

/// Executes `dump_module` (dump module).
pub fn dump_module(m: *Module) -> void {
	std.io.print("Module(");
	for let mut i: usize = 0; i < m.mod_path.len; i += 1 {
		if i > 0 {
			std.io.print(".");
		}
		std.io.print(m.mod_path.data[i]);
	}
	std.io.printf(", decls={})\n", m.decls.len);
	for let mut i: usize = 0; i < m.decls.len; i += 1 {
		dump_top_decl(m.decls.data[i], 1);
	}
}
