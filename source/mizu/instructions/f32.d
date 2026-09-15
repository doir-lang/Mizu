/**
* 32 bit floating point instructions.
*
* Mizu registers are raw 64 bit blobs, so a "float register" is just a
* register whose bits are being read as an `f32`. Convert with
* `convertToF32`/`convertFromF32` before and after doing float math on a
* value that arrived as an integer.
*/
module mizu.instructions.f32;

import core.stdc.math : sqrtf;

import mizu.opcode;

@nogc nothrow:

/// Reinterprets register `index` as a floating point value of type `F`.
ref F floatRegister(F)(ulong* registers, Reg index) @trusted
if (is(F == float) || is(F == double))
{
	return *cast(F*)&registers[index];
}

/// True if `value`'s sign bit is set (including for `-0.0` and `-nan`).
bool floatSignBit(float value) @trusted {
	return (*cast(const uint*)&value >> 31) != 0;
}

/// Ditto
bool floatSignBit(double value) @trusted {
	return (*cast(const ulong*)&value >> 63) != 0;
}

/// True if `value` is a quiet or signalling nan.
bool floatIsNan(float value) @trusted {
	immutable bits = *cast(const uint*)&value;
	return (bits & 0x7F80_0000) == 0x7F80_0000 && (bits & 0x007F_FFFF) != 0;
}

/// Ditto
bool floatIsNan(double value) @trusted {
	immutable bits = *cast(const ulong*)&value;
	return (bits & 0x7FF0_0000_0000_0000) == 0x7FF0_0000_0000_0000
		&& (bits & 0x000F_FFFF_FFFF_FFFF) != 0;
}

/// True if `value` is positive or negative infinity.
bool floatIsInfinity(float value) @trusted {
	return (*cast(const uint*)&value & 0x7FFF_FFFF) == 0x7F80_0000;
}

/// Ditto
bool floatIsInfinity(double value) @trusted {
	return (*cast(const ulong*)&value & 0x7FFF_FFFF_FFFF_FFFF) == 0x7FF0_0000_0000_0000;
}

extern(C):

/**
* Converts the provided register into a float register.
*
* Params:
*   out_ = register to store the result of the conversion in
*   a = register to convert to an `f32`
*/
void* convertToF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	floatRegister!float(registers, pc.out_) = cast(float) registers[pc.a];
	mixin(mizuNext);
}

/**
* Converts the provided (signed) register into a float register.
*
* Params:
*   out_ = register to store the result of the conversion in
*   a = register to convert to an `f32`
*/
void* convertSignedToF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	floatRegister!float(registers, pc.out_) = cast(float)*cast(long*)&registers[pc.a];
	mixin(mizuNext);
}

/**
* Truncates the provided float register and stores it as an unsigned integer.
*
* Params:
*   out_ = register to store the result of the conversion in
*   a = float register to convert to a `u64`
*/
void* convertFromF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = cast(ulong) floatRegister!float(registers, pc.a);
	mixin(mizuNext);
}

/**
* Truncates the provided float register and stores it as a signed integer.
*
* Params:
*   out_ = register to store the result of the conversion in
*   a = float register to convert to an `i64`
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
*/
void* addF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	floatRegister!float(registers, pc.out_) =
		floatRegister!float(registers, pc.a) + floatRegister!float(registers, pc.b);
	mixin(mizuNext);
}

/**
* Subtracts two `f32` numbers.
*
* Params:
*   out_ = register to store `a - b` in
*   a = register holding the first value
*   b = register holding the second value
*/
void* subtractF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	floatRegister!float(registers, pc.out_) =
		floatRegister!float(registers, pc.a) - floatRegister!float(registers, pc.b);
	mixin(mizuNext);
}

/**
* Multiplies two `f32` numbers.
*
* Params:
*   out_ = register to store `a * b` in
*   a = register holding the first value
*   b = register holding the second value
*/
void* multiplyF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	floatRegister!float(registers, pc.out_) =
		floatRegister!float(registers, pc.a) * floatRegister!float(registers, pc.b);
	mixin(mizuNext);
}

/**
* Divides two `f32` numbers.
*
* Params:
*   out_ = register to store `a / b` in
*   a = register holding the first value
*   b = register holding the second value
*/
void* divideF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	floatRegister!float(registers, pc.out_) =
		floatRegister!float(registers, pc.a) / floatRegister!float(registers, pc.b);
	mixin(mizuNext);
}

/**
* Finds the larger of two `f32` numbers.
*
* Params:
*   out_ = register to store `max(a, b)` in
*   a = register holding the first value
*   b = register holding the second value
*/
void* maxF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	immutable x = floatRegister!float(registers, pc.a);
	immutable y = floatRegister!float(registers, pc.b);
	floatRegister!float(registers, pc.out_) = x < y ? y : x;
	mixin(mizuNext);
}

/**
* Finds the smaller of two `f32` numbers.
*
* Params:
*   out_ = register to store `min(a, b)` in
*   a = register holding the first value
*   b = register holding the second value
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
*/
void* setIfGreaterEqualF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = floatRegister!float(registers, pc.a) >= floatRegister!float(registers, pc.b);
	mixin(mizuNext);
}

/**
* Checks if an `f32` register is negative.
*
* Params:
*   out_ = register set to one if `a`'s sign bit is set, zero otherwise
*   a = register holding the value to check
*/
void* setIfNegativeF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = floatSignBit(floatRegister!float(registers, pc.a));
	mixin(mizuNext);
}

/**
* Checks if an `f32` register is positive.
*
* Params:
*   out_ = register set to one if `a`'s sign bit is clear, zero otherwise
*   a = register holding the value to check
*/
void* setIfPositiveF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = !floatSignBit(floatRegister!float(registers, pc.a));
	mixin(mizuNext);
}

/**
* Checks if an `f32` register is an infinity.
*
* Params:
*   out_ = register set to one if `a` is +/- infinity, zero otherwise
*   a = register holding the value to check
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
*/
void* setIfNanF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = floatIsNan(floatRegister!float(registers, pc.a));
	mixin(mizuNext);
}
