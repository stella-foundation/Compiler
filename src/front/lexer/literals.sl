mod front.lexer;
import "front/ast.sl";
import "front/log.sl";
import "front/token.sl";
import "std/mem.sl";
import "std/str.sl";

/// Represents the `Lexer` data structure.

/// Represents `ParsedInt`.
pub struct ParsedInt {
	ok: bool,
	overflow: bool,
	value: u64
}

/// Executes `parse_int_literal`.
pub fn parse_int_literal(s: []u8) -> ParsedInt {
	let mut r: ParsedInt = { .ok = false, .overflow = false, .value = 0 };
	if s.len == 0 {
		return r;
	}
	let mut begin: usize = 0;
	let mut base: u64 = 10;
	if s.len > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X') {
		begin = 2;
		base = 16;
	} else if s.len > 2 && s[0] == '0' && (s[1] == 'b' || s[1] == 'B') {
		begin = 2;
		base = 2;
	}

	let max_u64: u64 = (0 cast u64) - 1;
	let mut v: u64 = 0;
	let mut had_digit: bool = false;
	for let mut k: usize = begin; k < s.len; k += 1 {
		let c: u8 = s[k];
		if c == '_' {
			continue;
		}
		let valid: bool = base == 16 ? is_xdigit(c) : (base == 2 ? is_bin_digit(c) : is_digit(c));
		if !valid {
			return r;
		}
		let d: u64 = hex_val(c) cast u64;
		if v > (max_u64 / base) {
			r.overflow = true;
			v = max_u64;
			had_digit = true;
			continue;
		}
		let nv: u64 = v * base + d;
		if nv < v {
			r.overflow = true;
			v = max_u64;
		} else {
			v = nv;
		}
		had_digit = true;
	}
	r.ok = had_digit;
	r.value = v;
	return r;
}

/// Executes `pow10_f64`.
pub fn pow10_f64(mut exp: i32) -> f64 {
	let mut res: f64 = 1.0;
	let mut base: f64 = 10.0;
	let neg: bool = exp < 0;
	if neg {
		exp = -exp;
	}
	for exp > 0 {
		if (exp & 1) != 0 {
			res = res * base;
		}
		base = base * base;
		exp = exp >> 1;
	}
	if neg {
		return 1.0 / res;
	}
	return res;
}

/// Executes `pow2_f64`.
pub fn pow2_f64(mut exp: i32) -> f64 {
	let mut res: f64 = 1.0;
	let mut base: f64 = 2.0;
	let neg: bool = exp < 0;
	if neg {
		exp = -exp;
	}
	for exp > 0 {
		if (exp & 1) != 0 {
			res = res * base;
		}
		base = base * base;
		exp = exp >> 1;
	}
	if neg {
		return 1.0 / res;
	}
	return res;
}

/// Executes `parse_float_literal`.
pub fn parse_float_literal(s: []u8) -> f64 {
	if s.len == 0 {
		return 0.0;
	}
	let mut i: usize = 0;
	let mut is_hex: bool = false;
	if s.len > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X') {
		is_hex = true;
		i = 2;
	}
	let base: f64 = is_hex ? 16.0 : 10.0;
	let mut val: f64 = 0.0;

	for i < s.len {
		let c: u8 = s[i];
		if c == '_' {
			i += 1;
			continue;
		}
		let valid: bool = is_hex ? is_xdigit(c) : is_digit(c);
		if !valid {
			break;
		}
		val = val * base + ((hex_val(c) cast i32) cast f64);
		i += 1;
	}

	if i < s.len && s[i] == '.' {
		i += 1;
		let mut frac_scale: f64 = 1.0 / base;
		for i < s.len {
			let c: u8 = s[i];
			if c == '_' {
				i += 1;
				continue;
			}
			let valid: bool = is_hex ? is_xdigit(c) : is_digit(c);
			if !valid {
				break;
			}
			val = val + ((hex_val(c) cast i32) cast f64) * frac_scale;
			frac_scale = frac_scale / base;
			i += 1;
		}
	}

	if i < s.len
		&& ((is_hex && (s[i] == 'p' || s[i] == 'P')) || (!is_hex && (s[i] == 'e' || s[i] == 'E'))) {
		i += 1;
		let mut exp_neg: bool = false;
		if i < s.len && (s[i] == '+' || s[i] == '-') {
			exp_neg = s[i] == '-';
			i += 1;
		}
		let mut exp: i32 = 0;
		for i < s.len {
			let c: u8 = s[i];
			if c == '_' {
				i += 1;
				continue;
			}
			if !is_digit(c) {
				break;
			}
			if exp < 100000 {
				exp = exp * 10 + ((c - '0') cast i32);
			}
			i += 1;
		}
		if exp_neg {
			exp = -exp;
		}
		if is_hex {
			val = val * pow2_f64(exp);
		} else {
			val = val * pow10_f64(exp);
		}
	}
	return val;
}
