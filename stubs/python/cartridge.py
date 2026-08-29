#!/usr/bin/env python3
"""__CARTRIDGE_NAME__ — a CapDAG cartridge (Python), scaffolded by `capdag new`.

Reads UTF-8 text on stdin and emits a single tag word: `positive`,
`neutral`, or `negative`.

The judgment is made by a REAL model: this cartridge does no inference itself,
it PEER-CALLS the `classify-en` cap and whichever model cartridge the host has
installed answers it. That is the shape most cartridges want — own the domain
logic, delegate the model — and it is what makes this the smallest useful
cartridge rather than a toy: one custom cap, one Op that calls a peer, one
manifest, one main().

Develop it with:
    capdag dev-install .          # install/update under the local `dev` slug
    echo "I love this" | capdag __CARTRIDGE_NAME__
    # edit the labels or the peer cap, then re-run `capdag dev-install .`
"""

import json

from capdag.bifaci.cartridge_runtime import (
    CartridgeRuntime,
    Request,
    WET_KEY_REQUEST,
    demux_peer_response,
)
from capdag.cap.caller import CapArgumentValue
from capdag.bifaci.manifest import CapManifest, default_group
from capdag.cap.definition import (
    Cap,
    CapArg,
    CapOutput,
    PositionSource,
    StdinSource,
)
from capdag.standard.caps import CAP_IDENTITY
from capdag.urn.cap_urn import CapUrn, CapUrnBuilder
from ops import DryContext, Op, OpMetadata, WetContext


# --- The peer cap this cartridge delegates to. ------------------------------

# `classify-en` — closed-set labeling by a real model, provided by whichever
# model cartridge the host has installed.
#
# The labels are token-level constrained to the set we pass, so the answer is
# always one of them: a hallucinated label is impossible by construction, and
# this cartridge does not have to defend against one.
CLASSIFY_CAP = (
    'cap:classify;constrained;in="media:enc=utf-8";language=en;'
    'out="media:fmt=json;record;semantic-judgment"'
)

# The item being classified, and the allowed labels — both addressed by MEDIA
# URN, which is how a peer call names its arguments.
CLASSIFY_ITEM_MEDIA = "media:enc=utf-8"
CLASSIFY_LABELS_MEDIA = "media:enc=utf-8;label-set"

LABELS = "positive,neutral,negative"


# --- Op — implements the cap. -----------------------------------------------

class TagOp(Op):
    async def perform(self, dry: DryContext, wet: WetContext) -> None:
        req: Request = wet.get_required(WET_KEY_REQUEST)
        # Drain the (finite) input stream(s) and decode as UTF-8 text.
        text = req.take_input().collect_all_bytes().decode("utf-8")

        emitter = req.emitter()
        emitter.start(False)

        # Ask the model cartridge. Arguments are addressed by media URN, not by
        # position.
        peer_frames = req.peer().invoke(
            CLASSIFY_CAP,
            [
                CapArgumentValue(CLASSIFY_ITEM_MEDIA, text.encode("utf-8")),
                CapArgumentValue(CLASSIFY_LABELS_MEDIA, LABELS.encode("utf-8")),
            ],
        )

        # FORWARDING collector: inference is slow and the model reports progress
        # as it goes. A plain collect_bytes REJECTS those LOG frames rather than
        # discarding them silently, so a peer that talks must be collected
        # through a forwarder. The peer's 0..1 progress is rescaled into the
        # 0.0..0.9 slice of ours, leaving the last tenth for our own work below.
        judgment = demux_peer_response(peer_frames).collect_bytes_forwarding(
            emitter, 0.0, 0.9
        )

        # The judgment record is {"label", "confidence", "reason"}; the label is
        # one of the labels we asked for.
        try:
            record = json.loads(judgment)
        except ValueError as error:
            raise RuntimeError(
                f"classify returned something that is not a semantic-judgment record: {error}"
            ) from error
        label = record.get("label")
        if not isinstance(label, str):
            raise RuntimeError("the semantic-judgment record has no string `label` field")

        emitter.finish(1.0, f"classified as {label}")
        emitter.emit_cbor(label)

    def metadata(self) -> OpMetadata:
        return (
            OpMetadata.builder("TagOp")
            .description("Classify text as positive / neutral / negative")
            .build()
        )


# --- URN + manifest. Media/cap URNs are seeded from the project name so they -
#     are unique per project and never collide with the published fabric. -----

IN_MEDIA = "media:enc=utf-8;__CARTRIDGE_NAME__-input"
OUT_MEDIA = "media:enc=utf-8;__CARTRIDGE_NAME__-tag"


def _cap_urn() -> CapUrn:
    """Build the cap URN ONCE via the builder, so the string we register with
    matches the runtime's canonical (alphabetically-sorted) byte form."""
    return (
        CapUrnBuilder()
        .marker("__CARTRIDGE_NAME__")
        .in_spec(IN_MEDIA)
        .out_spec(OUT_MEDIA)
        .build()
    )


CAP_URN: str = _cap_urn().to_string()


def build_manifest() -> CapManifest:
    cap = Cap(_cap_urn(), "__CARTRIDGE_NAME__", ["__CARTRIDGE_NAME__"])
    cap.cap_description = "Classify a piece of text as positive, neutral, or negative."
    cap.args = [
        CapArg(
            media_urn=IN_MEDIA,
            required=True,
            sources=[StdinSource(IN_MEDIA), PositionSource(0)],
            arg_description="UTF-8 text to classify.",
        )
    ]
    cap.output = CapOutput(
        media_urn=OUT_MEDIA,
        output_description="One of the literal strings 'positive', 'neutral', or 'negative'.",
    )

    # Every cartridge advertises CAP_IDENTITY; the runtime auto-registers its handler.
    identity = Cap(CapUrn.from_string(CAP_IDENTITY), "Identity", ["identity"])

    return CapManifest(
        name="__CARTRIDGE_NAME__",
        version="1.80.651",
        channel="nightly",          # 'nightly' or 'release'; nightly for dev.
        registry_url=None,           # None => dev cartridge (installed locally).
        description="Classify a piece of text as positive, neutral, or negative.",
        cap_groups=[default_group([identity, cap])],
    )


def main() -> None:
    runtime = CartridgeRuntime.with_manifest(build_manifest())
    runtime.register_op_type(CAP_URN, TagOp)
    runtime.run()


if __name__ == "__main__":
    main()
