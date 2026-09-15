/**
* Mizu's core instruction set: labels and jumps, the register/stack moves,
* the comparisons and the integer arithmetic.
*
* Every instruction has the `mizu.opcode.Instruction` signature and ends by
* mixing in `mizuNext`, which tail-calls whatever instruction the program
* counter now points at.
*/
module mizu.instructions.core;

import core.stdc.stdio : printf, fflush, stdout;

import mizu.opcode;

@nogc nothrow:

/**
* Converts a string label into an immediate value.
*
* Only the first 4 characters of the label are significant.
*
* Params:
*   label = the label to convert
* Returns: the immediate to store in an `Opcode`
*/
uint label2immediate(scope const(char)[] label) {
	uint result = 0;
	foreach (i; 0 .. label.length > uint.sizeof ? uint.sizeof : label.length)
		result |= cast(uint) cast(ubyte) label[i] << (i * 8);
	return result;
}

///
unittest {
	static assert(label2immediate("fib") == label2immediate("fib"));
	static assert(label2immediate("fib") != label2immediate("bub"));
	// Only the first four characters matter.
	static assert(label2immediate("threadA") == label2immediate("threadB"));
}

/// The `null` instruction, which marks the end of a program.
enum Instruction programEnd = null;

extern(C):

/**
* Noop marking a label that `findLabel` can find and `jumpTo` can jump to.
*
* Params:
*   immediate = integer label value, usually from `label2immediate`
*/
void* label(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	mixin(mizuNext);
}

/**
* Finds the given label and stores a pointer to it in `out_`.
*
* Params:
*   out_ = register to store the label pointer in
*   immediate = the label to search for
*
* Note:
*   Unlike every other assembly, this is a runtime function: time is spent
*   scanning the program to find the label. Cluster these instructions near
*   the beginning of a program, where they will not be executed repeatedly.
*
* Note:
*   Searches forward from this instruction first, then backward, so the
*   closest following label wins any ambiguity.
*/
void* findLabel(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	auto programStart = env.calculateProgramStart(pc);
	auto programEnd_ = env.calculateProgramEnd(pc);
	immutable needle = pc.immediate;
	registers[pc.out_] = 0;

	// Try to find it searching to the end.
	for (auto cur = pc; cur !is programEnd_; ++cur)
		if (cur.op is &label && cur.immediate == needle) {
			registers[pc.out_] = cast(ulong) cur;
			break;
		}
	// Failing that, search back to the beginning.
	if (registers[pc.out_] == 0)
		for (auto cur = pc; cur !is programStart; --cur)
			if (cur.op is &label && cur.immediate == needle) {
				registers[pc.out_] = cast(ulong) cur;
				break;
			}
	mixin(mizuNext);
}

/// Ends execution of the program or thread.
void* halt(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	import mizu.config : noHardwareThreads;
	static if (noHardwareThreads)
		Coroutine.getCurrentContext().programCounter = null; // Mark the context done.
	return null;
}

/**
* Prints the value in a register in several formats.
*
* Params:
*   a = the register to print the value of
*/
void* debugPrint(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	auto value = &registers[pc.a];
	registers[pc.out_] = printf("u64 = %lu, i64 = %ld, f64 = %f, f32 = %f\n",
		*value, *cast(long*) value, *cast(double*) value, cast(double)*cast(float*) value);
	fflush(stdout); // Make sure the buffer is flushed!
	mixin(mizuNext);
}

/**
* Prints the value in a register in several formats, including binary.
*
* Params:
*   a = the register to print the value of
*/
void* debugPrintBinary(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	auto bytes = cast(const(ubyte)*)&registers[pc.a];

	printf("binary = ");
	for (byte i = ulong.sizeof - 1; i >= 0; --i)
		for (byte j = 7; j >= 0; --j)
			printf("%u", (bytes[i] >> j) & 1);
	printf(", ");

	return debugPrint(pc, registers, env, sp);
}

/**
* Stores an immediate value into a register.
*
* Params:
*   out_ = the register to update
*   immediate = the value to store in `out_`
*
* Note:
*   Immediates are only 32 bits, so this sets the bottom 32 bits of the
*   64 bit register (clearing the top).
*/
void* loadImmediate(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = pc.immediate;
	mixin(mizuNext);
}

/**
* Stores an immediate value into the upper 32 bits of a register.
*
* Params:
*   out_ = the register to update
*   immediate = the value to store in the top half of `out_`
*
* Warning:
*   `loadImmediate` overwrites the whole register, so it must be called
*   $(I before) `loadUpperImmediate`.
*/
void* loadUpperImmediate(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] |= cast(ulong) pc.immediate << 32;
	mixin(mizuNext);
}

