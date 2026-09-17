#!/usr/bin/env bash
#
# Measures unit test coverage and prints a per-module summary.
#
# Mizu ships as -betterC, which has no druntime, while D's -cov registers its
# line counters through druntime -- so the coverage build is an ordinary D
# build of exactly the same sources and the same tests. `tests/runner.d`
# supplies a druntime `main` when `MizuCoverage` is set.
#
# -cov=ctfe counts lines executed while compiling as well as at run time,
# which matters because the instruction lookup table in `mizu.lookup` is
# built entirely at compile time.
#
# Threading is a compile-time choice (`MizuNoHardwareThreads`), so half of
# `mizu.instructions.parallel` is absent from any single build. Both
# configurations are therefore built and run, and a line counts as covered if
# either of them executed it.
#
# Usage: tools/coverage.sh [-v]    (-v lists the uncovered lines)
set -euo pipefail

verbose=""
[ "${1:-}" = "-v" ] && verbose=1

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compiler="${DC:-ldc2}"
out="bin/coverage"

# LDC and DMD spell the version and optimization flags differently. DMD gets
# no further than mizu.opcode's `static assert`, but it has to get as far as
# reading the sources for that to be the error it reports.
case "$compiler" in
	*dmd*) versionFlag="-version=";   optFlag="-O"  ;;
	*)     versionFlag="-d-version="; optFlag="-O2" ;;
esac

# Under MSYS/Git Bash, dub and the shell disagree about how to spell a path:
# dub says `C:\dir`, while find and `[[ ]]` want `/c/dir`, and the compiler
# and the shell's own `.exe`-less command names want something in between.
case "$(uname -s)" in
	MINGW*|MSYS*|CYGWIN*) windows=1; exeSuffix=".exe" ;;
	*)                    windows="";  exeSuffix="" ;;
esac

toShellPath()    { if [ -n "$windows" ]; then cygpath -u "$1"; else printf '%s\n' "$1"; fi; }
toCompilerPath() { if [ -n "$windows" ]; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }

cd "$root"

# Ask dub where everything lives, so this follows dub.json rather than
# repeating it. Read with a loop rather than `mapfile`, which macOS's bash
# 3.2 does not have. The loop cannot see dub failing inside a process
# substitution either, so check the arrays came back non-empty. dub's output
# is CRLF-terminated on Windows, and a stray \r turns every path into one
# that does not exist.
importPaths=()
while IFS= read -r line; do
	[ -n "$line" ] && importPaths+=("$line")
done < <(dub describe --import-paths -c unittest --compiler="$compiler" | tr -d '\r')

sources=()
while IFS= read -r line; do
	[ -n "$line" ] && sources+=("$line")
done < <(dub describe --data=source-files --data-list -c unittest --compiler="$compiler" | tr -d '\r')

if [ "${#importPaths[@]}" -eq 0 ] || [ "${#sources[@]}" -eq 0 ]; then
	echo "coverage.sh: 'dub describe' produced nothing; cannot build." >&2
	exit 1
fi

