/**
* A Mizu program that opens a window and draws a triangle, without a single
* line of D doing any of the work: GLFW is `dlopen`ed, every entry point is
* resolved by name, and each call goes out through `mizu.ffi`.
*
* The interesting part is that Mizu never links against GLFW or OpenGL. The
* host executable knows nothing about either one — the running Mizu program
* describes each signature with the `pushType*` instructions, turns it into an
* interface, and calls the resolved pointer with `ffi.call`, exactly the way it
* would `jumpTo` one of its own labels.
*
* The triangle itself is drawn with OpenGL 1.1 immediate mode
* (`glBegin`/`glVertex2f`/`glEnd`) rather than a core-profile VAO and shader
* pair. That is not how anyone should write OpenGL today, but this example is
* about the FFI and not about OpenGL: immediate mode is seven opcodes per
* vertex, where compiling a shader would bury the FFI under a hundred opcodes
* of string and object juggling. GLFW hands out a compatibility context by
* default, so the legacy entry points are there.
*
* Run with: `dub run -c example-triangle --compiler=ldc2`
*
* Requires GLFW at run time (`libglfw.so.3`, `libglfw.3.dylib`, `glfw3.dll`)
* and a display to open a window on. When either is missing the program says
* so and halts rather than crashing.
*/
module examples.triangle;

import core.stdc.stdio : printf;

import mizu;
import mizu.ffi;

/// How many frames to draw before closing the window on our own.
enum uint frameCount = 240;

/// `GL_COLOR_BUFFER_BIT`, the only bit this example clears.
enum uint GL_COLOR_BUFFER_BIT = 0x0000_4000;
/// `GL_TRIANGLES`, the primitive `glBegin` is asked for.
enum uint GL_TRIANGLES = 0x0004;

/**
* Registers holding the GLFW entry points, plus libc's `puts` for the error
* paths. Mizu has 256 registers and the examples use the high ones as
* globals, so the whole program can refer to a function by a readable name.
*/
enum : Reg {
	pInit = 100,              /// `int glfwInit(void)`
	pCreateWindow,            /// `GLFWwindow* glfwCreateWindow(int, int, const char*, void*, void*)`
	pMakeContextCurrent,      /// `void glfwMakeContextCurrent(GLFWwindow*)`
	pSwapInterval,            /// `void glfwSwapInterval(int)`
	pWindowShouldClose,       /// `int glfwWindowShouldClose(GLFWwindow*)`
	pSwapBuffers,             /// `void glfwSwapBuffers(GLFWwindow*)`
	pPollEvents,              /// `void glfwPollEvents(void)`
	pTerminate,               /// `void glfwTerminate(void)`
	pGetProcAddress,          /// `void* glfwGetProcAddress(const char*)`
	pGetFramebufferSize,      /// `void glfwGetFramebufferSize(GLFWwindow*, int*, int*)`
	pPuts,                    /// `int puts(const char*)`
}

/// Registers holding the OpenGL entry points, resolved via `glfwGetProcAddress`.
enum : Reg {
	pClearColor = 120,        /// `void glClearColor(float, float, float, float)`
	pClear,                   /// `void glClear(uint)`
	pBegin,                   /// `void glBegin(uint)`
	pColor3f,                 /// `void glColor3f(float, float, float)`
	pVertex2f,                /// `void glVertex2f(float, float)`
	pEnd,                     /// `void glEnd(void)`
	pViewport,                /// `void glViewport(i32, i32, i32, i32)`
}

/// Registers holding the interfaces `createInterface` prepares.
enum : Reg {
	ifVoid = 140,             /// `void()`
	ifI32,                    /// `i32()`
	ifVoidPtr,                /// `void(void*)`
	ifI32Ptr,                 /// `i32(void*)`
	ifPtrPtr,                 /// `void*(void*)`
	ifVoidI32,                /// `void(i32)`
	ifCreateWindow,           /// `void*(i32, i32, void*, void*, void*)`
	ifVoidU32,                /// `void(u32)`
	ifVoid4F32,               /// `void(f32, f32, f32, f32)`
	ifVoid3F32,               /// `void(f32, f32, f32)`
	ifVoid2F32,               /// `void(f32, f32)`
	ifVoid3Ptr,               /// `void(void*, void*, void*)`
	ifVoid4I32,               /// `void(i32, i32, i32, i32)`
}

