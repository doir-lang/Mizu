#!/usr/bin/env python3
"""Checks D sources against AGENTS.md's layering, naming and wrapper rules, reporting each finding as `file:line: TAG: message; hint`.

The rules are shared by libfp and every library built on it; each repository keeps a copy of this tool, with its own `CONFIG` below and the same `PUSHED` registry.
When code moves into a lower library, add the pattern it replaced to `PUSHED` in every copy, with the replacement as the hint.

Tags:
- `NAME-Cryptic`: a C-heritage or abbreviated identifier.
- `WRAP-OneLine`: a function whose whole body forwards to one call or field; mark a wrapper a protocol requires with `// wrapper: <reason>` on the line above its documentation comment.
- `LAYER-Platform`: an OS API or C runtime binding (`core.sys.*`, `core.stdc.*`) outside the modules allowed to use one, tests aside.
- `LAYER-Pushed`: a pattern a lower library replaced.
- `E-Remap`: a hand-written `remap[` lookup outside libECRS.
- `ECRS-Write`: a write through a component pointer from a read accessor; use `getForWriting`, `findForWriting` or `setComponent`.
- `FN-Length`: a function outside the tests whose body is longer than `CONFIG['max_function_lines']`, in a file `CONFIG['any_length']` does not match; let the caller branch and move the straight-line parts into helpers.
- `REC-Bound`: a function that calls itself (a call another overload in the file could take does not count) without `// bounded: <the bound>` on the line above its documentation comment.
- `CMT-Sentence`: a comment line, of any kind, holding more than one sentence; put each on its own line.
- `CMT-Wrap`: a sentence hard-wrapped onto the next line of its comment; editors here soft-wrap.
- `DUP-Across` (report-only, with `--across`): a function body identical to one in another repository.

`--report` prints, for information, how many asserts each module has per function outside its tests.

Usage: python3 tools/lint.py [--report] [--across dir...] [file.d...]   (default sources: CONFIG['sources']; exits 1 on any finding but DUP-Across)
"""
import collections
import fnmatch
import glob
import hashlib
import os
import re
import sys


# --- per-repository configuration ---------------------------------------------

CONFIG = {
	'sources': ['source/**/*.d'],
	'platform': ['source/mizu/ffi/*.d'],
	'remap_allowed': False,
	'check_ecrs_writes': False,
	'max_function_lines': 70,
	# Files whose functions may be any length: generated code, and example or benchmark programs read top to bottom.
	'any_length': [],
	'exempt': {
		'hand-written-shared-cast': [],
		'posix-yield': [],
		'raw-memcmp': [],
		'raw-byte-hash': [],
		'snprintf-buffer': [],
	},
}


# --- shared registry (identical in every copy) ---------------------------------

CRYPTIC = {
	'malloc': 'allocate', 'realloc': 'resize', 'calloc': 'allocate', 'alloca': 'allocateOnStack',
	'ctx': 'context', 'mgr': 'manager', 'diag': 'diagnostic', 'fn': 'function or step', 'tok': 'token',
	'loc': 'location', 'cp': 'codepoint', 'decl': 'declaration', 'da': 'array', 'str': 'text',
	'outp': 'output', 'srcP': 'source', 'tableP': 'table', 'buf': 'buffer', 'len': 'length',
	'idx': 'index', 'tmp': 'a name for what it holds', 'cnt': 'count', 'msg': 'message', 'ch': 'channel or character',
}

