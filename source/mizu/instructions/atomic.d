/**
* Atomic instructions on 64 bit values, held either in registers or in memory a register points at.
*
* `a` names the register to update, `b` the register holding the operand, and `out_` receives the value `a` held before the instruction. Each instruction has a `Pointer` twin that instead updates the memory `a` points at, which is how threads forked by `mizu.instructions.parallel`, each with its own copy of the registers, share a value. Every access is sequentially consistent.
*
* Like `mizu.instructions.unsafe`'s pointer instructions, the `Pointer` twins check nothing beyond alignment: the address may be a host allocation from `allocate`, anywhere on Mizu's stack, or a register from `pointerToRegister`.
*/
module mizu.instructions.atomic;

static import core.atomic;

import mizu.opcode;

@nogc nothrow:

// Register `index` as atomic operations take it.
private shared(ulong)* cell(ulong* registers, size_t index) {
	return cast(shared(ulong)*) &registers[index];
}

// The memory register `index` points at, asserted to be aligned as an atomic access requires.
private shared(ulong)* pointee(ulong* registers, size_t index) {
	immutable address = registers[index];
	assert(address % ulong.sizeof == 0, "mizu: atomic access to a misaligned address");
	return cast(shared(ulong)*) address;
}

// Atomically replaces `*address` with `combine(old, operand)`, returning `old`.
private ulong fetchCombine(alias combine)(shared(ulong)* address, ulong operand) {
	ulong old = core.atomic.atomicLoad(*address);
	// On failure `cas` stores the value it found in `old`, so each retry combines against fresh data.
	while (!core.atomic.cas(address, &old, combine(old, operand))) {}
	return old;
}

extern(C):

/**
* Orders every memory access before this instruction ahead of every access after it, as seen by other threads.
*
* Examples:
* ---
* static immutable Opcode[2] program = [Opcode(&atomicFence), Opcode(&halt)];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* ---
*/
void* atomicFence(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	core.atomic.atomicFence();
	mixin(mizuNext);
}

/**
* Atomically copies one register into another.
*
* Params:
*   out_ = register to store the copy in
*   a = register to read
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(42),
* 	Opcode(&atomicLoad, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 42);
* ---
*/
void* atomicLoad(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = core.atomic.atomicLoad(*cell(registers, pc.a));
	mixin(mizuNext);
}

/**
* Atomically overwrites a register with another's value.
*
* Params:
*   out_ = register to store another copy of `b` in
*   a = register to overwrite
*   b = register holding the value to store
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&loadImmediate, Registers.t(1)).setImmediate(42),
* 	Opcode(&atomicStore, 0, Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(0)] == 42);
* ---
*/
void* atomicStore(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	immutable value = registers[pc.b];
	core.atomic.atomicStore(*cell(registers, pc.a), value);
	registers[pc.out_] = value;
	mixin(mizuNext);
}

/**
* Atomically overwrites a register with another's value, keeping the value it held.
*
* Params:
*   out_ = register to store the value `a` held before in
*   a = register to overwrite
*   b = register holding the value to store
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(1),
* 	Opcode(&loadImmediate, Registers.t(1)).setImmediate(2),
* 	Opcode(&atomicExchange, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 1);
* assert(env.memory[Registers.t(0)] == 2);
* ---
*/
void* atomicExchange(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = core.atomic.atomicExchange(cell(registers, pc.a), registers[pc.b]);
	mixin(mizuNext);
}

/**
* Atomically overwrites a register with another's value, but only if it holds the value expected.
*
* Like RISC-V's `amocas.d`, `out_` is read as well as written: it holds the expected value going in and the value `a` held coming out. The store happened exactly when the two are equal, so keep a copy of the expected value to compare against.
*
* Params:
*   out_ = register holding the expected value, overwritten with the value `a` held before
*   a = register to overwrite
*   b = register holding the value to store
*
* Examples:
* ---
* static immutable Opcode[6] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(1),
* 	Opcode(&loadImmediate, Registers.t(1)).setImmediate(2),
* 	Opcode(&loadImmediate, Registers.t(2)).setImmediate(1),
* 	Opcode(&atomicCompareExchange, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&atomicCompareExchange, Registers.t(3), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(0)] == 2); // The first expected 1 and stored 2.
* assert(env.memory[Registers.t(2)] == 1);
* assert(env.memory[Registers.t(3)] == 2); // The second expected 0, so stored nothing.
* ---
*/
void* atomicCompareExchange(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	ulong expected = registers[pc.out_];
	cast(void) core.atomic.cas(cell(registers, pc.a), &expected, registers[pc.b]);
	registers[pc.out_] = expected;
	mixin(mizuNext);
}

