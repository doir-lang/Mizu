#pragma once
#ifdef MIZU_IMPLEMENTATION
#define FP_IMPLEMENTATION
#endif
#include <fp/pointer.hpp>
#include <fp/dynarray.hpp>

#ifndef MIZU_REGISTER_INSTRUCTION
#define MIZU_REGISTER_INSTRUCTION(name)
#endif
#ifndef MIZU_REGISTER_INSTRUCTION_PROTOTYPE
#define MIZU_REGISTER_INSTRUCTION_PROTOTYPE(name)
#endif

#ifdef _WIN32
	#define MIZU_EXPORT __declspec(dllexport)
#elif __EMSCRIPTEN__
	#include <emscripten.h>
	#define MIZU_EXPORT EMSCRIPTEN_KEEPALIVE
#else
	#define MIZU_EXPORT __attribute__((__visibility__("default")))
#endif
#define MIZU_EXPORT_C extern "C" MIZU_EXPORT

#if defined(__clang__) || defined(MIZU_FORCE_ENABLE_TAIL_CALL)
	#define MIZU_TAIL_CALL __attribute__((musttail))
#else
	#define MIZU_TAIL_CALL
#endif

#ifdef _WIN32
	#define MIZU_MAIN(...) MIZU_EXPORT_C int dll_main(const int argc, const char** argv __VA_ARGS__)
#else
	#define MIZU_MAIN(...) int main(const int argc, const char** argv __VA_ARGS__)
#endif

#ifdef MIZU_ENABLE_TRACING
	#include <iostream>
	#define MIZU_TRACE(pc) (std::cout << __FUNCTION__ << "(" << pc->out << ", " << pc->a << ", " << pc->b << ")" << std::endl)
#else
	#define MIZU_TRACE(pc)
#endif



namespace mizu {
	using reg_t = uint16_t;
	/**
	 * - x0 (zero) is always zero
	 * - x1-x20 (t0-t19) are temporary registers which are expected to be saved by the caller if necessary
	 * - x21 (ra) is the return address (callee saved)
	 * - x22-x256 (a0-a234) are the argument registers (callee saved)
	 * @note x22/a0 and x23/a1 are the canonical return registers
	 */
	inline namespace registers {
		/**
		 * Generic register lookup
		 *
		 * @param i The register's index
		 * @return constexpr reg_t associated value to store in an opcode
		 */
		constexpr reg_t x(std::size_t i) { return i; }
		/**
		 * Temporary register lookup
		 *
		 * @param i The temporary register's index
		 * @return constexpr reg_t associated value to store in an opcode
		 */
		constexpr reg_t t(std::size_t i) { return i + 1; assert(i <= 20); }
		/**
		 * Argument register lookup
		 *
		 * @param i The argument register's index
		 * @return constexpr reg_t associated value to store in an opcode
		 */
		constexpr reg_t a(std::size_t i) { return i + 22; }

		constexpr static reg_t zero = x(0);
		constexpr static reg_t return_address = x(21), ra = return_address;
	}

	/**
	 * Function pointer type representing the interface every instruction is expected to have
	 */
	using instruction_t = void*(*)(struct opcode* pc, uint64_t* registers, struct registers_and_stack* env, uint8_t* sp);

	/**
	 * Type which holds an instruction and (upto) 3 registers for it to act upon.
	 * @note Since instruction_t is a pointer, this struct will have different sizes on different machines.
	 * 	Thus Mizu binaries are only compatible with machines of the same pointer size and endianness.
	 */
	struct opcode {
		/**
		 * Instruction to perform
		 */
		instruction_t op;
		/**
		 * Register to store the instructions result in
		 */
		reg_t out;
		/**
		 * Register storing the first argument
		 */
		reg_t a;
		/**
		 * Register storing the second argument
		 */
		reg_t b;

		/**
		 * Replaces a and b with a u32 immediate value
		 *
		 * @return opcode& this
		 */
		opcode& set_immediate(const uint32_t value) { (uint32_t&)a = value; return *this; }
		/**
		 * Replaces a and b with a i32 immediate value
		 *
		 * @return opcode& this
		 */
		opcode& set_immediate_signed(const int32_t value) { (int32_t&)a = value; return *this; }
		/**
		 * Replaces b with a i16 immediate value (Used to determine branch offsets)
		 *
		 * @return opcode& this
		 */
		opcode& set_branch_immediate(const int16_t value) { (int16_t&)b = value; return *this; }