/**
* Converts a register to a 64 bit integer.
*
* Params:
*   out_ = register to store the result in
*   a = register whose value to convert
*/
void* convertToU64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = registers[pc.a];
	mixin(mizuNext);
}

/**
* Converts a register to a 32 bit integer.
*
* Params:
*   out_ = register to store the result in
*   a = register whose value to convert
*/
void* convertToU32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	*cast(uint*)&registers[pc.out_] = cast(uint) registers[pc.a];
	mixin(mizuNext);
}

/**
* Converts a register to a 16 bit integer.
*
* Params:
*   out_ = register to store the result in
*   a = register whose value to convert
*/
void* convertToU16(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	*cast(ushort*)&registers[pc.out_] = cast(ushort) registers[pc.a];
	mixin(mizuNext);
}

/**
* Converts a register to an 8 bit integer.
*
* Params:
*   out_ = register to store the result in
*   a = register whose value to convert
*/
void* convertToU8(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	*cast(ubyte*)&registers[pc.out_] = cast(ubyte) registers[pc.a];
	mixin(mizuNext);
}

/**
* Loads a 64 bit integer from the stack.
*
* Params:
*   out_ = register to store the result in
*   a = register holding a byte offset from the current stack pointer
*/
void* stackLoadU64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	ubyte* offset = sp + registers[pc.a];
	assert(offset > env.stackBoundary);
	assert(offset <= env.stackBottom);
	registers[pc.out_] = *cast(ulong*) offset;
	mixin(mizuNext);
}

/**
* Copies a 64 bit integer from a register onto the stack.
*
* Params:
*   out_ = register to store another copy in
*   a = register holding the value to copy
*   b = register holding a byte offset from the current stack pointer
*/
void* stackStoreU64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	ubyte* offset = sp + registers[pc.b];
	assert(offset > env.stackBoundary);
	assert(offset <= env.stackBottom);
	registers[pc.out_] = *cast(ulong*) offset = registers[pc.a];
	mixin(mizuNext);
}

/**
* Loads a 32 bit integer from the stack.
*
* Params:
*   out_ = register to store the result in
*   a = register holding a byte offset from the current stack pointer
*/
void* stackLoadU32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	ubyte* offset = sp + registers[pc.a];
	assert(offset > env.stackBoundary);
	assert(offset <= env.stackBottom);
	registers[pc.out_] = *cast(uint*) offset;
	mixin(mizuNext);
}

/**
* Copies a 32 bit integer from a register onto the stack.
*
* Params:
*   out_ = register to store another copy in
*   a = register holding the value to copy
*   b = register holding a byte offset from the current stack pointer
*/
void* stackStoreU32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	ubyte* offset = sp + registers[pc.b];
	assert(offset > env.stackBoundary);
	assert(offset <= env.stackBottom);
	registers[pc.out_] = *cast(uint*) offset = cast(uint) registers[pc.a];
	mixin(mizuNext);
}

/**
* Loads a 16 bit integer from the stack.
*
* Params:
*   out_ = register to store the result in
*   a = register holding a byte offset from the current stack pointer
*/
void* stackLoadU16(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	ubyte* offset = sp + registers[pc.a];
	assert(offset > env.stackBoundary);
	assert(offset <= env.stackBottom);
	registers[pc.out_] = *cast(ushort*) offset;
	mixin(mizuNext);
}

/**
* Copies a 16 bit integer from a register onto the stack.
*
* Params:
*   out_ = register to store another copy in
*   a = register holding the value to copy
*   b = register holding a byte offset from the current stack pointer
*/
void* stackStoreU16(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	ubyte* offset = sp + registers[pc.b];
	assert(offset > env.stackBoundary);
	assert(offset <= env.stackBottom);
	registers[pc.out_] = *cast(ushort*) offset = cast(ushort) registers[pc.a];
	mixin(mizuNext);
}

/**
* Loads an 8 bit integer from the stack.
*
* Params:
*   out_ = register to store the result in
*   a = register holding a byte offset from the current stack pointer
*/
void* stackLoadU8(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	ubyte* offset = sp + registers[pc.a];
	assert(offset > env.stackBoundary);
	assert(offset <= env.stackBottom);
	registers[pc.out_] = *offset;
	mixin(mizuNext);
}

/**
* Copies an 8 bit integer from a register onto the stack.
*
* Params:
*   out_ = register to store another copy in
*   a = register holding the value to copy
*   b = register holding a byte offset from the current stack pointer
*/
void* stackStoreU8(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	ubyte* offset = sp + registers[pc.b];
	assert(offset > env.stackBoundary);
	assert(offset <= env.stackBottom);
	registers[pc.out_] = *offset = cast(ubyte) registers[pc.a];
	mixin(mizuNext);
}

