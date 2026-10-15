/**
* 32 bit floating point instructions.
*
* Mizu registers are raw 64 bit blobs, so a "float register" is just a register whose bits are being read as an `f32`. Convert with `convertToF32`/`convertFromF32` before and after doing float math on a value that arrived as an integer.
*
* An `f32` lives in a register's low 32 bits, and an instruction writing one leaves the upper 32 bits as they were.
*/
module mizu.instructions.f32;

import core.stdc.math : sqrtf;

import mizu.opcode;

@nogc nothrow:

/**
* Reinterprets register `index` as a floating point value of type `F`; an `f32` occupies the register's low 32 bits.
*
* Examples:
* ---
* RegistersAndStack env;
* floatRegister!double(env.memory.ptr, Registers.t(0)) = 1.5;
* assert(env.memory[Registers.t(0)] == 0x3FF8_0000_0000_0000);
* ---
*/
ref F floatRegister(F)(ulong* registers, Reg index) @trusted if (is(F == float) || is(F == double)) {
	return *cast(F*)&registers[index];
}

/**
* True if `value`'s sign bit is set, including for `-0.0` and `-nan`.
*
* Examples:
* ---
* assert(floatSignBit(-0.0f));
* assert(!floatSignBit(0.0));
* ---
*/
bool floatSignBit(float value) @trusted {
	return (*cast(const uint*)&value >> 31) != 0;
}

/// Ditto
bool floatSignBit(double value) @trusted {
	return (*cast(const ulong*)&value >> 63) != 0;
}

/**
* True if `value` is a quiet or signalling nan.
*
* Examples:
* ---
* assert(floatIsNan(float.nan));
* assert(!floatIsNan(double.infinity));
* ---
*/
bool floatIsNan(float value) @trusted {
	immutable bits = *cast(const uint*)&value;
	return (bits & 0x7F80_0000) == 0x7F80_0000 && (bits & 0x007F_FFFF) != 0;
}

/// Ditto
bool floatIsNan(double value) @trusted {
	immutable bits = *cast(const ulong*)&value;
	return (bits & 0x7FF0_0000_0000_0000) == 0x7FF0_0000_0000_0000 && (bits & 0x000F_FFFF_FFFF_FFFF) != 0;
}

/**
* True if `value` is positive or negative infinity.
*
* Examples:
* ---
* assert(floatIsInfinity(-float.infinity));
* assert(!floatIsInfinity(double.nan));
* ---
*/
bool floatIsInfinity(float value) @trusted {
	return (*cast(const uint*)&value & 0x7FFF_FFFF) == 0x7F80_0000;
}

/// Ditto
bool floatIsInfinity(double value) @trusted {
	return (*cast(const ulong*)&value & 0x7FFF_FFFF_FFFF_FFFF) == 0x7FF0_0000_0000_0000;
}

extern(C):

/**
* Converts an unsigned integer register to `f32`.
*
* Params:
*   out_ = register to store the `f32` in
*   a = register holding the `u64` to convert
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&convertToF32, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 42;
* cast(void) startFromEnvironment(program[], env);
* assert(floatRegister!float(env.memory.ptr, Registers.t(1)) == 42);
* ---
*/
void* convertToF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	floatRegister!float(registers, pc.out_) = cast(float) registers[pc.a];
	mixin(mizuNext);
}

/**
* Converts a signed integer register to `f32`.
*
* Params:
*   out_ = register to store the `f32` in
*   a = register holding the `i64` to convert
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&convertSignedToF32, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = -42;
* cast(void) startFromEnvironment(program[], env);
* assert(floatRegister!float(env.memory.ptr, Registers.t(1)) == -42);
* ---
*/
void* convertSignedToF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	floatRegister!float(registers, pc.out_) = cast(float)*cast(long*)&registers[pc.a];
	mixin(mizuNext);
}

/**
* Truncates an `f32` register to an unsigned integer.
*
* Params:
*   out_ = register to store the `u64` in
*   a = register holding the `f32` to convert
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&convertFromF32, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!float(env.memory.ptr, Registers.t(0)) = 42.75f;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 42);
* ---
*/
void* convertFromF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = cast(ulong) floatRegister!float(registers, pc.a);
	mixin(mizuNext);
}

/**
* Truncates an `f32` register to a signed integer.
*
* Params:
*   out_ = register to store the `i64` in
*   a = register holding the `f32` to convert
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&convertSignedFromF32, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!float(env.memory.ptr, Registers.t(0)) = -42.75f;
* cast(void) startFromEnvironment(program[], env);
* assert(cast(long) env.memory[Registers.t(1)] == -42);
* ---
*/
void* convertSignedFromF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	*cast(long*)&registers[pc.out_] = cast(long) floatRegister!float(registers, pc.a);
	mixin(mizuNext);
}

