#!/usr/bin/env bash
# localize-deps.sh — point a rendered stub at the capdag WORKING COPIES.
#
# A stub's manifest pins capdag by what its NEXT release will tag (the pin is
# stamped from the mirror's own version.txt), so the bytes a scaffolder writes
# are right for the world after the release and wrong for the checkout that is
# about to make it: the tag does not exist yet. The stub suites exist to prove
# that the stub builds against THIS capdag before it is released, so they build
# the rendered project against the sibling working copies instead — by
# rewriting the one dependency line, after every byte-level check has run and
# before the build, with ABSOLUTE paths (the project lives in a temp dir).
#
# The rewrite is exact, not a search: the line it expects is the one the
# templates emit, and a manifest without it is a contract change this file
# must learn about — so that is a hard failure, never a silent no-op build
# against whatever cargo/go/swift would otherwise fetch.
#
#   localize_stub_deps <language> <project-dir> <capdag-root>
#
# <capdag-root> is the directory holding the capdag-rs / capdag-go /
# capdag-objc checkouts (the parent of this repository).

# Rewrite one file in place, portably.
#
# `sed -i -E` is not portable and fails in two different ways on the two
# platforms this runs on. BSD sed's `-i` takes the backup suffix as its own
# argument, so it swallows the `-E` — extended expressions are then off, and
# the same script either errors (`\{` becomes a BRE interval whose repetition
# count is ` git`) or, worse, quietly stops matching and leaves the dependency
# pinned to a tag that does not exist yet. The second one is silent: the
# rewrite reports success and the build fails later complaining about a
# version, with nothing pointing back to here.
#
# So: no `-i`. Read, transform, replace.
_rewrite_in_place() {   # _rewrite_in_place <file> <sed-expression>
    local file="$1" expression="$2" scratch
    scratch="$(mktemp)" || return 1
    if ! sed -E "$expression" "$file" > "$scratch"; then
        rm -f "$scratch"
        return 1
    fi
    mv "$scratch" "$file"
}
localize_stub_deps() {
    local lang="$1" dir="$2" capdag_root="$3"
    case "$lang" in
        rust)
            local manifest="$dir/Cargo.toml" path="$capdag_root/capdag-rs"
            [[ -f "$path/Cargo.toml" ]] || { echo "localize_stub_deps: no capdag-rs checkout at $path" >&2; return 1; }
            grep -qE '^capdag = \{ git = "[^"]+", tag = "v[0-9.]+" \}$' "$manifest" \
                || { echo "localize_stub_deps: $manifest has no \`capdag = { git = …, tag = … }\` line to localize — the rust stub template changed; update localize-deps.sh" >&2; return 1; }
            _rewrite_in_place "$manifest" "s|^capdag = \{ git = \"[^\"]+\", tag = \"v[0-9.]+\" \}$|capdag = { path = \"$path\" }|" \
                || { echo "localize_stub_deps: could not rewrite $manifest" >&2; return 1; }
            ;;
        go)
            local manifest="$dir/go.mod" path="$capdag_root/capdag-go"
            [[ -f "$path/go.mod" ]] || { echo "localize_stub_deps: no capdag-go checkout at $path" >&2; return 1; }
            grep -qE '^require github.com/machinefabric/capdag-go v[0-9.]+$' "$manifest" \
                || { echo "localize_stub_deps: $manifest has no \`require github.com/machinefabric/capdag-go vX.Y.Z\` line to localize — the go stub template changed; update localize-deps.sh" >&2; return 1; }
            printf '\nreplace github.com/machinefabric/capdag-go => %s\n' "$path" >> "$manifest"
            ;;
        swift)
            local manifest="$dir/Package.swift" path="$capdag_root/capdag-objc"
            [[ -f "$path/Package.swift" ]] || { echo "localize_stub_deps: no capdag-objc checkout at $path" >&2; return 1; }
            grep -qE '\.package\(url: "https://github.com/machinefabric/capdag-objc.git", from: "[0-9.]+"\)' "$manifest" \
                || { echo "localize_stub_deps: $manifest has no \`.package(url: …capdag-objc.git, from: …)\` entry to localize — the swift stub template changed; update localize-deps.sh" >&2; return 1; }
            _rewrite_in_place "$manifest" "s|\.package\(url: \"https://github.com/machinefabric/capdag-objc.git\", from: \"[0-9.]+\"\)|.package(path: \"$path\")|" \
                || { echo "localize_stub_deps: could not rewrite $manifest" >&2; return 1; }
            ;;
        python)
            # The python stub imports the `capdag` package from the interpreter
            # the suite runs it with; the suite's PYTHON carries the workspace
            # install. Nothing in the project to rewrite.
            ;;
        *)
            echo "localize_stub_deps: no localization known for '$lang' — add it before adding the stub" >&2
            return 1
            ;;
    esac
}