/**
* Atomically adds one register's value to another.
*
* Params:
*   out_ = register to store the value `a` held before in
*   a = register to add to
*   b = register holding the value to add
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(40),
* 	Opcode(&loadImmediate, Registers.t(1)).setImmediate(2),
* 	Opcode(&atomicFetchAdd, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 40);
* assert(env.memory[Registers.t(0)] == 42);
* ---
*/
void* atomicFetchAdd(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	// `core.atomic.atomicFetchAdd` takes a `size_t`, too narrow on 32 bit targets; wrapping arithmetic recovers the old value from the new.
	registers[pc.out_] = core.atomic.atomicOp!"+="(*cell(registers, pc.a), registers[pc.b]) - registers[pc.b];
	mixin(mizuNext);
}

/**
* Atomically subtracts one register's value from another.
*
* Params:
*   out_ = register to store the value `a` held before in
*   a = register to subtract from
*   b = register holding the value to subtract
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(44),
* 	Opcode(&loadImmediate, Registers.t(1)).setImmediate(2),
* 	Opcode(&atomicFetchSubtract, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 44);
* assert(env.memory[Registers.t(0)] == 42);
* ---
*/
void* atomicFetchSubtract(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = core.atomic.atomicOp!"-="(*cell(registers, pc.a), registers[pc.b]) + registers[pc.b];
	mixin(mizuNext);
}

/**
* Atomically ands one register's value into another.
*
* Params:
*   out_ = register to store the value `a` held before in
*   a = register to update
*   b = register holding the value to and with
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(0b1100),
* 	Opcode(&loadImmediate, Registers.t(1)).setImmediate(0b1010),
* 	Opcode(&atomicFetchAnd, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 0b1100);
* assert(env.memory[Registers.t(0)] == 0b1000);
* ---
*/
void* atomicFetchAnd(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = fetchCombine!((x, y) => x & y)(cell(registers, pc.a), registers[pc.b]);
	mixin(mizuNext);
}

/**
* Atomically ors one register's value into another.
*
* Params:
*   out_ = register to store the value `a` held before in
*   a = register to update
*   b = register holding the value to or with
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(0b1100),
* 	Opcode(&loadImmediate, Registers.t(1)).setImmediate(0b1010),
* 	Opcode(&atomicFetchOr, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 0b1100);
* assert(env.memory[Registers.t(0)] == 0b1110);
* ---
*/
void* atomicFetchOr(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = fetchCombine!((x, y) => x | y)(cell(registers, pc.a), registers[pc.b]);
	mixin(mizuNext);
}

/**
* Atomically exclusive-ors one register's value into another.
*
* Params:
*   out_ = register to store the value `a` held before in
*   a = register to update
*   b = register holding the value to exclusive-or with
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(0b1100),
* 	Opcode(&loadImmediate, Registers.t(1)).setImmediate(0b1010),
* 	Opcode(&atomicFetchXor, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 0b1100);
* assert(env.memory[Registers.t(0)] == 0b0110);
* ---
*/
void* atomicFetchXor(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = fetchCombine!((x, y) => x ^ y)(cell(registers, pc.a), registers[pc.b]);
	mixin(mizuNext);
}

/**
* Atomically replaces a register with the smaller of it and another register, comparing both as unsigned.
*
* Params:
*   out_ = register to store the value `a` held before in
*   a = register to update
*   b = register holding the value to compare with
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(7),
* 	Opcode(&loadImmediate, Registers.t(1)).setImmediate(3),
* 	Opcode(&atomicFetchMin, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 7);
* assert(env.memory[Registers.t(0)] == 3);
* ---
*/
void* atomicFetchMin(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = fetchCombine!((x, y) => x < y ? x : y)(cell(registers, pc.a), registers[pc.b]);
	mixin(mizuNext);
}

/**
* Atomically replaces a register with the larger of it and another register, comparing both as unsigned.
*
* Params:
*   out_ = register to store the value `a` held before in
*   a = register to update
*   b = register holding the value to compare with
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(3),
* 	Opcode(&loadImmediate, Registers.t(1)).setImmediate(7),
* 	Opcode(&atomicFetchMax, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 3);
* assert(env.memory[Registers.t(0)] == 7);
* ---
*/
void* atomicFetchMax(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = fetchCombine!((x, y) => x > y ? x : y)(cell(registers, pc.a), registers[pc.b]);
	mixin(mizuNext);
}

