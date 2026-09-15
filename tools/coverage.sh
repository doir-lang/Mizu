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
out="$root/bin/coverage"

rm -rf "$out"
mkdir -p "$out"

# Ask dub where everything lives, so this follows dub.json rather than
# repeating it. `mapfile` cannot see dub failing inside a process
# substitution, so check the arrays came back non-empty.
mapfile -t importPaths < <(dub describe --import-paths -c unittest --compiler="$compiler")
mapfile -t sources < <(dub describe --data=source-files --data-list -c unittest --compiler="$compiler")
if [ "${#importPaths[@]}" -eq 0 ] || [ "${#sources[@]}" -eq 0 ]; then
	echo "coverage.sh: 'dub describe' produced nothing; cannot build." >&2
	exit 1
fi

# dub lists only Mizu's own modules; the dependencies have to be compiled in
# too, since -I alone would leave their symbols undefined at link time.
for path in "${importPaths[@]}"; do
	case "$path" in
		"$root"/*) continue ;;
	esac
	while IFS= read -r file; do sources+=("$file"); done < <(find "$path" -name '*.d')
done

link=(-L--export-dynamic -L-lffi)
[ "$(uname -s)" = "Linux" ] && link+=(-L-ldl)

# Each configuration gets its own directory, because the two builds write
# .lst files under the same names.
build() {
	local name="$1"; shift
	mkdir -p "$out/$name"
	# -O2 is not optional: Mizu's dispatch depends on tail calls, and an
	# unoptimised build overflows the stack on the deeper tests.
	"$compiler" -cov=ctfe -O2 -g -unittest -d-version=MizuCoverage "$@" \
		"${importPaths[@]/#/-I}" "${sources[@]}" "${link[@]}" \
		-of="$out/$name/mizu-coverage"
	# Without --DRT-testmode, druntime exits before reaching main, so the
	# runner never reports.
	(cd "$out/$name" && ./mizu-coverage --DRT-testmode=run-main > run.log 2>&1) \
		|| { cat "$out/$name/run.log"; exit 1; }
}

build threads
build coroutine -d-version=MizuNoHardwareThreads

# .lst files are named after the source path, with the separators flattened.
# The glob is already in alphabetical order, so remembering the order files
# are first seen keeps the report sorted and each file's uncovered lines
# attached to it. The same source appears once per configuration, so counts
# are merged by line number and the best result wins.
cd "$out"
awk -v prefix="${root//\//-}-source-" -v verbose="$verbose" '
	FNR == 1 {
		base = FILENAME
		sub(/.*\//, "", base)
		skip = index(base, prefix) != 1
		if (!skip) {
			file = substr(base, length(prefix) + 1)
			sub(/\.lst$/, "", file)
			gsub(/-/, "/", file)
			file = file ".d"
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
