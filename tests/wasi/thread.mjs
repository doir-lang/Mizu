// A worker that runs one thread the tests create, on the test worker's module and memory.
import { ConsoleStdout, File, OpenFile, PreopenDirectory, WASI } from "./node_modules/@bjorn3/browser_wasi_shim/dist/index.js";
import { ThreadMessageHandler, WASIThreads } from "./node_modules/@emnapi/wasi-threads/dist/wasi-threads.js";
import { channelName, onMessage, postToParent } from "./env.mjs";

const channel = new BroadcastChannel(channelName);
const say = (stream) => (line) => channel.postMessage({ stream, line });

const handler = new ThreadMessageHandler({
	postMessage: postToParent,
	async onLoad({ wasmModule, wasmMemory }) {
		const wasi = new WASI(["mizu-tests"], [], [new OpenFile(new File([])), ConsoleStdout.lineBuffered(say("stdout")), ConsoleStdout.lineBuffered(say("stderr")), new PreopenDirectory("/tmp", new Map())], { debug: false });
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