/**
* Atomically replaces a register with the smaller of it and another register, comparing both as signed.
*
* Params:
*   out_ = register to store the value `a` held before in
*   a = register to update
*   b = register holding the value to compare with
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(3),
* 	Opcode(&atomicFetchMinSigned, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(1)] = -7L;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 3);
* assert(cast(long) env.memory[Registers.t(0)] == -7);
* ---
*/
void* atomicFetchMinSigned(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = fetchCombine!((x, y) => cast(long) x < cast(long) y ? x : y)(cell(registers, pc.a), registers[pc.b]);
	mixin(mizuNext);
}

/**
* Atomically replaces a register with the larger of it and another register, comparing both as signed.
*
* Params:
*   out_ = register to store the value `a` held before in
*   a = register to update
*   b = register holding the value to compare with
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&loadImmediate, Registers.t(1)).setImmediate(7),
* 	Opcode(&atomicFetchMaxSigned, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = -3L;
* cast(void) startFromEnvironment(program[], env);
* assert(cast(long) env.memory[Registers.t(2)] == -3);
* assert(env.memory[Registers.t(0)] == 7);
* ---
*/
void* atomicFetchMaxSigned(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = fetchCombine!((x, y) => cast(long) x > cast(long) y ? x : y)(cell(registers, pc.a), registers[pc.b]);
	mixin(mizuNext);
}

/**
* Atomically loads a 64 bit integer from the memory a register points at.
*
* Params:
*   out_ = register to store the result in
*   a = register holding the address to read, which must be 8 byte aligned
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(42),
* 	Opcode(&pointerToRegister, Registers.t(1), Registers.t(0)),
* 	Opcode(&atomicLoadPointer, Registers.t(2), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 42);
* ---
*/
void* atomicLoadPointer(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = core.atomic.atomicLoad(*pointee(registers, pc.a));
	mixin(mizuNext);
}

/**
* Atomically copies a register's value into the memory a register points at.
*
* Params:
*   out_ = register to store another copy of `b` in
*   a = register holding the address to write, which must be 8 byte aligned
*   b = register holding the value to store
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&pointerToRegister, Registers.t(1), Registers.t(0)),
* 	Opcode(&loadImmediate, Registers.t(2)).setImmediate(42),
* 	Opcode(&atomicStorePointer, 0, Registers.t(1), Registers.t(2)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(0)] == 42);
* ---
*/
void* atomicStorePointer(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	immutable value = registers[pc.b];
	core.atomic.atomicStore(*pointee(registers, pc.a), value);
	registers[pc.out_] = value;
	mixin(mizuNext);
}

/**
* Atomically swaps a register's value into the memory a register points at.
*
* Params:
*   out_ = register to store the value the memory held before in
*   a = register holding the address to swap with, which must be 8 byte aligned
*   b = register holding the value to store
*
* Examples:
* ---
* static immutable Opcode[5] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(1),
* 	Opcode(&pointerToRegister, Registers.t(1), Registers.t(0)),
* 	Opcode(&loadImmediate, Registers.t(2)).setImmediate(2),
* 	Opcode(&atomicExchangePointer, Registers.t(3), Registers.t(1), Registers.t(2)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(3)] == 1);
* assert(env.memory[Registers.t(0)] == 2);
* ---
*/
void* atomicExchangePointer(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = core.atomic.atomicExchange(pointee(registers, pc.a), registers[pc.b]);
	mixin(mizuNext);
}

/**
* Atomically stores a register's value into the memory a register points at, but only if that memory holds the value expected.
*
* As with `atomicCompareExchange`, `out_` holds the expected value going in and the value the memory held coming out.
*
* Params:
*   out_ = register holding the expected value, overwritten with the value the memory held before
*   a = register holding the address to update, which must be 8 byte aligned
*   b = register holding the value to store
*
* Examples:
* ---
* static immutable Opcode[7] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(1),
* 	Opcode(&pointerToRegister, Registers.t(1), Registers.t(0)),
* 	Opcode(&loadImmediate, Registers.t(2)).setImmediate(2),
* 	Opcode(&loadImmediate, Registers.t(3)).setImmediate(1),
* 	Opcode(&atomicCompareExchangePointer, Registers.t(3), Registers.t(1), Registers.t(2)),
* 	Opcode(&atomicCompareExchangePointer, Registers.t(4), Registers.t(1), Registers.t(2)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(0)] == 2); // The first expected 1 and stored 2.
* assert(env.memory[Registers.t(3)] == 1);
* assert(env.memory[Registers.t(4)] == 2); // The second expected 0, so stored nothing.
* ---
*/
void* atomicCompareExchangePointer(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	ulong expected = registers[pc.out_];
	cast(void) core.atomic.cas(pointee(registers, pc.a), &expected, registers[pc.b]);
	registers[pc.out_] = expected;
	mixin(mizuNext);
}

