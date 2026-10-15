/**
* Instructions that reach outside Mizu's sandbox: host heap allocation, raw pointers into the VM's own memory, and unchecked `memcpy`/`memset`.
*
* Nothing here is validated. A Mizu program that gets one of these wrong can corrupt the host process.
*/
module mizu.instructions.unsafe;

import core.stdc.stdio : fflush, fputs, stdout;
import core.stdc.stdlib : malloc, free;
import core.stdc.string : memcpy, memset;

static import core.checkedint;

static import fp.pointer;

import mizu.opcode;

@nogc nothrow:

// `bytes` as an allocation size, or `size_t.max`, which no allocator grants, when a 32 bit host could not address that many.
private size_t hostSize(ulong bytes) {
	return bytes > size_t.max ? size_t.max : cast(size_t) bytes;
}

extern(C):

/**
* Allocates memory on the host application heap with C `malloc`.
*
* Params:
*   out_ = register to store a pointer to the allocation in, or zero if it failed
*   a = register holding how many bytes to allocate
*
* Examples:
* ---
* static immutable Opcode[7] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(8),
* 	Opcode(&allocate, Registers.t(1), Registers.t(0)),
* 	Opcode(&loadImmediate, Registers.t(2)).setImmediate(42),
* 	Opcode(&pointerStoreU64, 0, Registers.t(2), Registers.t(1)),
* 	Opcode(&pointerLoadU64, Registers.t(3), Registers.t(1)),
* 	Opcode(&freeAllocated, 0, Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(3)] == 42);
* assert(env.memory[Registers.t(1)] == 0);
* ---
*/
void* allocate(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = cast(size_t) malloc(hostSize(registers[pc.a]));
	mixin(mizuNext);
}

/**
* Frees an allocation made by `allocate`.
*
* Params:
*   a = register holding the allocation to free, then overwritten with `b`
*   b = register holding the value to overwrite `a` with, usually `zero`
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(8),
* 	Opcode(&allocate, Registers.t(1), Registers.t(0)),
* 	Opcode(&freeAllocated, 0, Registers.t(1), Registers.zero),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 0);
* ---
*/
void* freeAllocated(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	free(cast(void*) registers[pc.a]);
	registers[pc.a] = registers[pc.b];
	mixin(mizuNext);
}

/**
* Allocates memory on the host application heap as a libfp fat pointer, so the allocation remembers how large it is.
*
* Params:
*   out_ = register to store a pointer to the allocation in, or zero if it failed or would be empty
*   a = register holding the size of each element
*   b = register holding how many elements there are
*
* Note: the length the fat pointer records is the total size `a * b` in $(I bytes), not the element count the C++ original recorded; they agree when the element size is one.
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(4),
* 	Opcode(&loadImmediate, Registers.t(1)).setImmediate(2),
* 	Opcode(&allocateFatPointer, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(fp.pointer.length(cast(ubyte*) env.memory[Registers.t(2)]) == 8);
* fp.pointer.free(cast(ubyte*) env.memory[Registers.t(2)]);
* ---
*/
void* allocateFatPointer(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	bool overflow;
	immutable bytes = core.checkedint.mulu(registers[pc.a], registers[pc.b], overflow);
	registers[pc.out_] = overflow ? 0 : cast(size_t) fp.pointer.malloc!ubyte(hostSize(bytes));
	mixin(mizuNext);
}

/**
* Frees an allocation made by `allocateFatPointer`.
*
* Params:
*   a = register holding the allocation to free, then overwritten with `b`
*   b = register holding the value to overwrite `a` with, usually `zero`
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(8),
* 	Opcode(&allocateFatPointer, Registers.t(1), Registers.t(0), Registers.t(0)),
* 	Opcode(&freeFatPointer, 0, Registers.t(1), Registers.zero),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 0);
* ---
*/
void* freeFatPointer(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	fp.pointer.free(cast(const(ubyte)*) registers[pc.a]);
	registers[pc.a] = registers[pc.b];
	mixin(mizuNext);
}

/**
* Generates a pointer to memory on Mizu's stack.
*
* Params:
*   out_ = register to store the pointer in
*   a = register holding a signed byte offset from the current stack pointer
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&stackPushImmediate).setImmediate(8),
* 	Opcode(&pointerToStack, Registers.t(0), Registers.zero),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(0)] == cast(size_t)(env.stackBottom - 8));
* ---
*/
void* pointerToStack(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	immutable offset = *cast(long*)&registers[pc.a];
	registers[pc.out_] = cast(size_t)(sp + offset);
	mixin(mizuNext);
}

