/**
* Mizu's core instruction set: labels and jumps, the register/stack moves, the comparisons and the integer arithmetic.
*
* Every instruction has the `mizu.opcode.Instruction` signature and ends by mixing in `mizuNext`, which tail-calls whatever instruction the program counter now points at.
*/
module mizu.instructions.core;

import core.stdc.stdio : printf, fflush, stdout;

static import mizu.config;
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
*
* Examples:
* ---
* static assert(label2immediate("fib") != label2immediate("bub"));
* static assert(label2immediate("threadA") == label2immediate("threadB"));
* ---
*/
uint label2immediate(scope const(char)[] label) {
	uint result = 0;
	foreach (i; 0 .. label.length > uint.sizeof ? uint.sizeof : label.length)
		result |= cast(uint) cast(ubyte) label[i] << (i * 8);
	return result;
}

/// The `null` instruction, which marks the end of a program.
enum Instruction programEnd = null;

// Whether `size` bytes at `address` lie wholly in the stack proper: from `stackBoundary`, where the registers end, up to `stackBottom`.
private bool onStack(const RegistersAndStack* env, const(ubyte)* address, size_t size) {
	return address >= env.stackBoundary && address <= env.stackBottom && size <= env.stackBottom - address;
}

// The address `offset` bytes up the stack from `sp`, asserted to hold `size` bytes of stack.
private ubyte* stackAddress(const RegistersAndStack* env, ubyte* sp, ulong offset, size_t size) {
	ubyte* address = sp + offset;
	assert(onStack(env, address, size), "mizu: stack access out of bounds");
	return address;
}

extern(C):

/**
* Noop marking a label that `findLabel` can find and `jumpTo` can jump to.
*
* Params:
*   immediate = the label's value, usually from `label2immediate`
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&findLabel, Registers.t(0)).setImmediate(label2immediate("here")),
* 	Opcode(&label).setImmediate(label2immediate("here")),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(0)] == cast(ulong) &program[1]);
* ---
*/
void* label(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	mixin(mizuNext);
}

/**
* Finds the given label and stores a pointer to it in `out_`, or zero if there is none.
*
* Params:
*   out_ = register to store the label's address in
*   immediate = the label to search for
*
* Note: unlike every other assembly, this is a runtime function: time is spent scanning the program to find the label. Cluster these instructions near the beginning of a program, where they will not be executed repeatedly.
*
* Note: searches forward from this instruction first, then backward, so the closest following label wins any ambiguity. Without known program bounds it scans `mizu.config.maximumLabelSearch` instructions each way.
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&label).setImmediate(label2immediate("top")),
* 	Opcode(&findLabel, Registers.t(0)).setImmediate(label2immediate("top")),
* 	Opcode(&findLabel, Registers.t(1)).setImmediate(label2immediate("none")),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(0)] == cast(ulong) &program[0]);
* assert(env.memory[Registers.t(1)] == 0);
* ---
*/
void* findLabel(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	auto programStart = calculateProgramStart(*env, pc);
	auto programEnd_ = calculateProgramEnd(*env, pc);
	immutable needle = immediate(*pc);
	registers[pc.out_] = 0;

	for (auto cur = pc; cur !is programEnd_; ++cur)
		if (cur.op is &label && immediate(*cur) == needle) {
			registers[pc.out_] = cast(ulong) cur;
			break;
		}
	// Tested after the body so `programStart` itself is examined; a label opening the program would otherwise be unfindable.
	if (registers[pc.out_] == 0)
		for (auto cur = pc;; --cur) {
			if (cur.op is &label && immediate(*cur) == needle) {
				registers[pc.out_] = cast(ulong) cur;
				break;
			}
			if (cur is programStart) break;
		}
	mixin(mizuNext);
}

/**
* Ends execution of the program or thread, returning null; with `MizuNoHardwareThreads` it also marks the running coroutine context finished.
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(1),
* 	Opcode(&halt),
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(2),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* assert(startFromEnvironment(program[], env) is null);
* assert(env.memory[Registers.t(0)] == 1);
* ---
*/
void* halt(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	static if (mizu.config.noHardwareThreads)
		Coroutine.getCurrentContext().programCounter = null;
	return null;
}

