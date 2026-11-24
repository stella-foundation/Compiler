mod middle.sema.control_flow;
import "front/ast.sl";
import "front/log.sl";

/// Executes `stmt_always_returns` (stmt always returns).
pub fn stmt_always_returns(s: *front.ast.Stmt) -> bool {
	if s == null {
		return false;
	}
	match s.kind {
		.Return | .Unreachable => return true,
		.Block => {
			for let mut i: usize = 0; i < s.body.len; i += 1 {
				if stmt_always_returns(s.body.data[i]) {
					return true;
				}
			}
			return false;
		}
		.If => {
			return s.else_block != null
				&& stmt_always_returns(s.then_block)
				&& stmt_always_returns(s.else_block);
		}
		.Match => {
			if s.arms.len == 0 {
				return false;
			}
			for let mut i: usize = 0; i < s.arms.len; i += 1 {
				if !stmt_always_returns(s.arms.data[i].body) {
					return false;
				}
			}
			return true;
		}
		_ => return false
	}
}

/// Executes `check_control_flow` (check control flow).
pub fn check_control_flow(s: *front.ast.Stmt, loop_depth: i32, in_block_expr: bool) -> void {
	if s == null {
		return;
	}
	match s.kind {
		.Break => {
			if loop_depth == 0 {
				front.log.report(
					front.log.Level.Error,
					s.loc,
					"'break' outside of loop",
					front.log.DiagCode.InvalidControlFlow
				);
			}
		}
		.Continue => {
			if loop_depth == 0 {
				front.log.report(
					front.log.Level.Error,
					s.loc,
					"'continue' outside of loop",
					front.log.DiagCode.InvalidControlFlow
				);
			}
		}
		.Yield => {
			if !in_block_expr {
				front.log.report(
					front.log.Level.Error,
					s.loc,
					"'yield' outside of block expression",
					front.log.DiagCode.InvalidControlFlow
				);
			}
		}
		.Block => {
			for let mut i: usize = 0; i < s.body.len; i += 1 {
				check_control_flow(s.body.data[i], loop_depth, in_block_expr);
			}
		}
		.If => {
			check_control_flow(s.then_block, loop_depth, in_block_expr);
			if s.else_block != null {
				check_control_flow(s.else_block, loop_depth, in_block_expr);
			}
		}
		.For => {
			check_control_flow(s.loop_body, loop_depth + 1, in_block_expr);
		}
		.Match => {
			for let mut i: usize = 0; i < s.arms.len; i += 1 {
				check_control_flow(s.arms.data[i].body, loop_depth, in_block_expr);
			}
		}
		.Defer => {
			check_control_flow(s.defer_body, loop_depth, in_block_expr);
		}
		_ => {}
	}
}