/**
* Subtracts a value from the stack pointer, reserving memory on the stack.
*
* Params:
*   a = register holding how many bytes to reserve
*/
void* stackPush(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	sp -= registers[pc.a];
	assert(sp > env.stackBoundary);
	assert(sp <= env.stackBottom);
	mixin(mizuNext);
}

/**
* Subtracts a value from the stack pointer, reserving memory on the stack.
*
* Params:
*   immediate = how many bytes to reserve
*/
void* stackPushImmediate(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	sp -= pc.immediate;
	assert(sp > env.stackBoundary);
	assert(sp <= env.stackBottom);
	mixin(mizuNext);
}

/**
* Adds a value to the stack pointer, releasing memory reserved on the stack.
*
* Params:
*   a = register holding how many bytes to release
*/
void* stackPop(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	sp += registers[pc.a];
	assert(sp > env.stackBoundary);
	assert(sp <= env.stackBottom);
	mixin(mizuNext);
}

/**
* Adds a value to the stack pointer, releasing memory reserved on the stack.
*
* Params:
*   immediate = how many bytes to release
*/
void* stackPopImmediate(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	sp += pc.immediate;
	assert(sp > env.stackBoundary);
	assert(sp <= env.stackBottom);
	mixin(mizuNext);
}

/**
* Calculates the offset needed to load from or store to the bottom of the stack.
*
* Params:
*   out_ = register to store the calculated offset in
*   a = register holding a signed offset relative to the bottom of the stack
*/
void* offsetOfStackBottom(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	immutable offset = *cast(long*)&registers[pc.a];
	auto bottom = env.stackBottom - offset;
	assert(bottom > env.stackBoundary);
	assert(bottom <= env.stackBottom);
	registers[pc.out_] = bottom - sp;
	mixin(mizuNext);
}

/**
* Moves the program counter by an offset. Zero re-executes this instruction,
* one continues as usual, and a negative offset jumps backward.
*
* Params:
*   out_ = register to store the address of the instruction that would have run next
*   a = register holding how many instructions to jump (signed)
*/
void* jumpRelative(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	immutable offset = *cast(long*)&registers[pc.a];
	registers[pc.out_] = cast(ulong)(pc + 1);
	pc += offset - 1;
	mixin(mizuNext);
}

/**
* Moves the program counter by an offset. Zero re-executes this instruction,
* one continues as usual, and a negative offset jumps backward.
*
* Params:
*   out_ = register to store the address of the instruction that would have run next
*   immediate = how many instructions to jump (signed)
*/
void* jumpRelativeImmediate(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = cast(ulong)(pc + 1);
	pc += pc.immediateSigned - 1;
	mixin(mizuNext);
}

/**
* Sets the program counter to a value, usually the output of another jump.
*
* Params:
*   out_ = register to store the address of the instruction that would have run next
*   a = register holding the address of the instruction to jump to
*/
void* jumpTo(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = cast(ulong)(pc + 1);
	pc = cast(Opcode*) registers[pc.a] - 1;
	mixin(mizuNext);
}

/**
* Moves the program counter by an offset, but only if the condition register
* is non-zero.
*
* Params:
*   out_ = register to store the address of the instruction that would have run next
*   a = register holding the condition; zero means no jump
*   b = register holding how many instructions to jump (signed)
*/
void* branchRelative(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = cast(ulong)(pc + 1);
	if (registers[pc.a])
		pc += *cast(long*)&registers[pc.b] - 1;
	mixin(mizuNext);
}

/**
* Moves the program counter by an offset, but only if the condition register
* is non-zero.
*
* Params:
*   out_ = register to store the address of the instruction that would have run next
*   a = register holding the condition; zero means no jump
*   b = branch immediate holding how many instructions to jump (signed)
*/
void* branchRelativeImmediate(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = cast(ulong)(pc + 1);
	if (registers[pc.a])
		pc += pc.branchImmediate - 1;
	mixin(mizuNext);
}

/**
* Sets the program counter to a value, but only if the condition register is
* non-zero.
*
* Params:
*   out_ = register to store the address of the instruction that would have run next
*   a = register holding the condition; zero means no jump
*   b = register holding the address of the instruction to jump to
*/
void* branchTo(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = cast(ulong)(pc + 1);
	if (registers[pc.a])
		pc = cast(Opcode*) registers[pc.b] - 1;
	mixin(mizuNext);
}

/**
* Checks if two registers are equal.
*
* Params:
*   out_ = register set to one if `a == b`, zero otherwise
*   a = register holding the first value to compare
*   b = register holding the second value to compare
*/
void* setIfEqual(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = registers[pc.a] == registers[pc.b];
	mixin(mizuNext);
}

