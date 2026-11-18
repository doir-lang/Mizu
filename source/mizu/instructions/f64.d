/**
* 64 bit floating point instructions.
*
* The mirror image of `mizu.instructions.f32`, plus the two instructions that move a value between the two widths.
*/
module mizu.instructions.f64;

static import core.math;

import mizu.opcode;
static import mizu.instructions.f32;

@nogc nothrow extern(C):

/**
* Widens an `f32` register to `f64`.
*
* Params:
*   out_ = register to store the `f64` in
*   a = register holding the `f32` to convert
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&convertF32ToF64, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!float(env.memory.ptr, Registers.t(0)) = 1.5f;
* cast(void) startFromEnvironment(program[], env);
* assert(floatRegister!double(env.memory.ptr, Registers.t(1)) == 1.5);
* ---
*/
void* convertF32ToF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	mizu.instructions.f32.floatRegister!double(registers, pc.out_) = mizu.instructions.f32.floatRegister!float(registers, pc.a);
	mixin(nextInstruction);
}

/**
* Narrows an `f64` register to `f32`, rounding it.
*
* Params:
*   out_ = register whose low 32 bits are overwritten with the `f32`
*   a = register holding the `f64` to convert
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&convertF64ToF32, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!double(env.memory.ptr, Registers.t(0)) = 1.5;
* cast(void) startFromEnvironment(program[], env);
* assert(floatRegister!float(env.memory.ptr, Registers.t(1)) == 1.5f);
* ---
*/
void* convertF64ToF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	mizu.instructions.f32.floatRegister!float(registers, pc.out_) = cast(float) mizu.instructions.f32.floatRegister!double(registers, pc.a);
	mixin(nextInstruction);
}

/**
* Converts an unsigned integer register to `f64`.
*
* Params:
*   out_ = register to store the `f64` in
*   a = register holding the `u64` to convert
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&convertToF64, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = 42;
* cast(void) startFromEnvironment(program[], env);
* assert(floatRegister!double(env.memory.ptr, Registers.t(1)) == 42);
* ---
*/
void* convertToF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	assert(mizu.opcode.registersValid!("a")(*pc), "mizu: a register index past registerCount");
	mizu.instructions.f32.floatRegister!double(registers, pc.out_) = cast(double) registers[pc.a];
	mixin(nextInstruction);
}

/**
* Converts a signed integer register to `f64`.
*
* Params:
*   out_ = register to store the `f64` in
*   a = register holding the `i64` to convert
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&convertSignedToF64, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = -42;
* cast(void) startFromEnvironment(program[], env);
* assert(floatRegister!double(env.memory.ptr, Registers.t(1)) == -42);
* ---
*/
void* convertSignedToF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	assert(mizu.opcode.registersValid!("a")(*pc), "mizu: a register index past registerCount");
	mizu.instructions.f32.floatRegister!double(registers, pc.out_) = cast(double)*cast(long*)&registers[pc.a];
	mixin(nextInstruction);
}

/**
* Truncates an `f64` register to an unsigned integer.
*
* Params:
*   out_ = register to store the `u64` in
*   a = register holding the `f64` to convert
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&convertFromF64, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!double(env.memory.ptr, Registers.t(0)) = 42.75;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 42);
* ---
*/
void* convertFromF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	assert(mizu.opcode.registersValid!("out_")(*pc), "mizu: a register index past registerCount");
	registers[pc.out_] = cast(ulong) mizu.instructions.f32.floatRegister!double(registers, pc.a);
	mixin(nextInstruction);
}

/**
* Truncates an `f64` register to a signed integer.
*
* Params:
*   out_ = register to store the `i64` in
*   a = register holding the `f64` to convert
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&convertSignedFromF64, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!double(env.memory.ptr, Registers.t(0)) = -42.75;
* cast(void) startFromEnvironment(program[], env);
* assert(cast(long) env.memory[Registers.t(1)] == -42);
* ---
*/
void* convertSignedFromF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	assert(mizu.opcode.registersValid!("out_")(*pc), "mizu: a register index past registerCount");
	*cast(long*)&registers[pc.out_] = cast(long) mizu.instructions.f32.floatRegister!double(registers, pc.a);
	mixin(nextInstruction);
}

/**
* Adds two `f64` numbers.
*
* Params:
*   out_ = register to store `a + b` in
*   a = register holding the first value
*   b = register holding the second value
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&addF64, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!double(env.memory.ptr, Registers.t(0)) = 40.5;
* floatRegister!double(env.memory.ptr, Registers.t(1)) = 1.5;
* cast(void) startFromEnvironment(program[], env);
* assert(floatRegister!double(env.memory.ptr, Registers.t(2)) == 42);
* ---
*/
void* addF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	mizu.instructions.f32.floatRegister!double(registers, pc.out_) = mizu.instructions.f32.floatRegister!double(registers, pc.a) + mizu.instructions.f32.floatRegister!double(registers, pc.b);
	mixin(nextInstruction);
}