/**
* Prints the value in a register as `u64`, `i64`, `f64` and `f32` to stdout, flushing it.
*
* Params:
*   out_ = register to store how many characters were printed in (negative on failure)
*   a = register holding the value to print
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(42),
* 	Opcode(&debugPrint, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] > 0);
* ---
*/
void* debugPrint(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	auto value = &registers[pc.a];
	registers[pc.out_] = printf("u64 = %lu, i64 = %ld, f64 = %f, f32 = %f\n", *value, *cast(long*) value, *cast(double*) value, cast(double)*cast(float*) value);
	cast(void) fflush(stdout);
	mixin(mizuNext);
}

/**
* Prints the value in a register in binary, then as `debugPrint` does.
*
* Params:
*   out_ = register to store how many characters the `debugPrint` part printed in (negative on failure)
*   a = register holding the value to print
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(5),
* 	Opcode(&debugPrintBinary, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] > 0);
* ---
*/
void* debugPrintBinary(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	auto bytes = cast(const(ubyte)*)&registers[pc.a];

	cast(void) printf("binary = ");
	for (byte i = ulong.sizeof - 1; i >= 0; --i)
		for (byte j = 7; j >= 0; --j)
			cast(void) printf("%u", (bytes[i] >> j) & 1);
	cast(void) printf(", ");

	return debugPrint(pc, registers, env, sp);
}

/**
* Stores an immediate value into a register.
*
* Params:
*   out_ = register to store the immediate in
*   immediate = the value to store
*
* Note: immediates are only 32 bits, so this sets the bottom 32 bits of the 64 bit register, clearing the top.
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(42),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(0)] == 42);
* ---
*/
void* loadImmediate(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = immediate(*pc);
	mixin(mizuNext);
}

/**
* Ors an immediate value into the upper 32 bits of a register.
*
* Params:
*   out_ = register to update
*   immediate = the value to place in the top half of `out_`
*
* Warning: `loadImmediate` overwrites the whole register, so it must run $(I before) `loadUpperImmediate`.
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(2),
* 	Opcode(&loadUpperImmediate, Registers.t(0)).setImmediate(1),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(0)] == 0x1_0000_0002);
* ---
*/
void* loadUpperImmediate(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] |= cast(ulong) immediate(*pc) << 32;
	mixin(mizuNext);
}

/**
* Copies a whole 64 bit register.
*
* Params:
*   out_ = register to store the copy in
*   a = register holding the value to copy
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&convertToU64, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = ulong.max;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == ulong.max);
* ---
*/
void* convertToU64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = registers[pc.a];
	mixin(mizuNext);
}

/**
* Truncates a register to a 32 bit integer.
*
* Params:
*   out_ = register whose low 32 bits are overwritten with the result, keeping its upper bits
*   a = register holding the value to truncate
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&convertToU32, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 0x1_2345_6789;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 0x2345_6789);
* ---
*/
void* convertToU32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	*cast(uint*)&registers[pc.out_] = cast(uint) registers[pc.a];
	mixin(mizuNext);
}

/**
* Truncates a register to a 16 bit integer.
*
* Params:
*   out_ = register whose low 16 bits are overwritten with the result, keeping its upper bits
*   a = register holding the value to truncate
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&convertToU16, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 0x1_2345;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 0x2345);
* ---
*/
void* convertToU16(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	*cast(ushort*)&registers[pc.out_] = cast(ushort) registers[pc.a];
	mixin(mizuNext);
}

/**
* Truncates a register to an 8 bit integer.
*
* Params:
*   out_ = register whose low 8 bits are overwritten with the result, keeping its upper bits
*   a = register holding the value to truncate
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&convertToU8, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 0x1234;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 0x34);
* ---
*/
void* convertToU8(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	*cast(ubyte*)&registers[pc.out_] = cast(ubyte) registers[pc.a];
	mixin(mizuNext);
}

