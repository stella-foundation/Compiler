mod front.ast;
import "front/log.sl";
import "front/token.sl";
import "std/io.sl";
import "std/mem.sl";

pub struct PtrList<T> {
	/// Stores the `data` field (data).
	pub data: *mut *mut T,
	/// Stores the `len` field (len).
	pub len: usize,
	/// Stores the `cap` field (cap).
	pub cap: usize
}

impl<T> PtrList<T> {
	/// Executes `init` (init).
	pub fn init(self: *mut Self) -> void {
		self.data = null;
		self.len = 0;
		self.cap = 0;
	}

	/// Executes `push` (push).
	pub fn push(self: *mut Self, item: *mut T) -> bool {
		if self.len == self.cap {
			let new_cap: usize = self.cap == 0 ? 4 : self.cap * 2;
			let raw: *mut u8 = arena_alloc(new_cap * @of.size(usize));
			if raw == null {
				return false;
			}
			let next_buf: *mut *mut T = raw cast *mut *mut T;
			if self.data != null {
				std.mem.copy(raw, self.data cast *u8, self.len * @of.size(usize));
			}
			self.data = next_buf;
			self.cap = new_cap;
		}
		self.data[self.len] = item;
		self.len += 1;
		return true;
	}

	/// Executes `free_array` (free array).
	pub fn free_array(self: *mut Self) -> void {
		self.data = null;
		self.len = 0;
		self.cap = 0;
	}
}

// Contiguous value list for small value structs.

/// Represents the `ValList` data structure.
pub struct ValList<T> {
	/// Stores the `data` field (data).
	pub data: *mut T,
	/// Stores the `len` field (len).
	pub len: usize,
	/// Stores the `cap` field (cap).
	pub cap: usize
}

impl<T> ValList<T> {
	/// Executes `init` (init).
	pub fn init(self: *mut Self) -> void {
		self.data = null;
		self.len = 0;
		self.cap = 0;
	}

	/// Executes `push` (push).
	pub fn push(self: *mut Self, item: T) -> bool {
		if self.len == self.cap {
			let new_cap: usize = self.cap == 0 ? 4 : self.cap * 2;
			let raw: *mut u8 = arena_alloc(new_cap * @of.size(T));
			if raw == null {
				return false;
			}
			let next_buf: *mut T = raw cast *mut T;
			if self.data != null {
				std.mem.copy(raw, self.data cast *u8, self.len * @of.size(T));
			}
			self.data = next_buf;
			self.cap = new_cap;
		}
		self.data[self.len] = item;
		self.len += 1;
		return true;
	}

	/// Executes `free_array` (free array).
	pub fn free_array(self: *mut Self) -> void {
		self.data = null;
		self.len = 0;
		self.cap = 0;
	}
}
