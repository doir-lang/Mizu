import { readFile } from "node:fs/promises";
import { runTests } from "./run.mjs";

const module = await WebAssembly.compile(await readFile(process.argv[2]));
process.exit(await runTests(module, (line) => console.log(line), (line) => console.error(line)));
