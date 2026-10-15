/**
* Hand-written `extern(C)` bindings for the small slice of $(LINK2 https://github.com/libffi/libffi, libffi) that Mizu needs, keeping libffi's own names.
*
* Two things in `<ffi.h>` do not translate mechanically:
*
* $(UL
*   $(LI `ffi_cif` ends with an arch-specific `FFI_EXTRA_CIF_FIELDS` macro, so its size is not knowable from D. Mizu never declares one; it hands libffi `cifStorageBytes` of aligned scratch space, generous against the 40-56 bytes it takes on every supported target.)
*   $(LI `FFI_DEFAULT_ABI` differs per target, so `defaultAbi` reproduces the values from `ffitarget.h`, and an unknown target fails to compile rather than passing a wrong ABI.))
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

// FFI_DEFAULT_ABI per target, from `ffitarget.h`.
version(X86_64) {
	version(Win64) {
		version(GNU) private enum uint targetAbi = 2; // FFI_GNUW64
		else private enum uint targetAbi = 1; // FFI_WIN64
	} else private enum uint targetAbi = 2; // FFI_UNIX64
} else version(X86) {
	version(Windows) private enum uint targetAbi = 5; // FFI_MS_CDECL
	else private enum uint targetAbi = 1; // FFI_SYSV
} else version(AArch64) {
	private enum uint targetAbi = 1; // FFI_SYSV
} else version(ARM) {
	version(ARM_HardFloat) private enum uint targetAbi = 2; // FFI_VFP
	else private enum uint targetAbi = 1; // FFI_SYSV
} else version(RISCV64) {
	private enum uint targetAbi = 1; // FFI_SYSV
} else {
	static assert(0, "mizu.ffi.libffi does not know FFI_DEFAULT_ABI for this target. Add it from your libffi's ffitarget.h, or build with -version=MizuNoFFI.");
}

/// The calling convention libffi should assume, `FFI_DEFAULT_ABI` for the target.
enum uint defaultAbi = targetAbi;

/// How much scratch space Mizu reserves for one `ffi_cif`; see the module documentation for why this is a byte count rather than a struct.
enum size_t cifStorageBytes = 256;

extern(C) {
	/**
	* Prepares a call interface in `cif`, at least `cifStorageBytes` wide and 16 byte aligned, returning `FFI_OK` or why it could not.
	*
	* Examples:
	* ---
	* align(16) ubyte[cifStorageBytes] cif;
	* ffi_type*[1] arguments = [&ffi_type_sint32];
	* assert(ffi_prep_cif(cif.ptr, defaultAbi, 1, &ffi_type_sint32, arguments.ptr) == ffi_status.FFI_OK);
	* ---
	*/
	ffi_status ffi_prep_cif(void* cif, uint abi, uint nargs, ffi_type* rtype, ffi_type** atypes);
	/**
	* Calls `fn` through a prepared `cif`, reading the arguments through the pointers in `avalue` and storing the result, widened to at least 8 bytes, in `rvalue`.
	*
	* Examples:
	* ---
	* import core.stdc.stdlib : abs;
	* align(16) ubyte[cifStorageBytes] cif;
	* ffi_type*[1] arguments = [&ffi_type_sint32];
	* assert(ffi_prep_cif(cif.ptr, defaultAbi, 1, &ffi_type_sint32, arguments.ptr) == ffi_status.FFI_OK);
	* int value = -42;
	* void*[1] values = [&value];
	* long result;
	* ffi_call(cif.ptr, cast(void*) &abs, &result, values.ptr);
	* assert(cast(int) result == 42);
	* ---
	*/
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