# (id, pattern, message, hint)
PUSHED = [
	('hand-written-shared-cast', r'\*\s*cast\s*\(\s*shared\s*\(', 'field viewed as shared through a hand-written cast', 'use bc.platform.asShared'),
	('posix-yield', r'\bsched_yield\b|\bnanosleep\b|\bclock_gettime\b', 'direct scheduler or clock call', 'use bc.thread.yield, bc.thread.sleep or bc.thread.monotonicMicroseconds'),
	('millisecond-clock', r'monotonicMicroseconds\s*\(\s*\)\s*/\s*1_?000', 'milliseconds derived from the microsecond clock', 'use bc.thread.monotonicMilliseconds'),
	('raw-memcmp', r'\bmemcmp\s*\(\s*&', 'struct compared by its raw bytes, padding included', 'use fp.lifecycle.equal'),
	('raw-byte-hash', r'\b(murmur|hashBytes)\s*\(\s*\(\s*cast\s*\(\s*const\s*\(\s*ubyte\s*\)\s*\*\s*\)\s*&', 'struct hashed by its raw bytes, padding included', 'use fp.lifecycle.contentHash'),
	('make-dynamic', r'\bmakeDynamic\b', 'makeDynamic', 'use fp.string.clone'),
	('size-max-sentinel', r'[!=]=\s*size_t\.max\b', 'raw size_t.max sentinel', 'compare against fp.pointer.notFound'),
	('qsort', r'\bqsort\b|\bextern\s*\(\s*C\s*\)\s*int\s+compare', 'qsort with a C comparator', 'use std.algorithm.sorting.sort'),
	('snprintf-buffer', r'\bsnprintf\s*\(', 'snprintf into a local buffer', 'use fp.string.format or fp.string.numbers.appendUnsigned'),
	('fp-string-ascii', r'\bfp\.string\.(isDigit|isOctalDigit|isHexDigit|isAsciiAlpha|equalIgnoringAsciiCase)\b', 'character class or case-insensitive comparison through fp.string', 'use fp.string.ascii (isDigit, isHexDigit, isLetter, equalIgnoringCase)'),
	('fp-string-numbers', r'\bfp\.string\.(maxDecimalLength|formatUnsigned|formatSigned|appendUnsigned|appendSigned|appendHex|appendFloat|hexDigitValue|parseUnsigned|parseFloat|Unsigned|Float)\b', 'number formatting or parsing through fp.string', 'use fp.string.numbers'),
	('fp-string-utf', r'\bfp\.string\.(Utf8Error|encodeUtf8|decodeUtf8|utf8SequenceLength|utf16Length|appendCodepoint|inCodepointRanges|codepoints|utf16|fromCodepoints|fromUtf16)\b', 'UTF-8 or UTF-16 through fp.string', 'use fp.string.utf (EncodeError, encode, decode, sequenceLength, utf16Length, append, inRanges, codepoints, toUtf16, fromCodepoints, fromUtf16)'),
	('renamed-replace-hash', r'\bfp\.string\.replace\s*\(|\bhashBytesFast\b', 'fp.string.replace or fp.algorithms.hashBytesFast, since renamed', 'use fp.string.replaceAll or fp.algorithms.hashShortBytes'),
	('hand-written-line-break', r'==\s+\|\|\s*\(\s*[\w.]+\[[^\]]+\]\s*==\s+&&\s*\(', 'line break (\\n, \\r\\n or lone \\r) tested by hand', 'use fp.string.breaksLine, lineOf, lineStart or lineEnd'),
	('hand-written-trim', r'while\s*\(\s*([\w.]+)\.length\s*&&\s*\(\s*\1\[\s*(0|\$\s*-\s*1)\s*\]\s*==', 'leading or trailing characters trimmed by hand', 'use fp.string.trim, trimStart or trimEnd'),
	('renamed-fp-file', r'\bfp\.file\b', 'fp.file, since renamed', 'use fp.io'),
	('inline-generator', r'\*\s*1103515245\b|\*\s*6364136223846793005\b', 'random numbers from a hand-written generator', 'use fp.algorithms.Random'),
	('fix-from-hint', r'\bstartsWith\s*\(\s*hint\b', 'quick fix parsed back out of a hint\'s text', 'attach a diagnose.Diagnostic.Fix where the diagnostic is made'),
]

PLATFORM = re.compile(r'\bcore\s*\.\s*(?:sys|stdc)\s*\.')

