/**
* Instructions that reach outside Mizu's sandbox: host heap allocation, raw
* pointers into the VM's own memory, and unchecked `memcpy`/`memset`.
*
* Nothing here is validated. A Mizu program that gets one of these wrong can
* corrupt the host process.
*/
module mizu.instructions.unsafe;

import core.stdc.stdlib : cMalloc = malloc, cFree = free;
import core.stdc.string : memcpy, memset;

import fp.pointer : fpMalloc = malloc, fpFree = free;

import mizu.opcode;

@nogc nothrow extern(C):

/**
* Allocates new memory on the host application heap.
*
* Params:
*   out_ = register a pointer to the allocated memory is stored in
*   a = register holding how many bytes to allocate
*/
void* allocate(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = cast(size_t) cMalloc(registers[pc.a]);
	mixin(mizuNext);
}

/**
* Frees an allocation made by `allocate`.
*
* Params:
*   a = register holding the allocation to free
*   b = register holding a value to overwrite `a` with (defaults to zero)
*/
void* freeAllocated(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	cFree(cast(void*) registers[pc.a]);
	registers[pc.a] = registers[pc.b];
	mixin(mizuNext);
}

/**
* Allocates new memory on the host application heap as a libfp fat pointer,
* so the allocation remembers how large it is.
*
* Params:
*   out_ = register a pointer to the allocated memory is stored in
*   a = register holding the size of each element
*   b = register holding how many elements there are
*
* Note: the total size of the allocation is `a * b`.
*
* Note:
*   The C++ original recorded the fat pointer's length as the $(I element)
*   count, because it could reach the internal `__fp_realloc(p, size, n)`.
*   libfp's D API only exposes element-size-as-a-template-parameter
*   allocation, so the length recorded here is the total size in $(I bytes).
*   The two agree whenever the element size is one.
*/
void* allocateFatPointer(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = cast(size_t) fpMalloc!ubyte(registers[pc.a] * registers[pc.b]);
	mixin(mizuNext);
}

/**
* Frees an allocation made by `allocateFatPointer`.
*
* Params:
*   a = register holding the allocation to free
*   b = register holding a value to overwrite `a` with (defaults to zero)
*/
void* freeFatPointer(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	fpFree(cast(const(ubyte)*) registers[pc.a]);
	registers[pc.a] = registers[pc.b];
	mixin(mizuNext);
}

/**
* Generates a pointer to memory on Mizu's stack.
*
* Params:
*   out_ = register to store the pointer in
*   a = register holding a signed offset from the current stack pointer
*/
void* pointerToStack(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	immutable offset = *cast(long*)&registers[pc.a];
	registers[pc.out_] = cast(size_t)(sp + offset);
	mixin(mizuNext);
}

/**
* Generates a pointer to memory at the bottom of Mizu's stack.
*
* Params:
*   out_ = register to store the pointer in
*   a = register holding a signed offset from the bottom of the stack
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
*   a = register to take a pointer to
*/
void* pointerToRegister(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	registers[pc.out_] = cast(size_t)(registers + pc.a);
	mixin(mizuNext);
}

/**
* Copies memory from one pointer to another.
*
* Params:
*   out_ = register holding the pointer data should be copied to
*   a = register holding the pointer data should be copied from
*   b = register holding how many bytes to copy
*/
void* copyMemory(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	memcpy(cast(void*) registers[pc.out_], cast(const(void)*) registers[pc.a], registers[pc.b]);
	mixin(mizuNext);
}

/**
* Copies memory from one pointer to another.
*
* Params:
*   out_ = register holding the pointer data should be copied to
*   a = register holding the pointer data should be copied from
*   b = branch immediate holding how many bytes to copy
*/
void* copyMemoryImmediate(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	memcpy(cast(void*) registers[pc.out_], cast(const(void)*) registers[pc.a], pc.b);
	mixin(mizuNext);
}

/**
* Sets all of the given memory to the provided byte.
*
* Params:
*   out_ = register holding a pointer to the memory to overwrite
*   a = register holding the `u8` to overwrite it with
*   b = register holding how many bytes to overwrite
*/
void* setMemory(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	memset(cast(void*) registers[pc.out_], cast(int) registers[pc.a], registers[pc.b]);
	mixin(mizuNext);
}

/**
* Sets all of the given memory to the provided byte.
*
* Params:
*   out_ = register holding a pointer to the memory to overwrite
*   a = register holding the `u8` to overwrite it with
*   b = branch immediate holding how many bytes to overwrite
*/
void* setMemoryImmediate(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	memset(cast(void*) registers[pc.out_], cast(int) registers[pc.a], pc.b);
	mixin(mizuNext);
}
