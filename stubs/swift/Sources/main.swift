// __CARTRIDGE_NAME__ — a MachineFabric cartridge (Swift), scaffolded by `capdag new`.
//
// Reads UTF-8 text on stdin and emits a single tag word: `positive`,
// `neutral`, or `negative`.
//
// The judgment is made by a REAL model: this cartridge does no inference
// itself, it PEER-CALLS the `classify-en` cap and whichever model cartridge the
// host has installed answers it. That is the shape most cartridges want — own
// the domain logic, delegate the model — and it is what makes this the smallest
// useful cartridge rather than a toy: one custom cap, one Op that calls a peer,
// one manifest, one main.
//
// Develop it with:
//     swift build -c release                    # the entry the host launches
//     capdag dev-install .                      # install under the local `dev` slug
//     echo "I love this" | capdag __CARTRIDGE_NAME__
//     # edit the labels or the peer cap, then re-run both to update

import Foundation
import Bifaci
import CapDAG
import Ops

// --- The peer cap this cartridge delegates to. ------------------------------

/// `classify-en` — closed-set labeling by a real model, provided by whichever
/// model cartridge the host has installed.
///
/// The labels are token-level constrained to the set we pass, so the answer is
/// always one of them: a hallucinated label is impossible by construction, and
/// this cartridge does not have to defend against one.
let classifyCap =
    "cap:classify;constrained;in=\"media:enc=utf-8\";language=en;"
    + "out=\"media:fmt=json;record;semantic-judgment\""

/// The item being classified, and the allowed labels — both addressed by MEDIA
/// URN, which is how a peer call names its arguments.
let classifyItemMedia = "media:enc=utf-8"
let classifyLabelsMedia = "media:enc=utf-8;label-set"

let labels = "positive,neutral,negative"

/// The shape `classify-en` answers with: {"label", "confidence", "reason"}.
struct SemanticJudgment: Decodable {
    let label: String
}

// --- Op — implements the cap. -----------------------------------------------

struct TagOp: Op, Sendable {
    typealias Output = Void

    func perform(dry: DryContext, wet: WetContext) async throws {
        let req = try wet.getRequired(CborRequest.self, for: WET_KEY_REQUEST)
        // Drain the (finite) input stream and decode as UTF-8 text.
        let payload = try req.takeInput().collectAllBytes()
        let text = String(decoding: payload, as: UTF8.self)

        let out = req.output()
        try out.start(isSequence: false)

        // Ask the model cartridge. Arguments are addressed by media URN, not by
        // position.
        let response = try req.peer().callWithBytes(
            capUrn: classifyCap,
            args: [
                (mediaUrn: classifyItemMedia, data: Data(text.utf8)),
                (mediaUrn: classifyLabelsMedia, data: Data(labels.utf8)),
            ]
        )

        // FORWARDING collector: inference is slow and the model reports progress
        // as it goes. A plain collectBytes REJECTS those LOG frames rather than
        // discarding them silently, so a peer that talks must be collected
        // through a forwarder. The peer's 0..1 progress is rescaled into the
        // 0.0..0.9 slice of ours, leaving the last tenth for our own work below.
        let judgment = try response.collectBytesForwarding(
            output: out, progressBase: 0.0, progressWeight: 0.9)

        // The judgment record is {"label", "confidence", "reason"}; the label is
        // one of the labels we asked for.
        let record: SemanticJudgment
        do {
            record = try JSONDecoder().decode(SemanticJudgment.self, from: judgment)
        } catch {
            throw CartridgeRuntimeError.handlerError(
                "classify returned something that is not a semantic-judgment record: \(error)")
        }

        out.finish(progress: 1.0, message: "classified as \(record.label)")
        try await out.emitCbor(.utf8String(record.label))
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
        version: "1.60.400",
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