/**
* Loads a 64 bit integer from the stack.
*
* Params:
*   out_ = register to store the value in
*   a = register holding a byte offset from the current stack pointer
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&stackPushImmediate).setImmediate(8),
* 	Opcode(&stackLoadU64, Registers.t(0), Registers.zero),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* *cast(ulong*)(env.stackBottom - 8) = 42;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(0)] == 42);
* ---
*/
void* stackLoadU64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = *cast(ulong*) stackAddress(env, sp, registers[pc.a], ulong.sizeof);
	mixin(mizuNext);
}

/**
* Copies a 64 bit integer from a register onto the stack.
*
* Params:
*   out_ = register to store another copy of the value in
*   a = register holding the value to copy
*   b = register holding a byte offset from the current stack pointer
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(42),
* 	Opcode(&stackPushImmediate).setImmediate(8),
* 	Opcode(&stackStoreU64, 0, Registers.t(0), Registers.zero),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(*cast(ulong*)(env.stackBottom - 8) == 42);
* ---
*/
void* stackStoreU64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = *cast(ulong*) stackAddress(env, sp, registers[pc.b], ulong.sizeof) = registers[pc.a];
	mixin(mizuNext);
}

/**
* Loads a 32 bit integer from the stack.
*
* Params:
*   out_ = register to store the value in
*   a = register holding a byte offset from the current stack pointer
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&stackPushImmediate).setImmediate(4),
* 	Opcode(&stackLoadU32, Registers.t(0), Registers.zero),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* *cast(uint*)(env.stackBottom - 4) = 42;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(0)] == 42);
* ---
*/
void* stackLoadU32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = *cast(uint*) stackAddress(env, sp, registers[pc.a], uint.sizeof);
	mixin(mizuNext);
}

/**
* Copies a 32 bit integer from a register onto the stack.
*
* Params:
*   out_ = register to store another copy of the truncated value in
*   a = register holding the value to copy
*   b = register holding a byte offset from the current stack pointer
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(42),
* 	Opcode(&stackPushImmediate).setImmediate(4),
* 	Opcode(&stackStoreU32, 0, Registers.t(0), Registers.zero),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(*cast(uint*)(env.stackBottom - 4) == 42);
* ---
*/
void* stackStoreU32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = *cast(uint*) stackAddress(env, sp, registers[pc.b], uint.sizeof) = cast(uint) registers[pc.a];
	mixin(mizuNext);
}

/**
* Loads a 16 bit integer from the stack.
*
* Params:
*   out_ = register to store the value in
*   a = register holding a byte offset from the current stack pointer
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&stackPushImmediate).setImmediate(2),
* 	Opcode(&stackLoadU16, Registers.t(0), Registers.zero),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* *cast(ushort*)(env.stackBottom - 2) = 42;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(0)] == 42);
* ---
*/
void* stackLoadU16(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = *cast(ushort*) stackAddress(env, sp, registers[pc.a], ushort.sizeof);
	mixin(mizuNext);
}

/**
* Copies a 16 bit integer from a register onto the stack.
*
* Params:
*   out_ = register to store another copy of the truncated value in
*   a = register holding the value to copy
*   b = register holding a byte offset from the current stack pointer
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(42),
* 	Opcode(&stackPushImmediate).setImmediate(2),
* 	Opcode(&stackStoreU16, 0, Registers.t(0), Registers.zero),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(*cast(ushort*)(env.stackBottom - 2) == 42);
* ---
*/
void* stackStoreU16(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = *cast(ushort*) stackAddress(env, sp, registers[pc.b], ushort.sizeof) = cast(ushort) registers[pc.a];
	mixin(mizuNext);
}

/**
* Loads an 8 bit integer from the stack.
*
* Params:
*   out_ = register to store the value in
*   a = register holding a byte offset from the current stack pointer
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&stackPushImmediate).setImmediate(1),
* 	Opcode(&stackLoadU8, Registers.t(0), Registers.zero),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.stackBottom[-1] = 42;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(0)] == 42);
* ---
*/
void* stackLoadU8(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = *stackAddress(env, sp, registers[pc.a], ubyte.sizeof);
	mixin(mizuNext);
}