/**
* Subtracts two `f64` numbers.
*
* Params:
*   out_ = register to store `a - b` in
*   a = register holding the first value
*   b = register holding the second value
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&subtractF64, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!double(env.memory.ptr, Registers.t(0)) = 43.5;
* floatRegister!double(env.memory.ptr, Registers.t(1)) = 1.5;
* cast(void) startFromEnvironment(program[], env);
* assert(floatRegister!double(env.memory.ptr, Registers.t(2)) == 42);
* ---
*/
void* subtractF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	mizu.instructions.f32.floatRegister!double(registers, pc.out_) = mizu.instructions.f32.floatRegister!double(registers, pc.a) - mizu.instructions.f32.floatRegister!double(registers, pc.b);
	mixin(nextInstruction);
}

/**
* Multiplies two `f64` numbers.
*
* Params:
*   out_ = register to store `a * b` in
*   a = register holding the first value
*   b = register holding the second value
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&multiplyF64, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!double(env.memory.ptr, Registers.t(0)) = 10.5;
* floatRegister!double(env.memory.ptr, Registers.t(1)) = 4;
* cast(void) startFromEnvironment(program[], env);
* assert(floatRegister!double(env.memory.ptr, Registers.t(2)) == 42);
* ---
*/
void* multiplyF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	mizu.instructions.f32.floatRegister!double(registers, pc.out_) = mizu.instructions.f32.floatRegister!double(registers, pc.a) * mizu.instructions.f32.floatRegister!double(registers, pc.b);
	mixin(nextInstruction);
}

/**
* Divides two `f64` numbers.
*
* Params:
*   out_ = register to store `a / b` in
*   a = register holding the first value
*   b = register holding the second value
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&divideF64, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!double(env.memory.ptr, Registers.t(0)) = 84;
* floatRegister!double(env.memory.ptr, Registers.t(1)) = 2;
* cast(void) startFromEnvironment(program[], env);
* assert(floatRegister!double(env.memory.ptr, Registers.t(2)) == 42);
* ---
*/
void* divideF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	mizu.instructions.f32.floatRegister!double(registers, pc.out_) = mizu.instructions.f32.floatRegister!double(registers, pc.a) / mizu.instructions.f32.floatRegister!double(registers, pc.b);
	mixin(nextInstruction);
}

/**
* Finds the larger of two `f64` numbers; if either is nan, the result is `a`.
*
* Params:
*   out_ = register to store `max(a, b)` in
*   a = register holding the first value
*   b = register holding the second value
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&maxF64, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!double(env.memory.ptr, Registers.t(0)) = -1;
* floatRegister!double(env.memory.ptr, Registers.t(1)) = 42;
* cast(void) startFromEnvironment(program[], env);
* assert(floatRegister!double(env.memory.ptr, Registers.t(2)) == 42);
* ---
*/
void* maxF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	immutable x = mizu.instructions.f32.floatRegister!double(registers, pc.a);
	immutable y = mizu.instructions.f32.floatRegister!double(registers, pc.b);
	mizu.instructions.f32.floatRegister!double(registers, pc.out_) = x < y ? y : x;
	mixin(nextInstruction);
}

/**
* Finds the smaller of two `f64` numbers; if either is nan, the result is `a`.
*
* Params:
*   out_ = register to store `min(a, b)` in
*   a = register holding the first value
*   b = register holding the second value
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&minF64, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!double(env.memory.ptr, Registers.t(0)) = 42;
* floatRegister!double(env.memory.ptr, Registers.t(1)) = 100;
* cast(void) startFromEnvironment(program[], env);
* assert(floatRegister!double(env.memory.ptr, Registers.t(2)) == 42);
* ---
*/
void* minF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	immutable x = mizu.instructions.f32.floatRegister!double(registers, pc.a);
	immutable y = mizu.instructions.f32.floatRegister!double(registers, pc.b);
	mizu.instructions.f32.floatRegister!double(registers, pc.out_) = y < x ? y : x;
	mixin(nextInstruction);
}

/**
* Finds the square root of an `f64` number.
*
* Params:
*   out_ = register to store `sqrt(a)` in
*   a = register holding the value
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&squareRootF64, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!double(env.memory.ptr, Registers.t(0)) = 1764;
* cast(void) startFromEnvironment(program[], env);
* assert(floatRegister!double(env.memory.ptr, Registers.t(1)) == 42);
* ---
*/
void* squareRootF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	mizu.instructions.f32.floatRegister!double(registers, pc.out_) = core.math.sqrt(mizu.instructions.f32.floatRegister!double(registers, pc.a));
	mixin(nextInstruction);
}

/**
* Checks if two `f64` registers are equal.
*
* Params:
*   out_ = register set to one if `a == b`, zero otherwise
*   a = register holding the first value to compare
*   b = register holding the second value to compare
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&setIfEqualF64, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!double(env.memory.ptr, Registers.t(0)) = 1.5;
* floatRegister!double(env.memory.ptr, Registers.t(1)) = 1.5;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 1);
* ---
*/
void* setIfEqualF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	assert(mizu.opcode.registersValid!("out_")(*pc), "mizu: a register index past registerCount");
	registers[pc.out_] = mizu.instructions.f32.floatRegister!double(registers, pc.a) == mizu.instructions.f32.floatRegister!double(registers, pc.b);
	mixin(nextInstruction);
}

