#!/usr/bin/env python3
"""Measures per-module unittest coverage; pass -v to list uncovered lines. Set DC to use a compiler other than ldc2."""
import glob, os, platform, re, shutil, subprocess, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out = os.path.join('bin', 'coverage')
compiler = os.environ.get('DC', 'ldc2')
exe_name = 'mizu-coverage' + ('.exe' if os.name == 'nt' else '')
prefix = 'source-'


def describe(*args):
	result = subprocess.run(['dub', 'describe', *args, '-c', 'unittest', '--compiler=' + compiler],
		cwd=root, capture_output=True, text=True)
	if result.returncode != 0:
		sys.exit(result.stdout + result.stderr)
	return [line.strip() for line in result.stdout.splitlines() if line.strip()]


# -cov names each listing after the path it compiled, so relative paths give the same names on every platform.
def relative_to_root(path):
	path = os.path.normpath(path)
	try:
		inside = os.path.commonpath([root, os.path.abspath(path)]) == root
	except ValueError:
		# Windows raises this for paths on different drives, which cannot share a root.
		inside = False
	return os.path.relpath(path, root) if inside else path


# Mirrors dub.json's `libs-*` and `lflags-*`; the FFI tests' callbacks need the executable's symbols exported.
def link_flags():
	if os.name == 'nt':
		# tools/vcpkg-libffi.ps1 stages libffi here; a missing LIBPATH is ignored, so one on LIB still resolves.
		return ['-L=/LIBPATH:' + os.path.join(root, '.vcpkg', 'lib'), '-L=ffi.lib']
	system = platform.system()
	if system == 'Darwin':
		return ['-L-export_dynamic', '-L-lffi']
	if system == 'Linux':
		return ['-L--export-dynamic', '-L-lffi', '-L-ldl']
	return ['-L--export-dynamic', '-L-lffi']


def build_and_run():
	import_paths = [relative_to_root(p) for p in describe('--import-paths')]
	sources = [relative_to_root(p) for p in describe('--data=source-files', '--data-list')]
	if not import_paths or not sources:
		sys.exit("coverage.py: 'dub describe' produced nothing; cannot build.")

	# dub lists only Mizu's own modules; bc-threads and libfp must be compiled in too, or they would not link.
	for path in import_paths:
		if os.path.isabs(path):
			sources += sorted(glob.glob(os.path.join(path, '**', '*.d'), recursive=True))

	shutil.rmtree(os.path.join(root, out), ignore_errors=True)

	dmd = 'dmd' in os.path.basename(compiler)
	version_flag = '-version=' if dmd else '-d-version='
	# Threading is a compile-time choice, so each half of mizu.instructions.parallel needs its own build.
	for name, extra in (('threads', []), ('coroutine', [version_flag + 'MizuNoHardwareThreads'])):
		directory = os.path.join(out, name)
		os.makedirs(os.path.join(root, directory))
		exe = os.path.join(directory, exe_name)
		# -cov needs druntime, so these are the same tests built as plain D rather than -betterC.
		# -cov=ctfe, since mizu.lookup builds its instruction table entirely during compilation.
		# Optimized, since dispatch relies on tail calls and an unoptimized build overflows the stack.
		command = [compiler, '-cov=ctfe', '-O' if dmd else '-O2', '-g', '-unittest', '-debug' if dmd else '-d-debug',
			version_flag + 'MizuCoverage', *extra, *('-I' + p for p in import_paths), *sources, *link_flags(), '-of=' + exe]
		if subprocess.run(command, cwd=root).returncode != 0:
			sys.exit(1)

		# Run from the root, since -cov reopens sources by the relative paths it compiled.
		run = subprocess.run([os.path.join(root, exe), '--DRT-testmode=run-main', '--DRT-covopt=dstpath:' + directory + ' merge:0'],
			cwd=root, capture_output=True, text=True)
		with open(os.path.join(root, directory, 'run.log'), 'w') as log:
			log.write(run.stdout + run.stderr)
		if run.returncode != 0:
			sys.exit(run.stdout + run.stderr)


# Maps each source to {line: (hits, text)}; lines with no count were compiled out, so are not code.
def read_listings():
	files = {}
	listings = glob.glob(os.path.join(root, out, '*', prefix + '*.lst'))
	for listing in sorted(listings, key=os.path.basename):
		name = os.path.basename(listing)[len(prefix):-len('.lst')]
		counts = files.setdefault('source/' + name.replace('-', '/') + '.d', {})
		with open(listing, encoding='utf-8', errors='replace') as f:
			for number, line in enumerate(f, 1):
				hits, bar, text = line.rstrip('\n').partition('|')
				if not bar or not re.fullmatch(r'\d+', hits.strip()):
					continue
				# A source appears once per configuration; any one running a line covers it.
				before = counts.get(number, (-1, text))[0]
				counts[number] = (max(before, int(hits)), text)
	return files


def report(files, verbose):
	all_covered = all_total = 0
	for name, counts in files.items():
		missed = sorted(n for n, (hits, _) in counts.items() if hits == 0)
		total = len(counts)
		covered = total - len(missed)
		# A file with no counters was not measured, so it is not 100% covered.
		if total == 0:
			print(f'{name:<40} {"n/a":>6}')
		else:
			flag = f'   <-- {len(missed)} uncovered' if missed else ''
			print(f'{name:<40} {100 * covered / total:6.2f}%  ({covered}/{total}){flag}')
		if verbose:
			for n in missed:
				print(f'      {n:5}: {counts[n][1]}')
		all_covered += covered
		all_total += total
	print('-' * 70)
	percent = 100 * all_covered / all_total if all_total else 100
	print(f'{"TOTAL":<40} {percent:6.2f}%  ({all_covered}/{all_total})')


if __name__ == '__main__':
	build_and_run()
	report(read_listings(), '-v' in sys.argv[1:])