/**
* Copies an 8 bit integer from a register onto the stack.
*
* Params:
*   out_ = register to store another copy of the truncated value in
*   a = register holding the value to copy
*   b = register holding a byte offset from the current stack pointer
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(42),
* 	Opcode(&stackPushImmediate).setImmediate(1),
* 	Opcode(&stackStoreU8, 0, Registers.t(0), Registers.zero),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.stackBottom[-1] == 42);
* ---
*/
void* stackStoreU8(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = *stackAddress(env, sp, registers[pc.b], ubyte.sizeof) = cast(ubyte) registers[pc.a];
	mixin(mizuNext);
}

/**
* Subtracts a value from the stack pointer, reserving memory on the stack.
*
* Params:
*   a = register holding how many bytes to reserve
*
* Examples:
* ---
* static immutable Opcode[5] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(8),
* 	Opcode(&stackPush, 0, Registers.t(0)),
* 	Opcode(&loadImmediate, Registers.t(1)).setImmediate(42),
* 	Opcode(&stackStoreU64, 0, Registers.t(1), Registers.zero),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(*cast(ulong*)(env.stackBottom - 8) == 42);
* ---
*/
void* stackPush(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	sp -= registers[pc.a];
	assert(onStack(env, sp, 0), "mizu: stack overflow");
	mixin(mizuNext);
}

/**
* Subtracts a value from the stack pointer, reserving memory on the stack.
*
* Params:
*   immediate = how many bytes to reserve
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&stackPushImmediate).setImmediate(8),
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(42),
* 	Opcode(&stackStoreU64, 0, Registers.t(0), Registers.zero),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(*cast(ulong*)(env.stackBottom - 8) == 42);
* ---
*/
void* stackPushImmediate(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	sp -= immediate(*pc);
	assert(onStack(env, sp, 0), "mizu: stack overflow");
	mixin(mizuNext);
}

/**
* Adds a value to the stack pointer, releasing memory reserved on the stack.
*
* Params:
*   a = register holding how many bytes to release
*
* Examples:
* ---
* static immutable Opcode[6] program = [
* 	Opcode(&stackPushImmediate).setImmediate(16),
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(8),
* 	Opcode(&stackPop, 0, Registers.t(0)),
* 	Opcode(&loadImmediate, Registers.t(1)).setImmediate(42),
* 	Opcode(&stackStoreU64, 0, Registers.t(1), Registers.zero),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(*cast(ulong*)(env.stackBottom - 8) == 42);
* ---
*/
void* stackPop(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	sp += registers[pc.a];
	assert(onStack(env, sp, 0), "mizu: stack underflow");
	mixin(mizuNext);
}

/**
* Adds a value to the stack pointer, releasing memory reserved on the stack.
*
* Params:
*   immediate = how many bytes to release
*
* Examples:
* ---
* static immutable Opcode[5] program = [
* 	Opcode(&stackPushImmediate).setImmediate(16),
* 	Opcode(&stackPopImmediate).setImmediate(8),
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(42),
* 	Opcode(&stackStoreU64, 0, Registers.t(0), Registers.zero),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(*cast(ulong*)(env.stackBottom - 8) == 42);
* ---
*/
void* stackPopImmediate(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	sp += immediate(*pc);
	assert(onStack(env, sp, 0), "mizu: stack underflow");
	mixin(mizuNext);
}

/**
* Calculates the offset from the current stack pointer of a position measured up from the bottom of the stack, for the stack loads and stores.
*
* Params:
*   out_ = register to store the offset in
*   a = register holding how many bytes above the bottom of the stack the position is (signed)
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&stackPushImmediate).setImmediate(16),
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(8),
* 	Opcode(&offsetOfStackBottom, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 8);
* ---
*/
void* offsetOfStackBottom(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	immutable offset = *cast(long*)&registers[pc.a];
	auto bottom = env.stackBottom - offset;
	assert(onStack(env, bottom, 0), "mizu: offset is not on the stack");
	registers[pc.out_] = bottom - sp;
	mixin(mizuNext);
}