PROTOCOL_HOOKS = {
	'remapEntities', 'finalize', 'moveTo', 'copyTo', 'opCall', 'compute', 'empty', 'front', 'popFront', 'back', 'popBack', 'save',
	'opIndex', 'opSlice', 'opDollar', 'opEquals', 'opCmp', 'opAssign', 'opApply', 'opUnary', 'opBinary', 'opCast', 'toHash',
	'contentHash', 'equal', 'serialize', 'deserialize', 'keyEqual', 'keyHash', 'valueEqual', 'cycleFallback', 'describeKey', 'main',
}

CONTROL = {
	'if', 'else', 'for', 'foreach', 'foreach_reverse', 'while', 'do', 'switch', 'case', 'default', 'with', 'try', 'catch', 'finally',
	'synchronized', 'scope', 'version', 'debug', 'unittest', 'struct', 'union', 'class', 'interface', 'enum', 'template', 'mixin',
	'in', 'out', 'body', 'do', 'static', 'return', 'assert', 'import', 'module', 'alias', 'new', 'delete', 'cast', 'typeof', 'is',
	'__traits', 'invariant', 'this', 'extern', 'pragma', 'align', 'deprecated',
}

LEADING_ATTRIBUTE = re.compile(r'^\s*(?:(?:private|public|protected|export|static|override|final|abstract|nothrow|pure|inout|const|immutable|shared|auto|ref|scope|return|__gshared)\b|package(?:\s*\([^)]*\))?|extern\s*\([^)]*\)|pragma\s*\([^)]*\)|deprecated(?:\s*\([^)]*\))?|@\w+(?:\s*\([^)]*\))?)\s*')

FUNCTION_HEADER = re.compile(r'^(?P<prefix>[\w.!*\[\]()\s,]*?)\b(?P<name>[A-Za-z_]\w*)\s*(?:\([^()]*(?:\([^()]*\)[^()]*)*\)\s*)?\((?P<params>.*)\)[\w@\s()]*?(?:\bif\s*\(.*\))?\s*$', re.S)


# --- reading sources -----------------------------------------------------------

def _blank(match):
	return re.sub(r'[^\n]', ' ', match.group(0))


def strip_code(text):
	"""Returns `text` with comments and string and character literals blanked to spaces, keeping every offset and newline."""
	pattern = re.compile(r'//[^\n]*|/\*.*?\*/|/\+.*?\+/|r"[^"]*"|`[^`]*`|q\{.*?\}|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])+\'', re.S)
	return pattern.sub(_blank, text)


def line_of(text, offset):
	"""The 1-based line number of `offset` in `text`."""
	return text.count('\n', 0, offset) + 1


def matching_brace(code, open_at):
	"""The offset of the `}` closing the `{` at `open_at` in stripped `code`, or None if it never closes."""
	depth = 0
	for i in range(open_at, len(code)):
		if code[i] == '{':
			depth += 1
		elif code[i] == '}':
			depth -= 1
			if depth == 0:
				return i
	return None


def test_ranges(code):
	"""The (start, end) offsets of every `unittest` block and `version(unittest)` block in stripped `code`."""
	ranges = []
	for match in re.finditer(r'\bversion\s*\(\s*unittest\s*\)\s*\{|\bunittest\s*\{', code):
		end = matching_brace(code, match.end() - 1)
		if end is not None:
			ranges.append((match.start(), end))
	for match in re.finditer(r'\bversion\s*\(\s*unittest\s*\)\s*:', code):
		ranges.append((match.start(), len(code)))
	return ranges


def inside(ranges, offset):
	"""Whether `offset` falls in any of `ranges`."""
	return any(start <= offset <= end for start, end in ranges)


# --- functions -------------------------------------------------------------------

Function = collections.namedtuple('Function', 'name start body body_start parameters')