/**
* Adds two `f32` numbers.
*
* Params:
*   out_ = register to store `a + b` in
*   a = register holding the first value
*   b = register holding the second value
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&addF32, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!float(env.memory.ptr, Registers.t(0)) = 40.5f;
* floatRegister!float(env.memory.ptr, Registers.t(1)) = 1.5f;
* cast(void) startFromEnvironment(program[], env);
* assert(floatRegister!float(env.memory.ptr, Registers.t(2)) == 42);
* ---
*/
void* addF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	floatRegister!float(registers, pc.out_) = floatRegister!float(registers, pc.a) + floatRegister!float(registers, pc.b);
	mixin(mizuNext);
}

/**
* Subtracts two `f32` numbers.
*
* Params:
*   out_ = register to store `a - b` in
*   a = register holding the first value
*   b = register holding the second value
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&subtractF32, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!float(env.memory.ptr, Registers.t(0)) = 43.5f;
* floatRegister!float(env.memory.ptr, Registers.t(1)) = 1.5f;
* cast(void) startFromEnvironment(program[], env);
* assert(floatRegister!float(env.memory.ptr, Registers.t(2)) == 42);
* ---
*/
void* subtractF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	floatRegister!float(registers, pc.out_) = floatRegister!float(registers, pc.a) - floatRegister!float(registers, pc.b);
	mixin(mizuNext);
}

/**
* Multiplies two `f32` numbers.
*
* Params:
*   out_ = register to store `a * b` in
*   a = register holding the first value
*   b = register holding the second value
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&multiplyF32, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!float(env.memory.ptr, Registers.t(0)) = 10.5f;
* floatRegister!float(env.memory.ptr, Registers.t(1)) = 4f;
* cast(void) startFromEnvironment(program[], env);
* assert(floatRegister!float(env.memory.ptr, Registers.t(2)) == 42);
* ---
*/
void* multiplyF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	floatRegister!float(registers, pc.out_) = floatRegister!float(registers, pc.a) * floatRegister!float(registers, pc.b);
	mixin(mizuNext);
}

/**
* Divides two `f32` numbers.
*
* Params:
*   out_ = register to store `a / b` in
*   a = register holding the first value
*   b = register holding the second value
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&divideF32, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!float(env.memory.ptr, Registers.t(0)) = 84f;
* floatRegister!float(env.memory.ptr, Registers.t(1)) = 2f;
* cast(void) startFromEnvironment(program[], env);
* assert(floatRegister!float(env.memory.ptr, Registers.t(2)) == 42);
* ---
*/
void* divideF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	floatRegister!float(registers, pc.out_) = floatRegister!float(registers, pc.a) / floatRegister!float(registers, pc.b);
	mixin(mizuNext);
}

/**
* Finds the larger of two `f32` numbers; if either is nan, the result is `a`.
*
* Params:
*   out_ = register to store `max(a, b)` in
*   a = register holding the first value
*   b = register holding the second value
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&maxF32, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!float(env.memory.ptr, Registers.t(0)) = -1f;
* floatRegister!float(env.memory.ptr, Registers.t(1)) = 42f;
* cast(void) startFromEnvironment(program[], env);
* assert(floatRegister!float(env.memory.ptr, Registers.t(2)) == 42);
* ---
*/
void* maxF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	immutable x = floatRegister!float(registers, pc.a);
	immutable y = floatRegister!float(registers, pc.b);
	floatRegister!float(registers, pc.out_) = x < y ? y : x;
	mixin(mizuNext);
}

/**
* Finds the smaller of two `f32` numbers; if either is nan, the result is `a`.
*
* Params:
*   out_ = register to store `min(a, b)` in
*   a = register holding the first value
*   b = register holding the second value
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&minF32, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!float(env.memory.ptr, Registers.t(0)) = 42f;
* floatRegister!float(env.memory.ptr, Registers.t(1)) = 100f;
* cast(void) startFromEnvironment(program[], env);
* assert(floatRegister!float(env.memory.ptr, Registers.t(2)) == 42);
* ---
*/
void* minF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	immutable x = floatRegister!float(registers, pc.a);
	immutable y = floatRegister!float(registers, pc.b);
	floatRegister!float(registers, pc.out_) = y < x ? y : x;
	mixin(mizuNext);
}

