#!/usr/bin/env python3
"""Builds the unittests for wasm32-wasi with threads and runs them in a browser, or headlessly under Node, through @bjorn3/browser_wasi_shim's WASI and @emnapi/wasi-threads.

Threads need atomics and a shared memory, so the build targets wasip1-threads unless --single-threaded asks for plain wasip1, which tests the coroutine scheduler instead. It asks `dub describe` for the sources and import paths, compiling bc-threads and libfp in alongside. Mizu dispatches by tail call, so the build is optimized and targets wasm's tail-call feature, which every current browser and Node support. The build links against a wasi-sdk sysroot and compiler-rt builtins, downloaded once into bin/wasi-sdk unless WASI_SYSROOT and WASI_BUILTINS name local copies. It links with `wasm-ld` from PATH (or WASM_LD), falling back to LDC's internal linker.

Usage:
  tools/wasi.py                      build bin/wasi/mizu-tests.wasm and the page that runs it
  tools/wasi.py --serve              ... then serve bin/wasi on http://localhost:8000 to open in a browser
  tools/wasi.py --node               ... then run the same page script under Node, exiting with the tests' status
  tools/wasi.py --single-threaded    build (and serve or run) without threads
"""
import argparse, functools, glob, http.server, os, shutil, subprocess, sys, tarfile, urllib.request

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out = os.path.join(root, 'bin', 'wasi')
sdk = os.path.join(root, 'bin', 'wasi-sdk')
page = os.path.join(root, 'tests', 'wasi')
compiler = os.environ.get('DC', 'ldc2')
wasm = os.path.join(out, 'mizu-tests.wasm')

sdkVersion = '34'
release = f'https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-{sdkVersion}/'
packages = ['@bjorn3/browser_wasi_shim@0.4.2', '@emnapi/wasi-threads@2.2.0']
# Keep in step with `initialPages` and `maximumPages` in tests/wasi/main.mjs.
initialMemory = 256 * 65536
maxMemory = 16384 * 65536


def fetch(name):
	"""Downloads and unpacks a wasi-sdk release archive into bin/wasi-sdk, unless already there, and returns where it unpacked."""
	dest = os.path.join(sdk, name)
	if not os.path.isdir(dest):
		os.makedirs(sdk, exist_ok=True)
		archive = dest + '.tar.gz'
		print(f'downloading {name}', file=sys.stderr)
		urllib.request.urlretrieve(release + name + '.tar.gz', archive)
		with tarfile.open(archive) as tar:
			tar.extractall(sdk, filter='data')
		os.remove(archive)
	return dest


def describe(*args):
	result = subprocess.run(['dub', 'describe', *args, '-c', 'unittest', '--compiler=' + compiler],
		cwd=root, capture_output=True, text=True)
	if result.returncode != 0:
		sys.exit(result.stdout + result.stderr)
	return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def checkThreadLocals():
	"""Exits with an explanation if the compiler emits D's thread-locals on wasm as ordinary globals, as LDC 1.43 and earlier do, which every thread would share."""
	probe = os.path.join(out, 'tlsprobe')
	with open(probe + '.d', 'w') as f:
		f.write('int perThread;\n')
	subprocess.run([compiler, '-mtriple=wasm32-unknown-wasi', '-mattr=+atomics,+bulk-memory', '-betterC',
		'-output-ll', '-of=' + probe + '.ll', probe + '.d'], check=True)
	with open(probe + '.ll') as f:
		if 'thread_local' not in f.read():
			sys.exit(f'{compiler} gives wasm no thread-local storage, so threads would share every thread-local; '
				'use an LDC with ldc-developers/ldc#5268 (newer than 1.43), or pass --single-threaded.')