def functions(code):
	"""Yields each function definition in stripped `code` with a braced or `=>` body, as a `Function`."""
	for match in re.finditer(r'\{', code):
		open_at = match.start()
		head_start = max(code.rfind(';', 0, open_at), code.rfind('{', 0, open_at), code.rfind('}', 0, open_at)) + 1
		header = code[head_start:open_at]
		label = re.search(r'^[^()]*:\s*$', header, re.M)
		while label:
			header = header[label.end():]
			label = re.search(r'^[^()]*:\s*$', header, re.M)
		while True:
			stripped = LEADING_ATTRIBUTE.sub('', header, count=1)
			if stripped == header:
				break
			header = stripped
		# A header that closes a parenthesis it did not open is the tail of a `foreach (i; 0 .. f(x))`, not a function.
		if '(' not in header or '=' in header.split('(', 1)[0] or header.count(')') != header.count('('):
			continue
		first_word = re.match(r'\s*(\w+)', header)
		if not first_word or first_word.group(1) in CONTROL:
			continue
		found = FUNCTION_HEADER.match(header.strip())
		if not found or found.group('name') in CONTROL or not found.group('prefix').strip():
			continue
		close_at = matching_brace(code, open_at)
		if close_at is None:
			continue
		name_at = code.rfind(found.group('name'), head_start, open_at - len(header.strip()) + header.strip().find(found.group('name')) + len(found.group('name')))
		yield Function(found.group('name'), name_at, code[open_at + 1:close_at], open_at + 1, found.group('params'))


def _top_level(expression):
	depth = 0
	out = []
	for c in expression:
		if c in '([':
			depth += 1
		elif c in ')]':
			depth -= 1
		elif depth == 0:
			out.append(c)
	return ''.join(out)


def forwards_only(body):
	"""Whether `body`, a stripped function body, is one statement that only calls a function or reads a field: no check, loop, operator or second statement."""
	statements = [s.strip() for s in body.split(';') if s.strip()]
	if len(statements) != 1 or '{' in body or body.strip()[-1:] != ';':
		return False
	expression = re.sub(r'^return\b', '', statements[0]).strip()
	if not expression or re.search(r'==|!=|<=|>=|&&|\|\||\?|=>|\+|-|/|%|\^|~|<|>|\bnew\b|\bassert\b|\bif\b|\bfor', expression):
		return False
	if re.search(r'(?<![\w)\]])=(?!=)|[\w)\]]\s*=(?!=)', expression):
		return False
	if re.fullmatch(r'[\w.!*&\s]*(?:cast)?[\w.!*&\s]*', _top_level(expression)) is None:
		return False
	# A body that combines the results of two or more calls adds something.
	return len(re.findall(r'(?<!cast)\b(?!cast\b)\w+\s*(?:!\s*\(?[\w.,\s]*\)?\s*)?\(', expression)) <= 2


# --- comments ----------------------------------------------------------------------

ABBREVIATIONS = {'e.g.', 'i.e.', 'cf.', 'vs.', 'al.', 'etc.', 'approx.', 'resp.', 'viz.'}

SENTENCE_END = re.compile(r'[.!?:][*_"\')]*$')

CommentLine = collections.namedtuple('CommentLine', 'line prose own comment')


def comment_lines(text):
	"""Yields a `CommentLine` per line of each comment in `text`: its 1-based line, its text without the comment marker, whether the comment starts its line, and which comment it is part of (`'///'` or `'//'` for a run of line comments, a block's offset)."""
	pattern = re.compile(r'(//[^\n]*)|(/\*.*?\*/|/\+.*?\+/)|r"[^"]*"|`[^`]*`|q\{.*?\}|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])+\'', re.S)
	for match in pattern.finditer(text):
		if not match.group(1) and not match.group(2):
			continue
		first = line_of(text, match.start())
		own = not text[text.rfind('\n', 0, match.start()) + 1:match.start()].strip()
		if match.group(1):
			yield CommentLine(first, re.sub(r'^//+ ?', '', match.group(1)), own, '///' if match.group(1).startswith('///') else '//')
			continue
		for k, line in enumerate(match.group(2)[2:-2].split('\n')):
			yield CommentLine(first + k, re.sub(r'^\s*[*+]+(?=\s|$) ?', '', line) if k else re.sub(r'^[*+]+ ?', '', line), own, match.start())