/**
* Moves the program counter by an offset. Zero re-executes this instruction, one continues as usual, and a negative offset jumps backward.
*
* Params:
*   out_ = register to store the address of the instruction that would have run next in
*   a = register holding how many instructions to jump (signed)
*
* Examples:
* ---
* static immutable Opcode[5] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(2),
* 	Opcode(&jumpRelative, Registers.t(2), Registers.t(0)),
* 	Opcode(&loadImmediate, Registers.t(1)).setImmediate(1),
* 	Opcode(&halt),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 0);
* assert(env.memory[Registers.t(2)] == cast(ulong) &program[2]);
* ---
*/
void* jumpRelative(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	immutable offset = *cast(long*)&registers[pc.a];
	registers[pc.out_] = cast(ulong)(pc + 1);
	pc += offset - 1;
	mixin(mizuNext);
}

/**
* Moves the program counter by an offset. Zero re-executes this instruction, one continues as usual, and a negative offset jumps backward.
*
* Params:
*   out_ = register to store the address of the instruction that would have run next in
*   immediate = how many instructions to jump, set with `setImmediateSigned`
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&jumpRelativeImmediate).setImmediateSigned(2),
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(1),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(0)] == 0);
* ---
*/
void* jumpRelativeImmediate(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = cast(ulong)(pc + 1);
	pc += immediateSigned(*pc) - 1;
	mixin(mizuNext);
}

/**
* Sets the program counter to a value, usually the output of another jump or a `findLabel`.
*
* Params:
*   out_ = register to store the address of the instruction that would have run next in
*   a = register holding the address of the instruction to jump to
*
* Examples:
* ---
* static immutable Opcode[5] program = [
* 	Opcode(&findLabel, Registers.t(0)).setImmediate(label2immediate("end")),
* 	Opcode(&jumpTo, 0, Registers.t(0)),
* 	Opcode(&loadImmediate, Registers.t(1)).setImmediate(1),
* 	Opcode(&label).setImmediate(label2immediate("end")),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 0);
* ---
*/
void* jumpTo(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	auto target = cast(Opcode*) registers[pc.a];
	registers[pc.out_] = cast(ulong)(pc + 1);
	pc = target - 1;
	mixin(mizuNext);
}

/**
* Moves the program counter by an offset, but only if the condition register is non-zero.
*
* Params:
*   out_ = register to store the address of the instruction that would have run next in
*   a = register holding the condition; zero means no jump
*   b = register holding how many instructions to jump (signed)
*
* Examples:
* ---
* static immutable Opcode[6] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(1),
* 	Opcode(&loadImmediate, Registers.t(1)).setImmediate(2),
* 	Opcode(&branchRelative, 0, Registers.t(0), Registers.t(1)),
* 	Opcode(&loadImmediate, Registers.t(2)).setImmediate(1),
* 	Opcode(&halt),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 0);
* ---
*/
void* branchRelative(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	immutable condition = registers[pc.a];
	immutable offset = *cast(long*)&registers[pc.b];
	registers[pc.out_] = cast(ulong)(pc + 1);
	if (condition)
		pc += offset - 1;
	mixin(mizuNext);
}

/**
* Moves the program counter by an offset, but only if the condition register is non-zero.
*
* Params:
*   out_ = register to store the address of the instruction that would have run next in
*   a = register holding the condition; zero means no jump
*   b = how many instructions to jump, a signed offset set with `setBranchImmediate`
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&branchRelativeImmediate, 0, Registers.zero).setBranchImmediate(2),
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(1),
* 	Opcode(&halt),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(0)] == 1);
* ---
*/
void* branchRelativeImmediate(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	immutable condition = registers[pc.a];
	registers[pc.out_] = cast(ulong)(pc + 1);
	if (condition)
		pc += branchImmediate(*pc) - 1;
	mixin(mizuNext);
}