/**
* Generates a pointer to memory measured up from the bottom of Mizu's stack.
*
* Params:
*   out_ = register to store the pointer in
*   a = register holding how many bytes above the bottom of the stack to point (signed)
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(4),
* 	Opcode(&pointerToStackBottom, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == cast(size_t)(env.stackBottom - 4));
* ---
*/
void* pointerToStackBottom(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	immutable offset = *cast(long*)&registers[pc.a];
	registers[pc.out_] = cast(size_t)(env.stackBottom - offset);
	mixin(mizuNext);
}

/**
* Generates a pointer to one of Mizu's registers.
*
* Params:
*   out_ = register to store the pointer in
*   a = register to take a pointer to; its index, not its value, is used
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&pointerToRegister, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == cast(size_t) &env.memory[Registers.t(0)]);
* ---
*/
void* pointerToRegister(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = cast(size_t)(registers + pc.a);
	mixin(mizuNext);
}

/**
* Copies memory from one pointer to another, which must not overlap.
*
* Params:
*   out_ = register holding the pointer to copy to; it is read, not written
*   a = register holding the pointer to copy from
*   b = register holding how many bytes to copy
*
* Examples:
* ---
* static immutable Opcode[5] program = [
* 	Opcode(&pointerToRegister, Registers.t(2), Registers.t(0)),
* 	Opcode(&pointerToRegister, Registers.t(3), Registers.t(1)),
* 	Opcode(&loadImmediate, Registers.t(4)).setImmediate(8),
* 	Opcode(&copyMemory, Registers.t(3), Registers.t(2), Registers.t(4)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 42;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 42);
* ---
*/
void* copyMemory(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	memcpy(cast(void*) registers[pc.out_], cast(const(void)*) registers[pc.a], cast(size_t) registers[pc.b]);
	mixin(mizuNext);
}

/**
* Copies memory from one pointer to another, which must not overlap.
*
* Params:
*   out_ = register holding the pointer to copy to; it is read, not written
*   a = register holding the pointer to copy from
*   b = how many bytes to copy, the unsigned field itself rather than a register
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&pointerToRegister, Registers.t(2), Registers.t(0)),
* 	Opcode(&pointerToRegister, Registers.t(3), Registers.t(1)),
* 	Opcode(&copyMemoryImmediate, Registers.t(3), Registers.t(2), 8),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 42;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 42);
* ---
*/
void* copyMemoryImmediate(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	memcpy(cast(void*) registers[pc.out_], cast(const(void)*) registers[pc.a], pc.b);
	mixin(mizuNext);
}

/**
* Sets all of the given memory to the provided byte.
*
* Params:
*   out_ = register holding a pointer to the memory to overwrite; it is read, not written
*   a = register holding the `u8` to overwrite it with
*   b = register holding how many bytes to overwrite
*
* Examples:
* ---
* static immutable Opcode[5] program = [
* 	Opcode(&pointerToRegister, Registers.t(1), Registers.t(0)),
* 	Opcode(&loadImmediate, Registers.t(2)).setImmediate(0xAB),
* 	Opcode(&loadImmediate, Registers.t(3)).setImmediate(2),
* 	Opcode(&setMemory, Registers.t(1), Registers.t(2), Registers.t(3)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(0)] == 0xABAB);
* ---
*/
void* setMemory(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	memset(cast(void*) registers[pc.out_], cast(int) registers[pc.a], cast(size_t) registers[pc.b]);
	mixin(mizuNext);
}

/**
* Sets all of the given memory to the provided byte.
*
* Params:
*   out_ = register holding a pointer to the memory to overwrite; it is read, not written
*   a = register holding the `u8` to overwrite it with
*   b = how many bytes to overwrite, the unsigned field itself rather than a register
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&pointerToRegister, Registers.t(1), Registers.t(0)),
* 	Opcode(&loadImmediate, Registers.t(2)).setImmediate(0xAB),
* 	Opcode(&setMemoryImmediate, Registers.t(1), Registers.t(2), 2),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(0)] == 0xABAB);
* ---
*/
void* setMemoryImmediate(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	memset(cast(void*) registers[pc.out_], cast(int) registers[pc.a], pc.b);
	mixin(mizuNext);
}

/**
* Prints the null terminated string a register points at to stdout, followed by a newline, as C's `puts` does, and flushes it.
*
* Params:
*   out_ = register set to a non-negative value on success, negative on failure
*   a = register holding a pointer to the null terminated string to print
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&printString, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = cast(size_t) "Hello from Mizu".ptr;
* cast(void) startFromEnvironment(program[], env);
* assert(cast(long) env.memory[Registers.t(1)] >= 0);
* ---
*/
void* printString(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	immutable printed = fputs(cast(const(char)*) registers[pc.a], stdout) >= 0 && fputs("\n", stdout) >= 0;
	immutable flushed = fflush(stdout) == 0;
	registers[pc.out_] = printed && flushed ? 0 : -1;
	mixin(mizuNext);
}