/**
* Checks if two registers are not equal.
*
* Params:
*   out_ = register set to one if `a != b`, zero otherwise
*   a = register holding the first value to compare
*   b = register holding the second value to compare
*/
void* setIfNotEqual(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = registers[pc.a] != registers[pc.b];
	mixin(mizuNext);
}

/**
* Checks if one register is less than another.
*
* Params:
*   out_ = register set to one if `a < b`, zero otherwise
*   a = register holding the first value to compare
*   b = register holding the second value to compare
*/
void* setIfLess(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = registers[pc.a] < registers[pc.b];
	mixin(mizuNext);
}

/**
* Checks if one register is less than another, treating both as signed.
*
* Params:
*   out_ = register set to one if `a < b`, zero otherwise
*   a = register holding the first value to compare
*   b = register holding the second value to compare
*/
void* setIfLessSigned(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = *cast(long*)&registers[pc.a] < *cast(long*)&registers[pc.b];
	mixin(mizuNext);
}

/**
* Checks if one register is greater than or equal to another.
*
* Params:
*   out_ = register set to one if `a >= b`, zero otherwise
*   a = register holding the first value to compare
*   b = register holding the second value to compare
*/
void* setIfGreaterEqual(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = registers[pc.a] >= registers[pc.b];
	mixin(mizuNext);
}

/**
* Checks if one register is greater than or equal to another, treating both
* as signed.
*
* Params:
*   out_ = register set to one if `a >= b`, zero otherwise
*   a = register holding the first value to compare
*   b = register holding the second value to compare
*/
void* setIfGreaterEqualSigned(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = *cast(long*)&registers[pc.a] >= *cast(long*)&registers[pc.b];
	mixin(mizuNext);
}

/**
* Adds two numbers.
*
* Params:
*   out_ = register to store `a + b` in
*   a = register holding the first value
*   b = register holding the second value
*/
void* add(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = registers[pc.a] + registers[pc.b];
	mixin(mizuNext);
}

/**
* Subtracts two numbers.
*
* Params:
*   out_ = register to store `a - b` in
*   a = register holding the first value
*   b = register holding the second value
*/
void* subtract(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = registers[pc.a] - registers[pc.b];
	mixin(mizuNext);
}

/**
* Multiplies two numbers.
*
* Params:
*   out_ = register to store `a * b` in
*   a = register holding the first value
*   b = register holding the second value
*/
void* multiply(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = registers[pc.a] * registers[pc.b];
	mixin(mizuNext);
}

/**
* Divides two numbers.
*
* Params:
*   out_ = register to store `a / b` in
*   a = register holding the first value
*   b = register holding the second value
*/
void* divide(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = registers[pc.a] / registers[pc.b];
	mixin(mizuNext);
}

/**
* Finds the remainder of the division of two numbers.
*
* Params:
*   out_ = register to store `a % b` in
*   a = register holding the first value
*   b = register holding the second value
*/
void* modulus(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = registers[pc.a] % registers[pc.b];
	mixin(mizuNext);
}

/**
* Shifts one number left by another.
*
* Params:
*   out_ = register to store `a << b` in
*   a = register holding the value to shift
*   b = register holding the shift amount
*/
void* shiftLeft(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = registers[pc.a] << registers[pc.b];
	mixin(mizuNext);
}

/**
* Shifts one number right by another.
*
* Params:
*   out_ = register to store `a >> b` in
*   a = register holding the value to shift
*   b = register holding the shift amount
*/
void* shiftRightLogical(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = registers[pc.a] >> registers[pc.b];
	mixin(mizuNext);
}

/**
* Shifts one number right by another, sign extending it.
*
* Params:
*   out_ = register to store `a >> b` in
*   a = register holding the value to shift
*   b = register holding the shift amount
*/
void* shiftRightArithmetic(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = *cast(long*)&registers[pc.a] >> registers[pc.b];
	mixin(mizuNext);
}

/**
* Exclusive-ors two numbers.
*
* Params:
*   out_ = register to store `a ^ b` in
*   a = register holding the first value
*   b = register holding the second value
*/
void* bitwiseXor(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = registers[pc.a] ^ registers[pc.b];
	mixin(mizuNext);
}

/**
* Ands two numbers.
*
* Params:
*   out_ = register to store `a & b` in
*   a = register holding the first value
*   b = register holding the second value
*/
void* bitwiseAnd(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = registers[pc.a] & registers[pc.b];
	mixin(mizuNext);
}

/**
* Ors two numbers.
*
* Params:
*   out_ = register to store `a | b` in
*   a = register holding the first value
*   b = register holding the second value
*/
void* bitwiseOr(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = registers[pc.a] | registers[pc.b];
	mixin(mizuNext);
}
