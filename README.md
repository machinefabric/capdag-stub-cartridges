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

The judgment comes from a REAL model. No stub classifies anything itself — each
PEER-CALLS `classify-en` and whichever model cartridge the host has installed
answers. That is deliberate: delegating the model while owning the domain logic
is the shape most cartridges want, and a stub that faked it with a word list
would teach the wrong thing about the protocol on someone's first day.

Three details are worth reading in whichever language you know best, because
they are the parts people get wrong:

- **Peer arguments are addressed by MEDIA URN**, not by position — the item goes
  to `media:enc=utf-8`, the allowed labels to `media:enc=utf-8;label-set`.
- **The response is collected through a FORWARDING collector.** Inference is
  slow and the model reports progress; a plain collector *rejects* those LOG
  frames rather than discarding them, because dropping a callee's diagnostics
  loses the only record of what it said. The peer's 0..1 progress is rescaled
  into a slice of this cartridge's own, so the caller sees one continuous
  progression.
- **The labels are token-level constrained** to the set passed, so a
  hallucinated label is impossible and the stub needs no defensive parsing.

It is the smallest *useful* shape of a cartridge — one custom cap, one Op that
calls a peer, one manifest, one main — rather than a hello-world that teaches
nothing about the protocol. Media and cap URNs are seeded from the project name
so a scaffolded cap can never collide with a published one.

Because the judgment is delegated, a stub **needs the capdag host**: run it as
`capdag <name>`, not by executing the built entry directly. Run directly it
reaches its handler and then fails there, honestly, on the unroutable peer
call.

Because they implement the same cap, every stub's `manifest` subcommand emits
**byte-identical JSON** for the same project name. That equality is the parity
test: it catches a mirror whose cap builder, argument sources, or URN
canonicalization has drifted from the rest.

## Languages

| Language | Entry | Runtime package |
|---|---|---|
| Python | `cartridge.py` | `capdag` on PyPI |
| Rust | `target/release/<name>` | `capdag` at a git tag |
| Go | `<name>`, compiled | `github.com/machinefabric/capdag-go` |
| Swift | `.build/release/<name>` | `capdag-objc` (macOS only) |

JavaScript has no stub: `capdag-js` mirrors the planner and notation surface
only — it has no cartridge runtime, host or relay — so there is nothing for a JS
cartridge to be built on.

A language belongs here once its cartridge runtime is installable by name. A
stub whose `import` cannot be resolved is not a starting point, it is a broken
project handed to someone on their first minute with the tool.

## Tests

`./test.sh` renders every stub under a temporary name, builds it, runs its
`manifest` subcommand, and asserts that all languages agree — both that each one
builds, and that their manifests are byte-identical.

It also checks that each entry REACHES its handler: run without a host the
handler is entered and then fails on the unroutable peer call, which proves
dispatch worked and that the cartridge refuses rather than inventing an answer.
Real end-to-end inference belongs to a scenario with a host and a model, not to
a contract test that must stay fast and offline.
