#pragma once

#include "../mizu/opcode.hpp"
#include "../mizu/exception.hpp"

#include <simd/f32.h>

namespace mizu { 
	inline namespace instructions { extern "C" {

		/**
		 * Creates a new SIMD register than can store f32s
		 * 
		 * @param out the register to imbue with SIMD
		 */
		inline static void* simd_create_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto dbg = registers[pc->out] = (size_t)simd_f32_create();
			MIZU_NEXT();
		}

		/**
		 * Releases a SIMD register
		 * 
		 * @param a the SIMD register to release
		 * @param b register storing the value to overwrite \p a with (defaults to 0)
		 */
		inline static void* simd_free_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto v = (simd_f32v)registers[pc->a];
			if(!v) MIZU_THROW("Register is not a SIMD!");
			simd_f32_free(v);
			registers[pc->a] = registers[pc->b];
			MIZU_NEXT();
		}

		/**
		 * On different hardware a SIMD registers have different sizes, this function tells us how many f32s a SIMD register can hold
		 *  
		 * @param out register to store the size in
		 */
		inline static void* simd_size_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto dbg = registers[pc->out] = simd_f32_size();
			MIZU_NEXT();
		}

		/**
		 * On different hardware a SIMD registers have different sizes, this function tells us how many bytes a SIMD register can hold
		 *  
		 * @param out register to store the byte size in
		 */
		inline static void* simd_byte_size_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto dbg = registers[pc->out] = simd_f32_size() * sizeof(float);
			MIZU_NEXT();
		}

		/**
		 * For SIMD registers to load/store optimally the pointers they are given must be aligned to this number of bytes
		 *  
		 * @param out register to store the optimal alignment in
		 */
		 inline static void* simd_optimal_alignment_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto dbg = registers[pc->out] = simd_f32_optimal_alignment();
			MIZU_NEXT();
		}

		/**
		 * Fills every slot in a SIMD register with a single f32 value
		 *  
		 * @param out SIMD register to fill
		 * @param a register storing the value to fill with
		 */
		inline static void* simd_broadcast_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto out = (simd_f32v)registers[pc->out];
			auto a = (float&)registers[pc->a];
			simd_f32_broadcast(out, a)
			MIZU_NEXT();
		}

		/**
		 * Loads values into a SIMD register off the stack
		 *  
		 * @param out SIMD register to fill
		 * @param a register storing an offset to the current stack pointer
		 */
		inline static void* simd_load_stack_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto v = (simd_f32v)registers[pc->out];
			auto p = sp + *(int64_t*)&registers[pc->a];
			assert(p > stack_boundary);
			assert(p <= ((uint8_t*)registers) + memory_size);
			simd_f32_load(v, (float*)p);
			MIZU_NEXT();
		}

		/**
		 * Loads values into a SIMD register off the stack
		 *  
		 * @param out SIMD register to fill
		 * @param immediate a signed offset to the current stack pointer
		 */
		inline static void* simd_load_stack_immediate_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto v = (simd_f32v)registers[pc->out];
			auto p = sp + *(int32_t*)&pc->a;
			assert(p > stack_boundary);
			assert(p <= ((uint8_t*)registers) + memory_size);
			simd_f32_load(v, (float*)p);
			MIZU_NEXT();
		}

		/**
		 * Loads values into a SIMD register off the stack
		 * @note Using this instruction means you guarantee the data is aligned to the optimal alignment fetched from \ref simd_optimal_alignment_f32
		 *  
		 * @param out SIMD register to fill
		 * @param a register storing an offset to the current stack pointer
		 */
		inline static void* simd_load_stack_aligned_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto v = (simd_f32v)registers[pc->out];
			auto p = sp + *(int64_t*)&registers[pc->a];
			assert(p > stack_boundary);
			assert(p <= ((uint8_t*)registers) + memory_size);
			simd_f32_load_aligned(v, (float*)p);
			MIZU_NEXT();
		}

		/**
		 * Loads values into a SIMD register off the stack
		 * @note Using this instruction means you guarantee the data is aligned to the optimal alignment fetched from \ref simd_optimal_alignment_f32
		 *  
		 * @param out SIMD register to fill
		 * @param immediate a signed offset to the current stack pointer
		 */
		inline static void* simd_load_stack_immediate_aligned_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto v = (simd_f32v)registers[pc->out];
			auto p = sp + *(int32_t*)&pc->a;
			assert(p > stack_boundary);
			assert(p <= ((uint8_t*)registers) + memory_size);
			simd_f32_load_aligned(v, (float*)p);
			MIZU_NEXT();
		}

		/**
		 * Stores values in a SIMD register onto the stack
		 *  
		 * @param a SIMD register to store from
		 * @param b register storing an offset to the current stack pointer
		 */
		inline static void* simd_store_stack_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto v = (simd_f32v)registers[pc->a];
			auto p = sp + *(int64_t*)&registers[pc->b];
			assert(p > stack_boundary);
			assert(p <= ((uint8_t*)registers) + memory_size);
			simd_f32_store(v, (float*)p);
			MIZU_NEXT();
		}

		/**
		 * Stores values in a SIMD register onto the stack
		 *  
		 * @param a SIMD register to store from
		 * @param immediate a signed offset to the current stack pointer
		 */
		inline static void* simd_store_stack_immediate_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto v = (simd_f32v)registers[pc->a];
			auto p = sp + *(int16_t*)&pc->b;
			assert(p > stack_boundary);
			assert(p <= ((uint8_t*)registers) + memory_size);
			simd_f32_store(v, (float*)p);
			MIZU_NEXT();
		}

		/**
		 * Stores values in a SIMD register onto the stack
		 * @note Using this instruction means you guarantee the data is aligned to the optimal alignment fetched from \ref simd_optimal_alignment_f32
		 *  
		 * @param a SIMD register to store from
		 * @param b register storing an offset to the current stack pointer
		 */
		inline static void* simd_store_stack_aligned(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto v = (simd_f32v)registers[pc->a];
			auto p = sp + *(int64_t*)&registers[pc->b];
			assert(p > stack_boundary);
			assert(p <= ((uint8_t*)registers) + memory_size);
			simd_f32_store_aligned(v, (float*)p);
			MIZU_NEXT();
		}

		/**
		 * Stores values in a SIMD register onto the stack
		 * @note Using this instruction means you guarantee the data is aligned to the optimal alignment fetched from \ref simd_optimal_alignment_f32
		 *  
		 * @param a SIMD register to store from
		 * @param immediate a signed offset to the current stack pointer
		 */
		inline static void* simd_store_stack_immediate_aligned_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto v = (simd_f32v)registers[pc->a];
			auto p = sp + *(int16_t*)&pc->b;
			assert(p > stack_boundary);
			assert(p <= ((uint8_t*)registers) + memory_size);
			simd_f32_store_aligned(v, (float*)p);
			MIZU_NEXT();
		}

		/**
		 * @brief Adds two SIMD registers together (out = a + b)
		 * 
		 * @param out SIMD register to store the result in
		 * @param a SIMD register storing first operand
		 * @param b SIMD register storing second operand
		 */
		inline static void* simd_add_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			simd_f32_add_inplace((simd_f32v)registers[pc->out], (simd_f32v)registers[pc->a], (simd_f32v)registers[pc->b]);
			MIZU_NEXT();
		}

		/**
		 * @brief Subtracts two SIMD registers (out = a - b)
		 * 
		 * @param out SIMD register to store the result in
		 * @param a SIMD register storing first operand
		 * @param b SIMD register storing second operand
		 */
		inline static void* simd_subtract_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			simd_f32_subtract_inplace((simd_f32v)registers[pc->out], (simd_f32v)registers[pc->a], (simd_f32v)registers[pc->b]);
			MIZU_NEXT();
		}

		/**
		 * @brief Multiplies two SIMD registers together (out = a * b)
		 * 
		 * @param out SIMD register to store the result in
		 * @param a SIMD register storing first operand
		 * @param b SIMD register storing second operand
		 */
		inline static void* simd_multiply_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			simd_f32_multiply_inplace((simd_f32v)registers[pc->out], (simd_f32v)registers[pc->a], (simd_f32v)registers[pc->b]);
			MIZU_NEXT();
		}

		/**
		 * @brief Divides two SIMD registers (out = a / b)
		 * 
		 * @param out SIMD register to store the result in
		 * @param a SIMD register storing first operand
		 * @param b SIMD register storing second operand
		 */
		inline static void* simd_divide_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			simd_f32_divide_inplace((simd_f32v)registers[pc->out], (simd_f32v)registers[pc->a], (simd_f32v)registers[pc->b]);
			MIZU_NEXT();
		}

		/**
		 * @brief Check if two SIMD registers are equal (out = a == b)
		 * 
		 * @param out SIMD mask register to store the result in
		 * @param a SIMD register storing first operand
		 * @param b SIMD register storing second operand
		 */
		inline static void* simd_equal_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			simd_f32_equal_inplace((simd_f32v_mask)registers[pc->out], (simd_f32v)registers[pc->a], (simd_f32v)registers[pc->b]);
			MIZU_NEXT();
		}

		/**
		 * @brief Check if two SIMD registers are not equal (out = a != b)
		 * 
		 * @param out SIMD mask register to store the result in
		 * @param a SIMD register storing first operand
		 * @param b SIMD register storing second operand
		 */
		inline static void* simd_not_equal_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			simd_f32_not_equal_inplace((simd_f32v_mask)registers[pc->out], (simd_f32v)registers[pc->a], (simd_f32v)registers[pc->b]);
			MIZU_NEXT();
		}

		/**
		 * @brief Check if two SIMD registers are greater or equal (out = a >= b)
		 * 
		 * @param out SIMD mask register to store the result in
		 * @param a SIMD register storing first operand
		 * @param b SIMD register storing second operand
		 */
		inline static void* simd_greater_equal_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			simd_f32_greater_equal_inplace((simd_f32v_mask)registers[pc->out], (simd_f32v)registers[pc->a], (simd_f32v)registers[pc->b]);
			MIZU_NEXT();
		}

		/**
		 * @brief Check if two SIMD registers are less or equal (out = a <= b)
		 * 
		 * @param out SIMD mask register to store the result in
		 * @param a SIMD register storing first operand
		 * @param b SIMD register storing second operand
		 */
		inline static void* simd_less_equal_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			simd_f32_less_equal_inplace((simd_f32v_mask)registers[pc->out], (simd_f32v)registers[pc->a], (simd_f32v)registers[pc->b]);
			MIZU_NEXT();
		}

		/**
		 * @brief Check if two SIMD registers are greater (out = a > b)
		 * 
		 * @param out SIMD mask register to store the result in
		 * @param a SIMD register storing first operand
		 * @param b SIMD register storing second operand
		 */
		inline static void* simd_greater_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			simd_f32_greater_inplace((simd_f32v_mask)registers[pc->out], (simd_f32v)registers[pc->a], (simd_f32v)registers[pc->b]);
			MIZU_NEXT();
		}

		/**
		 * @brief Check if two SIMD registers are less (out = a < b)
		 * 
		 * @param out SIMD mask register to store the result in
		 * @param a SIMD register storing first operand
		 * @param b SIMD register storing second operand
		 */
		inline static void* simd_less_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			simd_f32_less_inplace((simd_f32v_mask)registers[pc->out], (simd_f32v)registers[pc->a], (simd_f32v)registers[pc->b]);
			MIZU_NEXT();
		}





		inline static void* simd_mask_create_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto dbg = registers[pc->out] = (size_t)simd_f32_mask_create();
			MIZU_NEXT();
		}

		inline static void* simd_mask_free_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto m = (simd_f32v_mask)registers[pc->a];
			if(!m) MIZU_THROW("Register is not a SIMD!");
			simd_f32_mask_free(m);
			registers[pc->a] = registers[pc->b];
			MIZU_NEXT();
		}

		// out.load(sp + a)
		inline static void* simd_mask_load_stack_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto m = (simd_f32v_mask)registers[pc->out];
			auto p = sp + *(int64_t*)&registers[pc->a];
			assert(p > stack_boundary);
			assert(p <= ((uint8_t*)registers) + memory_size);
			simd_f32_mask_load(m, (bool*)p);
			MIZU_NEXT();
		}

		inline static void* simd_mask_load_stack_immediate_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto m = (simd_f32v_mask)registers[pc->out];
			auto p = sp + *(int32_t*)&pc->a;
			assert(p > stack_boundary);
			assert(p <= ((uint8_t*)registers) + memory_size);
			simd_f32_mask_load(m, (bool*)p);
			MIZU_NEXT();
		}

		inline static void* simd_mask_load_stack_aligned(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto m = (simd_f32v_mask)registers[pc->out];
			auto p = sp + *(int64_t*)&registers[pc->a];
			assert(p > stack_boundary);
			assert(p <= ((uint8_t*)registers) + memory_size);
			simd_f32_mask_load_aligned(m, (bool*)p);
			MIZU_NEXT();
		}

		inline static void* simd_mask_load_stack_immediate_aligned_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto m = (simd_f32v_mask)registers[pc->out];
			auto p = sp + *(int32_t*)&pc->a;
			assert(p > stack_boundary);
			assert(p <= ((uint8_t*)registers) + memory_size);
			simd_f32_mask_load_aligned(m, (bool*)p);
			MIZU_NEXT();
		}

		// out.load(a)
		inline static void* simd_mask_load_bitmask_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto m = (simd_f32v_mask)registers[pc->out];
			simd_f32_mask_load_bitmask(m, registers[pc->a]);
			MIZU_NEXT();
		}

		// a.store(sp + b)
		inline static void* simd_mask_store_stack_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto m = (simd_f32v_mask)registers[pc->a];
			auto p = sp + *(int64_t*)&registers[pc->b];
			assert(p > stack_boundary);
			assert(p <= ((uint8_t*)registers) + memory_size);
			simd_f32_mask_store(m, (bool*)p);
			MIZU_NEXT();
		}

		inline static void* simd_mask_store_stack_immediate_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto m = (simd_f32v_mask)registers[pc->a];
			auto p = sp + *(int16_t*)&pc->b;
			assert(p > stack_boundary);
			assert(p <= ((uint8_t*)registers) + memory_size);
			simd_f32_mask_store(m, (bool*)p);
			MIZU_NEXT();
		}

		inline static void* simd_mask_store_stack_aligned_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto m = (simd_f32v_mask)registers[pc->a];
			auto p = sp + *(int64_t*)&registers[pc->b];
			assert(p > stack_boundary);
			assert(p <= ((uint8_t*)registers) + memory_size);
			simd_f32_mask_store_aligned(m, (bool*)p);
			MIZU_NEXT();
		}

		inline static void* simd_mask_store_stack_immediate_aligned_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto m = (simd_f32v_mask)registers[pc->a];
			auto p = sp + *(int16_t*)&pc->b;
			assert(p > stack_boundary);
			assert(p <= ((uint8_t*)registers) + memory_size);
			simd_f32_mask_store_aligned(m, (bool*)p);
			MIZU_NEXT();
		}

		// a.load(out)
		inline static void* simd_mask_store_bitmask_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto m = (simd_f32v_mask)registers[pc->out];
			auto dbg = registers[pc->out] = simd_f32_mask_store_bitmask(m);
			MIZU_NEXT();
		}

		inline static void* simd_mask_set_if_all_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto m = (simd_f32v_mask)registers[pc->a];
			auto dbg = registers[pc->out] = simd_f32_mask_set_if_all(m);
			MIZU_NEXT();
		}

		inline static void* simd_mask_set_if_none_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto m = (simd_f32v_mask)registers[pc->a];
			auto dbg = registers[pc->out] = simd_f32_mask_set_if_none(m);
			MIZU_NEXT();
		}

		inline static void* simd_mask_set_if_any_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto m = (simd_f32v_mask)registers[pc->a];
			auto dbg = registers[pc->out] = simd_f32_mask_set_if_any(m);
			MIZU_NEXT();
		}

		inline static void* simd_mask_negate_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto out = (simd_f32v_mask)registers[pc->out];
			auto a = (simd_f32v_mask)registers[pc->a];
			simd_f32_mask_negate_inplace(out, a);
			MIZU_NEXT();
		}

		inline static void* simd_mask_and_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto out = (simd_f32v_mask)registers[pc->out];
			auto a = (simd_f32v_mask)registers[pc->a];
			auto b = (simd_f32v_mask)registers[pc->b];
			simd_f32_mask_and_inplace(out, a, b);
			MIZU_NEXT();
		}

		inline static void* simd_mask_or_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto out = (simd_f32v_mask)registers[pc->out];
			auto a = (simd_f32v_mask)registers[pc->a];
			auto b = (simd_f32v_mask)registers[pc->b];
			simd_f32_mask_or_inplace(out, a, b);
			MIZU_NEXT();
		}

		inline static void* simd_mask_xor_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto out = (simd_f32v_mask)registers[pc->out];
			auto a = (simd_f32v_mask)registers[pc->a];
			auto b = (simd_f32v_mask)registers[pc->b];
			simd_f32_mask_xor_inplace(out, a, b);
			MIZU_NEXT();
		}

		inline static void* simd_mask_equal_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto out = (simd_f32v_mask)registers[pc->out];
			auto a = (simd_f32v_mask)registers[pc->a];
			auto b = (simd_f32v_mask)registers[pc->b];
			simd_f32_mask_equal_inplace(out, a, b);
			MIZU_NEXT();
		}

		inline static void* simd_mask_not_equal_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto out = (simd_f32v_mask)registers[pc->out];
			auto a = (simd_f32v_mask)registers[pc->a];
			auto b = (simd_f32v_mask)registers[pc->b];
			simd_f32_mask_not_equal_inplace(out, a, b);
			MIZU_NEXT();
		}

		/**
		 * @brief Overwrites part of one SIMD register with another based on a mask
		 * 
		 * @param out SIMD register to overwrite
		 * @param a SIMD mask register storing the mask
		 * @param b SIMD register storing values to overwrite with
		 */
		inline static void* simd_assign_where_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			simd_f32_assign_where((simd_f32v)registers[pc->out], (simd_f32v_mask)registers[pc->a], (simd_f32v)registers[pc->b]);
			MIZU_NEXT();
		}
	}}

	namespace unsafe { inline namespace instructions { extern "C" {
		inline static void* simd_load_pointer_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto m = (simd_f32v)registers[pc->out];
			simd_f32_load(m, (float*)registers[pc->a]);
			MIZU_NEXT();
		}

		inline static void* simd_load_pointer_aligned_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto m = (simd_f32v)registers[pc->out];
			simd_f32_load_aligned(m, (float*)registers[pc->a]);
			MIZU_NEXT();
		}

		inline static void* simd_store_pointer_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto m = (simd_f32v)registers[pc->a];
			simd_f32_store(m, (float*)registers[pc->out]);
			MIZU_NEXT();
		}

		inline static void* simd_store_pointer_aligned_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto m = (simd_f32v)registers[pc->a];
			simd_f32_store_aligned(m, (float*)registers[pc->out]);
			MIZU_NEXT();
		}

		inline static void* simd_mask_load_pointer_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto m = (simd_f32v_mask)registers[pc->out];
			simd_f32_mask_load(m, (bool*)registers[pc->a]);
			MIZU_NEXT();
		}

		inline static void* simd_mask_load_pointer_aligned_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto m = (simd_f32v_mask)registers[pc->out];
			simd_f32_mask_load_aligned(m, (bool*)registers[pc->a]);
			MIZU_NEXT();
		}

		inline static void* simd_mask_store_pointer_f32(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto m = (simd_f32v_mask)registers[pc->a];
			simd_f32_mask_store(m, (bool*)registers[pc->out]);
			MIZU_NEXT();
		}

		inline static void* simd_mask_store_pointer_aligned(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
			auto m = (simd_f32v_mask)registers[pc->a];
			simd_f32_mask_store_aligned(m, (bool*)registers[pc->out]);
			MIZU_NEXT();
		}
	}}}
}