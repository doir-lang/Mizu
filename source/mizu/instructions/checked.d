/**
* Instructions that check whether `mizu.instructions.core`'s integer operations would overflow, without performing them.
*
* Each sets `out_` to one if the matching core instruction, given the same `a` and `b`, would produce a result that does not fit in 64 bits, and to zero otherwise, so the result can feed a branch. The `Signed` variants treat both operands as two's complement.
*
* Unsigned `divide` and `modulus` cannot overflow; check `b` against zero with `setIfEqual` instead. Right shifts discard bits by design, so they have no check either.
*/
module mizu.instructions.checked;

static import core.checkedint;

import mizu.opcode;

@nogc nothrow extern(C):

/**
* Checks whether adding two numbers would overflow, treating both as unsigned.
*
* Params:
*   out_ = register set to one if `a + b` would overflow, zero otherwise
*   a = register holding the first value
*   b = register holding the second value
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&addWouldOverflow, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&addWouldOverflow, Registers.t(3), Registers.t(0), Registers.zero),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = ulong.max;
* env.memory[Registers.t(1)] = 1;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 1);
* assert(env.memory[Registers.t(3)] == 0);
* ---
*/
void* addWouldOverflow(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	bool overflow = false;
	cast(void) core.checkedint.addu(registers[pc.a], registers[pc.b], overflow);
	registers[pc.out_] = overflow;
	mixin(mizuNext);
}

/**
* Checks whether adding two numbers would overflow, treating both as signed.
*
* Params:
*   out_ = register set to one if `a + b` would overflow, zero otherwise
*   a = register holding the first value
*   b = register holding the second value
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&addWouldOverflowSigned, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&addWouldOverflowSigned, Registers.t(3), Registers.t(1), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = long.max;
* env.memory[Registers.t(1)] = 1;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 1);
* assert(env.memory[Registers.t(3)] == 0);
* ---
*/
void* addWouldOverflowSigned(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	bool overflow = false;
	cast(void) core.checkedint.adds(cast(long) registers[pc.a], cast(long) registers[pc.b], overflow);
	registers[pc.out_] = overflow;
	mixin(mizuNext);
}

/**
* Checks whether subtracting two numbers would overflow, treating both as unsigned.
*
* Params:
*   out_ = register set to one if `a - b` would overflow, zero otherwise
*   a = register holding the first value
*   b = register holding the second value
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&subtractWouldOverflow, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&subtractWouldOverflow, Registers.t(3), Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 1;
* env.memory[Registers.t(1)] = 2;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 1);
* assert(env.memory[Registers.t(3)] == 0);
* ---
*/
void* subtractWouldOverflow(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	bool overflow = false;
	cast(void) core.checkedint.subu(registers[pc.a], registers[pc.b], overflow);
	registers[pc.out_] = overflow;
	mixin(mizuNext);
}

/**
* Checks whether subtracting two numbers would overflow, treating both as signed.
*
* Params:
*   out_ = register set to one if `a - b` would overflow, zero otherwise
*   a = register holding the first value
*   b = register holding the second value
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&subtractWouldOverflowSigned, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&subtractWouldOverflowSigned, Registers.t(3), Registers.zero, Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = long.min;
* env.memory[Registers.t(1)] = 1;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 1);
* assert(env.memory[Registers.t(3)] == 0);
* ---
*/
void* subtractWouldOverflowSigned(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	bool overflow = false;
	cast(void) core.checkedint.subs(cast(long) registers[pc.a], cast(long) registers[pc.b], overflow);
	registers[pc.out_] = overflow;
	mixin(mizuNext);
}

/**
* Checks whether multiplying two numbers would overflow, treating both as unsigned.
*
* Params:
*   out_ = register set to one if `a * b` would overflow, zero otherwise
*   a = register holding the first value
*   b = register holding the second value
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&multiplyWouldOverflow, Registers.t(2), Registers.t(0), Registers.t(0)),
* 	Opcode(&multiplyWouldOverflow, Registers.t(3), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 1UL << 32;
* env.memory[Registers.t(1)] = 2;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 1);
* assert(env.memory[Registers.t(3)] == 0);
* ---
*/
void* multiplyWouldOverflow(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	bool overflow = false;
	cast(void) core.checkedint.mulu(registers[pc.a], registers[pc.b], overflow);
	registers[pc.out_] = overflow;
	mixin(mizuNext);
}

/**
* Checks whether multiplying two numbers would overflow, treating both as signed.
*
* Params:
*   out_ = register set to one if `a * b` would overflow, zero otherwise
*   a = register holding the first value
*   b = register holding the second value
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&multiplyWouldOverflowSigned, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&multiplyWouldOverflowSigned, Registers.t(3), Registers.t(1), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = long.min;
* env.memory[Registers.t(1)] = -1L;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 1);
* assert(env.memory[Registers.t(3)] == 0);
* ---
*/
void* multiplyWouldOverflowSigned(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	bool overflow = false;
	cast(void) core.checkedint.muls(cast(long) registers[pc.a], cast(long) registers[pc.b], overflow);
	registers[pc.out_] = overflow;
	mixin(mizuNext);
}