		/**
		 * Replaces a and b with a f32 immediate value
		 *
		 * @return opcode& this
		 */
		opcode& set_immediate_f32(const float value) { (float&)a = value; return *this; }
		/**
		 * Replaces a and b with the lower half of an f64 immediate value
		 *
		 * @param value the full f64 value
		 * @return opcode& this
		 */
		opcode& set_lower_immediate_f64(const double value) { return set_immediate((uint64_t&)value); }
		/**
		 * Replaces a and b with the upper half of an f64 immediate value
		 *
		 * @param value the full f64 value
		 * @return opcode& this
		 */
		opcode& set_upper_immediate_f64(const double value) { return set_immediate(((uint64_t&)value) >> 32); }

		/**
		 * Replaces a and b with the lower half of a host pointer immediate value
		 *
		 * @param ptr the full host pointer
		 * @return opcode& this
		 */
		opcode& set_host_pointer_lower_immediate(const void* ptr) { set_immediate((std::size_t)ptr); return *this; }
		/**
		 * Replaces a and b with the upper half of a host pointer immediate value
		 *
		 * @param ptr the full host pointer
		 * @return opcode& this
		 */
		opcode& set_host_pointer_upper_immediate(const void* ptr) { set_immediate(((std::size_t)ptr) >> 32); return *this; }
	};

	/**
	 * How many registers long the memory space is.
	 * @note set using the MIZU_STACK_SIZE (measured in kilobytes) config option.
	 */
	constexpr static size_t memory_size = 1024 * MIZU_STACK_SIZE / sizeof(uint64_t); // 8kB by default
	/**
	 * How many bytes the memory space is.
	 * @note set using the MIZU_STACK_SIZE (measured in kilobytes) config option.
	 */
	constexpr static size_t memory_size_bytes = memory_size * sizeof(uint64_t);

	/**
	 * Type representing holding the registers and stack space for a Mizu program or thread.
	 */
	struct registers_and_stack {
		/**
		 * Memory used to store the stack and registers
		 * @note 8kB in size by default, MIZU_STACK_SIZE is a tweakble cmake property
		 */
		fp::array<uint64_t, memory_size> memory;
		/**
		 * Pointer to the boundary between the stack and the registers
		 */
		uint8_t* stack_boundary;
		/**
		 * Pointer to the start (bottom/last byte of) the stack
		 * @note In Mizu the stack pointer counts down from the last byte of the memory until it hits the stack boundary
		 */
		uint8_t* stack_bottom;

		/**
		 * Pointer to the start of the program
		 */
		const opcode* program_start = nullptr;
		/**
		 * Pointer to the end of the program
		 */
		const opcode* program_end = nullptr;

		/**
		 * Calculates where the program starts (or a estimate based on the current program counter if null)
		 *
		 * @param pc program counter to reference for fallback
		 * @return const opcode* (estimated) program start
		 */
		const opcode* calculate_program_start(const opcode* pc) {
			return program_start ? program_start : pc - MIZU_MAXIMUM_LABEL_SEARCH;
		}
		/**
		 * Calculates where the program ends (or a estimate based on the current program counter if null)
		 *
		 * @param pc program counter to reference for fallback
		 * @return const opcode* (estimated) program end
		 */
		const opcode* calculate_program_end(const opcode* pc) {
			return program_end ? program_end : pc - MIZU_MAXIMUM_LABEL_SEARCH;
		}
	};

/** \addtogroup setup_environment
 *  @{
 */
	/**
	 * Configures a new Mizu environment
	 * @note sets register x0 to zero
	 *
	 * @param env the environment to configure
	 * @param program_start pointer to the start of the program (defaults to null)
	 * @param program_end pointer to the end of the program (defaults to null)
	 */
	inline void setup_environment(registers_and_stack& env, const opcode* program_start = nullptr, const opcode* program_end = nullptr) {
		env.memory[0] = 0;
		env.stack_boundary = (uint8_t*)(env.memory.data() + 256);
		env.stack_bottom = (uint8_t*)(env.memory.data() + env.memory.size());
		env.program_start = program_start;
		env.program_end = program_end;
	}

	/**
	 * Configures a new Mizu environment
	 * @note sets register x0 to zero
	 *
	 * @param env the environment to configure
	 * @param program view representing the whole program
	 */
	inline void setup_environment(registers_and_stack& env, fp::view<const opcode> program) {
		setup_environment(env, program.data(), program.data() + program.size());
	}