/**
* Sets the program counter to a value, but only if the condition register is non-zero.
*
* Params:
*   out_ = register to store the address of the instruction that would have run next in
*   a = register holding the condition; zero means no jump
*   b = register holding the address of the instruction to jump to
*
* Examples:
* ---
* static immutable Opcode[6] program = [
* 	Opcode(&findLabel, Registers.t(0)).setImmediate(label2immediate("end")),
* 	Opcode(&loadImmediate, Registers.t(1)).setImmediate(1),
* 	Opcode(&branchTo, 0, Registers.t(1), Registers.t(0)),
* 	Opcode(&loadImmediate, Registers.t(2)).setImmediate(1),
* 	Opcode(&label).setImmediate(label2immediate("end")),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 0);
* ---
*/
void* branchTo(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	immutable condition = registers[pc.a];
	auto target = cast(Opcode*) registers[pc.b];
	registers[pc.out_] = cast(ulong)(pc + 1);
	if (condition)
		pc = target - 1;
	mixin(mizuNext);
}

/**
* Checks if two registers are equal.
*
* Params:
*   out_ = register set to one if `a == b`, zero otherwise
*   a = register holding the first value to compare
*   b = register holding the second value to compare
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&setIfEqual, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&setIfEqual, Registers.t(3), Registers.t(0), Registers.zero),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 5;
* env.memory[Registers.t(1)] = 5;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 1);
* assert(env.memory[Registers.t(3)] == 0);
* ---
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
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&setIfNotEqual, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&setIfNotEqual, Registers.t(3), Registers.t(0), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 5;
* env.memory[Registers.t(1)] = 6;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 1);
* assert(env.memory[Registers.t(3)] == 0);
* ---
*/
void* setIfNotEqual(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = registers[pc.a] != registers[pc.b];
	mixin(mizuNext);
}

/**
* Checks if one register is less than another, treating both as unsigned.
*
* Params:
*   out_ = register set to one if `a < b`, zero otherwise
*   a = register holding the first value to compare
*   b = register holding the second value to compare
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&setIfLess, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&setIfLess, Registers.t(3), Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 1;
* env.memory[Registers.t(1)] = -1;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 1);
* assert(env.memory[Registers.t(3)] == 0);
* ---
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
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&setIfLessSigned, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = -1;
* env.memory[Registers.t(1)] = 1;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 1);
* ---
*/
void* setIfLessSigned(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = *cast(long*)&registers[pc.a] < *cast(long*)&registers[pc.b];
	mixin(mizuNext);
}

/**
* Checks if one register is greater than or equal to another, treating both as unsigned.
*
* Params:
*   out_ = register set to one if `a >= b`, zero otherwise
*   a = register holding the first value to compare
*   b = register holding the second value to compare
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&setIfGreaterEqual, Registers.t(2), Registers.t(0), Registers.t(0)),
* 	Opcode(&setIfGreaterEqual, Registers.t(3), Registers.zero, Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 5;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 1);
* assert(env.memory[Registers.t(3)] == 0);
* ---
*/
void* setIfGreaterEqual(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = registers[pc.a] >= registers[pc.b];
	mixin(mizuNext);
}

/**
* Checks if one register is greater than or equal to another, treating both as signed.
*
* Params:
*   out_ = register set to one if `a >= b`, zero otherwise
*   a = register holding the first value to compare
*   b = register holding the second value to compare
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&setIfGreaterEqualSigned, Registers.t(2), Registers.zero, Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = -1;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 1);
* ---
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
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(40),
* 	Opcode(&loadImmediate, Registers.t(1)).setImmediate(2),
* 	Opcode(&add, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 42);
* ---
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
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&subtract, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 44;
* env.memory[Registers.t(1)] = 2;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 42);
* ---
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
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&multiply, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 6;
* env.memory[Registers.t(1)] = 7;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 42);
* ---
*/
void* multiply(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = registers[pc.a] * registers[pc.b];
	mixin(mizuNext);
}

