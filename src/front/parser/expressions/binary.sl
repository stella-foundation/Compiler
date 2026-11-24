mod front.parser;
import "front/ast.sl";
import "front/log.sl";
import "front/token.sl";
import "std/mem.sl";
import "std/str.sl";

/// Represents the `Parser` data structure.

impl Parser {
	pub fn parse_expr(self: *mut Parser) -> *mut front.ast.Expr {
		return self.parse_assign();
	}

	/// Executes `parse_assign` (parse assign).
	pub fn parse_assign(self: *mut Parser) -> *mut front.ast.Expr {
		let lhs: *mut front.ast.Expr = self.parse_conditional();
		if self.at(front.token.TokenKind.Assign) {
			let loc: front.log.SourceLoc = self.peek(0).loc;
			self.consume();
			let rhs: *mut front.ast.Expr = self.parse_assign();
			let e: *mut front.ast.Expr = front.ast.alloc_expr(front.ast.ExprKind.Assign, loc);
			e.lhs = lhs;
			e.rhs = rhs;
			return e;
		}
		let t: front.token.Token = self.peek(0);
		if t.kind == front.token.TokenKind.Operator && t.compound_assignment {
			self.consume();
			let rhs: *mut front.ast.Expr = self.parse_assign();
			let bin: *mut front.ast.Expr = front.ast.alloc_expr(front.ast.ExprKind.Binary, t.loc);
			bin.op = t.op;
			bin.op_variant = t.variant;
			bin.lhs = front.ast.clone_expr(lhs);
			bin.rhs = rhs;
			let e: *mut front.ast.Expr = front.ast.alloc_expr(front.ast.ExprKind.Assign, t.loc);
			e.is_compound_assignment = true;
			e.lhs = lhs;
			e.rhs = bin;
			return e;
		}
		return lhs;
	}

	/// Executes `parse_conditional` (parse conditional).
	pub fn parse_conditional(self: *mut Parser) -> *mut front.ast.Expr {
		let cond: *mut front.ast.Expr = self.parse_logic_or();
		if !self.accept(front.token.TokenKind.Question) {
			return cond;
		}
		let loc: front.log.SourceLoc = cond != null ? cond.loc : self.peek(0).loc;
		let e: *mut front.ast.Expr = front.ast.alloc_expr(front.ast.ExprKind.Conditional, loc);
		e.condition = cond;
		e.then_expr = self.parse_expr();
		self.expect(front.token.TokenKind.Colon, "':' in conditional expression");
		e.else_expr = self.parse_conditional();
		return e;
	}

	/// Executes `parse_logic_or` (parse logic or).
	pub fn parse_logic_or(self: *mut Parser) -> *mut front.ast.Expr {
		let mut lhs: *mut front.ast.Expr = self.parse_logic_and();
		for self.at_binop(front.token.Op.LogicalOr) {
			let op_tok: front.token.Token = self.consume();
			let rhs: *mut front.ast.Expr = self.parse_logic_and();
			lhs = make_binary(op_tok, lhs, rhs);
		}
		return lhs;
	}

	/// Executes `parse_logic_and` (parse logic and).
	pub fn parse_logic_and(self: *mut Parser) -> *mut front.ast.Expr {
		let mut lhs: *mut front.ast.Expr = self.parse_bitor();
		for self.at_binop(front.token.Op.LogicalAnd) {
			let op_tok: front.token.Token = self.consume();
			let rhs: *mut front.ast.Expr = self.parse_bitor();
			lhs = make_binary(op_tok, lhs, rhs);
		}
		return lhs;
	}

	/// Executes `parse_bitor` (parse bitor).
	pub fn parse_bitor(self: *mut Parser) -> *mut front.ast.Expr {
		let mut lhs: *mut front.ast.Expr = self.parse_bitxor();
		for self.at_binop(front.token.Op.BitOr) {
			let op_tok: front.token.Token = self.consume();
			let rhs: *mut front.ast.Expr = self.parse_bitxor();
			lhs = make_binary(op_tok, lhs, rhs);
		}
		return lhs;
	}

	/// Executes `parse_bitxor` (parse bitxor).
	pub fn parse_bitxor(self: *mut Parser) -> *mut front.ast.Expr {
		let mut lhs: *mut front.ast.Expr = self.parse_bitand();
		for self.at_binop(front.token.Op.BitXor) {
			let op_tok: front.token.Token = self.consume();
			let rhs: *mut front.ast.Expr = self.parse_bitand();
			lhs = make_binary(op_tok, lhs, rhs);
		}
		return lhs;
	}

	/// Executes `parse_bitand` (parse bitand).
	pub fn parse_bitand(self: *mut Parser) -> *mut front.ast.Expr {
		let mut lhs: *mut front.ast.Expr = self.parse_equality();
		for self.at_binop(front.token.Op.BitAnd) {
			let op_tok: front.token.Token = self.consume();
			let rhs: *mut front.ast.Expr = self.parse_equality();
			lhs = make_binary(op_tok, lhs, rhs);
		}
		return lhs;
	}

