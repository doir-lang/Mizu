// Runs the wasm32-wasi unittest build, shared by the browser page and Node. The tests run on a worker, since the page's main thread may not block.
import { channelName, spawn } from "./env.mjs";

/// Runs the compiled test `module` to completion on a worker, passing each line any of its threads writes to `stdout` or `stderr`. Resolves to the exit status, or 134 (SIGABRT's) when a failed assertion trapped on any thread.
export function runTests(module, stdout, stderr) {
	return new Promise((resolve) => {
		const channel = new BroadcastChannel(channelName);
		const worker = spawn(new URL("./main.mjs", import.meta.url));
		const finish = (code) => {
			channel.close();
			// Terminating the test worker ends the thread workers it started, which may still be blocked.
			worker.terminate();
			resolve(code);
		};
		channel.onmessage = ({ data }) => {
			if ("line" in data) (data.stream === "stdout" ? stdout : stderr)(data.line);
			else if ("trap" in data) {
				stderr(`trapped: ${data.trap}`);
				finish(134);
			} else if ("error" in data) {
				stderr(`could not run: ${data.error}`);
				finish(1);
			} else finish(data.exit);
		};
		worker.postMessage({ module });
	});
}
