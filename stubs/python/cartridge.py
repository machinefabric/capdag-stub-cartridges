#!/usr/bin/env python3
"""__CARTRIDGE_NAME__ — a MachineFabric cartridge (Python), scaffolded by `capdag new`.

Reads UTF-8 text on stdin and emits a single tag word: `positive`,
`neutral`, or `negative`. This is the smallest useful shape of a cartridge:
one custom cap, one Op, one manifest, one main(). Replace `classify()` and
the input/output media URNs to build your own capability.

Develop it with:
    capdag dev-install .          # install/update under the local `dev` slug
    echo "I love this" | capdag __CARTRIDGE_NAME__
    # edit classify(), then re-run `capdag dev-install .` to update
"""

from capdag.bifaci.cartridge_runtime import (
    CartridgeRuntime,
    Request,
    WET_KEY_REQUEST,
)
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


# --- Domain logic — pure Python, no MachineFabric awareness. ----------------

POSITIVE_WORDS = {
    "good", "great", "love", "happy", "excellent",
    "wonderful", "amazing", "fantastic", "delightful",
}
NEGATIVE_WORDS = {
    "bad", "terrible", "hate", "sad", "awful",
    "disappointing", "horrible", "miserable", "broken",
}


def classify(text: str) -> str:
    """Return one of `positive`, `neutral`, `negative` for the input.

    Case-insensitive whole-word match against two small word lists. Replace
    this with a real model when you graduate from `getting started`.
    """
    tokens = {t.strip(".,!?;:").lower() for t in text.split()}
    pos = len(tokens & POSITIVE_WORDS)
    neg = len(tokens & NEGATIVE_WORDS)
    if pos > neg:
        return "positive"
    if neg > pos:
        return "negative"
    return "neutral"


# --- Op — implements the cap. -----------------------------------------------

class TagOp(Op):
    async def perform(self, dry: DryContext, wet: WetContext) -> None:
        req: Request = wet.get_required(WET_KEY_REQUEST)
        # Drain the (finite) input stream(s) and decode as UTF-8 text.
        text = req.take_input().collect_all_bytes().decode("utf-8")
        # emit_cbor writes one CHUNK frame; the runtime emits END for us.
        req.emitter().emit_cbor(classify(text))

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
        version="0.1.0",
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
