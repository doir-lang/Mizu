#!/usr/bin/env python3
"""Compiles and runs every DDoc `---` example under -betterC, and reports public definitions missing documentation or an example. Set DC to use a compiler other than ldc2."""
import glob, os, platform, re, subprocess, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out = os.path.join(root, 'bin', 'doctest')
compiler = os.environ.get('DC', 'ldc2')
exe = os.path.join(out, 'doctests' + ('.exe' if os.name == 'nt' else ''))


def describe(*args):
	result = subprocess.run(['dub', 'describe', *args, '--compiler=' + compiler], cwd=root, capture_output=True, text=True)
	if result.returncode != 0:
		sys.exit(result.stdout + result.stderr)
	return [line.strip() for line in result.stdout.splitlines() if line.strip()]


# Conditions a public definition may sit under; `version(unittest)` holds test-only code, so it is not one.
conditional = re.compile(r'(?!version\s*\(\s*unittest\s*\))(?:(version|static\s+if)\s*\((?:[^()]|\([^()]*\))*\)|debug\b(?!\s*=))\s*')


def strip_conditions(s):
	while (m := conditional.match(s)):
		s = s[m.end():]
	return s


# Yields, for each DDoc comment, the index of the line after it and its (line number, text) pairs.
def ddoc_blocks(lines):
	i = 0
	while i < len(lines):
		s = lines[i].strip()
		if s.startswith('///'):
			body = []
			while i < len(lines) and lines[i].strip().startswith('///'):
				t = lines[i].strip()[3:]
				body.append((i + 1, t[1:] if t.startswith(' ') else t))
				i += 1
			yield i, body
		elif s.startswith('/**') and not s.startswith('/**/'):
			body = []
			first = s[3:]
			if first.endswith('*/'):
				yield i + 1, [(i + 1, first[:-2].strip())]
				i += 1
				continue
			if first.strip():
				body.append((i + 1, first.strip()))
			i += 1
			while i < len(lines) and '*/' not in lines[i]:
				body.append((i + 1, re.sub(r'^\s*\*\s?', '', lines[i])))
				i += 1
			yield i + 1, body
			i += 1
		else:
			i += 1


def is_function(decl):
	if decl.startswith(('struct', 'enum', 'alias', 'module', 'package struct', 'package enum')):
		return decl.startswith('struct') and '(' in decl.split('{')[0]
	if '=' in decl.split('(')[0]:
		return False
	return decl.startswith(('mixin template', 'pragma(inline')) or bool(
		re.match(r'(package\s+|extern\s*\(C\)\s*)?[\w!().\[\]* ]+?\s+\w+(\([^)]*\))?\(', decl))


def check(path, lines, problems, examples):
	documented = set()
	for end, body in ddoc_blocks(lines):
		j = end
		while j < len(lines) and not lines[j].strip():
			j += 1
		documented.add(j)
		decl = strip_conditions(lines[j].strip()) if j < len(lines) else ''
		k = j
		while k < len(lines) and lines[k].strip().startswith('pragma('):
			k += 1
		package = k < len(lines) and strip_conditions(lines[k].strip()).startswith('package')
		found = []
		code = None
		for line, text in body:
			if text.strip() == '---':
				if code is None:
					code = (line + 1, [], package)
				else:
					found.append(code)
					code = None
			elif code is not None:
				code[1].append(text)
		ditto = any(t.strip().lower().startswith('ditto') for _, t in body)
		if is_function(decl) and not found and not ditto:
			problems.append(f'{path}:{j + 1}: documented without an example: {decl}')
		# Module documentation sketches configuration and user code, which need not compile on its own.
		if not decl.startswith('module'):
			examples += found

	# Flags top-level declarations with no DDoc directly above; conditional blocks do not count as nesting.
	skip = ('mixin(', '//', '/*', '*', 'import', 'static import', 'public import', 'module', 'unittest', '}', '@nogc', 'version', 'debug',
		'private', 'else', '{', '~', '"', ')', ';', 'pragma(inline', 'pragma(msg', 'static assert', 'shared static')
	opened = []
	previous = ''
	for k, line in enumerate(lines):
		s = re.sub(r'^extern\s*\(\w+\)\s*', '', strip_conditions(line.strip()))
		depth = opened.count(False)
		continues = previous and not previous.endswith((';', '{', '}', ':', '*/')) and not previous.startswith('//')
		if depth == 0 and s and not continues and not s.startswith(skip) and re.match(r'[\w(]', s) and k not in documented:
			prev = k - 1
			while prev >= 0 and lines[prev].strip().startswith('pragma('):
				prev -= 1
			above = lines[prev].strip() if prev >= 0 else ''
			if not (above.startswith('///') or above.endswith('*/')):
				problems.append(f'{path}:{k + 1}: undocumented: {s}')
		if line.strip():
			previous = line.strip() if strip_conditions(line.strip()) else ''
		head = line.strip().lstrip('}').strip()
		transparent = line.rstrip().endswith('{') and strip_conditions(head) == '{'
		braces = [c for c in line if c in '{}']
		for n, c in enumerate(braces):
			if c == '{':
				opened.append(transparent and n == len(braces) - 1)
			elif opened:
				opened.pop()