/**
* Divides two numbers, treating both as unsigned; `b` must not be zero.
*
* Params:
*   out_ = register to store `a / b` in
*   a = register holding the dividend
*   b = register holding the divisor
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&divide, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 85;
* env.memory[Registers.t(1)] = 2;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 42);
* ---
*/
void* divide(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = registers[pc.a] / registers[pc.b];
	mixin(mizuNext);
}

/**
* Finds the remainder of the division of two numbers, treating both as unsigned; `b` must not be zero.
*
* Params:
*   out_ = register to store `a % b` in
*   a = register holding the dividend
*   b = register holding the divisor
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&modulus, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 142;
* env.memory[Registers.t(1)] = 100;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 42);
* ---
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
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&shiftLeft, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 21;
* env.memory[Registers.t(1)] = 1;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 42);
* ---
*/
void* shiftLeft(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = registers[pc.a] << registers[pc.b];
	mixin(mizuNext);
}

/**
* Shifts one number right by another, filling with zeros.
*
* Params:
*   out_ = register to store `a >>> b` in
*   a = register holding the value to shift
*   b = register holding the shift amount
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&shiftRightLogical, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = ulong.max;
* env.memory[Registers.t(1)] = 63;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 1);
* ---
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
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&shiftRightArithmetic, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = -84;
* env.memory[Registers.t(1)] = 1;
* cast(void) startFromEnvironment(program[], env);
* assert(cast(long) env.memory[Registers.t(2)] == -42);
* ---
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
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&bitwiseXor, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 0b1100;
* env.memory[Registers.t(1)] = 0b1010;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 0b0110);
* ---
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
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&bitwiseAnd, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 0b1100;
* env.memory[Registers.t(1)] = 0b1010;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 0b1000);
* ---
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
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&bitwiseOr, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 0b1100;
* env.memory[Registers.t(1)] = 0b1010;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 0b1110);
* ---
*/
void* bitwiseOr(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = registers[pc.a] | registers[pc.b];
	mixin(mizuNext);
}

unittest {
	static assert(label2immediate("fib") == label2immediate("fib"));
	static assert(label2immediate("fib") != label2immediate("bub"));
	// Only the first four characters matter.
	static assert(label2immediate("threadA") == label2immediate("threadB"));
}

unittest {
	// The stack runs from `stackBoundary` inclusive to `stackBottom` exclusive, so an access must end at or before the bottom.
	RegistersAndStack env;
	setupEnvironment(env);
	assert(onStack(&env, env.stackBoundary, ulong.sizeof));
	assert(onStack(&env, env.stackBottom - ulong.sizeof, ulong.sizeof));
	assert(onStack(&env, env.stackBottom, 0));
	assert(!onStack(&env, env.stackBottom, 1));
	assert(!onStack(&env, env.stackBottom - 4, ulong.sizeof));
	assert(!onStack(&env, env.stackBoundary - 1, 1));
}

unittest {
	// Jumps and branches read their operands before writing `out_`, so `out_` may name an operand register, as `zero` often is for both.
	static immutable Opcode[9] program = [
		Opcode(&branchRelativeImmediate, Registers.zero, Registers.zero).setBranchImmediate(2),
		Opcode(&loadImmediate, Registers.t(0)).setImmediate(1),
		Opcode(&branchTo, Registers.zero, Registers.zero, Registers.zero),
		Opcode(&loadImmediate, Registers.t(1)).setImmediate(1),
		Opcode(&findLabel, Registers.t(2)).setImmediate(label2immediate("end")),
		Opcode(&jumpTo, Registers.t(2), Registers.t(2)),
		Opcode(&halt),
		Opcode(&label).setImmediate(label2immediate("end")),
		Opcode(&halt),
	];

	RegistersAndStack env;
	setupEnvironment(env, program[]);
	assert(startFromEnvironment(program[], env) is null);
	assert(env.memory[Registers.t(0)] == 1);
	assert(env.memory[Registers.t(1)] == 1);
	assert(env.memory[Registers.t(2)] == cast(ulong) &program[6]);
}