/**
* Checks whether shifting one number left by another would lose set bits, treating the value as unsigned.
*
* A shift amount of 64 or more loses every bit, so overflows whenever `a` is non-zero.
*
* Params:
*   out_ = register set to one if `a << b` would overflow, zero otherwise
*   a = register holding the value to shift
*   b = register holding the shift amount
*
* Examples:
* ---
* static immutable Opcode[5] program = [
* 	Opcode(&loadImmediate, Registers.t(1)).setImmediate(63),
* 	Opcode(&loadImmediate, Registers.t(2)).setImmediate(62),
* 	Opcode(&shiftLeftWouldOverflow, Registers.t(3), Registers.t(0), Registers.t(1)),
* 	Opcode(&shiftLeftWouldOverflow, Registers.t(4), Registers.t(0), Registers.t(2)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 3;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(3)] == 1);
* assert(env.memory[Registers.t(4)] == 0);
* ---
*/
void* shiftLeftWouldOverflow(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	immutable value = registers[pc.a], amount = registers[pc.b];
	// D leaves a shift by the full width or more undefined, so it never reaches `<<`.
	registers[pc.out_] = amount >= 64 ? value != 0 : (value << amount) >> amount != value;
	mixin(mizuNext);
}

/**
* Checks whether shifting one number left by another would change its value as a signed number, by losing set bits or flipping its sign.
*
* A shift amount of 64 or more overflows whenever `a` is non-zero.
*
* Params:
*   out_ = register set to one if `a << b` would overflow, zero otherwise
*   a = register holding the value to shift
*   b = register holding the shift amount
*
* Examples:
* ---
* static immutable Opcode[5] program = [
* 	Opcode(&loadImmediate, Registers.t(1)).setImmediate(62),
* 	Opcode(&loadImmediate, Registers.t(2)).setImmediate(61),
* 	Opcode(&shiftLeftWouldOverflowSigned, Registers.t(3), Registers.t(0), Registers.t(1)),
* 	Opcode(&shiftLeftWouldOverflowSigned, Registers.t(4), Registers.t(0), Registers.t(2)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = -3L;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(3)] == 1);
* assert(env.memory[Registers.t(4)] == 0);
* ---
*/
void* shiftLeftWouldOverflowSigned(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	immutable value = cast(long) registers[pc.a], amount = registers[pc.b];
	// Shifting back arithmetically restores `value` exactly when no bit, sign included, was lost.
	registers[pc.out_] = amount >= 64 ? value != 0 : (value << amount) >> amount != value;
	mixin(mizuNext);
}

/**
* Checks whether converting a register to a 32 bit integer would lose bits, treating it as unsigned.
*
* Params:
*   out_ = register set to one if `a` does not fit in 32 bits, zero otherwise
*   a = register holding the value to convert
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&convertToU32WouldOverflow, Registers.t(1), Registers.t(0)),
* 	Opcode(&convertToU32WouldOverflow, Registers.t(2), Registers.zero),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 1UL << 32;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 1);
* assert(env.memory[Registers.t(2)] == 0);
* ---
*/
void* convertToU32WouldOverflow(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = registers[pc.a] > uint.max;
	mixin(mizuNext);
}

/**
* Checks whether converting a register to a 16 bit integer would lose bits, treating it as unsigned.
*
* Params:
*   out_ = register set to one if `a` does not fit in 16 bits, zero otherwise
*   a = register holding the value to convert
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(ushort.max + 1),
* 	Opcode(&convertToU16WouldOverflow, Registers.t(1), Registers.t(0)),
* 	Opcode(&convertToU16WouldOverflow, Registers.t(2), Registers.zero),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 1);
* assert(env.memory[Registers.t(2)] == 0);
* ---
*/
void* convertToU16WouldOverflow(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = registers[pc.a] > ushort.max;
	mixin(mizuNext);
}

/**
* Checks whether converting a register to an 8 bit integer would lose bits, treating it as unsigned.
*
* Params:
*   out_ = register set to one if `a` does not fit in 8 bits, zero otherwise
*   a = register holding the value to convert
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(ubyte.max + 1),
* 	Opcode(&convertToU8WouldOverflow, Registers.t(1), Registers.t(0)),
* 	Opcode(&convertToU8WouldOverflow, Registers.t(2), Registers.zero),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 1);
* assert(env.memory[Registers.t(2)] == 0);
* ---
*/
void* convertToU8WouldOverflow(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = registers[pc.a] > ubyte.max;
	mixin(mizuNext);
}