# Mirrors dub.json's `libs-*` and `lflags-*`; the FFI examples' callbacks need the executable's symbols exported.
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


def modules_in(sources):
	return [re.search(r'^module\s+([\w.]+);', open(p, encoding='utf-8').read(), re.M).group(1) for p in sources]


def inside_root(path):
	try:
		return os.path.commonpath([root, os.path.abspath(path)]) == root
	except ValueError:
		# Windows raises this for paths on different drives, which cannot share a root.
		return False


def main():
	os.makedirs(out, exist_ok=True)
	for old in glob.glob(os.path.join(out, '*.d')):
		os.remove(old)

	sources = sorted(glob.glob(os.path.join(root, 'source', 'mizu', '**', '*.d'), recursive=True))
	# Import paths outside the root are bc-threads' and libfp's, whose modules must be compiled in too, or they would not link.
	import_paths = describe('--import-paths')
	dependencies = sorted(f for p in import_paths if not inside_root(p)
		for f in glob.glob(os.path.join(p, '**', '*.d'), recursive=True))
	reachable = [m for p, m in zip(sources + dependencies, modules_in(sources + dependencies))
		if os.path.basename(p) != 'package.d']
	problems = []
	generated = []
	for path in sources:
		text = open(path, encoding='utf-8').read()
		module = re.search(r'^module\s+([\w.]+);', text, re.M).group(1)
		relative = os.path.relpath(path, root).replace(os.sep, '/')
		examples = []
		check(relative, text.split('\n'), problems, examples)
		# `package` definitions are visible only inside their own package, so their examples are compiled there.
		for package, prefix in ((False, 'doctest_'), (True, module.rpartition('.')[0] + '.doctest_')):
			chosen = [(line, code) for line, code, inside in examples if inside == package]
			if not chosen:
				continue
			name = prefix + module.replace('.', '_')
			generated.append(name)
			# Examples read like user code, which reaches Mizu through `import mizu;`.
			body = [f'module {name};', 'import mizu;', f'import {module};']
			body += [f'static import {m};' for m in reachable if m != module]
			for k, (line, code) in enumerate(chosen):
				# A distinct line per unittest keeps their generated names apart.
				body.append(f'#line {100000 + 1000 * k} "doctest"')
				body.append('unittest {')
				body.append(f'#line {line} "{relative}"')
				body += code
				body.append('}')
			open(os.path.join(out, name.replace('.', '_') + '.d'), 'w', encoding='utf-8').write('\n'.join(body) + '\n')

	runner = ['module doctest_runner;', 'import core.stdc.stdio : printf;']
	runner += [f'static import {n};' for n in generated]
	runner += ['extern(C) int main() {', '\tint total = 0;']
	runner += [f'\tforeach (test; __traits(getUnitTests, {n})) {{ test(); ++total; }}' for n in generated]
	runner += ['\tprintf("doctest: all %d examples passed.\\n", total);', '\treturn 0;', '}']
	open(os.path.join(out, 'doctest_runner.d'), 'w', encoding='utf-8').write('\n'.join(runner) + '\n')

	for problem in problems:
		print(problem)

	dmd = 'dmd' in os.path.basename(compiler)
	# Optimized, since dispatch relies on tail calls and an unoptimized build overflows the stack.
	command = [compiler, '-betterC', '-checkaction=C', '-unittest', '-debug' if dmd else '-d-debug', '-O' if dmd else '-O2',
		*('-I' + p for p in import_paths), '-I' + out, *link_flags(), '-of=' + exe] + sources + dependencies + sorted(glob.glob(os.path.join(out, '*.d')))
	if subprocess.run(command, cwd=root).returncode != 0:
		return 1
	if subprocess.run([exe], cwd=root).returncode != 0:
		return 1
	if problems:
		print(f'doctest: {len(problems)} documentation problems')
		return 1
	return 0


if __name__ == '__main__':
	sys.exit(main())
