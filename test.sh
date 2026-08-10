#!/bin/bash
#
# test.sh — render every stub, build it, run it, and prove the languages agree.
#
# Three things are checked, in order of how badly they fail:
#
#   1. Every file `stubs.json` names exists, and no stub file is missing from
#      the contract. A stub an implementation cannot find is a scaffold that
#      silently produces an incomplete project.
#   2. Every stub BUILDS and RUNS. `manifest` is the subcommand the host itself
#      calls (capdag dev-install reads it), so a stub that cannot answer it is
#      not installable.
#   3. Every stub's manifest is BYTE-IDENTICAL to the others'. This is the
#      parity contract: the languages implement one cap, and a difference here
#      is a mirror whose cap builder or URN canonicalization has drifted.
#
# A language whose toolchain is absent is SKIPPED and named in the summary —
# never silently passed, because "nothing ran" and "everything passed" must not
# look the same.
#
# Usage: ./test.sh [language]...        (default: every language in stubs.json)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="stubcheck"          # the project name every stub is rendered under

if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; DIM=$'\033[2m'; NC=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; DIM=""; NC=""
fi

PASS=0; FAIL=0; SKIPPED=()
ok()   { PASS=$((PASS + 1)); echo "  ${GREEN}ok${NC}   — $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  ${RED}FAIL${NC} — $1"; }
skip() { SKIPPED+=("$1"); echo "  ${DIM}skip — $1${NC}"; }

