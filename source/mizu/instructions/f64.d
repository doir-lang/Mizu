/**
* 64 bit floating point instructions.
*
* The mirror image of `mizu.instructions.f32`, plus the two instructions that
* move a value between the two widths.
*/
module mizu.instructions.f64;

import core.stdc.math : sqrt;

import mizu.opcode;
import mizu.instructions.f32 : floatRegister, floatSignBit, floatIsNan, floatIsInfinity;

@nogc nothrow extern(C):

/**
* Converts the provided `f32` register to an `f64` register.
*
* Params:
*   out_ = register to store the `f64` result in
*   a = register holding the `f32` to convert
*/
void* convertF32ToF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	floatRegister!double(registers, pc.out_) = floatRegister!float(registers, pc.a);
	mixin(mizuNext);
}

/**
* Converts the provided `f64` register to an `f32` register.
*
* Params:
*   out_ = register to store the `f32` result in
*   a = register holding the `f64` to convert
*/
void* convertF64ToF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	floatRegister!float(registers, pc.out_) = cast(float) floatRegister!double(registers, pc.a);
	mixin(mizuNext);
}


/**
* Converts the provided register into a float register.
*
* Params:
*   out_ = register to store the result of the conversion in
*   a = register to convert to an `f64`
*/
void* convertToF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	floatRegister!double(registers, pc.out_) = cast(double) registers[pc.a];
	mixin(mizuNext);
}

/**
* Converts the provided (signed) register into a float register.
*
* Params:
*   out_ = register to store the result of the conversion in
*   a = register to convert to an `f64`
*/
void* convertSignedToF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	floatRegister!double(registers, pc.out_) = cast(double)*cast(long*)&registers[pc.a];
	mixin(mizuNext);
}

/**
* Truncates the provided float register and stores it as an unsigned integer.
*
* Params:
*   out_ = register to store the result of the conversion in
*   a = float register to convert to a `u64`
*/
void* convertFromF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = cast(ulong) floatRegister!double(registers, pc.a);
	mixin(mizuNext);
}

/**
* Truncates the provided float register and stores it as a signed integer.
*
* Params:
*   out_ = register to store the result of the conversion in
*   a = float register to convert to an `i64`
*/
void* convertSignedFromF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	*cast(long*)&registers[pc.out_] = cast(long) floatRegister!double(registers, pc.a);
	mixin(mizuNext);
}

/**
* Adds two `f64` numbers.
*
* Params:
*   out_ = register to store `a + b` in
*   a = register holding the first value
*   b = register holding the second value
*/
void* addF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	floatRegister!double(registers, pc.out_) =
		floatRegister!double(registers, pc.a) + floatRegister!double(registers, pc.b);
	mixin(mizuNext);
}

/**
* Subtracts two `f64` numbers.
*
* Params:
*   out_ = register to store `a - b` in
*   a = register holding the first value
*   b = register holding the second value
*/
void* subtractF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	floatRegister!double(registers, pc.out_) =
		floatRegister!double(registers, pc.a) - floatRegister!double(registers, pc.b);
	mixin(mizuNext);
}

/**
* Multiplies two `f64` numbers.
*
* Params:
*   out_ = register to store `a * b` in
*   a = register holding the first value
*   b = register holding the second value
*/
void* multiplyF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	floatRegister!double(registers, pc.out_) =
		floatRegister!double(registers, pc.a) * floatRegister!double(registers, pc.b);
	mixin(mizuNext);
}

/**
* Divides two `f64` numbers.
*
* Params:
*   out_ = register to store `a / b` in
*   a = register holding the first value
*   b = register holding the second value
*/
void* divideF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	floatRegister!double(registers, pc.out_) =
		floatRegister!double(registers, pc.a) / floatRegister!double(registers, pc.b);
	mixin(mizuNext);
}

/**
* Finds the larger of two `f64` numbers.
*
* Params:
*   out_ = register to store `max(a, b)` in
*   a = register holding the first value
*   b = register holding the second value
*/
void* maxF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	immutable x = floatRegister!double(registers, pc.a);
	immutable y = floatRegister!double(registers, pc.b);
	floatRegister!double(registers, pc.out_) = x < y ? y : x;
	mixin(mizuNext);
}

/**
* Finds the smaller of two `f64` numbers.
*
* Params:
*   out_ = register to store `min(a, b)` in
*   a = register holding the first value
*   b = register holding the second value
*/
void* minF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	immutable x = floatRegister!double(registers, pc.a);
	immutable y = floatRegister!double(registers, pc.b);
	floatRegister!double(registers, pc.out_) = y < x ? y : x;
	mixin(mizuNext);
}

/**
* Finds the square root of an `f64` number.
*
* Params:
*   out_ = register to store `sqrt(a)` in
*   a = register holding the value
*/
void* sqrtF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	floatRegister!double(registers, pc.out_) = sqrt(floatRegister!double(registers, pc.a));
	mixin(mizuNext);
}

/**
* Checks if two `f64` registers are equal.
*
* Params:
*   out_ = register set to one if `a == b`, zero otherwise
*   a = register holding the first value to compare
*   b = register holding the second value to compare
*/
void* setIfEqualF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = floatRegister!double(registers, pc.a) == floatRegister!double(registers, pc.b);
	mixin(mizuNext);
}

/**
* Checks if two `f64` registers are not equal.
*
* Params:
*   out_ = register set to one if `a != b`, zero otherwise
*   a = register holding the first value to compare
*   b = register holding the second value to compare
*/
void* setIfNotEqualF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = floatRegister!double(registers, pc.a) != floatRegister!double(registers, pc.b);
	mixin(mizuNext);
}

/**
* Checks if one `f64` register is less than another.
*
* Params:
*   out_ = register set to one if `a < b`, zero otherwise
*   a = register holding the first value to compare
*   b = register holding the second value to compare
*/
void* setIfLessF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = floatRegister!double(registers, pc.a) < floatRegister!double(registers, pc.b);
	mixin(mizuNext);
}

/**
* Checks if one `f64` register is greater than or equal to another.
*
* Params:
*   out_ = register set to one if `a >= b`, zero otherwise
*   a = register holding the first value to compare
*   b = register holding the second value to compare
*/
void* setIfGreaterEqualF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = floatRegister!double(registers, pc.a) >= floatRegister!double(registers, pc.b);
	mixin(mizuNext);
}

/**
* Checks if an `f64` register is negative.
*
* Params:
*   out_ = register set to one if `a`'s sign bit is set, zero otherwise
*   a = register holding the value to check
*/
void* setIfNegativeF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = floatSignBit(floatRegister!double(registers, pc.a));
	mixin(mizuNext);
}

/**
* Checks if an `f64` register is positive.
*
* Params:
*   out_ = register set to one if `a`'s sign bit is clear, zero otherwise
*   a = register holding the value to check
*/
void* setIfPositiveF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = !floatSignBit(floatRegister!double(registers, pc.a));
	mixin(mizuNext);
}

/**
* Checks if an `f64` register is an infinity.
*
* Params:
*   out_ = register set to one if `a` is +/- infinity, zero otherwise
*   a = register holding the value to check
*/
void* setIfInfinityF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = floatIsInfinity(floatRegister!double(registers, pc.a));
	mixin(mizuNext);
}

/**
* Checks if an `f64` register is nan.
*
* Params:
*   out_ = register set to one if `a` is nan, zero otherwise
*   a = register holding the value to check
*/
void* setIfNanF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = floatIsNan(floatRegister!double(registers, pc.a));
	mixin(mizuNext);
}
