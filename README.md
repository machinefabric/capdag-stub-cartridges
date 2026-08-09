# capdag-stub-cartridges

The canonical cartridge stubs `capdag new` scaffolds, in every language capdag
supports — one source of truth that all five capdag implementations reproduce.

`capdag new <name> --<language>` must write the same project whichever capdag
binary you run it from. A stub kept privately inside each implementation would
drift the moment one of them was edited, and the drift would be invisible: five
CLIs each producing a slightly different "canonical" starting point. So the
stubs live here, and every implementation renders *these* files.

## The contract

`stubs.json` is the machine-readable form, and it is what an implementation
reads. Per language it declares:

| field | meaning |
|---|---|
| `flag` | the `capdag new` flag that selects this language |
| `entry` | the executable the host launches (rendered, so a compiled entry can be named after the project) |
| `build` | commands that turn the sources into `entry` — empty for interpreted languages |
| `runtime` | the cartridge runtime package the stub imports, and how to install it |
| `files` | `source` in this repo → `dest` in the scaffolded project, plus the executable bit |

Every occurrence of the `placeholder` (`__CARTRIDGE_NAME__`) in a file's
**contents and in its `dest` and `entry`** is replaced with the project name.
There is no other templating: no conditionals, no loops, no partials. A stub is
a real, runnable project that happens to have its name spelled with a
placeholder, which is what makes it reviewable and testable as itself.

`.gitignore` is stored as `gitignore` (no dot) and renamed on render — a real
dotfile here would apply to this repository rather than to the scaffolded one.

## What every stub does

The same thing, so the languages can be compared line by line: read UTF-8 text
on stdin, and emit `positive`, `neutral`, or `negative`.

It is the smallest *useful* shape of a cartridge — one custom cap, one Op, one
manifest, one main — rather than a hello-world that teaches nothing about the
protocol. Media and cap URNs are seeded from the project name so a scaffolded
cap can never collide with a published one.

Because they implement the same cap, every stub's `manifest` subcommand emits
**byte-identical JSON** for the same project name. That equality is the parity
test: it catches a mirror whose cap builder, argument sources, or URN
canonicalization has drifted from the rest.

## Languages

| Language | Entry | Runtime package |
|---|---|---|
| Python | `cartridge.py` | `capdag` on PyPI |
| Go | compiled, named after the project | `github.com/machinefabric/capdag-go` |

A language belongs here once its cartridge runtime is installable by name. A
stub whose `import` cannot be resolved is not a starting point, it is a broken
project handed to someone on their first minute with the tool.

## Tests

`./test.sh` renders every stub under a temporary name, builds it, runs its
`manifest` subcommand, and asserts that all languages agree — both that each
one builds and runs, and that their manifests are identical.