def sentence_breaks(prose):
	"""The offsets in comment text `prose` where a new sentence starts, skipping code spans, parentheses, ellipses and abbreviations such as `e.g.`; a DDoc macro such as `$(LI …)` is read through."""
	out, open_brackets, i = [], [], 0
	while i < len(prose):
		c = prose[i]
		if c == '`':
			ticks = re.match(r'`+', prose[i:]).group(0)
			end = prose.find(ticks, i + len(ticks))
			i = end + len(ticks) if end >= 0 else i + len(ticks)
			continue
		if c in '([':
			open_brackets.append('macro' if c == '(' and prose[i - 1:i] == '$' else 'bracket')
		elif c in ')]':
			if open_brackets:
				open_brackets.pop()
		elif c in '.!?' and 'bracket' not in open_brackets and not (c == '.' and '.' in (prose[i - 1:i], prose[i + 1:i + 2])):
			start = re.compile(r'[*_"\']*( +)([A-Z`*\[("_\'$])').match(prose, i + 1)
			word = prose[:i + 1].rsplit(' ', 1)[-1].lstrip('(*_`')
			if start and word not in ABBREVIATIONS and not re.fullmatch(r'[A-Z]\.|\d+\.', word):
				out.append(start.start(2))
		i += 1
	return out


def _starts_part(prose):
	stripped = prose.strip()
	return prose[:1] in (' ', '\t') or re.match(r'([-*+]|\d+[.)])\s|\$\(|\)|[A-Z][\w ]*:(\s|$)|Ditto\b|\w+ = ', stripped) is not None


def check_comments(path, text):
	"""Yields a `CMT-Sentence` finding per comment line holding more than one sentence, and a `CMT-Wrap` finding per line whose sentence runs on to the next line of its comment; DDoc `---` examples are code and skipped."""
	example, last, open_sentence = False, None, None
	for line in comment_lines(text):
		continues = last is not None and line.own and line.line == last.line + 1 and line.comment == last.comment
		last = line
		prose = line.prose.strip()
		example = continues and example
		if prose.startswith('---'):
			example = not example
		if example or prose.startswith('---'):
			open_sentence = None
			continue
		if sentence_breaks(prose):
			yield Finding(path, line.line, 'CMT-Sentence', 'comment line holds more than one sentence', 'put each sentence on its own line')
		if continues and open_sentence is not None and prose and not _starts_part(line.prose):
			yield Finding(path, open_sentence, 'CMT-Wrap', 'sentence hard-wrapped onto the next comment line', 'join the lines, since editors here soft-wrap')
		open_sentence = line.line if line.own and prose and not SENTENCE_END.search(prose) and not re.match(r'(wrapper|bounded):|\)+$|`[^`]*`$', prose) else None


# --- checks ------------------------------------------------------------------------

Finding = collections.namedtuple('Finding', 'path line tag message hint')


def _exempt(config, rule, path):
	return any(fnmatch.fnmatch(path, pattern) for pattern in config['exempt'].get(rule, []))


def check_names(path, code):
	"""Yields one `NAME-Cryptic` finding per cryptic identifier in stripped `code`, at its first use, other than a qualified call into druntime's C bindings."""
	uses = collections.OrderedDict()
	for match in re.finditer(r'(?<![\w.])(?:[A-Za-z_]\w*\s*\.\s*)*([A-Za-z_]\w*)\b', code):
		name = match.group(1)
		if name in CRYPTIC and not re.match(r'core\s*\.', match.group(0)) and not re.search(r'pragma\s*\(\s*$', code[max(0, match.start() - 16):match.start()]):
			first, count = uses.get(name, (match.start(1), 0))
			uses[name] = (first, count + 1)
	for name, (first, count) in uses.items():
		yield Finding(path, line_of(code, first), 'NAME-Cryptic', '`%s` is cryptic (%d uses in this file)' % (name, count), 'name it %s' % CRYPTIC[name])