/// Registers holding the program's state.
enum : Reg {
	rLoop = 160,              /// Address of the `draw` label.
	rDone = 161,              /// Address of the `done` label.
	rFail = 162,              /// Address of the `fail` label.
	rLibrary = 163,           /// The `Library*` GLFW was loaded from.
	rWindow = 164,            /// The `GLFWwindow*` being drawn into.
	rFrame = 165,             /// Frames drawn so far.
	rFrameCount = 166,        /// `frameCount`, to compare `rFrame` against.
	rOne = 167,               /// The constant one, for incrementing `rFrame`.
	rWidth = 168,             /// Framebuffer width, as of this frame.
	rHeight = 169,            /// Framebuffer height, as of this frame.
}

// Symbol and string constants. Each is named rather than written inline at its
// use site because a name is loaded in two halves — a pointer does not fit in
// one 32 bit immediate — and both halves have to describe the same address.
immutable libraryNames = ["libglfw.so.3", "libglfw.3.dylib", "glfw3.dll", "glfw"];

immutable sInit = "glfwInit";
immutable sCreateWindow = "glfwCreateWindow";
immutable sMakeContextCurrent = "glfwMakeContextCurrent";
immutable sSwapInterval = "glfwSwapInterval";
immutable sWindowShouldClose = "glfwWindowShouldClose";
immutable sSwapBuffers = "glfwSwapBuffers";
immutable sPollEvents = "glfwPollEvents";
immutable sTerminate = "glfwTerminate";
immutable sGetProcAddress = "glfwGetProcAddress";
immutable sGetFramebufferSize = "glfwGetFramebufferSize";
immutable sPuts = "puts";

immutable sClearColor = "glClearColor";
immutable sClear = "glClear";
immutable sBegin = "glBegin";
immutable sColor3f = "glColor3f";
immutable sVertex2f = "glVertex2f";
immutable sEnd = "glEnd";
immutable sViewport = "glViewport";

immutable title = "Mizu, through libffi";
immutable errorLibrary = "[mizu] could not load GLFW; install it and try again.";
immutable errorInit = "[mizu] glfwInit() failed; is there a display to open?";
immutable errorWindow = "[mizu] glfwCreateWindow() failed.";

