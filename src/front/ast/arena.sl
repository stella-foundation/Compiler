mod front.ast;
import "front/log.sl";
import "front/token.sl";
import "std/io.sl";
import "std/mem.sl";


const ARENA_SLAB_SIZE: usize = 1048576;

let mut g_page_alloc: std.mem.PageAllocator;
let mut g_arena_ptr: *mut u8 = null;

/// Allocates `size` bytes (16-byte aligned) from the compiler's bump arena.
pub fn arena_alloc(size: usize) -> *mut u8 {
	let mut arena: *mut std.mem.ArenaAllocator<std.mem.PageAllocator> =
		g_arena_ptr cast *mut std.mem.ArenaAllocator<std.mem.PageAllocator>;
	if arena == null {
		g_page_alloc = std.mem.PageAllocator.init();
		let sz: usize = @of.size(*arena);
		let al: usize = @of.align(*arena);
		match g_page_alloc.alloc(sz, al) {
			.Ok(raw) => {
				arena = raw cast *mut std.mem.ArenaAllocator<std.mem.PageAllocator>;
				*arena = std.mem.ArenaAllocator<std.mem.PageAllocator>.init_with_capacity(
					&g_page_alloc,
					ARENA_SLAB_SIZE
				);
				g_arena_ptr = raw;
			}
			.Err(_) => return null
		}
	}
	let n: usize = size == 0 ? 1 : size;
	match arena.alloc(n, 16) {
		.Ok(p) => return p,
		.Err(_) => return null
	}
}

// Generic pointer list for AST child arrays.

/// Represents the `PtrList` data structure.