def _marked(lines, line, name, marker):
	above = line - 2
	while above >= 0 and (lines[above].strip().startswith(('//', '/*', '*')) or lines[above].strip().startswith('pragma(') or re.match(r'\s*template\s+%s\b' % re.escape(name), lines[above])):
		if lines[above].strip().startswith(marker):
			return True
		above -= 1
	return False


def check_wrappers(path, text, code):
	"""Yields a `WRAP-OneLine` finding for each function outside the tests whose whole body only forwards, unless it is a protocol hook or marked `// wrapper:`."""
	tests = test_ranges(code)
	lines = text.split('\n')
	for function in functions(code):
		if function.name in PROTOCOL_HOOKS or inside(tests, function.start) or not forwards_only(function.body):
			continue
		# Another overload of the same operation, or the constructor of a template struct D cannot infer, is API, not a wrapper.
		target = re.search(r'(?:return\s+)?\*?\s*(?:cast\s*\([^)]*\)\s*)?\.?([A-Za-z_]\w*)\s*(?:!\s*(?:\w+|\([^()]*\)))?\s*\(', function.body)
		if target and (target.group(1) == function.name or target.group(1).startswith(function.name[:1].upper() + function.name[1:])):
			continue
		line = line_of(code, function.start)
		if _marked(lines, line, function.name, '// wrapper:'):
			continue
		yield Finding(path, line, 'WRAP-OneLine', '`%s` only forwards to another call or field' % function.name, 'inline it, or rename what it wraps so the direct call reads as well; mark one a protocol requires with `// wrapper: <reason>`')


def check_length(path, code, config):
	"""Yields an `FN-Length` finding for each function outside the tests whose body has more lines than `config['max_function_lines']`."""
	if any(fnmatch.fnmatch(path, pattern) for pattern in config['any_length']):
		return
	tests = test_ranges(code)
	for function in functions(code):
		length = max(0, function.body.count('\n') - 1)
		if length > config['max_function_lines'] and not inside(tests, function.start):
			yield Finding(path, line_of(code, function.start), 'FN-Length', '`%s` is %d lines long, over the limit of %d' % (function.name, length, config['max_function_lines']), 'let it decide the cases and move each straight-line part into a helper defined above it')


def _arguments(code, open_at):
	depth = 0
	for i in range(open_at, len(code)):
		if code[i] in '([{':
			depth += 1
		elif code[i] in ')]}':
			depth -= 1
			if depth == 0:
				return code[open_at + 1:i]
	return ''


def _split(items):
	depth = 0
	parts = ['']
	for c in items:
		if c in '([{':
			depth += 1
		elif c in ')]}':
			depth -= 1
		if c == ',' and depth == 0:
			parts.append('')
		else:
			parts[-1] += c
	return [part for part in parts if part.strip()]


def _takes(function, given):
	parameters = _split(function.parameters)
	return '...' in function.parameters or sum(1 for parameter in parameters if '=' not in _top_level(parameter)) <= given <= len(parameters)


def _calls_itself(function, overloads):
	for call in re.finditer(r'(?<![.\w])%s\s*(?:!\s*(?:\w+|\([^()]*\)))?\s*\(' % re.escape(function.name), function.body):
		given = len(_split(_arguments(function.body, call.end() - 1)))
		# A call another overload could take is read as a call to that overload.
		if _takes(function, given) and not any(_takes(other, given) for other in overloads if other.start != function.start):
			return True
	return False