extern(C) int main() {
	printf("Drawing a triangle from Mizu; the window closes after %u frames.\n", frameCount);

	// Every pointer below — the library names, the symbol names, the window
	// title — is a host address, so unlike `examples/fib.d` this program has to
	// be assembled at run time rather than living in read-only data.
	Opcode[218] program = [
		Opcode(&findLabel, rLoop).setImmediate(label2immediate("draw")),
		Opcode(&findLabel, rDone).setImmediate(label2immediate("done")),
		Opcode(&findLabel, rFail).setImmediate(label2immediate("fail")),

		// --- Describe every signature this program calls through ------------
		// The first type pushed is the return type; the rest are parameters.
		// `createInterface` consumes the stack, so these can run back to back.

		// void()
		Opcode(&pushTypeVoid),
		Opcode(&createInterface, ifVoid),
		// i32()
		Opcode(&pushTypeI32),
		Opcode(&createInterface, ifI32),
		// void(void*)
		Opcode(&pushTypeVoid),
		Opcode(&pushTypePointer),
		Opcode(&createInterface, ifVoidPtr),
		// i32(void*)
		Opcode(&pushTypeI32),
		Opcode(&pushTypePointer),
		Opcode(&createInterface, ifI32Ptr),
		// void*(void*)
		Opcode(&pushTypePointer),
		Opcode(&pushTypePointer),
		Opcode(&createInterface, ifPtrPtr),
		// void(i32)
		Opcode(&pushTypeVoid),
		Opcode(&pushTypeI32),
		Opcode(&createInterface, ifVoidI32),
		// void*(i32, i32, void*, void*, void*)
		Opcode(&pushTypePointer),
		Opcode(&pushTypeI32),
		Opcode(&pushTypeI32),
		Opcode(&pushTypePointer),
		Opcode(&pushTypePointer),
		Opcode(&pushTypePointer),
		Opcode(&createInterface, ifCreateWindow),
		// void(u32)
		Opcode(&pushTypeVoid),
		Opcode(&pushTypeU32),
		Opcode(&createInterface, ifVoidU32),
		// void(f32, f32, f32, f32)
		Opcode(&pushTypeVoid),
		Opcode(&pushTypeF32),
		Opcode(&pushTypeF32),
		Opcode(&pushTypeF32),
		Opcode(&pushTypeF32),
		Opcode(&createInterface, ifVoid4F32),
		// void(f32, f32, f32)
		Opcode(&pushTypeVoid),
		Opcode(&pushTypeF32),
		Opcode(&pushTypeF32),
		Opcode(&pushTypeF32),
		Opcode(&createInterface, ifVoid3F32),
		// void(f32, f32)
		Opcode(&pushTypeVoid),
		Opcode(&pushTypeF32),
		Opcode(&pushTypeF32),
		Opcode(&createInterface, ifVoid2F32),
		// void(void*, void*, void*)
		Opcode(&pushTypeVoid),
		Opcode(&pushTypePointer),
		Opcode(&pushTypePointer),
		Opcode(&pushTypePointer),
		Opcode(&createInterface, ifVoid3Ptr),
		// void(i32, i32, i32, i32)
		Opcode(&pushTypeVoid),
		Opcode(&pushTypeI32),
		Opcode(&pushTypeI32),
		Opcode(&pushTypeI32),
		Opcode(&pushTypeI32),
		Opcode(&createInterface, ifVoid4I32),

		// --- Find GLFW ------------------------------------------------------
		// `loadFirstLibraryThatExists` reads its candidates out of the argument
		// registers and keeps the first one that opens, trying each name both
		// as given and with the platform's extension appended.
		Opcode(&loadImmediate, Registers.a(0)).setHostPointerLowerImmediate(libraryNames[0].ptr),
		Opcode(&loadUpperImmediate, Registers.a(0)).setHostPointerUpperImmediate(libraryNames[0].ptr),
		Opcode(&loadImmediate, Registers.a(1)).setHostPointerLowerImmediate(libraryNames[1].ptr),
		Opcode(&loadUpperImmediate, Registers.a(1)).setHostPointerUpperImmediate(libraryNames[1].ptr),
		Opcode(&loadImmediate, Registers.a(2)).setHostPointerLowerImmediate(libraryNames[2].ptr),
		Opcode(&loadUpperImmediate, Registers.a(2)).setHostPointerUpperImmediate(libraryNames[2].ptr),
		Opcode(&loadImmediate, Registers.a(3)).setHostPointerLowerImmediate(libraryNames[3].ptr),
		Opcode(&loadUpperImmediate, Registers.a(3)).setHostPointerUpperImmediate(libraryNames[3].ptr),
		Opcode(&loadFirstLibraryThatExists, rLibrary).setImmediate(cast(uint) libraryNames.length),

		// `puts` comes out of the host process itself (library zero), and is
		// how the failure paths below report what went wrong.
		Opcode(&loadImmediate, Registers.t(0)).setHostPointerLowerImmediate(sPuts.ptr),
		Opcode(&loadUpperImmediate, Registers.t(0)).setHostPointerUpperImmediate(sPuts.ptr),
		Opcode(&loadLibraryFunction, pPuts, 0, Registers.t(0)),

		// if (library == null) fail("could not load GLFW")
		Opcode(&setIfEqual, Registers.t(0), rLibrary, 0),
		Opcode(&loadImmediate, Registers.a(0)).setHostPointerLowerImmediate(errorLibrary.ptr),
		Opcode(&loadUpperImmediate, Registers.a(0)).setHostPointerUpperImmediate(errorLibrary.ptr),
		Opcode(&branchTo, 0, Registers.t(0), rFail),

		// --- Resolve the GLFW entry points ----------------------------------
		Opcode(&loadImmediate, Registers.t(0)).setHostPointerLowerImmediate(sInit.ptr),
		Opcode(&loadUpperImmediate, Registers.t(0)).setHostPointerUpperImmediate(sInit.ptr),
		Opcode(&loadLibraryFunction, pInit, rLibrary, Registers.t(0)),

		Opcode(&loadImmediate, Registers.t(0)).setHostPointerLowerImmediate(sCreateWindow.ptr),
		Opcode(&loadUpperImmediate, Registers.t(0)).setHostPointerUpperImmediate(sCreateWindow.ptr),
		Opcode(&loadLibraryFunction, pCreateWindow, rLibrary, Registers.t(0)),

		Opcode(&loadImmediate, Registers.t(0)).setHostPointerLowerImmediate(sMakeContextCurrent.ptr),
		Opcode(&loadUpperImmediate, Registers.t(0)).setHostPointerUpperImmediate(sMakeContextCurrent.ptr),
		Opcode(&loadLibraryFunction, pMakeContextCurrent, rLibrary, Registers.t(0)),

		Opcode(&loadImmediate, Registers.t(0)).setHostPointerLowerImmediate(sSwapInterval.ptr),
		Opcode(&loadUpperImmediate, Registers.t(0)).setHostPointerUpperImmediate(sSwapInterval.ptr),
		Opcode(&loadLibraryFunction, pSwapInterval, rLibrary, Registers.t(0)),

		Opcode(&loadImmediate, Registers.t(0)).setHostPointerLowerImmediate(sWindowShouldClose.ptr),
		Opcode(&loadUpperImmediate, Registers.t(0)).setHostPointerUpperImmediate(sWindowShouldClose.ptr),
		Opcode(&loadLibraryFunction, pWindowShouldClose, rLibrary, Registers.t(0)),

		Opcode(&loadImmediate, Registers.t(0)).setHostPointerLowerImmediate(sSwapBuffers.ptr),
		Opcode(&loadUpperImmediate, Registers.t(0)).setHostPointerUpperImmediate(sSwapBuffers.ptr),
		Opcode(&loadLibraryFunction, pSwapBuffers, rLibrary, Registers.t(0)),

		Opcode(&loadImmediate, Registers.t(0)).setHostPointerLowerImmediate(sPollEvents.ptr),
		Opcode(&loadUpperImmediate, Registers.t(0)).setHostPointerUpperImmediate(sPollEvents.ptr),
		Opcode(&loadLibraryFunction, pPollEvents, rLibrary, Registers.t(0)),

		Opcode(&loadImmediate, Registers.t(0)).setHostPointerLowerImmediate(sTerminate.ptr),
		Opcode(&loadUpperImmediate, Registers.t(0)).setHostPointerUpperImmediate(sTerminate.ptr),
		Opcode(&loadLibraryFunction, pTerminate, rLibrary, Registers.t(0)),

		Opcode(&loadImmediate, Registers.t(0)).setHostPointerLowerImmediate(sGetProcAddress.ptr),
		Opcode(&loadUpperImmediate, Registers.t(0)).setHostPointerUpperImmediate(sGetProcAddress.ptr),
		Opcode(&loadLibraryFunction, pGetProcAddress, rLibrary, Registers.t(0)),

		Opcode(&loadImmediate, Registers.t(0)).setHostPointerLowerImmediate(sGetFramebufferSize.ptr),
		Opcode(&loadUpperImmediate, Registers.t(0)).setHostPointerUpperImmediate(sGetFramebufferSize.ptr),
		Opcode(&loadLibraryFunction, pGetFramebufferSize, rLibrary, Registers.t(0)),

		// --- Bring up the window --------------------------------------------
		// if (!glfwInit()) fail("glfwInit() failed")
		Opcode(&callWithReturn, Registers.t(0), pInit, ifI32),
		Opcode(&setIfEqual, Registers.t(0), Registers.t(0), 0),
		Opcode(&loadImmediate, Registers.a(0)).setHostPointerLowerImmediate(errorInit.ptr),
		Opcode(&loadUpperImmediate, Registers.a(0)).setHostPointerUpperImmediate(errorInit.ptr),
		Opcode(&branchTo, 0, Registers.t(0), rFail),

		// window = glfwCreateWindow(640, 480, title, null, null)
		Opcode(&loadImmediate, Registers.a(0)).setImmediate(640),
		Opcode(&loadImmediate, Registers.a(1)).setImmediate(480),
		Opcode(&loadImmediate, Registers.a(2)).setHostPointerLowerImmediate(title.ptr),
		Opcode(&loadUpperImmediate, Registers.a(2)).setHostPointerUpperImmediate(title.ptr),
		Opcode(&loadImmediate, Registers.a(3)).setImmediate(0),
		Opcode(&loadImmediate, Registers.a(4)).setImmediate(0),
		Opcode(&callWithReturn, rWindow, pCreateWindow, ifCreateWindow),

		// if (window == null) fail("glfwCreateWindow() failed")
		Opcode(&setIfEqual, Registers.t(0), rWindow, 0),
		Opcode(&loadImmediate, Registers.a(0)).setHostPointerLowerImmediate(errorWindow.ptr),
		Opcode(&loadUpperImmediate, Registers.a(0)).setHostPointerUpperImmediate(errorWindow.ptr),
		Opcode(&branchTo, 0, Registers.t(0), rFail),

		// glfwMakeContextCurrent(window); glfwSwapInterval(1)
		Opcode(&add, Registers.a(0), rWindow, 0),
		Opcode(&call, 0, pMakeContextCurrent, ifVoidPtr),
		Opcode(&loadImmediate, Registers.a(0)).setImmediate(1),
		Opcode(&call, 0, pSwapInterval, ifVoidI32),

		// --- Resolve OpenGL itself ------------------------------------------
		// Only now that a context is current, and through GLFW rather than a
		// second `loadLibrary`: the driver decides where these actually live.
		Opcode(&loadImmediate, Registers.a(0)).setHostPointerLowerImmediate(sClearColor.ptr),
		Opcode(&loadUpperImmediate, Registers.a(0)).setHostPointerUpperImmediate(sClearColor.ptr),
		Opcode(&callWithReturn, pClearColor, pGetProcAddress, ifPtrPtr),

		Opcode(&loadImmediate, Registers.a(0)).setHostPointerLowerImmediate(sClear.ptr),
		Opcode(&loadUpperImmediate, Registers.a(0)).setHostPointerUpperImmediate(sClear.ptr),
		Opcode(&callWithReturn, pClear, pGetProcAddress, ifPtrPtr),

		Opcode(&loadImmediate, Registers.a(0)).setHostPointerLowerImmediate(sBegin.ptr),
		Opcode(&loadUpperImmediate, Registers.a(0)).setHostPointerUpperImmediate(sBegin.ptr),
		Opcode(&callWithReturn, pBegin, pGetProcAddress, ifPtrPtr),

		Opcode(&loadImmediate, Registers.a(0)).setHostPointerLowerImmediate(sColor3f.ptr),
		Opcode(&loadUpperImmediate, Registers.a(0)).setHostPointerUpperImmediate(sColor3f.ptr),
		Opcode(&callWithReturn, pColor3f, pGetProcAddress, ifPtrPtr),

		Opcode(&loadImmediate, Registers.a(0)).setHostPointerLowerImmediate(sVertex2f.ptr),
		Opcode(&loadUpperImmediate, Registers.a(0)).setHostPointerUpperImmediate(sVertex2f.ptr),
		Opcode(&callWithReturn, pVertex2f, pGetProcAddress, ifPtrPtr),

		Opcode(&loadImmediate, Registers.a(0)).setHostPointerLowerImmediate(sEnd.ptr),
		Opcode(&loadUpperImmediate, Registers.a(0)).setHostPointerUpperImmediate(sEnd.ptr),
		Opcode(&callWithReturn, pEnd, pGetProcAddress, ifPtrPtr),

		Opcode(&loadImmediate, Registers.a(0)).setHostPointerLowerImmediate(sViewport.ptr),
		Opcode(&loadUpperImmediate, Registers.a(0)).setHostPointerUpperImmediate(sViewport.ptr),
		Opcode(&callWithReturn, pViewport, pGetProcAddress, ifPtrPtr),

		// glClearColor(0.06, 0.07, 0.11, 1.0)
		// Mizu registers are raw 64 bit blobs, so an f32 argument is just the
		// float's bit pattern sitting in the low half of an argument register.
		Opcode(&loadImmediate, Registers.a(0)).setImmediateF32(0.06f),
		Opcode(&loadImmediate, Registers.a(1)).setImmediateF32(0.07f),
		Opcode(&loadImmediate, Registers.a(2)).setImmediateF32(0.11f),
		Opcode(&loadImmediate, Registers.a(3)).setImmediateF32(1.0f),
		Opcode(&call, 0, pClearColor, ifVoid4F32),

		Opcode(&loadImmediate, rFrame).setImmediate(0),
		Opcode(&loadImmediate, rFrameCount).setImmediate(frameCount),
		Opcode(&loadImmediate, rOne).setImmediate(1),

		// --- The draw loop ---------------------------------------------------
		Opcode(&label).setImmediate(label2immediate("draw")),
			// if (glfwWindowShouldClose(window)) goto done
			Opcode(&add, Registers.a(0), rWindow, 0),
			Opcode(&callWithReturn, Registers.t(0), pWindowShouldClose, ifI32Ptr),
			Opcode(&branchTo, 0, Registers.t(0), rDone),
			// if (frame >= frameCount) goto done
			Opcode(&setIfGreaterEqual, Registers.t(0), rFrame, rFrameCount),
			Opcode(&branchTo, 0, Registers.t(0), rDone),

			// glfwGetFramebufferSize(window, &width, &height)
			// The two out parameters are Mizu's own registers: `pointerToRegister`
			// hands their addresses straight to GLFW, which writes a 32 bit int
			// into the low half of each, so both are cleared first.
			Opcode(&loadImmediate, rWidth).setImmediate(0),
			Opcode(&loadImmediate, rHeight).setImmediate(0),
			Opcode(&add, Registers.a(0), rWindow, 0),
			Opcode(&pointerToRegister, Registers.a(1), rWidth),
			Opcode(&pointerToRegister, Registers.a(2), rHeight),
			Opcode(&call, 0, pGetFramebufferSize, ifVoid3Ptr),
			// glViewport(0, 0, width, height), because a window manager is free
			// to hand back a size other than the one asked for, and to resize
			// the window afterwards.
			Opcode(&loadImmediate, Registers.a(0)).setImmediate(0),
			Opcode(&loadImmediate, Registers.a(1)).setImmediate(0),
			Opcode(&add, Registers.a(2), rWidth, 0),
			Opcode(&add, Registers.a(3), rHeight, 0),
			Opcode(&call, 0, pViewport, ifVoid4I32),

			// glClear(GL_COLOR_BUFFER_BIT)
			Opcode(&loadImmediate, Registers.a(0)).setImmediate(GL_COLOR_BUFFER_BIT),
			Opcode(&call, 0, pClear, ifVoidU32),

			// glBegin(GL_TRIANGLES)
			Opcode(&loadImmediate, Registers.a(0)).setImmediate(GL_TRIANGLES),
			Opcode(&call, 0, pBegin, ifVoidU32),

			// glColor3f(0.96, 0.32, 0.30); glVertex2f(0.0, 0.7)
			Opcode(&loadImmediate, Registers.a(0)).setImmediateF32(0.96f),
			Opcode(&loadImmediate, Registers.a(1)).setImmediateF32(0.32f),
			Opcode(&loadImmediate, Registers.a(2)).setImmediateF32(0.30f),
			Opcode(&call, 0, pColor3f, ifVoid3F32),
			Opcode(&loadImmediate, Registers.a(0)).setImmediateF32(0.0f),
			Opcode(&loadImmediate, Registers.a(1)).setImmediateF32(0.7f),
			Opcode(&call, 0, pVertex2f, ifVoid2F32),

			// glColor3f(0.35, 0.78, 0.52); glVertex2f(-0.7, -0.5)
			Opcode(&loadImmediate, Registers.a(0)).setImmediateF32(0.35f),
			Opcode(&loadImmediate, Registers.a(1)).setImmediateF32(0.78f),
			Opcode(&loadImmediate, Registers.a(2)).setImmediateF32(0.52f),
			Opcode(&call, 0, pColor3f, ifVoid3F32),
			Opcode(&loadImmediate, Registers.a(0)).setImmediateF32(-0.7f),
			Opcode(&loadImmediate, Registers.a(1)).setImmediateF32(-0.5f),
			Opcode(&call, 0, pVertex2f, ifVoid2F32),

			// glColor3f(0.36, 0.55, 0.96); glVertex2f(0.7, -0.5)
			Opcode(&loadImmediate, Registers.a(0)).setImmediateF32(0.36f),
			Opcode(&loadImmediate, Registers.a(1)).setImmediateF32(0.55f),
			Opcode(&loadImmediate, Registers.a(2)).setImmediateF32(0.96f),
			Opcode(&call, 0, pColor3f, ifVoid3F32),
			Opcode(&loadImmediate, Registers.a(0)).setImmediateF32(0.7f),
			Opcode(&loadImmediate, Registers.a(1)).setImmediateF32(-0.5f),
			Opcode(&call, 0, pVertex2f, ifVoid2F32),

			// glEnd()
			Opcode(&call, 0, pEnd, ifVoid),

			// glfwSwapBuffers(window); glfwPollEvents(); ++frame
			Opcode(&add, Registers.a(0), rWindow, 0),
			Opcode(&call, 0, pSwapBuffers, ifVoidPtr),
			Opcode(&call, 0, pPollEvents, ifVoid),
			Opcode(&add, rFrame, rFrame, rOne),
			Opcode(&jumpTo, 0, rLoop),

		// --- Shut down --------------------------------------------------------
		// `glfwTerminate` destroys the window for us, so there is nothing left
		// to release but the interfaces Mizu itself allocated.
		Opcode(&label).setImmediate(label2immediate("done")),
		Opcode(&call, 0, pTerminate, ifVoid),
		Opcode(&freeInterface, 0, ifVoid, 0),
		Opcode(&freeInterface, 0, ifI32, 0),
		Opcode(&freeInterface, 0, ifVoidPtr, 0),
		Opcode(&freeInterface, 0, ifI32Ptr, 0),
		Opcode(&freeInterface, 0, ifPtrPtr, 0),
		Opcode(&freeInterface, 0, ifVoidI32, 0),
		Opcode(&freeInterface, 0, ifCreateWindow, 0),
		Opcode(&freeInterface, 0, ifVoidU32, 0),
		Opcode(&freeInterface, 0, ifVoid4F32, 0),
		Opcode(&freeInterface, 0, ifVoid3F32, 0),
		Opcode(&freeInterface, 0, ifVoid2F32, 0),
		Opcode(&freeInterface, 0, ifVoid3Ptr, 0),
		Opcode(&freeInterface, 0, ifVoid4I32, 0),
		Opcode(&debugPrint, 0, rFrame),
		Opcode(&halt),

		// Every failure path arrives here with `a0` already pointing at the
		// message explaining what went wrong.
		Opcode(&label).setImmediate(label2immediate("fail")),
		Opcode(&call, 0, pPuts, ifI32Ptr),
		Opcode(&halt),
	];

	RegistersAndStack environment;
	setupEnvironment(environment, program[]);
	startFromEnvironment(program[], environment);

	return 0;
}