	/**
	 * Copies the provided \p binary data into the bottom of an environment's stack.
	 *
	 * @param env The enviornment to copy data into
	 * @param binary The binary data to fill the bottom of its stack with
	 */
	inline void fill_stack_bottom(registers_and_stack& env, fp::view<const std::byte> binary) {
		assert(binary.size() <= memory_size_bytes);
		auto env_end = (std::byte*)(env.memory.data() + env.memory.size());
		memcpy(env_end - binary.size(), binary.data(), binary.size());
	}
/** @}*/

#ifndef MIZU_NO_HARDWARE_THREADS
	/**
	* Executes the next instruction
	* @note assumes all of the variables defined in the signature of instruction_t are available
	*/
	#define MIZU_NEXT()  MIZU_TRACE(pc); registers[0] = 0; ++pc; MIZU_TAIL_CALL return pc->op(pc, registers, env, sp)

	/**
	* Starts executing the provide program in the provided environment
	* @param program The program to execute
	* @param env The environment to execute \p program in
	*/
	#define MIZU_START_FROM_ENVIRONMENT(program, env) const_cast<mizu::opcode*>(program)->op(const_cast<mizu::opcode*>(program), env.memory.data(), &env, env.stack_bottom)
#else // MIZU_NO_HARDWARE_THREADS
	struct coroutine {
		struct execution_context {
			opcode* program_counter; // Set to null to indicate that a section is done
			uint8_t* stack_pointer;
			registers_and_stack* environment;

			inline bool done() {
				return !program_counter; // Done when program counter is null
			}
		};

		static fp_dynarray(execution_context) contexts;
		static size_t current_context /* = 0 */;

		inline static size_t next_context() {
			return current_context = (current_context + 1) % fpda_size(contexts);
		}

		inline static execution_context& get_context(size_t index) {
			assert(index >= 0);
			assert(index < fpda_size(contexts));
			return contexts[index];
		}

		inline static execution_context& get_current_context() {
			return get_context(current_context);
		}

		inline static void* next(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) { // NOTE: Next has the same signature as instructions for tail recursion purposes!
			assert(sp);
			get_current_context().stack_pointer = sp;

			if(fpda_size(contexts) == 1) {
				get_current_context().program_counter = ++pc;
				MIZU_TAIL_CALL return pc->op(pc, env, sp);
			} else get_current_context().program_counter = pc; // Make sure pc updates (jumps) are recorded

			auto& context = get_context(next_context());
			if(!context.program_counter) return next(pc, registers, env, context.stack_pointer); // If this context is done... recursively run the next one
			pc = ++context.program_counter;
			MIZU_TAIL_CALL return pc->op(pc, context.environment->memory, context.environment, context.stack_pointer);
		}

		static void start(opcode* program_counter, registers_and_stack* environment) {
			assert(program_counter && environment);
			execution_context ctx{program_counter - 1, enviornment.memory, environment->stack_bottom, environment};
			fpda_push_back(contexts, ctx);
		}

		static void clear() {
			if(contexts) fpda_free_and_null(contexts);
			current_context = 0;
		}

		static bool done() { // TODO: There has to be a better way to write this!
			fp_iterate_named(contexts, context)
				if(!context->done()) // We are done if all program counters are nullptr
					return false;
			return true;
		}
	};

	#define MIZU_NEXT() MIZU_TRACE(pc); registers[0] = 0; MIZU_TAIL_CALL return mizu::coroutine::next(pc, registers, env, sp)

	#define MIZU_START_FROM_ENVIRONMENT(program, env) [](mizu::opcode* program_counter, registers_and_stack* environment) -> void* {\
		mizu::coroutine::start(program_counter, environment);\
		void* result;\
		while(!(result = mizu::coroutine::next(\
			mizu::coroutine::get_current_context().program_counter, mizu::coroutine::get_current_context().environment.memory,\
			mizu::coroutine::get_current_context().environment, mizu::coroutine::get_current_context().stack_pointer)\
		) && !mizu::coroutine::done());\
		mizu::coroutine::clear();\
		return result;\
	}(const_cast<mizu::opcode*>(program), &env)

#ifdef MIZU_IMPLEMENTATION
	fp_dynarray(coroutine::execution_context) coroutine::contexts = nullptr;
	size_t coroutine::current_context = 0;
#endif
#endif // MIZU_NO_HARDWARE_THREADS
}