/**
* Finds the square root of an `f32` number.
*
* Params:
*   out_ = register to store `sqrt(a)` in
*   a = register holding the value
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&sqrtF32, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!float(env.memory.ptr, Registers.t(0)) = 1764f;
* cast(void) startFromEnvironment(program[], env);
* assert(floatRegister!float(env.memory.ptr, Registers.t(1)) == 42);
* ---
*/
void* sqrtF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	floatRegister!float(registers, pc.out_) = sqrtf(floatRegister!float(registers, pc.a));
	mixin(mizuNext);
}

/**
* Checks if two `f32` registers are equal.
*
* Params:
*   out_ = register set to one if `a == b`, zero otherwise
*   a = register holding the first value to compare
*   b = register holding the second value to compare
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&setIfEqualF32, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!float(env.memory.ptr, Registers.t(0)) = 1.5f;
* floatRegister!float(env.memory.ptr, Registers.t(1)) = 1.5f;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 1);
* ---
*/
void* setIfEqualF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = floatRegister!float(registers, pc.a) == floatRegister!float(registers, pc.b);
	mixin(mizuNext);
}

/**
* Checks if two `f32` registers are not equal.
*
* Params:
*   out_ = register set to one if `a != b`, zero otherwise
*   a = register holding the first value to compare
*   b = register holding the second value to compare
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&setIfNotEqualF32, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!float(env.memory.ptr, Registers.t(0)) = 1.5f;
* floatRegister!float(env.memory.ptr, Registers.t(1)) = 2.5f;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 1);
* ---
*/
void* setIfNotEqualF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = floatRegister!float(registers, pc.a) != floatRegister!float(registers, pc.b);
	mixin(mizuNext);
}

/**
* Checks if one `f32` register is less than another.
*
* Params:
*   out_ = register set to one if `a < b`, zero otherwise
*   a = register holding the first value to compare
*   b = register holding the second value to compare
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&setIfLessF32, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!float(env.memory.ptr, Registers.t(0)) = -1.5f;
* floatRegister!float(env.memory.ptr, Registers.t(1)) = 1.5f;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 1);
* ---
*/
void* setIfLessF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = floatRegister!float(registers, pc.a) < floatRegister!float(registers, pc.b);
	mixin(mizuNext);
}

/**
* Checks if one `f32` register is greater than or equal to another.
*
* Params:
*   out_ = register set to one if `a >= b`, zero otherwise
*   a = register holding the first value to compare
*   b = register holding the second value to compare
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&setIfGreaterEqualF32, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!float(env.memory.ptr, Registers.t(0)) = 1.5f;
* floatRegister!float(env.memory.ptr, Registers.t(1)) = 1.5f;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 1);
* ---
*/
void* setIfGreaterEqualF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = floatRegister!float(registers, pc.a) >= floatRegister!float(registers, pc.b);
	mixin(mizuNext);
}

/**
* Checks if an `f32` register is negative.
*
* Params:
*   out_ = register set to one if `a`'s sign bit is set, as for `-0.0`, zero otherwise
*   a = register holding the value to check
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&setIfNegativeF32, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!float(env.memory.ptr, Registers.t(0)) = -0.0f;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 1);
* ---
*/
void* setIfNegativeF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = floatSignBit(floatRegister!float(registers, pc.a));
	mixin(mizuNext);
}

/**
* Checks if an `f32` register is positive.
*
* Params:
*   out_ = register set to one if `a`'s sign bit is clear, as for `0.0`, zero otherwise
*   a = register holding the value to check
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&setIfPositiveF32, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!float(env.memory.ptr, Registers.t(0)) = 0.0f;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 1);
* ---
*/
void* setIfPositiveF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = !floatSignBit(floatRegister!float(registers, pc.a));
	mixin(mizuNext);
}

/**
* Checks if an `f32` register is an infinity.
*
* Params:
*   out_ = register set to one if `a` is positive or negative infinity, zero otherwise
*   a = register holding the value to check
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&setIfInfinityF32, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!float(env.memory.ptr, Registers.t(0)) = -float.infinity;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 1);
* ---
*/
void* setIfInfinityF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = floatIsInfinity(floatRegister!float(registers, pc.a));
	mixin(mizuNext);
}

/**
* Checks if an `f32` register is nan.
*
* Params:
*   out_ = register set to one if `a` is nan, zero otherwise
*   a = register holding the value to check
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&setIfNanF32, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!float(env.memory.ptr, Registers.t(0)) = float.nan;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 1);
* ---
*/
void* setIfNanF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = floatIsNan(floatRegister!float(registers, pc.a));
	mixin(mizuNext);
}