/**
* Atomically adds a register's value to the memory a register points at.
*
* Params:
*   out_ = register to store the value the memory held before in
*   a = register holding the address to update, which must be 8 byte aligned
*   b = register holding the value to add
*
* Examples:
* ---
* static immutable Opcode[5] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(40),
* 	Opcode(&pointerToRegister, Registers.t(1), Registers.t(0)),
* 	Opcode(&loadImmediate, Registers.t(2)).setImmediate(2),
* 	Opcode(&atomicFetchAddPointer, Registers.t(3), Registers.t(1), Registers.t(2)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(3)] == 40);
* assert(env.memory[Registers.t(0)] == 42);
* ---
*/
void* atomicFetchAddPointer(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = core.atomic.atomicOp!"+="(*pointee(registers, pc.a), registers[pc.b]) - registers[pc.b];
	mixin(mizuNext);
}

/**
* Atomically subtracts a register's value from the memory a register points at.
*
* Params:
*   out_ = register to store the value the memory held before in
*   a = register holding the address to update, which must be 8 byte aligned
*   b = register holding the value to subtract
*
* Examples:
* ---
* static immutable Opcode[5] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(44),
* 	Opcode(&pointerToRegister, Registers.t(1), Registers.t(0)),
* 	Opcode(&loadImmediate, Registers.t(2)).setImmediate(2),
* 	Opcode(&atomicFetchSubtractPointer, Registers.t(3), Registers.t(1), Registers.t(2)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(3)] == 44);
* assert(env.memory[Registers.t(0)] == 42);
* ---
*/
void* atomicFetchSubtractPointer(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = core.atomic.atomicOp!"-="(*pointee(registers, pc.a), registers[pc.b]) + registers[pc.b];
	mixin(mizuNext);
}

/**
* Atomically ands a register's value into the memory a register points at.
*
* Params:
*   out_ = register to store the value the memory held before in
*   a = register holding the address to update, which must be 8 byte aligned
*   b = register holding the value to and with
*
* Examples:
* ---
* static immutable Opcode[5] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(0b1100),
* 	Opcode(&pointerToRegister, Registers.t(1), Registers.t(0)),
* 	Opcode(&loadImmediate, Registers.t(2)).setImmediate(0b1010),
* 	Opcode(&atomicFetchAndPointer, Registers.t(3), Registers.t(1), Registers.t(2)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(3)] == 0b1100);
* assert(env.memory[Registers.t(0)] == 0b1000);
* ---
*/
void* atomicFetchAndPointer(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = fetchCombine!((x, y) => x & y)(pointee(registers, pc.a), registers[pc.b]);
	mixin(mizuNext);
}

/**
* Atomically ors a register's value into the memory a register points at.
*
* Params:
*   out_ = register to store the value the memory held before in
*   a = register holding the address to update, which must be 8 byte aligned
*   b = register holding the value to or with
*
* Examples:
* ---
* static immutable Opcode[5] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(0b1100),
* 	Opcode(&pointerToRegister, Registers.t(1), Registers.t(0)),
* 	Opcode(&loadImmediate, Registers.t(2)).setImmediate(0b1010),
* 	Opcode(&atomicFetchOrPointer, Registers.t(3), Registers.t(1), Registers.t(2)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(3)] == 0b1100);
* assert(env.memory[Registers.t(0)] == 0b1110);
* ---
*/
void* atomicFetchOrPointer(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = fetchCombine!((x, y) => x | y)(pointee(registers, pc.a), registers[pc.b]);
	mixin(mizuNext);
}