def check_recursion(path, text, code):
	"""Yields a `REC-Bound` finding for each function outside the tests that calls itself, by an unqualified call that its parameters fit and no other overload's do, unless marked `// bounded:`."""
	tests = test_ranges(code)
	lines = text.split('\n')
	found = list(functions(code))
	for function in found:
		if inside(tests, function.start) or not _calls_itself(function, [other for other in found if other.name == function.name]):
			continue
		line = line_of(code, function.start)
		if not _marked(lines, line, function.name, '// bounded:'):
			yield Finding(path, line, 'REC-Bound', '`%s` calls itself with no stated bound' % function.name, 'use a worklist, or say what bounds the depth with `// bounded: <the bound>` above its documentation comment')


def report(paths, root):
	"""Prints, per source in `paths` under `root`, the asserts and functions outside its tests, then the totals."""
	asserts_in_all = functions_in_all = 0
	for path in paths:
		with open(os.path.join(root, path), encoding='utf-8') as source:
			code = strip_code(source.read())
		tests = test_ranges(code)
		bodies = [function.body for function in functions(code) if not inside(tests, function.start)]
		asserts = sum(len(re.findall(r'\bassert\s*\(', body)) for body in bodies)
		asserts_in_all += asserts
		functions_in_all += len(bodies)
		print('%s: %d asserts in %d functions (%.2f each)' % (path, asserts, len(bodies), asserts / max(len(bodies), 1)))
	print('total: %d asserts in %d functions (%.2f each)' % (asserts_in_all, functions_in_all, asserts_in_all / max(functions_in_all, 1)))


def check_layers(path, code, config):
	"""Yields `LAYER-Platform` and `LAYER-Pushed` findings in stripped `code`."""
	tests = test_ranges(code)
	if not any(fnmatch.fnmatch(path, pattern) for pattern in config['platform']):
		for match in PLATFORM.finditer(code):
			if inside(tests, match.start()):
				continue  # a test may provoke the OS directly, as with a signal
			yield Finding(path, line_of(code, match.start()), 'LAYER-Platform', 'OS API or C runtime used above the platform libraries', 'reach it through libfp, bc-threads, bc-fetch or mizu.ffi (as fp.pointer.copy and fill, fp.string.sliceTerminated, fp.string.numbers.parseFloat, fp.io.print and abort), adding the call there if it is missing')
	for rule, pattern, message, hint in PUSHED:
		if _exempt(config, rule, path):
			continue
		for match in re.finditer(pattern, code):
			yield Finding(path, line_of(code, match.start()), 'LAYER-Pushed', message, hint)


def check_remap(path, code, config):
	"""Yields an `E-Remap` finding for each hand-written `remap[` lookup, unless this repository is libECRS."""
	if config['remap_allowed']:
		return
	for match in re.finditer(r'\bremap\s*\[', code):
		yield Finding(path, line_of(code, match.start()), 'E-Remap', 'hand-written entity remap', 'mix in ecrs.relation.Relates or RelatesEach and call its remapEntities')


def check_ecrs_writes(path, code, config):
	"""Yields an `ECRS-Write` finding for each write through a component reached by a read accessor (`findComponent`, `getComponent`)."""
	if not config['check_ecrs_writes']:
		return
	reader = r'\b(?:findComponent|getComponent)\s*!'
	hint = 'use ecrs.context.getForWriting, findForWriting or setComponent, which count the change and journal it'
	for match in re.finditer(reader + r'[^;\n]*?\)\s*(?:\.\s*\w+\s*)*(?:=(?!=)|\+\+|--|[+\-*/~|&]=)', code):
		yield Finding(path, line_of(code, match.start()), 'ECRS-Write', 'write through a read accessor', hint)
	for function in functions(code):
		names = set(re.findall(r'\b(?:auto|const|ref)?\s*(\w+)\s*=\s*&?\s*(?:ecrs\s*\.\s*context\s*\.\s*)?(?:findComponent|getComponent)\s*!', function.body))
		names |= set(re.findall(r'\bif\s*\(\s*auto\s+(\w+)\s*=\s*(?:ecrs\s*\.\s*context\s*\.\s*)?(?:findComponent|getComponent)\s*!', function.body))
		for name in names:
			for write in re.finditer(r'(?:\b%s\s*(?:\.\s*\w+\s*|\[[^\]]*\]\s*)+|\*\s*%s\s*)(?:=(?!=)|\+\+|--|[+\-*/~|&]=)' % (name, name), function.body):
				yield Finding(path, line_of(code, function.body_start + write.start()), 'ECRS-Write', 'write through `%s`, from a read accessor' % name, hint)


