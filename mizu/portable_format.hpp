#pragma once

#include <format>

#include "serialize.hpp"
#include <fp/string.hpp>

namespace mizu { inline namespace portable {
	/**
	* Converts a Mizu \p program and some \p data into a portable program that can executed anywhere
	* @note This function makes no account of different machine endianness or pointer sizes.
	*
	* @param program The program to serialize
	* @param data The data to put at the bottom of the program's stack
	* @return fp::dynarray<std::byte> a dynamically allocated array of bytes representing the serialized program
	*/
	inline fp::dynarray<std::byte> to_portable(fp::view<const opcode> program, fp::view<std::byte> data = {nullptr, 0}) {
		assert(data.size() <= memory_size_bytes);

		auto out = to_binary(program);
		if(data.size() == 0) return out;

		// Make sure there is a null opcode at the end
		auto& last = program[program.size() - 1];
		if(last.op != nullptr || last.out != 0 || last.a != 0 || last.b != 0) {
			auto marker = opcode{nullptr, 0, 0, 0};
			auto end = out.size();
			out.grow(sizeof(opcode));
			memcpy(out.data() + end, &marker, sizeof(opcode));
		}

		// Paste in the data
		auto end = out.size();
		out.grow(data.size());
		memcpy(out.data() + end, data.data(), data.size());
		return out;
	}

	/**
	* Converts a Mizu \p program and an \p env into a snapshot of a portable program that can executed anywhere
	* @note This function makes no account of different machine endianness or pointer sizes.
	*
	* @param program The program to snapshot
	* @param env The program enviornment to snapshot
	* @return fp::dynarray<std::byte> a dynamically allocated array of bytes representing the serialized program
	*/
	inline fp::dynarray<std::byte> to_portable(fp::view<const opcode> program, registers_and_stack& env) {
		return to_portable(program, {(std::byte*)env.memory.data(), env.memory.size() * sizeof(env.memory[0])});
	}

	/**
	* Converts a blob of \p binary data storing a portable Mizu program and stack data back into a Mizu program.
	* @note This function makes no account of different machine endianness or pointer sizes.
	*
	* @param binary The binary blob to deserialize
	* @return std::pair<fp::dynarray<opcode>, registers_and_stack> a dynamically allocated Mizu program and its enviornment
	*/
	inline std::pair<fp::dynarray<opcode>, registers_and_stack> from_portable(fp::view<const std::byte> binary) {
		fp::view<opcode> raw_program{(opcode*)binary.data(), 0};

		// While there are opcodes left in the data...
		while(binary.size() > sizeof(opcode)) {
			// Decode an opcode
			auto op = (opcode*)binary.data();
			// Push valid opcodes into the program
			++raw_program.raw().size;
			binary = binary.subview(sizeof(opcode));

			// If the opcode marks the end then we are finished
			if(op->op == nullptr && op->out == 0 && op->a == 0 && op->b == 0)
				break;
		}

		// Deserialize the opcodes
		auto program = from_binary(raw_program.byte_view());

		// Create the enviornment
		registers_and_stack env = {};
		if(binary.empty()) return {program, env};

		fill_stack_bottom(env, binary);
		return {program, env};
	}

	/**
	 * @brief Generates a C++ header file representing the provided Mizu \p program and \p env
	 *
	 * @param program The program to generate a header for.
	 * @param env The enviornment the program should begin executing in.
	 * @param extra_includes If the program requires extra instruction headers (like SIMD or custom) they should be listed (one per line, including the #include) here
	 * @return fp::string a string storing the resulting headerfile.
	 */
	inline fp::string generate_header_file(fp::view<opcode> program, registers_and_stack& env, fp::string_view extra_includes = fp::string_view::from_cstr("")) {
		fp::builder::string out{nullptr};
		out << "#define MIZU_IMPLEMENTATION\n"
			<< "#include <mizu/instructions.hpp>\n"
			<< extra_includes
			<< "\n"
			<< "const static mizu::opcode program[] = {\n";

		for(auto& op: program) {
			auto name = lookup(op.op);
			assert(name.has_value());
			out << "\tmizu::opcode{mizu::" << *name << ", " << op.out << ", " << op.a << ", " << op.b << "},\n";
		}

		out << "};\n"
			<< "\n"
			<< "int main() {\n"
			<< "\tmizu::registers_and_stack environment = { .memory = { {},\n";

		size_t i = 0;
		for(i = 0; i < memory_size; ) {
			out << "\t\t";
			for(size_t j = 0; j < 20 && i < memory_size; ++j, ++i)
				out << "0x" << std::format("{:X}", env.memory[i]) << ", ";
			out << "\n";
		}

		out << "\t}};\n"
			<< "\tsetup_environment(environment);\n"
			<< "\n"
			<< "\tMIZU_START_FROM_ENVIRONMENT(program, environment);\n"
			<< "}\n";

		return fp::string{out.release()};
	}
}}