/**
* Atomically exclusive-ors a register's value into the memory a register points at.
*
* Params:
*   out_ = register to store the value the memory held before in
*   a = register holding the address to update, which must be 8 byte aligned
*   b = register holding the value to exclusive-or with
*
* Examples:
* ---
* static immutable Opcode[5] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(0b1100),
* 	Opcode(&pointerToRegister, Registers.t(1), Registers.t(0)),
* 	Opcode(&loadImmediate, Registers.t(2)).setImmediate(0b1010),
* 	Opcode(&atomicFetchXorPointer, Registers.t(3), Registers.t(1), Registers.t(2)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(3)] == 0b1100);
* assert(env.memory[Registers.t(0)] == 0b0110);
* ---
*/
void* atomicFetchXorPointer(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = fetchCombine!((x, y) => x ^ y)(pointee(registers, pc.a), registers[pc.b]);
	mixin(mizuNext);
}

/**
* Atomically replaces the memory a register points at with the smaller of it and a register's value, comparing both as unsigned.
*
* Params:
*   out_ = register to store the value the memory held before in
*   a = register holding the address to update, which must be 8 byte aligned
*   b = register holding the value to compare with
*
* Examples:
* ---
* static immutable Opcode[5] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(7),
* 	Opcode(&pointerToRegister, Registers.t(1), Registers.t(0)),
* 	Opcode(&loadImmediate, Registers.t(2)).setImmediate(3),
* 	Opcode(&atomicFetchMinPointer, Registers.t(3), Registers.t(1), Registers.t(2)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(3)] == 7);
* assert(env.memory[Registers.t(0)] == 3);
* ---
*/
void* atomicFetchMinPointer(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = fetchCombine!((x, y) => x < y ? x : y)(pointee(registers, pc.a), registers[pc.b]);
	mixin(mizuNext);
}

/**
* Atomically replaces the memory a register points at with the larger of it and a register's value, comparing both as unsigned.
*
* Params:
*   out_ = register to store the value the memory held before in
*   a = register holding the address to update, which must be 8 byte aligned
*   b = register holding the value to compare with
*
* Examples:
* ---
* static immutable Opcode[5] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(3),
* 	Opcode(&pointerToRegister, Registers.t(1), Registers.t(0)),
* 	Opcode(&loadImmediate, Registers.t(2)).setImmediate(7),
* 	Opcode(&atomicFetchMaxPointer, Registers.t(3), Registers.t(1), Registers.t(2)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(3)] == 3);
* assert(env.memory[Registers.t(0)] == 7);
* ---
*/
void* atomicFetchMaxPointer(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = fetchCombine!((x, y) => x > y ? x : y)(pointee(registers, pc.a), registers[pc.b]);
	mixin(mizuNext);
}

/**
* Atomically replaces the memory a register points at with the smaller of it and a register's value, comparing both as signed.
*
* Params:
*   out_ = register to store the value the memory held before in
*   a = register holding the address to update, which must be 8 byte aligned
*   b = register holding the value to compare with
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(3),
* 	Opcode(&pointerToRegister, Registers.t(1), Registers.t(0)),
* 	Opcode(&atomicFetchMinSignedPointer, Registers.t(3), Registers.t(1), Registers.t(2)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(2)] = -7L;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(3)] == 3);
* assert(cast(long) env.memory[Registers.t(0)] == -7);
* ---
*/
void* atomicFetchMinSignedPointer(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = fetchCombine!((x, y) => cast(long) x < cast(long) y ? x : y)(pointee(registers, pc.a), registers[pc.b]);
	mixin(mizuNext);
}

/**
* Atomically replaces the memory a register points at with the larger of it and a register's value, comparing both as signed.
*
* Params:
*   out_ = register to store the value the memory held before in
*   a = register holding the address to update, which must be 8 byte aligned
*   b = register holding the value to compare with
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&pointerToRegister, Registers.t(1), Registers.t(0)),
* 	Opcode(&loadImmediate, Registers.t(2)).setImmediate(7),
* 	Opcode(&atomicFetchMaxSignedPointer, Registers.t(3), Registers.t(1), Registers.t(2)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = -3L;
* cast(void) startFromEnvironment(program[], env);
* assert(cast(long) env.memory[Registers.t(3)] == -3);
* assert(env.memory[Registers.t(0)] == 7);
* ---
*/
void* atomicFetchMaxSignedPointer(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = fetchCombine!((x, y) => cast(long) x > cast(long) y ? x : y)(pointee(registers, pc.a), registers[pc.b]);
	mixin(mizuNext);
}