# -cov names each .lst after the source path it was handed, with the
# separators flattened to `-`, so the project's own sources go to the
# compiler relative to the root: that makes those names identical on every
# platform, and keeps a Windows drive letter's `:` -- which is not a legal
# filename character there -- out of them. Anything outside the root is a
# dependency, whose .lst the report drops anyway.
relativizeToRoot() {
	local path; path="$(toShellPath "$1")"; path="${path%/}"
	case "$path" in
		"$root"/*) printf '%s\n' "${path#"$root"/}" ;;
		*)         toCompilerPath "$path" ;;
	esac
}

for i in "${!importPaths[@]}"; do importPaths[$i]="$(relativizeToRoot "${importPaths[$i]}")"; done
for i in "${!sources[@]}"; do sources[$i]="$(relativizeToRoot "${sources[$i]}")"; done

# dub lists only Mizu's own modules; the dependencies have to be compiled in
# too, since -I alone would leave their symbols undefined at link time. The
# paths left absolute above are exactly the ones outside the project.
for path in "${importPaths[@]}"; do
	case "$path" in
		/*|?:*) ;;
		*) continue ;;
	esac
	while IFS= read -r file; do
		sources+=("$(toCompilerPath "$file")")
	done < <(find "$(toShellPath "$path")" -name '*.d')
done

# Mirrors dub.json's `libs-*`/`lflags-posix`. The MSVC linker takes a library
# as a plain `.lib` argument rather than with `-l`, and has no equivalent of
# --export-dynamic: on Windows the FFI tests' callbacks resolve through the
# executable's export table instead.
if [ -n "$windows" ]; then
	# tools/vcpkg-libffi.ps1 stages libffi under .vcpkg/lib, the same place
	# dub.json points the linker at. A LIBPATH that does not exist is
	# ignored, so a libffi installed some other way still resolves off LIB.
	link=(-L="/LIBPATH:$(toCompilerPath "$root/.vcpkg/lib")" -L=ffi.lib)
else
	# Apple's linker spells --export-dynamic -export_dynamic.
	case "$(uname -s)" in
		Darwin) link=(-L-export_dynamic -L-lffi) ;;
		Linux)  link=(-L--export-dynamic -L-lffi -L-ldl) ;;
		*)      link=(-L--export-dynamic -L-lffi) ;;
	esac
fi

rm -rf "$out"
mkdir -p "$out"

# Each configuration gets its own directory, because the two builds write
# .lst files under the same names.
build() {
	local name="$1"; shift
	mkdir -p "$out/$name"
	# Optimization is not optional: Mizu's dispatch depends on tail calls, and
	# an unoptimised build overflows the stack on the deeper tests.
	"$compiler" -cov=ctfe "$optFlag" -g -unittest "${versionFlag}MizuCoverage" "$@" \
		"${importPaths[@]/#/-I}" "${sources[@]}" "${link[@]}" \
		-of="$out/$name/mizu-coverage$exeSuffix"
	# Without --DRT-testmode, druntime exits before reaching main, so the
	# runner never reports. The run stays in the project root: the coverage
	# writer reopens each source by the (relative) path it was compiled with
	# to build the annotated listing, and a source it cannot find yields an
	# empty .lst. `dstpath` is what still collects those listings per
	# configuration under `bin/`.
	"./$out/$name/mizu-coverage$exeSuffix" --DRT-testmode=run-main \
		--DRT-covopt="dstpath:$out/$name merge:0" > "$out/$name/run.log" 2>&1 \
		|| { cat "$out/$name/run.log"; exit 1; }
}

build threads
build coroutine "${versionFlag}MizuNoHardwareThreads"

# The glob is already in alphabetical order, so remembering the order files
# are first seen keeps the report sorted and each file's uncovered lines
# attached to it. Dependency and test sources land here too; the prefix test
# drops everything that is not Mizu's own. The same source appears once per
# configuration, so counts are merged by line number and the best result
# wins.
cd "$out"
awk -v prefix="source-" -v verbose="$verbose" '
	FNR == 1 {
		base = FILENAME
		sub(/.*\//, "", base)
		skip = index(base, prefix) != 1
		if (!skip) {
			file = substr(base, length(prefix) + 1)
			sub(/\.lst$/, "", file)
			gsub(/-/, "/", file)
			file = "source/" file ".d"
			if (!(file in seen)) { seen[file] = 1; order[++count] = file }
		}
	}
	skip { next }
	{
		bar = index($0, "|")
		if (bar == 0) next
		hits = substr($0, 1, bar - 1)
		gsub(/ /, "", hits)
		if (hits !~ /^[0-9]+$/) next

		# A line absent from `counted` was compiled out of every build and is
		# not code; one present with zero hits is code nothing reached.
		key = file SUBSEP FNR
		if (!(key in counted) || hits + 0 > counted[key]) counted[key] = hits + 0
		if (!(key in text)) text[key] = substr($0, bar + 1)
		if (FNR > lastLine[file]) lastLine[file] = FNR
	}
	END {
		for (i = 1; i <= count; i++) {
			f = order[i]
			covered = 0; missed = 0; lines = ""
			for (n = 1; n <= lastLine[f]; n++) {
				key = f SUBSEP n
				if (!(key in counted)) continue
				if (counted[key] > 0) covered++
				else {
					missed++
					lines = lines sprintf("      %5d: %s\n", n, text[key])
				}
			}
			total = covered + missed
			# "n/a" rather than 100%: a file with no counters at all (only
			# declarations, or one -cov failed to instrument) has not been
			# shown to be covered, it has not been measured.
			if (total == 0) printf "%-40s %6s\n", f, "n/a"
			else printf "%-40s %6.2f%%  (%d/%d)%s\n", f, 100 * covered / total, \
				covered, total, missed ? sprintf("   <-- %d uncovered", missed) : ""
			if (verbose && missed) printf "%s", lines
			allCovered += covered; allTotal += total
		}
		printf "%s\n", "----------------------------------------------------------------------"
		printf "%-40s %6.2f%%  (%d/%d)\n", "TOTAL", allTotal ? 100 * allCovered / allTotal : 100, \
			allCovered, allTotal
	}
' threads/*.lst coroutine/*.lst