/**
* Checks if two `f64` registers are not equal.
*
* Params:
*   out_ = register set to one if `a != b`, zero otherwise
*   a = register holding the first value to compare
*   b = register holding the second value to compare
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&setIfNotEqualF64, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!double(env.memory.ptr, Registers.t(0)) = 1.5;
* floatRegister!double(env.memory.ptr, Registers.t(1)) = 2.5;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 1);
* ---
*/
void* setIfNotEqualF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	assert(mizu.opcode.registersValid!("out_")(*pc), "mizu: a register index past registerCount");
	registers[pc.out_] = mizu.instructions.f32.floatRegister!double(registers, pc.a) != mizu.instructions.f32.floatRegister!double(registers, pc.b);
	mixin(nextInstruction);
}

/**
* Checks if one `f64` register is less than another.
*
* Params:
*   out_ = register set to one if `a < b`, zero otherwise
*   a = register holding the first value to compare
*   b = register holding the second value to compare
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&setIfLessF64, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!double(env.memory.ptr, Registers.t(0)) = -1.5;
* floatRegister!double(env.memory.ptr, Registers.t(1)) = 1.5;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 1);
* ---
*/
void* setIfLessF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	assert(mizu.opcode.registersValid!("out_")(*pc), "mizu: a register index past registerCount");
	registers[pc.out_] = mizu.instructions.f32.floatRegister!double(registers, pc.a) < mizu.instructions.f32.floatRegister!double(registers, pc.b);
	mixin(nextInstruction);
}

/**
* Checks if one `f64` register is greater than or equal to another.
*
* Params:
*   out_ = register set to one if `a >= b`, zero otherwise
*   a = register holding the first value to compare
*   b = register holding the second value to compare
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&setIfGreaterEqualF64, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!double(env.memory.ptr, Registers.t(0)) = 1.5;
* floatRegister!double(env.memory.ptr, Registers.t(1)) = 1.5;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 1);
* ---
*/
void* setIfGreaterEqualF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	assert(mizu.opcode.registersValid!("out_")(*pc), "mizu: a register index past registerCount");
	registers[pc.out_] = mizu.instructions.f32.floatRegister!double(registers, pc.a) >= mizu.instructions.f32.floatRegister!double(registers, pc.b);
	mixin(nextInstruction);
}

/**
* Checks if an `f64` register is negative.
*
* Params:
*   out_ = register set to one if `a`'s sign bit is set, as for `-0.0`, zero otherwise
*   a = register holding the value to check
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&setIfNegativeF64, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!double(env.memory.ptr, Registers.t(0)) = -0.0;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 1);
* ---
*/
void* setIfNegativeF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	assert(mizu.opcode.registersValid!("out_")(*pc), "mizu: a register index past registerCount");
	registers[pc.out_] = mizu.instructions.f32.floatSignBit(mizu.instructions.f32.floatRegister!double(registers, pc.a));
	mixin(nextInstruction);
}

/**
* Checks if an `f64` register is positive.
*
* Params:
*   out_ = register set to one if `a`'s sign bit is clear, as for `0.0`, zero otherwise
*   a = register holding the value to check
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&setIfPositiveF64, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!double(env.memory.ptr, Registers.t(0)) = 0.0;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 1);
* ---
*/
void* setIfPositiveF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	assert(mizu.opcode.registersValid!("out_")(*pc), "mizu: a register index past registerCount");
	registers[pc.out_] = !mizu.instructions.f32.floatSignBit(mizu.instructions.f32.floatRegister!double(registers, pc.a));
	mixin(nextInstruction);
}

/**
* Checks if an `f64` register is an infinity.
*
* Params:
*   out_ = register set to one if `a` is positive or negative infinity, zero otherwise
*   a = register holding the value to check
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&setIfInfiniteF64, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!double(env.memory.ptr, Registers.t(0)) = -double.infinity;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 1);
* ---
*/
void* setIfInfiniteF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	assert(mizu.opcode.registersValid!("out_")(*pc), "mizu: a register index past registerCount");
	registers[pc.out_] = mizu.instructions.f32.floatIsInfinite(mizu.instructions.f32.floatRegister!double(registers, pc.a));
	mixin(nextInstruction);
}

/**
* Checks if an `f64` register is nan.
*
* Params:
*   out_ = register set to one if `a` is nan, zero otherwise
*   a = register holding the value to check
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&setIfNanF64, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* floatRegister!double(env.memory.ptr, Registers.t(0)) = double.nan;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 1);
* ---
*/
void* setIfNanF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	assert(mizu.opcode.registersValid!("out_")(*pc), "mizu: a register index past registerCount");
	registers[pc.out_] = mizu.instructions.f32.floatIsNan(mizu.instructions.f32.floatRegister!double(registers, pc.a));
	mixin(nextInstruction);
}
