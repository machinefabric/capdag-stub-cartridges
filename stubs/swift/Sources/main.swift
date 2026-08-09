// __CARTRIDGE_NAME__ — a MachineFabric cartridge (Swift), scaffolded by `capdag new`.
//
// Reads UTF-8 text on stdin and emits a single tag word: `positive`,
// `neutral`, or `negative`. This is the smallest useful shape of a cartridge:
// one custom cap, one Op, one manifest, one main. Replace classify() and the
// input/output media URNs to build your own capability.
//
// Develop it with:
//     swift build -c release                    # the entry the host launches
//     capdag dev-install .                      # install under the local `dev` slug
//     echo "I love this" | capdag __CARTRIDGE_NAME__
//     # edit classify(), then re-run both to update

import Foundation
import Bifaci
import CapDAG
import Ops

// --- Domain logic — pure Swift, no MachineFabric awareness. -----------------

let positiveWords: Set<String> = [
    "good", "great", "love", "happy", "excellent",
    "wonderful", "amazing", "fantastic", "delightful",
]
let negativeWords: Set<String> = [
    "bad", "terrible", "hate", "sad", "awful",
    "disappointing", "horrible", "miserable", "broken",
]

/// Return one of `positive`, `neutral`, `negative` for the input.
///
/// Case-insensitive whole-word match against two small word lists. Replace
/// this with a real model when you graduate from `getting started`.
func classify(_ text: String) -> String {
    var pos = 0
    var neg = 0
    for raw in text.split(whereSeparator: { $0.isWhitespace }) {
        let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:")).lowercased()
        if positiveWords.contains(token) { pos += 1 }
        if negativeWords.contains(token) { neg += 1 }
    }
    if pos > neg { return "positive" }
    if neg > pos { return "negative" }
    return "neutral"
}

// --- Op — implements the cap. -----------------------------------------------

struct TagOp: Op, Sendable {
    typealias Output = Void

    func perform(dry: DryContext, wet: WetContext) async throws {
        let req = try wet.getRequired(CborRequest.self, for: WET_KEY_REQUEST)
        // Drain the (finite) input stream and decode as UTF-8 text.
        let payload = try req.takeInput().collectAllBytes()
        let text = String(decoding: payload, as: UTF8.self)

        // emitCbor writes one CHUNK frame; the runtime emits END for us.
        let out = req.output()
        try out.start(isSequence: false)
        try await out.emitCbor(.utf8String(classify(text)))
    }

    func metadata() -> OpMetadata {
        OpMetadata.builder("TagOp")
            .description("Classify text as positive / neutral / negative")
            .build()
    }
}

// --- URN + manifest. Media/cap URNs are seeded from the project name so they -
//     are unique per project and never collide with the published fabric. -----

let inMedia = "media:enc=utf-8;__CARTRIDGE_NAME__-input"
let outMedia = "media:enc=utf-8;__CARTRIDGE_NAME__-tag"

/// Build the cap URN ONCE via the builder, so the string we register with
/// matches the runtime's canonical (alphabetically-sorted) byte form.
func capURN() -> String {
    do {
        // Two Objective-C bridging details: `+builder` imports as `init()`, and
        // `build:` takes an NSError** which imports as a throwing call rather
        // than an inout argument.
        let urn = try CSCapUrnBuilder()
            .marker("__CARTRIDGE_NAME__")
            .inSpec(inMedia)
            .outSpec(outMedia)
            .build()
        return urn.toString()
    } catch {
        fatalError("BUG: the scaffolded cap URN is invalid: \(error)")
    }
}

func buildManifest() -> Manifest {
    let cap = CapDefinition(
        urn: capURN(),
        title: "__CARTRIDGE_NAME__",
        aliases: ["__CARTRIDGE_NAME__"],
        capDescription: "Classify a piece of text as positive, neutral, or negative.",
        args: [
            CapArg(
                mediaUrn: inMedia,
                required: true,
                sources: [.stdin(inMedia), .positional(0)],
                argDescription: "UTF-8 text to classify."
            )
        ],
        output: CapOutput(
            mediaUrn: outMedia,
            outputDescription: "One of the literal strings 'positive', 'neutral', or 'negative'."
        )
    )

    // Every cartridge advertises CAP_IDENTITY; the runtime auto-registers its handler.
    let identity = CapDefinition(urn: CSCapIdentity, title: "Identity", aliases: ["identity"])

    return Manifest(
        name: "__CARTRIDGE_NAME__",
        version: "0.1.0",
        channel: "nightly",   // 'nightly' or 'release'; nightly for dev.
        registryURL: nil,     // nil => dev cartridge (installed locally).
        description: "Classify a piece of text as positive, neutral, or negative.",
        capGroups: [CapGroup(name: "default", caps: [identity, cap])]
    )
}

// --- main -------------------------------------------------------------------

let manifestData = try JSONEncoder().encode(buildManifest())
let runtime = CartridgeRuntime(manifest: manifestData)
runtime.register_op_type(capUrn: capURN(), make: TagOp.init)

do {
    try runtime.run()
} catch {
    FileHandle.standardError.write(Data("[__CARTRIDGE_NAME__] Runtime error: \(error)\n".utf8))
    exit(1)
}
