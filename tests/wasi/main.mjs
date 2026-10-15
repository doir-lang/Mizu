// The test worker: instantiates the tests on shared memory and runs them, starting each thread they create on a worker from thread.mjs.
// The minified build: the plain one was built with its syscall tracing switched on.
import { WASI } from "./node_modules/@tybys/wasm-util/dist/wasm-util.esm.min.js";
import { WASIThreads } from "./node_modules/@emnapi/wasi-threads/dist/wasi-threads.js";
import { channelName, onMessage, spawn } from "./env.mjs";

// Keep in step with --initial-memory and --max-memory in tools/wasi.py, in 64 KiB pages.
const initialPages = 256;
const maximumPages = 16384;

const channel = new BroadcastChannel(channelName);
const say = (stream) => (line) => channel.postMessage({ stream, line });

onMessage(async ({ module }) => {
	try {
		const wasi = new WASI({ version: "preview1", args: ["mizu-tests"], returnOnExit: true, print: say("stdout"), printErr: say("stderr") });
		const threads = new WASIThreads({
			wasi,
			// A browser starts a worker only once its creator yields, so workers are started up front and reused rather than started inside `pthread_create`.
			reuseWorker: { size: 8, strict: false },
			waitThreadStart: 1000,
			onCreateWorker: () => spawn(new URL("./thread.mjs", import.meta.url)),
		});
		const memory = new WebAssembly.Memory({ initial: initialPages, maximum: maximumPages, shared: true });
		const instance = await WebAssembly.instantiate(module, {
			env: { memory },
			wasi_snapshot_preview1: wasi.wasiImport,
			...threads.getImportObject(),
		});
		threads.setup(instance, module, memory);
		await threads.preloadWorkers();
		let code;
		try {
			code = wasi.start(instance);
		} catch (e) {
			// wasi-libc's `abort` is a trap, which WASI does not turn into an exit status.
			if (!(e instanceof WebAssembly.RuntimeError)) throw e;
			channel.postMessage({ trap: e.message });
			return;
		}
		channel.postMessage({ exit: code });
	} catch (e) {
		channel.postMessage({ error: String(e?.stack ?? e) });
	}
});