	/// Executes `parse_equality` (parse equality).
	pub fn parse_equality(self: *mut Parser) -> *mut front.ast.Expr {
		let mut lhs: *mut front.ast.Expr = self.parse_relational();
		for self.at_binop(front.token.Op.Eq) || self.at_binop(front.token.Op.Ne) {
			let op_tok: front.token.Token = self.consume();
			let rhs: *mut front.ast.Expr = self.parse_relational();
			lhs = make_binary(op_tok, lhs, rhs);
		}
		return lhs;
	}

	/// Executes `parse_relational` (parse relational).
	pub fn parse_relational(self: *mut Parser) -> *mut front.ast.Expr {
		let mut lhs: *mut front.ast.Expr = self.parse_shift();
		for self.at_binop(front.token.Op.Lt)
			|| ((!self.parsing_generic_arg || self.generic_arg_nesting != 0)
			&& self.at_binop(front.token.Op.Gt))
			|| self.at_binop(front.token.Op.Le) || self.at_binop(front.token.Op.Ge) {
			let op_tok: front.token.Token = self.consume();
			let rhs: *mut front.ast.Expr = self.parse_shift();
			lhs = make_binary(op_tok, lhs, rhs);
		}
		return lhs;
	}

	/// Executes `parse_shift` (parse shift).
	pub fn parse_shift(self: *mut Parser) -> *mut front.ast.Expr {
		let mut lhs: *mut front.ast.Expr = self.parse_additive();
		for self.at_binop(front.token.Op.Shl) || self.at_binop(front.token.Op.Shr) {
			let op_tok: front.token.Token = self.consume();
			let rhs: *mut front.ast.Expr = self.parse_additive();
			lhs = make_binary(op_tok, lhs, rhs);
		}
		return lhs;
	}

	/// Executes `parse_additive` (parse additive).
	pub fn parse_additive(self: *mut Parser) -> *mut front.ast.Expr {
		let mut lhs: *mut front.ast.Expr = self.parse_multiplicative();
		for self.at_binop(front.token.Op.Add) || self.at_binop(front.token.Op.Sub) {
			let op_tok: front.token.Token = self.consume();
			let rhs: *mut front.ast.Expr = self.parse_multiplicative();
			lhs = make_binary(op_tok, lhs, rhs);
		}
		return lhs;
	}

	/// Executes `parse_multiplicative` (parse multiplicative).
	pub fn parse_multiplicative(self: *mut Parser) -> *mut front.ast.Expr {
		let mut lhs: *mut front.ast.Expr = self.parse_unary();
		for self.at_binop(front.token.Op.Mul) || self.at_binop(front.token.Op.Div)
			|| self.at_binop(front.token.Op.Mod) {
			let op_tok: front.token.Token = self.consume();
			let rhs: *mut front.ast.Expr = self.parse_unary();
			lhs = make_binary(op_tok, lhs, rhs);
		}
		return lhs;
	}

	/// Executes `parse_unary` (parse unary).
	pub fn parse_unary(self: *mut Parser) -> *mut front.ast.Expr {
		if self.at_binop(front.token.Op.Mul) {
			let loc: front.log.SourceLoc = self.peek(0).loc;
			self.consume();
			let e: *mut front.ast.Expr = front.ast.alloc_expr(front.ast.ExprKind.Deref, loc);
			e.lhs = self.parse_unary();
			return e;
		}
		if self.at_binop(front.token.Op.BitAnd) {
			let loc: front.log.SourceLoc = self.peek(0).loc;
			self.consume();
			let e: *mut front.ast.Expr = front.ast.alloc_expr(front.ast.ExprKind.AddrOf, loc);
			e.lhs = self.parse_unary();
			return e;
		}
		if self.at(front.token.TokenKind.Bang) {
			let loc: front.log.SourceLoc = self.peek(0).loc;
			self.consume();
			let e: *mut front.ast.Expr = front.ast.alloc_expr(front.ast.ExprKind.Unary, loc);
			e.unary_op = "!";
			e.lhs = self.parse_unary();
			return e;
		}
		if self.at(front.token.TokenKind.Tilde) {
			let loc: front.log.SourceLoc = self.peek(0).loc;
			self.consume();
			let e: *mut front.ast.Expr = front.ast.alloc_expr(front.ast.ExprKind.Unary, loc);
			e.unary_op = "~";
			e.lhs = self.parse_unary();
			return e;
		}
		if self.at_binop(front.token.Op.Sub) {
			let loc: front.log.SourceLoc = self.peek(0).loc;
			self.consume();
			let e: *mut front.ast.Expr = front.ast.alloc_expr(front.ast.ExprKind.Unary, loc);
			e.unary_op = "-";
			e.lhs = self.parse_unary();
			return e;
		}
		return self.parse_postfix();
	}

	/// Executes `parse_builtin_call` (parse builtin call).
}
