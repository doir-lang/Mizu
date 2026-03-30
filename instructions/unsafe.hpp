#pragma once

#include "../mizu/opcode.hpp"
#include <fp/pointer.h>

namespace mizu {
	namespace unsafe { inline namespace instructions { extern "C" {

		/**
		 * Allocates new memory on the host application heap.
		 *
		 * @param out Register in which a pointer to the allocated memory will be stored
		 * @param a Register storing how many bytes to allocate
		 */
		void* allocate(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			size_t n = registers[pc->a];
			registers[pc->out] = (size_t)malloc(n);
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION_PROTOTYPE(allocate);

		/**
		 * Frees an allocation alloacted with \ref allocate.
		 *
		 * @param a Register storing the allocation to free
		 * @param b Register storing a value to overwrite \p a with (defaults to zero)
		 */
		void* free_allocated(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			void* p = (void*)registers[pc->a];
			free(p);
			registers[pc->a] = registers[pc->b];
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION_PROTOTYPE(free_allocated);


		/**
		 * Allocates new memory on the host application heap. This memory knows how many element are stored in it.
		 *
		 * @param out Register in which a pointer to the allocated memory will be stored
		 * @param a Register storing the size of each element
		 * @param b Register storing how many elements there are
		 * @note The total size of this allocation is a * b
		 */
		void* allocate_fat_pointer(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			size_t size = registers[pc->a];
			size_t n = registers[pc->b];
			auto dbg = registers[pc->out] = (size_t)__fp_realloc(nullptr, size, n);
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION_PROTOTYPE(allocate_fat_pointer);

		/**
		 * Frees an allocation alloacted with \ref allocate_fat_pointer.
		 *
		 * @param a Register storing the allocation to free
		 * @param b Register storing a value to overwrite \p a with (defaults to zero)
		 */
		void* free_fat_pointer(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			void* p = (void*)registers[pc->a];
			fp_free(p);
			registers[pc->a] = registers[pc->b];
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION_PROTOTYPE(free_fat_pointer);

		/**
		 * Generates a pointer to memory on Mizu's stack.
		 *
		 * @param out Register to store the pointer in
		 * @param a Register storing a (signed) offset from the current stack pointer.
		 */
		void* pointer_to_stack(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto offset = (int64_t&)registers[pc->a];
			auto dbg = registers[pc->out] = (size_t)(sp + offset);
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION_PROTOTYPE(pointer_to_stack);

		/**
		 * Generates a pointer to memory on the bottom of Mizu's stack.
		 *
		 * @param out Register to store the pointer in
		 * @param a Register storing a (signed) offset from the current stack pointer.
		 */
		void* pointer_to_stack_bottom(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto offset = (int64_t&)registers[pc->a];
			auto dbg = registers[pc->out] = (size_t)(env->stack_bottom - offset);
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION_PROTOTYPE(pointer_to_stack_bottom);

		/**
		 * Generates a pointer to one of Mizu's registers
		 *
		 * @param a Register to take a pointer to.
		 * @param out Register to store the pointer in
		 */
		void* pointer_to_register(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			auto dbg = registers[pc->out] = (size_t)(registers + pc->a);
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION_PROTOTYPE(pointer_to_register);

		/**
		 * Copies memory from one pointer to another
		 *
		 * @param out Register storing a pointer that data should be copied to
		 * @param a Register storing a pointer that data should be copied from
		 * @param b Register storing how many bytes should be copied.
		 */
		void* copy_memory(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			size_t n = registers[pc->b];
			auto src = (void*)registers[pc->a];
			auto dest = (void*)registers[pc->out];
			std::memcpy(dest, src, n);
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION_PROTOTYPE(copy_memory);

		/**
		 * Copies memory from one pointer to another
		 *
		 * @param out Register storing a pointer that data should be copied to
		 * @param a Register storing a pointer that data should be copied from
		 * @param b (branch immediate) number of bytes that should be copied
		 */
		void* copy_memory_immediate(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			size_t n = pc->b;
			auto src = (void*)registers[pc->a];
			auto dest = (void*)registers[pc->out];
			std::memcpy(dest, src, n);
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION_PROTOTYPE(copy_memory_immediate);

		/**
		 * Sets all of the given memory to the provided byte
		 *
		 * @param out Register storing a pointer to what should be overwritten
		 * @param a Register storing a u8 to overwrite \p out with
		 * @param b Register storing how many bytes should be overwritten
		 */
		void* set_memory(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			size_t n = registers[pc->b];
			auto dest = (void*)registers[pc->out];
			std::memset(dest, registers[pc->a], n);
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION_PROTOTYPE(set_memory);

		/**
		 * Sets all of the given memory to the provided byte
		 *
		 * @param out Register storing a pointer to what should be overwritten
		 * @param a Register storing a u8 to overwrite \p out with
		 * @param b (branch immediate) how many bytes should be overwritten
		 */
		void* set_memory_immediate(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp)
#ifdef MIZU_IMPLEMENTATION
		{
			size_t n = pc->b;
			auto dest = (void*)registers[pc->out];
			std::memset(dest, registers[pc->a], n);
			MIZU_NEXT();
		}
#else
		;
#endif
		MIZU_REGISTER_INSTRUCTION_PROTOTYPE(set_memory_immediate);
	}}}

	// Register all the unsafe functions with the lookup system
	MIZU_REGISTER_INSTRUCTION(unsafe::allocate);
	MIZU_REGISTER_INSTRUCTION(unsafe::free_allocated);
	MIZU_REGISTER_INSTRUCTION(unsafe::allocate_fat_pointer);
	MIZU_REGISTER_INSTRUCTION(unsafe::free_fat_pointer);
	MIZU_REGISTER_INSTRUCTION(unsafe::pointer_to_stack);
	MIZU_REGISTER_INSTRUCTION(unsafe::pointer_to_stack_bottom);
	MIZU_REGISTER_INSTRUCTION(unsafe::pointer_to_register);
	MIZU_REGISTER_INSTRUCTION(unsafe::copy_memory);
	MIZU_REGISTER_INSTRUCTION(unsafe::copy_memory_immediate);
	MIZU_REGISTER_INSTRUCTION(unsafe::set_memory);
	MIZU_REGISTER_INSTRUCTION(unsafe::set_memory_immediate);
}
