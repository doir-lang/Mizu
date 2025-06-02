#define MIZU_IMPLEMENTATION
#include <mizu/instructions.hpp>
#include <instructions/simd.hpp>


int main() { // NOTE: we aren't loading any functions with ffi, thus we don't need to use MIZU main
	using namespace mizu;

	float A[16] = {
        1, 2, 3, 4,
        5, 6, 7, 8,
        9,10,11,12,
       13,14,15,16
    };

    float B[16] = {
        16,15,14,13,
        12,11,10, 9,
         8, 7, 6, 5,
         4, 3, 2, 1
    };

	const static opcode program[] = {
		opcode{find_label, 200}.set_immediate(label2immediate("multiply")),
		opcode{find_label, 201}.set_immediate(label2immediate("mloop")),
		
		// - 100 = sizeof(float)
		opcode{load_immediate, 100}.set_immediate(sizeof(float)),
		// - 101 = (16 + f32v.size()) * sizeof(float)
		opcode{simd_size_f32, t(0)},
		opcode{load_immediate, t(2)}.set_immediate(16),
		opcode{add, t(0), t(0), t(2)},
		opcode{multiply, 101, t(0), 100},
		// - 102 = 16 * sizeof(float)
		opcode{load_immediate, 102}.set_immediate(16 * sizeof(float)),
		// - 103 = &t0
		opcode{unsafe::pointer_to_register, 103, t(0)},



		// Main!
		// (a0) float result[16];
		opcode{stack_push_immediate}.set_immediate_signed(16 * sizeof(float)),
		opcode{unsafe::pointer_to_stack, a(0)},
		// a1 = A
		opcode{load_immediate, a(1)}.set_host_pointer_lower_immediate(A),	
		opcode{load_upper_immediate, a(1)}.set_host_pointer_upper_immediate(A),		
		// a2 = B
		opcode{load_immediate, a(2)}.set_host_pointer_lower_immediate(B),	
		opcode{load_upper_immediate, a(2)}.set_host_pointer_upper_immediate(B),
		// mat4_multiply(a0, a1, a2);
		opcode{jump_to, return_address, 200},

		// i(t0) = 0, t1 = 16
		opcode{add, t(0), zero},
		opcode{load_immediate, t(1)}.set_immediate(16),
		// for(int i = 0; i < 16; ++i)
			// t2 = a0[i]
			opcode{multiply, t(2), t(0), 100}, // 100 == sizeof(float)
			opcode{add, t(2), t(2), a(0)},
			opcode{unsafe::pointer_to_register, t(3), t(2)},
			opcode{unsafe::copy_memory, t(3), t(2), 100},
			// print(t2)
			opcode{debug_print, 0, t(2)},
			// if(i < 16) ++i; continue 
			opcode{load_immediate, t(2)}.set_immediate(1),
			opcode{add, t(0), t(0), t(2)},
			opcode{set_if_less, t(3), t(0), t(1)},
			opcode{branch_relative_immediate, 0, t(3)}.set_branch_immediate(-8),

		// Done!
		opcode{halt},

		
		
		// mat4_multiply (a0 == result, a1 == a, a2 == b)
		// 	uses t0, t1, t2, t3, t4, t5, t6, t7, t8, t9, a3, a4, a5
		opcode{label}.set_immediate(label2immediate("multiply")),
			// - Push 16 + f32v.size() floats onto the stack
			opcode{stack_push, 0, 100},

			// - (t1) f32v b_col0(&b[0], std::experimental::element_aligned);
			opcode{load_immediate, t(5)}.set_immediate(0 * sizeof(float)),
			opcode{add, t(5), a(2), t(5)},
			opcode{simd_create_f32, t(1)},
			opcode{unsafe::simd_load_pointer_f32, t(1), t(5)},
			// - (t2) f32v b_col1(&b[4], std::experimental::element_aligned);
            opcode{load_immediate, t(5)}.set_immediate(4 * sizeof(float)),
            opcode{add, t(5), a(2), t(5)},
			opcode{simd_create_f32, t(2)},
            opcode{unsafe::simd_load_pointer_f32, t(2), t(5)},
			// - (t3) f32v b_col2(&b[8], std::experimental::element_aligned);
            opcode{load_immediate, t(5)}.set_immediate(8 * sizeof(float)),
            opcode{add, t(5), a(2), t(5)},
			opcode{simd_create_f32, t(3)},
            opcode{unsafe::simd_load_pointer_f32, t(3), t(5)},
			// - (t4) f32v b_col3(&b[12], std::experimental::element_aligned);
            opcode{load_immediate, t(5)}.set_immediate(12 * sizeof(float)),
            opcode{add, t(5), a(2), t(5)},
			opcode{simd_create_f32, t(4)},
            opcode{unsafe::simd_load_pointer_f32, t(4), t(5)},

			// Mark t5, t6, t7, t8 as simd
			opcode{simd_create_f32, t(5)},
			opcode{simd_create_f32, t(6)},
			opcode{simd_create_f32, t(7)},
			opcode{simd_create_f32, t(8)},

			// - a3(row) = 0; a4(size) = 4; t9(done) = ?
			opcode{add, a(3), zero},
			opcode{load_immediate, a(4)}.set_immediate(4),
			// for (int row = 0; row < 4; ++row)
			opcode{label}.set_immediate(label2immediate("mloop")),
				// - t9 = row * 4
				opcode{load_immediate, t(9)}.set_immediate(4),
				opcode{multiply, t(9), a(3), t(9)},
				// - (t5) simd_f32 a_row0(a[row * 4 + 0]); t0 == offset
				opcode{load_immediate, t(0)}.set_immediate(0),
				opcode{add, t(0), t(0), t(9)},
				opcode{multiply, t(0), t(0), 100},
				opcode{add, t(0), t(0), a(1)},
				opcode{unsafe::copy_memory, 103, t(0), 100}, // Copy the float into t(0)
				opcode{simd_broadcast_f32, t(5), t(0)},
				// - (t6) simd_f32 a_row1(a[row * 4 + 1]); t0 == offset
				opcode{load_immediate, t(0)}.set_immediate(1),
				opcode{add, t(0), t(0), t(9)},
				opcode{multiply, t(0), t(0), 100},
				opcode{add, t(0), t(0), a(1)},
				opcode{unsafe::copy_memory, 103, t(0), 100}, // Copy the float into t(0)
				opcode{simd_broadcast_f32, t(6), t(0)},
				// - (t7) simd_f32 a_row2(a[row * 4 + 2]); t0 == offset
				opcode{load_immediate, t(0)}.set_immediate(2),
				opcode{add, t(0), t(0), t(9)},
				opcode{multiply, t(0), t(0), 100},
				opcode{add, t(0), t(0), a(1)},
				opcode{unsafe::copy_memory, 103, t(0), 100}, // Copy the float into t(0)
				opcode{simd_broadcast_f32, t(7), t(0)},
				// - (t8) simd_f32 a_row3(a[row * 4 + 3]); t0 == offset
				opcode{load_immediate, t(0)}.set_immediate(3),
				opcode{add, t(0), t(0), t(9)},
				opcode{multiply, t(0), t(0), 100},
				opcode{add, t(0), t(0), a(1)},
				opcode{unsafe::copy_memory, 103, t(0), 100}, // Copy the float into t(0)
				opcode{simd_broadcast_f32, t(8), t(0)},

				// - We need to simd compute with the last temporaries for a while
				opcode{simd_create_f32, t(0)},
				opcode{simd_create_f32, t(9)},
				// t8 = a_row0(t5) * b_col0(t1) + a_row1(t6) * b_col1(t2) 
				// 	+ a_row2(t7) * b_col2(t3) + a_row3(t8) * b_col3(t4);
				opcode{simd_multiply_f32, t(0), t(5), t(1)},
				opcode{simd_multiply_f32, t(9), t(6), t(2)},
				opcode{simd_add_f32, t(0), t(0), t(9)},
				opcode{simd_multiply_f32, t(9), t(7), t(3)},
				opcode{simd_add_f32, t(0), t(0), t(9)},	
				opcode{simd_multiply_f32, t(9), t(8), t(4)},
				opcode{simd_add_f32, t(8), t(0), t(9)},	
				// - Unmark t0, t9 as simd
				opcode{simd_free_f32, 0, t(0)},
				opcode{simd_free_f32, 0, t(9)},

				// - t9 = row * 4 * sizeof(float)
				opcode{load_immediate, t(9)}.set_immediate(4),
				opcode{multiply, t(9), a(3), t(9)},
				opcode{multiply, t(9), t(9), 100},
				// - t8.copy_to(sp + t9)
				opcode{simd_store_stack_f32, 0, t(8), t(9)},

				// if(row < 4) ++row; continue
				opcode{load_immediate, t(0)}.set_immediate(1),
				opcode{add, a(3), a(3), t(0)},
				opcode{set_if_less, t(9), a(3), a(4)},
				opcode{branch_to, 0, t(9), 201}, // 201 == mloop

			// Loop done!
			opcode{label}.set_immediate(label2immediate("mdone")),
			// Cleanup simd
			opcode{simd_free_f32, 0, t(1)},
			opcode{simd_free_f32, 0, t(2)},
			opcode{simd_free_f32, 0, t(3)},
			opcode{simd_free_f32, 0, t(4)},
			opcode{simd_free_f32, 0, t(5)},
			opcode{simd_free_f32, 0, t(6)},
			opcode{simd_free_f32, 0, t(7)},
			opcode{simd_free_f32, 0, t(8)},
			// memcpy(a0, stack, 16 * sizeof(float))
			opcode{unsafe::pointer_to_stack, t(0)},
			opcode{unsafe::copy_memory, a(0), t(0), 102}, // 102 == 16 * sizeof(float)
			// Pop floats off stack
			opcode{stack_pop, 0, 100},
			// return
			opcode{jump_to, 0, return_address}
	};

	{
		registers_and_stack env = {};
		setup_environment(env);

		MIZU_START_FROM_ENVIRONMENT(program, env);
	}

	return 0;
}