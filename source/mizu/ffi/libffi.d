/**
* Hand-written `extern(C)` bindings for the small slice of
* $(LINK2 https://github.com/libffi/libffi, libffi) that Mizu needs.
*
* The C++ original `#include`d `<ffi.h>`; D has to declare these itself. Two
* things in that header do not translate mechanically:
*
* $(UL
*   $(LI `ffi_cif` ends with an arch-specific `FFI_EXTRA_CIF_FIELDS` macro,
*        so its size is not knowable from D. Mizu therefore never declares a
*        `ffi_cif` — it hands libffi `cifStorageBytes` of suitably aligned
*        scratch space and treats the contents as opaque. The struct is
*        roughly 40-56 bytes on every supported target, so the reserve is
*        generous.)
*   $(LI `FFI_DEFAULT_ABI` is an enumerator whose value differs per target,
*        so `defaultAbi` reproduces the per-target values from `ffitarget.h`.
*        Unsupported targets fail to compile rather than silently passing a
*        wrong ABI.))
*/
module mizu.ffi.libffi;

@nogc nothrow:

/// A libffi type descriptor.
struct ffi_type {
	size_t size;
	ushort alignment;
	ushort type;
	ffi_type** elements;
}

/// libffi's result codes.
enum ffi_status {
	FFI_OK = 0,
	FFI_BAD_TYPEDEF,
	FFI_BAD_ABI,
	FFI_BAD_ARGTYPE,
}

/// The calling convention libffi should assume, from `ffitarget.h`.
version(X86_64) {
	version(Win64) {
		version(GNU) enum uint defaultAbi = 2;  // FFI_GNUW64
		else enum uint defaultAbi = 1;          // FFI_WIN64
	} else enum uint defaultAbi = 2;            // FFI_UNIX64
} else version(X86) {
	version(Windows) enum uint defaultAbi = 5;  // FFI_MS_CDECL
	else enum uint defaultAbi = 1;              // FFI_SYSV
} else version(AArch64) {
	enum uint defaultAbi = 1;                   // FFI_SYSV
} else version(ARM) {
	version(ARM_HardFloat) enum uint defaultAbi = 2; // FFI_VFP
	else enum uint defaultAbi = 1;              // FFI_SYSV
} else version(RISCV64) {
	enum uint defaultAbi = 1;                   // FFI_SYSV
} else {
	static assert(0, "mizu.ffi.libffi does not know FFI_DEFAULT_ABI for this "
		~ "target. Add it from your libffi's ffitarget.h, or build with "
		~ "-version=MizuNoFFI.");
}

/**
* How much scratch space Mizu reserves for one `ffi_cif`.
*
* See the module documentation for why this is a byte count rather than a
* struct.
*/
enum size_t cifStorageBytes = 256;

extern(C) {
	/// Prepares a call interface in `cif` (at least `cifStorageBytes` wide).
	ffi_status ffi_prep_cif(void* cif, uint abi, uint nargs, ffi_type* rtype, ffi_type** atypes);
	/// Calls `fn` through a prepared `cif`.
	void ffi_call(void* cif, void* fn, void* rvalue, void** avalue);

	/// The type descriptors Mizu's `pushType*` instructions push.
	extern __gshared ffi_type ffi_type_void;
	/// Ditto
	extern __gshared ffi_type ffi_type_uint8;
	/// Ditto
	extern __gshared ffi_type ffi_type_sint8;
	/// Ditto
	extern __gshared ffi_type ffi_type_uint16;
	/// Ditto
	extern __gshared ffi_type ffi_type_sint16;
	/// Ditto
	extern __gshared ffi_type ffi_type_uint32;
	/// Ditto
	extern __gshared ffi_type ffi_type_sint32;
	/// Ditto
	extern __gshared ffi_type ffi_type_uint64;
	/// Ditto
	extern __gshared ffi_type ffi_type_sint64;
	/// Ditto
	extern __gshared ffi_type ffi_type_float;
	/// Ditto
	extern __gshared ffi_type ffi_type_double;
	/// Ditto
	extern __gshared ffi_type ffi_type_pointer;
}
