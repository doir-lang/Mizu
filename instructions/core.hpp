#pragma once

#include "../mizu/opcode.hpp"

#include <fp/string.h>

namespace mizu {

	/**
	 * Converts a string label to an immediate value
	 * @note Only the first 4 characters of the label are relevant.
	 *
	 * @param label string_view to be converted
	 * @return constexpr uint32_t the immediate
	 */
	constexpr uint32_t label2immediate(const fp_string_view label) {
		size_t length = fp_string_view_length(label);
		if(length > sizeof(uint32_t)) return *fp_view_data(uint32_t, label);

		uint32_t out = 0;
		for(size_t i = 0; i < fp_string_view_length(label); ++i)
			out |= fp_view_data(char, label)[i] << (i * 8);
		return out;
	}
	/**
	 * Converts a string label to an immediate value
	 * @note Only the first 4 characters of the label are relevant.
	 *
	 * @param label string to be converted
	 * @return constexpr uint32_t the immediate
	 */
	constexpr uint32_t label2immediate(const fp_string label) { return label2immediate(fp_string_to_view_const(label)); }

	inline namespace instructions { extern "C" {
		constexpr auto program_end = nullptr;

		/**
		 * Noop which marks a label that can be found using mizu::find_label and then jumped to using mizu::jump_to
		 * @param immediate Integer label value
		 * @note mizu::label2int can convert a string into an immediate for this function
		 */
		void* label(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(label);

		/**
		 * Finds the provided label and stores a pointer to it in \p out
		 * @param out register to store the label pointer in
		 * @param immediate the label to search for
		 * @note Unlike every other assembly this is a runtime function, time is spent scanning the program to find the label.
		 *	It is this recommended to cluster these instructions near the beginning of the program where they won't be executed multiple times.
		 * @note This function first searches below it in the program then searches above it if the label can't be found.
		 *	The closest matching label following these rules will be found if there is any ambiguity.
		 */
		void* find_label(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto program_start = env->calculate_program_start(pc);
			auto program_end = env->calculate_program_end(pc);
			auto needle = *(uint32_t*)&pc->a;
			registers[pc->out] = 0;

			// Try to find searching till the end
			for(auto cur = pc; cur != program_end; ++cur)
				if(cur->op == label && *(uint32_t*)&cur->a == needle) {
					registers[pc->out] = (uint64_t)cur;
					break;
				}
			// If we failed to find try searching till the beginning
			if(registers[pc->out] == 0)
				for(auto cur = pc; cur != program_start; --cur)
					if(cur->op == label && *(uint32_t*)&cur->a == needle) {
						registers[pc->out] = (uint64_t)cur;
						break;
					}
			auto dbg = (opcode*)registers[pc->out];
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(find_label);

		/**
		 * Ends execution of the program or thread.
		 */
		void* halt(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
	#ifdef MIZU_NO_HARDWARE_THREADS
			mizu::coroutine::get_current_context().program_counter = nullptr; // Mark the coroutine context as done!
	#endif
			return nullptr;
		}
#else // MIZU_IMPLEMENTATION
		;
#endif
		MIZU_REGISTER_INSTRUCTION(halt);

		/**
		 * Prints the value stored in a register in several formats
		 * @param a the register to print the value of
		 */
		void* debug_print(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			registers[pc->out] = printf("u64 = %lu, i64 = %ld, f64 = %f, f32 = %f\n", registers[pc->a], (int64_t&)registers[pc->a], (double&)registers[pc->a], (float&)registers[pc->a]);
			fflush(stdout); // Make sure buffer is flushed!
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(debug_print);

		/**
		 * Prints the value stored in a register in several formats including binary
		 * @param a the register to print the value of
		 */
		void* debug_print_binary(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			constexpr static auto print_binary = [](void* ptr){ // From: https://stackoverflow.com/a/3974138
				uint8_t* b = (uint8_t*)ptr;

				printf("binary = ");
				for(int8_t i = sizeof(uint64_t)-1; i >= 0; --i)
					for(int8_t j = 7; j >= 0; --j) {
						uint8_t byte = (b[i] >> j) & 1;
						printf("%u", byte);
					}
			};

			print_binary(&registers[pc->a]);
			printf(", ");
			return debug_print(pc, registers, env, sp);
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(debug_print_binary);

		/**
		 * Stores an immediate value into a register
		 * @param out the register to update
		 * @param immediate the value to store in \p out
		 * @note Since immediate are only 32bit numbers this function sets the bottom 32 bits of our 64 bit registers.
		 */
		void* load_immediate(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto dbg = registers[pc->out] = *(uint32_t*)&pc->a;
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(load_immediate);

		/**
		 * Stores an immediate value into a register shifting it so that its content fills the upper 32bits.
		 * @param out the register to update
		 * @param immediate the value to store in \p out
		 * @warning The load immediate instruction overwrites the entire register, thus it should be called before load_upper_immediate!
		 */
		void* load_upper_immediate(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto dbg = registers[pc->out] |= uint64_t(*(uint32_t*)&pc->a) << 32;
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(load_upper_immediate);

		/**
		 * Converts a register to a 64 bit integer.
		 * @param out register to store the result in
		 * @param a register whose value to convert
		 */
		void* convert_to_u64(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto dbg = ((uint64_t&)registers[pc->out]) = registers[pc->a];
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(convert_to_u64);

// 		void* convert_to_i64(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
// #ifdef MIZU_IMPLEMENTATION
// 		{
// 			auto dbg = ((int64_t&)registers[pc->out]) = registers[pc->a];
// 			MIZU_NEXT();
// 		}
// #else
// 		;
// #endif
//		MIZU_REGISTER_INSTRUCTION(convert_to_i64);

		/**
		 * Converts a register to a 32 bit integer.
		 * @param out register to store the result in
		 * @param a register whose value to convert
		 */
		void* convert_to_u32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto dbg = ((uint32_t&)registers[pc->out]) = registers[pc->a];
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(convert_to_u32);

// 		void* convert_to_i32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
// #ifdef MIZU_IMPLEMENTATION
// 		{
// 			auto dbg = ((int32_t&)registers[pc->out]) = registers[pc->a];
// 			MIZU_NEXT();
// 		}
// #else
// 		;
// #endif
//		MIZU_REGISTER_INSTRUCTION(convert_to_i32);

		/**
		 * Converts a register to a 16 bit integer.
		 * @param out register to store the result in
		 * @param a register whose value to convert
		 */
		void* convert_to_u16(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto dbg = ((uint16_t&)registers[pc->out]) = registers[pc->a];
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(convert_to_u16);

// 		void* convert_to_i16(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
// #ifdef MIZU_IMPLEMENTATION
// 		{
// 			auto dbg = ((int16_t&)registers[pc->out]) = registers[pc->a];
// 			MIZU_NEXT();
// 		}
// #else
// 		;
// #endif
//		MIZU_REGISTER_INSTRUCTION(convert_to_i16);

		/**
		 * Converts a register to an 8 bit integer.
		 * @param out register to store the result in
		 * @param a register whose value to convert
		 */
		void* convert_to_u8(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto dbg = ((uint8_t&)registers[pc->out]) = registers[pc->a];
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(convert_to_u8);

		/**
		 * Loads a 64 bit integer from the stack
		 * @param out register to store the result in
		 * @param a register storing an offset to the current stack pointer (defaults to zero bytes)
		 */
		void* stack_load_u64(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			uint8_t* offset = (uint8_t*)(sp + registers[pc->a]);
			assert(offset > env->stack_boundary);
			assert(offset <= env->stack_bottom);
			auto dbg = registers[pc->out] = *(uint64_t*)offset;
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(stack_load_u64);

		/**
		 * Copies a 64 bit integer from a register to the stack.
		 * @param out register to store another copy in
		 * @param a register storing the value to copy
		 * @param b register storing an offset to the current stack pointer (defaults to zero bytes)
		 */
		void* stack_store_u64(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			uint8_t* offset = (uint8_t*)(sp + registers[pc->b]);
			assert(offset > env->stack_boundary);
			assert(offset <= env->stack_bottom);
			auto dbg = registers[pc->out] = *(uint64_t*)offset = *(uint64_t*)&registers[pc->a];
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(stack_store_u64);

		/**
		 * Loads a 32 bit integer from the stack
		 * @param out register to store the result in
		 * @param a register storing an offset to the current stack pointer (defaults to zero bytes)
		 */
		void* stack_load_u32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			uint8_t* offset = (uint8_t*)(sp + registers[pc->a]);
			assert(offset > env->stack_boundary);
			assert(offset <= env->stack_bottom);
			auto dbg = registers[pc->out] = *(uint32_t*)offset;
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(stack_load_u32);

		/**
		 * Copies a 32 bit integer from a register to the stack.
		 * @param out register to store another copy in
		 * @param a register storing the value to copy
		 * @param b register storing an offset to the current stack pointer (defaults to zero bytes)
		 */
		void* stack_store_u32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			uint8_t* offset = (uint8_t*)(sp + registers[pc->b]);
			assert(offset > env->stack_boundary);
			assert(offset <= env->stack_bottom);
			auto dbg = registers[pc->out] = *(uint32_t*)offset = *(uint32_t*)&registers[pc->a];
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(stack_store_u32);

		/**
		 * Loads a 16 bit integer from the stack
		 * @param out register to store the result in
		 * @param a register storing an offset to the current stack pointer (defaults to zero bytes)
		 */
		void* stack_load_u16(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			uint8_t* offset = (uint8_t*)(sp + registers[pc->a]);
			assert(offset > env->stack_boundary);
			assert(offset <= env->stack_bottom);
			auto dbg = registers[pc->out] = *(uint16_t*)offset;
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(stack_load_u16);

		/**
		 * Copies a 16 bit integer from a register to the stack.
		 * @param out register to store another copy in
		 * @param a register storing the value to copy
		 * @param b register storing an offset to the current stack pointer (defaults to zero bytes)
		 */
		void* stack_store_u16(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			uint8_t* offset = (uint8_t*)(sp + registers[pc->b]);
			assert(offset > env->stack_boundary);
			assert(offset <= env->stack_bottom);
			auto dbg = registers[pc->out] = *(uint16_t*)offset = *(uint16_t*)&registers[pc->a];
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(stack_store_u16);

		/**
		 * Loads an 8 bit integer from the stack
		 * @param out register to store the result in
		 * @param a register storing an offset to the current stack pointer (defaults to zero bytes)
		 */
		void* stack_load_u8(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			uint8_t* offset = (uint8_t*)(sp + registers[pc->a]);
			assert(offset > env->stack_boundary);
			assert(offset <= env->stack_bottom);
			auto dbg = registers[pc->out] = *offset;
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(stack_load_u8);

		/**
		 * Copies a 8 bit integer from a register to the stack.
		 * @param out register to store another copy in
		 * @param a register storing the value to copy
		 * @param b register storing an offset to the current stack pointer (defaults to zero bytes)
		 */
		void* stack_store_u8(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			uint8_t* offset = (uint8_t*)(sp + registers[pc->b]);
			assert(offset > env->stack_boundary);
			assert(offset <= env->stack_bottom);
			auto dbg = registers[pc->out] = *offset = *(uint8_t*)&registers[pc->a];
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(stack_store_u8);

		/**
		 * Subtracts a value from the stack pointer. In other words reserves some additional memory on the stack.
		 * @param a register storing how many bytes to reserve
		 */
		void* stack_push(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			sp -= registers[pc->a];
			assert(sp > env->stack_boundary);
			assert(sp <= env->stack_bottom);
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(stack_push);

		/**
		 * Subtracts a value from the stack pointer. In other words reserves some additional memory on the stack.
		 * @param immediate how many bytes to reserve
		 */
		void* stack_push_immediate(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto& size = *(uint32_t*)&pc->a;
			sp -= size;
			assert(sp > env->stack_boundary);
			assert(sp <= env->stack_bottom);
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(stack_push_immediate);

		/**
		 * Adds a value to stack pointer. In other words releases reserved memory on the stack.
		 * @param a register storing how many bytes to release
		 */
		void* stack_pop(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			sp += registers[pc->a];
			assert(sp > env->stack_boundary);
			assert(sp <= env->stack_bottom);
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(stack_pop);

		/**
		 * Adds a value to stack pointer. In other words releases reserved memory on the stack.
		 * @param immediate how many bytes to release
		 */
		void* stack_pop_immediate(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto& size = *(uint32_t*)&pc->a;
			sp += size;
			assert(sp > env->stack_boundary);
			assert(sp <= env->stack_bottom);
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(stack_pop_immediate);

		/**
		 * Returns the offset needed to load/store to the bottom of the stack
		 * @param out register to store the calculated offset in
		 * @param a register storing a signed offset relative to the bottom of the stack
		 */
		void* offset_of_stack_bottom(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto offset = (int64_t&)registers[pc->a];
			auto bottom = env->stack_bottom - offset;
			assert(bottom > env->stack_boundary);
			assert(bottom <= env->stack_bottom);
			auto dbg = registers[pc->out] = sp - bottom;
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(offset_of_stack_bottom);

		/**
		 * Moves the program counter by an offset. If the offset is zero this instruction is executed again. If it is one the next instruction is executed as usual.
		 *	If it is negative a previous instruction is executed.
		 * @param out register to store the address of the instruction that should be executed next.
		 * @param a register storing how many instructions to jump
		 * @note \p a is interpreted as a signed integer, allowing for negative jumps
		 */
		void* jump_relative(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto a = registers[pc->a];
			auto dbg = registers[pc->out] = (uint64_t)(pc + 1);
			pc += *(int64_t*)&a - 1;
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(jump_relative);

		/**
		 * Moves the program counter by an offset. If the offset is zero this instruction is executed again. If it is one the next instruction is executed as usual.
		 *	If it is negative a previous instruction is executed.
		 * @param out register to store the address of the instruction that should be executed next.
		 * @param immediate how many instructions to jump
		 * @note \p immediate is interpreted as a signed integer, allowing for negative jumps
		 */
		void* jump_relative_immediate(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto dbg = registers[pc->out] = (uint64_t)(pc + 1);
			pc += *(int32_t*)&pc->a - 1;
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(jump_relative_immediate);

		/**
		 * Sets the program counter to a value (usually the output of another jump)
		 * @param out register to store the address of the instruction that should be executed next.
		 * @param a register storing the address of the instruction to jump to.
		 */
		void* jump_to(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto dbg = registers[pc->out] = (uint64_t)(pc + 1);
			pc = (opcode*)registers[pc->a] - 1;
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(jump_to);

		/**
		 * Moves the program counter by an offset similar to a jump, however only does so if the condition register is not zero
		 * @param out register to store the address of the instruction that should be executed next.
		 * @param a register storing a condition, zero indicates no jump while any other number indicates that a jump should occur
		 * @param b register storing how many instructions to jump
		 * @note \p b is interpreted as a signed integer, allowing for negative jumps
		 */
		void* branch_relative(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto dbg = registers[pc->out] = (uint64_t)(pc + 1);
			if(registers[pc->a])
				pc += *(int64_t*)&registers[pc->b] - 1;
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(branch_relative);

		/**
		 * Moves the program counter by an offset similar to a jump, however only does so if the condition register is not zero
		 * @param out register to store the address of the instruction that should be executed next.
		 * @param a register storing a condition, zero indicates no jump while any other number indicates that a jump should occur
		 * @param b (branch immediate) how many instructions to jump
		 * @note \p b is interpreted as a signed integer, allowing for negative jumps
		 */
		void* branch_relative_immediate(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto dbg = registers[pc->out] = (uint64_t)(pc + 1);
			if(registers[pc->a])
				pc += *(int16_t*)&pc->b - 1;
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(branch_relative_immediate);

		/**
		 * Sets the program counter to a value (usually the output of another jump), however only does so if the condition register is not zero
		 * @param out register to store the address of the instruction that should be executed next.
		 * @param a register storing a condition, zero indicates no jump while any other number indicates that a jump should occur
		 * @param b register storing the address of the instruction to jump to.
		 */
		void* branch_to(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto dbg = registers[pc->out] = (uint64_t)(pc + 1);
			if(registers[pc->a])
				pc = (opcode*)registers[pc->b] - 1;
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(branch_to);

		/**
		 * Checks if two registers are equal
		 * @param out register to be set to one if \p a == \p b or zero otherwise
		 * @param a register storing the first value to compare
		 * @param b register storing the second value to compare
		 */
		void* set_if_equal(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto dbg = registers[pc->out] = registers[pc->a] == registers[pc->b];
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(set_if_equal);

		/**
		 * Checks if two registers are not equal
		 * @param out register to be set to one if \p a != \p b or zero otherwise
		 * @param a register storing the first value to compare
		 * @param b register storing the second value to compare
		 */
		void* set_if_not_equal(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto dbg = registers[pc->out] = registers[pc->a] != registers[pc->b];
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(set_if_not_equal);

		/**
		 * Checks if a register is less than another
		 * @param out register to be set to one if \p a < \p b or zero otherwise
		 * @param a register storing the first value to compare
		 * @param b register storing the second value to compare
		 */
		void* set_if_less(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto dbg = registers[pc->out] = registers[pc->a] < registers[pc->b];
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(set_if_less);

		/**
		 * Checks if a register is less than another
		 * @param out register to be set to one if \p a == \p b or zero otherwise
		 * @param a register storing the first value to compare
		 * @param b register storing the second value to compare
		 * @note Both \p a and \p b are treated as being signed
		 */
		void* set_if_less_signed(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto dbg = registers[pc->out] = *(int64_t*)&registers[pc->a] < *(int64_t*)&registers[pc->b];
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(set_if_less_signed);

		/**
		 * Checks if a register is greater or equal to another
		 * @param out register to be set to one if \p a >= \p b or zero otherwise
		 * @param a register storing the first value to compare
		 * @param b register storing the second value to compare
		 */
		void* set_if_greater_equal(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto dbg = registers[pc->out] = registers[pc->a] >= registers[pc->b];
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(set_if_greater_equal);

		/**
		 * Checks if a register is greater or equal to another
		 * @param out register to be set to one if \p a >= \p b or zero otherwise
		 * @param a register storing the first value to compare
		 * @param b register storing the second value to compare
		 * @note Both \p a and \p b are treated as being signed
		 */
		void* set_if_greater_equal_signed(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto dbg = registers[pc->out] = *(int64_t*)&registers[pc->a] >= *(int64_t*)&registers[pc->b];
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(set_if_greater_equal_signed);

		/**
		 * Adds two numbers
		 * @param out register to store \p a + \p b in
		 * @param a register storing first value
		 * @param b register storing second value
		 */
		void* add(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto dbg = registers[pc->out] = registers[pc->a] + registers[pc->b];
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(add);

		/**
		 * Subtracts two numbers
		 * @param out register to store \p a - \p b in
		 * @param a register storing first value
		 * @param b register storing second value
		 */
		void* subtract(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto dbg = registers[pc->out] = registers[pc->a] - registers[pc->b];
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(subtract);

		/**
		 * Multiplies two numbers
		 * @param out register to store \p a * \p b in
		 * @param a register storing first value
		 * @param b register storing second value
		 */
		void* multiply(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto dbg = registers[pc->out] = registers[pc->a] * registers[pc->b];
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(multiply);

		/**
		 * Divides two numbers
		 * @param out register to store \p a / \p b in
		 * @param a register storing first value
		 * @param b register storing second value
		 */
		void* divide(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto dbg = registers[pc->out] = registers[pc->a] / registers[pc->b];
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(divide);

		/**
		 * Finds the remainder of the division of two numbers
		 * @param out register to store \p a % \p b in
		 * @param a register storing first value
		 * @param b register storing second value
		 */
		void* modulus(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto dbg = registers[pc->out] = registers[pc->a] % registers[pc->b];
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(modulus);

		/**
		 * Shifts one number left by another
		 * @param out register to store \p a << \p b in
		 * @param a register storing first value
		 * @param b register storing second value
		 */
		void* shift_left(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto dbg = registers[pc->out] = registers[pc->a] << registers[pc->b];
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(shift_left);

		/**
		 * Shifts one number right by another
		 * @param out register to store \p a >> \p b in
		 * @param a register storing first value
		 * @param b register storing second value
		 */
		void* shift_right_logical(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto dbg = registers[pc->out] = registers[pc->a] >> registers[pc->b];
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(shift_right_logical);

		/**
		 * Shifts one number right by another, sign extending it
		 * @param out register to store \p a >> \p b in
		 * @param a register storing first value
		 * @param b register storing second value
		 */
		void* shift_right_arithmetic(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto dbg = registers[pc->out] = *(int64_t*)&registers[pc->a] >> registers[pc->b];
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(shift_right_arithmetic);

		/**
		 * Xor's two numbers
		 * @param out register to store \p a ^ \p b in
		 * @param a register storing first value
		 * @param b register storing second value
		 */
		void* bitwise_xor(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto dbg = registers[pc->out] = registers[pc->a] ^ registers[pc->b];
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(bitwise_xor);

		/**
		 * And's two numbers
		 * @param out register to store \p a & \p b in
		 * @param a register storing first value
		 * @param b register storing second value
		 */
		void* bitwise_and(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto dbg = registers[pc->out] = registers[pc->a] & registers[pc->b];
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(bitwise_and);

		/**
		 * Or's two numbers
		 * @param out register to store \p a | \p b in
		 * @param a register storing first value
		 * @param b register storing second value
		 */
		void* bitwise_or(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto dbg = registers[pc->out] = registers[pc->a] | registers[pc->b];
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION(bitwise_or);
	}}
}