def build(threads):
	target = 'wasm32-wasip1-threads' if threads else 'wasm32-wasip1'
	sysroot = os.environ.get('WASI_SYSROOT') or fetch(f'wasi-sysroot-{sdkVersion}.0')
	builtins = os.environ.get('WASI_BUILTINS') or os.path.join(
		fetch(f'libclang_rt-{sdkVersion}.0'), 'wasm32-unknown-' + target.removeprefix('wasm32-'), 'libclang_rt.builtins.a')
	libs = os.path.join(sysroot, 'lib', target)

	importPaths = describe('--import-paths')
	sources = describe('--data=source-files', '--data-list')
	# dub lists only Mizu's own modules; bc-threads and libfp must be compiled in too, or they would not link.
	for path in importPaths:
		if os.path.commonpath([root, os.path.abspath(path)]) != root:
			sources += sorted(glob.glob(os.path.join(path, '**', '*.d'), recursive=True))
	os.makedirs(out, exist_ok=True)
	if threads:
		checkThreadLocals()
	# Debug and optimized, like dub.json's `unittest` build type; dispatch overflows the stack without tail calls.
	# `bc.platform` turns threads on exactly when the target has atomics, and `mizu.config` follows it.
	features = '+tail-call,+atomics,+bulk-memory' if threads else '+tail-call'
	compile = [compiler, '-mtriple=wasm32-unknown-wasi', '-mattr=' + features, '-betterC', '-checkaction=C', '-unittest', '-d-debug', '-O',
		*('-I' + p for p in importPaths), '-od=' + out, *sources]
	# The long-double archive replaces libc's printf, so it must come first; D's `real` is a 128-bit long double here.
	linkArgs = [os.path.join(libs, 'crt1-command.o'), '-L' + libs, '-lc-printscan-long-double', '-lc', builtins]
	# Every thread's instance imports the one memory, which the host creates to the same limits; @emnapi/wasi-threads allocates spawn results with malloc.
	if threads:
		linkArgs += ['--shared-memory', '--import-memory', '--export-memory', f'--initial-memory={initialMemory}', f'--max-memory={maxMemory}',
			'--export=malloc', '--export=free']

	linker = os.environ.get('WASM_LD') or shutil.which('wasm-ld')
	if linker:
		obj = os.path.join(out, 'mizu-tests.o')
		subprocess.run([*compile, '-c', '-of=' + obj], cwd=root, check=True)
		subprocess.run([linker, '-o', wasm, *linkArgs, obj], cwd=root, check=True)
	else:
		subprocess.run([*compile, '--link-internally', '-of=' + wasm, *('-L' + a for a in linkArgs)], cwd=root, check=True)

	for f in os.listdir(page):
		shutil.copy(os.path.join(page, f), out)
	install()


def install():
	"""Installs the WASI packages beside the page scripts, which import them by relative path in the browser and Node alike."""
	if not all(os.path.isdir(os.path.join(out, 'node_modules', *p.rpartition('@')[0].split('/'))) for p in packages):
		subprocess.run(['npm', 'install', '--no-save', '--no-package-lock', '--prefix', out, *packages],
			check=True, shell=os.name == 'nt')


class IsolatedHandler(http.server.SimpleHTTPRequestHandler):
	"""Serves with the headers that make a page cross-origin isolated, without which a browser offers no shared memory."""
	def end_headers(self):
		self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
		self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
		super().end_headers()


def serve(port):
	handler = functools.partial(IsolatedHandler, directory=out)
	with http.server.ThreadingHTTPServer(('localhost', port), handler) as server:
		print(f'open http://localhost:{port}/ to run the tests (Ctrl+C stops the server)', file=sys.stderr)
		try:
			server.serve_forever()
		except KeyboardInterrupt:
			pass


def runNode():
	return subprocess.run(['node', os.path.join(out, 'node.mjs'), wasm]).returncode


def main():
	parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
	mode = parser.add_mutually_exclusive_group()
	mode.add_argument('--serve', nargs='?', const=8000, type=int, metavar='PORT', help='serve the test page for a browser')
	mode.add_argument('--node', action='store_true', help='run the tests under Node')
	parser.add_argument('--single-threaded', action='store_true', help='build for plain wasip1, without threads')
	args = parser.parse_args()

	build(not args.single_threaded)
	if args.serve:
		serve(args.serve)
	elif args.node:
		sys.exit(runNode())


if __name__ == '__main__':
	main()
