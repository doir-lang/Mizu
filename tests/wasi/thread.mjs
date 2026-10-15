// A worker that runs one thread the tests create, on the test worker's module and memory.
// The minified build: the plain one was built with its syscall tracing switched on.
import { WASI } from "./node_modules/@tybys/wasm-util/dist/wasm-util.esm.min.js";
import { ThreadMessageHandler, WASIThreads } from "./node_modules/@emnapi/wasi-threads/dist/wasi-threads.js";
import { channelName, onMessage, postToParent } from "./env.mjs";

const channel = new BroadcastChannel(channelName);
const say = (stream) => (line) => channel.postMessage({ stream, line });

const handler = new ThreadMessageHandler({
	postMessage: postToParent,
	async onLoad({ wasmModule, wasmMemory }) {
		const wasi = new WASI({ version: "preview1", args: ["mizu-tests"], print: say("stdout"), printErr: say("stderr") });
		const threads = new WASIThreads({ wasi, childThread: true, postMessage: postToParent });
		const instance = await WebAssembly.instantiate(wasmModule, {
			env: { memory: wasmMemory },
			wasi_snapshot_preview1: wasi.wasiImport,
			...threads.getImportObject(),
		});
		return { module: wasmModule, instance: threads.initialize(instance, wasmModule, wasmMemory) };
	},
	// The thread that would hear about this through the handler's own report may be blocked joining this one.
	onError: (error) => channel.postMessage({ trap: error.message }),
});
onMessage((data) => handler.handle({ data }));