/**
* Loads a 64 bit integer from the memory a register points at.
*
* This family is `mizu.instructions.core`'s stack loads and stores with `sp + offset` replaced by an address register, unchecked, since the address may be a host allocation as well as somewhere on the stack. Unlike `copyMemory`, `out_` stays a genuine output, so a compiler that binds `out_` to a call's destination can still dereference a pointer.
*
* Params:
*   out_ = register to store the value in
*   a = register holding the address to read
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&pointerToRegister, Registers.t(1), Registers.t(0)),
* 	Opcode(&pointerLoadU64, Registers.t(2), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 0x1_2345_6789;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 0x1_2345_6789);
* ---
*/
void* pointerLoadU64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = *cast(ulong*) registers[pc.a];
	mixin(mizuNext);
}

/**
* Copies a 64 bit integer from a register into the memory a register points at.
*
* Params:
*   out_ = register to store another copy of the stored value in
*   a = register holding the value to copy
*   b = register holding the address to write
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&pointerToRegister, Registers.t(1), Registers.t(2)),
* 	Opcode(&pointerStoreU64, 0, Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 0x1_2345_6789;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 0x1_2345_6789);
* ---
*/
void* pointerStoreU64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = *cast(ulong*) registers[pc.b] = registers[pc.a];
	mixin(mizuNext);
}

/**
* Loads a 32 bit integer from the memory a register points at.
*
* Params:
*   out_ = register to store the value in
*   a = register holding the address to read
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&pointerToRegister, Registers.t(1), Registers.t(0)),
* 	Opcode(&pointerLoadU32, Registers.t(2), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 0x1_2345_6789;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 0x2345_6789);
* ---
*/
void* pointerLoadU32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = *cast(uint*) registers[pc.a];
	mixin(mizuNext);
}

/**
* Copies a 32 bit integer from a register into the memory a register points at.
*
* Params:
*   out_ = register to store another copy of the stored value in
*   a = register holding the value to copy
*   b = register holding the address to write
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&pointerToRegister, Registers.t(1), Registers.t(2)),
* 	Opcode(&pointerStoreU32, 0, Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 0x1_2345_6789;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 0x2345_6789);
* ---
*/
void* pointerStoreU32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = *cast(uint*) registers[pc.b] = cast(uint) registers[pc.a];
	mixin(mizuNext);
}

/**
* Loads a 16 bit integer from the memory a register points at.
*
* Params:
*   out_ = register to store the value in
*   a = register holding the address to read
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&pointerToRegister, Registers.t(1), Registers.t(0)),
* 	Opcode(&pointerLoadU16, Registers.t(2), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 0x1_2345_6789;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 0x6789);
* ---
*/
void* pointerLoadU16(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = *cast(ushort*) registers[pc.a];
	mixin(mizuNext);
}

/**
* Copies a 16 bit integer from a register into the memory a register points at.
*
* Params:
*   out_ = register to store another copy of the stored value in
*   a = register holding the value to copy
*   b = register holding the address to write
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&pointerToRegister, Registers.t(1), Registers.t(2)),
* 	Opcode(&pointerStoreU16, 0, Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 0x1_2345_6789;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 0x6789);
* ---
*/
void* pointerStoreU16(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = *cast(ushort*) registers[pc.b] = cast(ushort) registers[pc.a];
	mixin(mizuNext);
}

/**
* Loads an 8 bit integer from the memory a register points at.
*
* Params:
*   out_ = register to store the value in
*   a = register holding the address to read
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&pointerToRegister, Registers.t(1), Registers.t(0)),
* 	Opcode(&pointerLoadU8, Registers.t(2), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 0x1_2345_6789;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 0x89);
* ---
*/
void* pointerLoadU8(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = *cast(ubyte*) registers[pc.a];
	mixin(mizuNext);
}

/**
* Copies an 8 bit integer from a register into the memory a register points at.
*
* Params:
*   out_ = register to store another copy of the stored value in
*   a = register holding the value to copy
*   b = register holding the address to write
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&pointerToRegister, Registers.t(1), Registers.t(2)),
* 	Opcode(&pointerStoreU8, 0, Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 0x1_2345_6789;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 0x89);
* ---
*/
void* pointerStoreU8(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = *cast(ubyte*) registers[pc.b] = cast(ubyte) registers[pc.a];
	mixin(mizuNext);
}
