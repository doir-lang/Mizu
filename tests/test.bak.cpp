#define MIZU_IMPLEMENTATION
#include <mizu/instructions.hpp>

#include <ffi/instructions.hpp>

MIZU_MAIN() {
	using namespace mizu;

#ifdef _WIN32
	auto path = "./tst_load";
#else
	auto path = "./libtst_load";
#endif
	auto function = "print";
	auto hw = "Hello 世界";
	const static opcode program[] = {
		opcode{find_label, 200}.set_immediate(label2immediate("thread")),
		opcode{ffi::push_type_void},
		opcode{ffi::push_type_pointer},
		opcode{ffi::create_interface, 201},

		opcode{load_immediate, 202}.set_host_pointer_lower_immediate(path),
		opcode{load_upper_immediate, 202}.set_host_pointer_upper_immediate(path),
		opcode{load_immediate, 203}.set_host_pointer_lower_immediate(function),
		opcode{load_upper_immediate, 203}.set_host_pointer_upper_immediate(function),
		opcode{load_immediate, 204}.set_host_pointer_lower_immediate(hw),
		opcode{load_upper_immediate, 204}.set_host_pointer_upper_immediate(hw),

		opcode{ffi::load_library, 202, 202},
		opcode{ffi::load_library_function, 203, 202, 203},

		opcode{load_immediate, 1}.set_immediate(5),
		opcode{stack_push_immediate}.set_immediate(1),
		opcode{stack_store_u32, 0, 1},
		opcode{load_immediate, 2}.set_immediate(6),
		opcode{add, 3, 2, 1},
		opcode{debug_print, 0, 3},
		opcode{load_immediate, 4}.set_immediate(1),
		opcode{set_if_equal, 4, 4, 0},
		opcode{branch_relative_immediate, 0, 4}.set_branch_immediate(5),
		// opcode{fork_relative_immediate, 5}.set_immediate_signed(5),
		opcode{channel_create, 220, 0},
		opcode{fork_to, 5, 200},
		opcode{stack_load_u32, 3},
		opcode{debug_print, 0, 3},

		opcode{load_immediate, 6}.set_immediate(7),
		opcode{convert_to_f64, 6, 6},
		opcode{convert_to_f64, 7, 3},
		opcode{add_f64, 8, 6, 7},
		opcode{debug_print, 0, 8},
		opcode{channel_receive, 1, 220},
		opcode{channel_close, 0, 220},
		opcode{debug_print, 0, 1},
		opcode{join_thread, 0, 5, 0},
		opcode{halt},


		// Thread
		opcode{label}.set_immediate(label2immediate("thread")),
		opcode{find_label, 200}.set_immediate(label2immediate("fib")),
		opcode{load_immediate, 1}.set_immediate(22),
		opcode{debug_print, 0, 1},
		// FFI call (print)
		opcode{add, registers::a(0), 204, 0},
		opcode{ffi::call, 0, 203, 201},
		// Mizu call (a0 = fib(40))
		opcode{load_immediate, registers::a(0)}.set_immediate(40),
		opcode{jump_to, registers::return_address, 200},
		opcode{channel_send, 0, 220, registers::a(0)},
		opcode{debug_print, 0, registers::a(0)},
		opcode{halt},


		// Recursive Fibonacci
		opcode{label}.set_immediate(label2immediate("fib")),
		// if(a0 >= 3) skip return 1
		opcode{load_immediate, registers::t(0)}.set_immediate(3),
		opcode{set_if_greater_equal, registers::t(0), registers::a(0), registers::t(0)},
		opcode{branch_relative_immediate, 0, registers::t(0)}.set_branch_immediate(3),
		// return 1
		opcode{load_immediate, registers::a(0)}.set_immediate(1),
		opcode{jump_to, 0, registers::return_address}, // return
		// save ra, save a2, save a3
		opcode{stack_push_immediate, 0}.set_immediate(24),
		opcode{load_immediate, registers::t(0)}.set_immediate(24),
		opcode{stack_store_u64, 0, registers::return_address, registers::t(0)},
		opcode{load_immediate, registers::t(0)}.set_immediate(16),
		opcode{stack_store_u64, 0, registers::a(2), registers::t(0)},
		opcode{load_immediate, registers::t(0)}.set_immediate(8),
		opcode{stack_store_u64, 0, registers::a(3), registers::t(0)},
		// a2 = a0 - 1
		opcode{load_immediate, registers::t(0)}.set_immediate(1),
		opcode{subtract, registers::a(2), registers::a(0), registers::t(0)},
		// a3 = a0 - 2
		opcode{load_immediate, registers::t(0)}.set_immediate(2),
		opcode{subtract, registers::a(3), registers::a(0), registers::t(0)},
		// a2 = fib(a2)
		opcode{add, registers::a(0), registers::a(2), 0},
		opcode{jump_to, registers::return_address, 200}, // 200 == fib
		opcode{add, registers::a(2), registers::a(0), 0},
		// a0 = fib(a3)
		opcode{add, registers::a(0), registers::a(3), 0},
		opcode{jump_to, registers::return_address, 200}, // 200 == fib
		// opcode{add, registers::a(3), registers::a(0), 0},
		// a0 = a2 + a0
		opcode{add, registers::a(0), registers::a(2), registers::a(0)},
		// restore ra, a2, a3
		opcode{load_immediate, registers::t(0)}.set_immediate(24),
		opcode{stack_load_u64, registers::return_address, registers::t(0)},
		opcode{load_immediate, registers::t(0)}.set_immediate(16),
		opcode{stack_load_u64, registers::a(2), registers::t(0)},
		opcode{load_immediate, registers::t(0)}.set_immediate(8),
		opcode{stack_load_u64, registers::a(3), registers::t(0)},
		opcode{stack_pop_immediate}.set_immediate(24),
		// return
		opcode{jump_to, 0, registers::return_address}, // return
	};

	{
		registers_and_stack env = {};
		setup_environment(env);

		MIZU_START_FROM_ENVIRONMENT(program, env);
	}

	return 0;
}