def lint(path, root, config):
	"""All findings for the D source at `path`, relative to repository `root`."""
	with open(os.path.join(root, path), encoding='utf-8') as source:
		text = source.read()
	code = strip_code(text)
	findings = []
	findings.extend(check_names(path, code))
	findings.extend(check_wrappers(path, text, code))
	findings.extend(check_length(path, code, config))
	findings.extend(check_recursion(path, text, code))
	findings.extend(check_layers(path, code, config))
	findings.extend(check_remap(path, code, config))
	findings.extend(check_ecrs_writes(path, code, config))
	findings.extend(check_comments(path, text))
	return findings


# --- duplicates across repositories -------------------------------------------------

def _shape(body):
	tokens = re.findall(r'[A-Za-z_]\w*|\d+|\S', body)
	keywords = CONTROL | {'return', 'foreach', 'break', 'continue', 'null', 'true', 'false'}
	return [t if t in keywords or not re.match(r'[A-Za-z_\d]', t) else ('N' if t[0].isdigit() else 'I') for t in tokens]


def duplicates(roots, minimum_tokens=40):
	"""Groups of functions, across repository `roots`, whose bodies have the same shape once identifiers and numbers are normalized, each group spanning more than one repository."""
	seen = collections.defaultdict(list)
	for root in roots:
		for path in sorted(glob.glob(os.path.join(root, 'source', '**', '*.d'), recursive=True)):
			with open(path, encoding='utf-8') as source:
				text = source.read()
			code = strip_code(text)
			tests = test_ranges(code)
			for function in functions(code):
				shape = _shape(function.body)
				if len(shape) < minimum_tokens or inside(tests, function.start):
					continue
				digest = hashlib.sha1(' '.join(shape).encode()).hexdigest()
				seen[digest].append((root, os.path.relpath(path, root), line_of(code, function.start), function.name))
	return [group for group in seen.values() if len({entry[0] for entry in group}) > 1]


def main():
	"""Lints the sources named on the command line, or `CONFIG['sources']`, and prints each finding."""
	root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
	arguments = sys.argv[1:]
	reporting = '--report' in arguments
	arguments = [a for a in arguments if a != '--report']
	across = []
	while '--across' in arguments:
		at = arguments.index('--across')
		del arguments[at]
		while at < len(arguments) and not arguments[at].startswith('-') and not arguments[at].endswith('.d'):
			across.append(arguments.pop(at))
	paths = [os.path.relpath(os.path.abspath(a), root) for a in arguments]
	if not paths:
		paths = sorted({os.path.relpath(p, root) for pattern in CONFIG['sources'] for p in glob.glob(os.path.join(root, pattern), recursive=True)})
	if reporting:
		report(paths, root)
	failed = False
	for path in paths:
		for finding in lint(path, root, CONFIG):
			failed = True
			print('%s:%d: %s: %s; %s' % finding)
	if across:
		for group in duplicates([root] + [os.path.abspath(a) for a in across]):
			first = group[0]
			others = ', '.join('%s:%d (%s)' % (os.path.join(os.path.basename(r), p), line, name) for r, p, line, name in group[1:])
			print('%s:%d: DUP-Across: `%s` has the same body as %s; keep one, in the lowest library that has everything it needs' % (os.path.join(os.path.basename(first[0]), first[1]), first[2], first[3], others))
	sys.exit(1 if failed else 0)


if __name__ == '__main__':
	main()
