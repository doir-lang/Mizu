// What differs between the browser and Node: starting a worker, and a worker talking to whoever started it.
export const isNode = typeof process === "object" && typeof process.versions?.node === "string";
const workerThreads = isNode ? await import("node:worker_threads") : null;

/// Every thread reports its output, traps and the exit status here, since a thread blocked in `pthread_join` can receive no message.
export const channelName = "mizu-tests";

/// Starts the module script `url` on a new worker.
export function spawn(url) {
	return isNode ? new workerThreads.Worker(url) : new Worker(url, { type: "module" });
}

/// Calls `handle` with each message the worker's creator posts it.
export function onMessage(handle) {
	if (isNode) workerThreads.parentPort.on("message", handle);
	else self.onmessage = (e) => handle(e.data);
}

/// Posts `message` from this worker to its creator.
export function postToParent(message) {
	if (isNode) workerThreads.parentPort.postMessage(message);
	else self.postMessage(message);
}