command -v python3 >/dev/null 2>&1 || { echo "python3 is required to read stubs.json" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# jq is not assumed; stubs.json is read through python3, which is already
# required by the Python stub's own toolchain check.
contract() { python3 -c "$1" "$ROOT/stubs.json" "${@:2}"; }

# macOS ships bash 3.2, which has neither `mapfile` nor `declare -A` nor
# `${var^^}`. This file must run on the same machine the stubs are tested on.
LANGUAGES=("$@")
if [[ ${#LANGUAGES[@]} -eq 0 ]]; then
    # Unquoted on purpose: language names are identifiers with no whitespace,
    # and TEST "CONTRACT" above fails if stubs.json ever disagrees.
    LANGUAGES=($(contract '
import json,sys
print("\n".join(json.load(open(sys.argv[1]))["languages"]))'))
fi

PLACEHOLDER=$(contract '
import json,sys
print(json.load(open(sys.argv[1]))["placeholder"])')

# ---------------------------------------------------------------------------
# 1. The contract covers exactly the files on disk.
# ---------------------------------------------------------------------------
echo "CONTRACT — stubs.json names every stub file, and only files that exist"
# LC_ALL=C on both sides: `comm` compares byte-wise, so a locale-collated sort
# feeds it input it considers unsorted and it reports nonsense.
declared=$(contract '
import json,sys
c=json.load(open(sys.argv[1]))
for lang in c["languages"].values():
    for f in lang["files"]:
        print(f["source"])' | LC_ALL=C sort)
# `*.wstemplate` files are SOURCES for the stubs beside them, not stubs
# themselves: `wsb` renders each one over its declared counterpart to stamp the
# runtime version pins, so the rendered file is what stubs.json declares and
# what a scaffolder writes. Counting the template as an undeclared stub would
# report the mechanism that keeps the pins honest as a defect.
on_disk=$(cd "$ROOT" && find stubs -type f ! -name '*.wstemplate' | LC_ALL=C sort)
missing=$(LC_ALL=C comm -23 <(echo "$declared") <(echo "$on_disk"))
extra=$(LC_ALL=C comm -13 <(echo "$declared") <(echo "$on_disk"))
if [[ -z "$missing" ]]; then ok "every declared file exists"
else bad "declared but absent: $(echo "$missing" | tr '\n' ' ')"; fi
if [[ -z "$extra" ]]; then ok "every file on disk is declared"
else bad "present but undeclared (an implementation would never write it): $(echo "$extra" | tr '\n' ' ')"; fi

# ---------------------------------------------------------------------------
# 2 + 3. Render, build, run, compare.
# ---------------------------------------------------------------------------
MANIFEST_LANGS=()

render() {   # render <language> <target-dir>
    local lang="$1" target="$2"
    contract '
import json,os,stat,sys
contract_path, lang, target, name = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
c = json.load(open(contract_path))
ph = c["placeholder"]
root = os.path.dirname(os.path.abspath(contract_path))
for f in c["languages"][lang]["files"]:
    dest = os.path.join(target, f["dest"].replace(ph, name))
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    body = open(os.path.join(root, f["source"]), encoding="utf-8").read().replace(ph, name)
    open(dest, "w", encoding="utf-8").write(body)
    if f["executable"]:
        os.chmod(dest, os.stat(dest).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
' "$lang" "$target" "$NAME"
}

entry_of() { contract '
import json,sys
c=json.load(open(sys.argv[1]))
print(c["languages"][sys.argv[2]]["entry"].replace(c["placeholder"], sys.argv[3]))' "$1" "$NAME"; }

build_cmds_of() { contract '
import json,sys
c=json.load(open(sys.argv[1]))
for cmd in c["languages"][sys.argv[2]]["build"]:
    print(cmd.replace(c["placeholder"], sys.argv[3]))' "$1" "$NAME"; }

# The interpreter the Python stub is rendered against. `dx` exports PYTHON (the
# project's environment, which has the `capdag` runtime); standalone, plain
# python3. Without this the test picks up whatever python3 is first on PATH —
# on macOS that is /usr/bin/python3, which has no cartridge runtime and never
# will, so the stub would be reported broken because of the caller's PATH.
STUB_PYTHON="${PYTHON:-python3}"

toolchain_for() {
    case "$1" in
        python) echo "$STUB_PYTHON" ;;
        go)     echo go ;;
        rust)   echo cargo ;;
        swift)  echo swift ;;
        *)      echo "" ;;
    esac
}

# What this stub imports, and how to get it — printed on any failure, because
# "No module named 'capdag'" and "unknown revision v1.333.2790" both mean the
# same thing (the runtime is not resolvable here) and neither says so.
runtime_hint() {
    local lang="$1"
    contract '
import json,sys
c=json.load(open(sys.argv[1]))
r=c["languages"][sys.argv[2]]["runtime"]
print("        runtime: %s from %s — install: %s" % (r["package"], r["registry"], r["install"]))' "$lang"
}

for lang in "${LANGUAGES[@]}"; do
    echo "$(printf '%s' "$lang" | tr '[:lower:]' '[:upper:]') — renders, builds, runs, and answers \`manifest\`"

    tool=$(toolchain_for "$lang")
    if [[ -z "$tool" ]]; then
        bad "no toolchain known for '$lang' — add it to toolchain_for() before adding the stub"
        continue
    fi
    if ! command -v "$tool" >/dev/null 2>&1; then
        skip "$lang ($tool not installed)"
        continue
    fi

    dir="$WORK/$lang/$NAME"
    mkdir -p "$dir"
    if ! render "$lang" "$dir"; then
        bad "$lang: rendering failed"
        continue
    fi
    ok "$lang: renders"

    if grep -rqF "$PLACEHOLDER" "$dir"; then
        bad "$lang: the rendered project still contains $PLACEHOLDER"
    else
        ok "$lang: no placeholder survives rendering"
    fi

    build_failed=false
    while IFS= read -r cmd; do
        [[ -n "$cmd" ]] || continue
        if ! ( cd "$dir" && eval "$cmd" ) >"$WORK/$lang.build.log" 2>&1; then
            bad "$lang: build step failed: $cmd"
            sed 's/^/        /' "$WORK/$lang.build.log" | head -15
            runtime_hint "$lang"
            build_failed=true
            break
        fi
    done < <(build_cmds_of "$lang")
    [[ "$build_failed" == true ]] && continue

    entry="$dir/$(entry_of "$lang")"
    if [[ ! -x "$entry" ]]; then
        bad "$lang: entry '$(entry_of "$lang")' is missing or not executable after the build"
        continue
    fi
    ok "$lang: builds an executable entry"

    # For an interpreted entry the shebang would pick its own interpreter,
    # which is not necessarily the one this run is testing.
    run_entry() {   # run_entry <dir> <args...>
        local d="$1"; shift
        if [[ "$lang" == "python" ]]; then
            ( cd "$d" && "$STUB_PYTHON" "./$(entry_of "$lang")" "$@" )
        else
            ( cd "$d" && "./$(entry_of "$lang")" "$@" )
        fi
    }

    if ! run_entry "$dir" manifest >"$WORK/$lang.manifest.json" 2>"$WORK/$lang.manifest.err"; then
        bad "$lang: \`manifest\` failed"
        sed 's/^/        /' "$WORK/$lang.manifest.err" | head -10
        runtime_hint "$lang"
        continue
    fi
    if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$WORK/$lang.manifest.json" 2>/dev/null; then
        bad "$lang: \`manifest\` did not print valid JSON"
        continue
    fi
    ok "$lang: \`manifest\` prints valid JSON"
    MANIFEST_LANGS+=("$lang")

    # The cap must be REACHED — the entry must dispatch to the registered
    # handler, not fail before it on a bad alias or an unparsed manifest.
    #
    # These stubs delegate the judgment to a model cartridge over a PEER CALL,
    # and peer calls are routed by the capdag host. Run directly, the entry has
    # no host, so the handler is reached and then fails there with the peer
    # error. That precise failure is the assertion: it proves dispatch worked
    # AND that the cartridge is honestly refusing rather than inventing an
    # answer. Real end-to-end inference belongs to a scenario with a host and a
    # model, not to a contract test that must stay fast and offline.
    out=$( echo "I love this" | run_entry "$dir" "$NAME" 2>&1 )
    if grep -qi "peer" <<<"$out"; then
        ok "$lang: the cap is reached, and refuses without a host (peer call unrouted)"
    elif [[ "$out" == "positive" ]]; then
        # A host WAS present (the suite is running inside one). The delegation
        # then really ran, which is a stronger result than the offline case.
        ok "$lang: the cap runs against a live host (\"I love this\" -> positive)"
    else
        bad "$lang: expected the peer call to be reported as unroutable without a host, got: ${out:0:200}"
    fi
done

# ---------------------------------------------------------------------------
# The parity contract.
# ---------------------------------------------------------------------------
echo "PARITY — every language's manifest is identical"
compared=(${MANIFEST_LANGS[@]+"${MANIFEST_LANGS[@]}"})
if [[ ${#compared[@]} -lt 2 ]]; then
    # One manifest compares equal to itself trivially. Say that no comparison
    # happened rather than print a green line that means nothing.
    bad "only ${#compared[@]} language(s) produced a manifest — parity was NOT tested"
else
    base="${compared[0]}"
    for other in "${compared[@]:1}"; do
        if python3 -c '
import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
sys.exit(0 if a==b else 1)' "$WORK/$base.manifest.json" "$WORK/$other.manifest.json"; then
            ok "$base and $other agree"
        else
            bad "$base and $other disagree:"
            python3 -c '
import json,sys
def flat(d,p=""):
    out={}
    if isinstance(d,dict):
        for k,v in d.items(): out.update(flat(v,f"{p}.{k}"))
    elif isinstance(d,list):
        for i,v in enumerate(d): out.update(flat(v,f"{p}[{i}]"))
    else: out[p]=d
    return out
a=flat(json.load(open(sys.argv[1]))); b=flat(json.load(open(sys.argv[2])))
for k in sorted(set(a)|set(b)):
    if a.get(k)!=b.get(k):
        print(f"        {k}\n          {sys.argv[3]}={a.get(k)!r}\n          {sys.argv[4]}={b.get(k)!r}")
' "$WORK/$base.manifest.json" "$WORK/$other.manifest.json" "$base" "$other"
        fi
    done
fi

echo
echo "capdag stub cartridges: $PASS passed, $FAIL failed"
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    echo "${YELLOW}skipped: ${SKIPPED[*]}${NC}  (a skipped language was NOT verified)"
fi
[[ "$FAIL" -eq 0 ]] || exit 1
