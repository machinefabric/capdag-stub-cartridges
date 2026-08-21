//! __CARTRIDGE_NAME__ — a MachineFabric cartridge (Rust), scaffolded by `capdag new`.
//!
//! Reads UTF-8 text on stdin and emits a single tag word: `positive`,
//! `neutral`, or `negative`.
//!
//! The judgment is made by a REAL model: this cartridge does no inference
//! itself, it PEER-CALLS the `classify-en` cap and whichever model cartridge
//! the host has installed answers it. That is the shape most cartridges want —
//! own the domain logic, delegate the model — and it is what makes this the
//! smallest useful cartridge rather than a toy: one custom cap, one Op that
//! calls a peer, one manifest, one main().
//!
//! Develop it with:
//!     cargo build --release                     # the entry the host launches
//!     capdag dev-install .                      # install under the local `dev` slug
//!     echo "I love this" | capdag __CARTRIDGE_NAME__
//!     # edit the labels or the peer cap, then re-run both to update

use anyhow::Result;
use capdag::standard::caps::identity_urn;
use capdag::{
    async_trait, ArgSource, Cap, CapArg, CapGroup, CapManifest, CapOutput, CapUrn, CapUrnBuilder,
    CartridgeChannel, CartridgeRuntime, DryContext, Op, OpError, OpMetadata, OpResult, Request,
    WetContext, WET_KEY_REQUEST,
};
use serde_json::Value as JsonValue;
use std::sync::Arc;

// --- The peer cap this cartridge delegates to. ------------------------------

/// `classify-en` — closed-set labeling by a real model, provided by whichever
/// model cartridge the host has installed.
///
/// The labels are token-level constrained to the set we pass, so the answer is
/// always one of them: a hallucinated label is impossible by construction, and
/// this cartridge does not have to defend against one.
const CLASSIFY_CAP: &str =
    r#"cap:classify;constrained;in="media:enc=utf-8";language=en;out="media:fmt=json;record;semantic-judgment""#;

/// The item being classified, and the allowed labels — both addressed by MEDIA
/// URN, which is how a peer call names its arguments.
const CLASSIFY_ITEM_MEDIA: &str = "media:enc=utf-8";
const CLASSIFY_LABELS_MEDIA: &str = "media:enc=utf-8;label-set";

const LABELS: &str = "positive,neutral,negative";

// --- Op — implements the cap. -----------------------------------------------

#[derive(Default)]
struct TagOp;

#[async_trait]
impl Op<()> for TagOp {
    async fn perform(&self, _dry: &mut DryContext, wet: &mut WetContext) -> OpResult<()> {
        let req: Arc<Request> = wet
            .get_required::<Request>(WET_KEY_REQUEST)
            .map_err(|e| OpError::ExecutionFailed(e.to_string()))?;

        // Drain the (finite) input stream and decode as UTF-8 text.
        let streams = req
            .take_input()
            .map_err(|e| OpError::ExecutionFailed(e.to_string()))?
            .collect_streams()
            .await
            .map_err(|e| OpError::ExecutionFailed(e.to_string()))?;
        let bytes: Vec<u8> = streams.into_iter().flat_map(|(_, body, _)| body).collect();

        let output = req.output();
        output
            .start(false, None)
            .map_err(|e| OpError::ExecutionFailed(e.to_string()))?;

        // Ask the model cartridge. `call_with_bytes` opens the call, writes each
        // argument, and finishes it; arguments are addressed by media URN, not
        // by position.
        let response = req
            .peer()
            .call_with_bytes(
                CLASSIFY_CAP,
                &[
                    (CLASSIFY_ITEM_MEDIA, bytes.as_slice()),
                    (CLASSIFY_LABELS_MEDIA, LABELS.as_bytes()),
                ],
            )
            .await
            .map_err(|e| OpError::ExecutionFailed(e.to_string()))?;

        // FORWARDING collector: inference is slow and the model reports
        // progress as it goes. A plain `collect_bytes` REJECTS those LOG frames
        // rather than discarding them silently, so a peer that talks must be
        // collected through a forwarder. The peer's 0..1 progress is rescaled
        // into the 0.0..0.9 slice of ours, leaving the last tenth for our own
        // work below.
        let judgment = response
            .collect_bytes_forwarding(output, 0.0, 0.9)
            .await
            .map_err(|e| OpError::ExecutionFailed(e.to_string()))?;

        // The judgment record is {"label", "confidence", "reason"}; the label is
        // one of the labels we asked for.
        let record: JsonValue = serde_json::from_slice(&judgment).map_err(|e| {
            OpError::ExecutionFailed(format!(
                "classify returned something that is not a semantic-judgment record: {e}"
            ))
        })?;
        let label = record
            .get("label")
            .and_then(|v| v.as_str())
            .ok_or_else(|| {
                OpError::ExecutionFailed(
                    "the semantic-judgment record has no string `label` field".to_string(),
                )
            })?;

        output.finish(1.0, &format!("classified as {label}"));
        output
            .emit_cbor(&ciborium::Value::Text(label.to_string()))
            .await
            .map_err(|e| OpError::ExecutionFailed(e.to_string()))
    }

    fn metadata(&self) -> OpMetadata {
        OpMetadata::builder("TagOp")
            .description("Classify text as positive / neutral / negative")
            .build()
    }
}

// --- URN + manifest. Media/cap URNs are seeded from the project name so they -
//     are unique per project and never collide with the published fabric. -----

const IN_MEDIA: &str = "media:enc=utf-8;__CARTRIDGE_NAME__-input";
const OUT_MEDIA: &str = "media:enc=utf-8;__CARTRIDGE_NAME__-tag";

/// Build the cap URN ONCE via the builder, so the string we register with
/// matches the runtime's canonical (alphabetically-sorted) byte form.
fn cap_urn() -> CapUrn {
    CapUrnBuilder::new()
        .marker("__CARTRIDGE_NAME__")
        .in_spec(IN_MEDIA)
        .out_spec(OUT_MEDIA)
        .build()
        .expect("BUG: the scaffolded cap URN is invalid")
}

fn build_manifest() -> CapManifest {
    let mut cap = Cap::new(
        cap_urn(),
        "__CARTRIDGE_NAME__".to_string(),
        vec!["__CARTRIDGE_NAME__".to_string()],
    );
    cap.cap_description =
        Some("Classify a piece of text as positive, neutral, or negative.".to_string());
    cap.add_arg(CapArg::with_description(
        IN_MEDIA,
        true,
        vec![
            ArgSource::Stdin {
                stdin: IN_MEDIA.to_string(),
            },
            ArgSource::Position { position: 0 },
        ],
        "UTF-8 text to classify.".to_string(),
    ));
    cap.set_output(CapOutput {
        media_urn: OUT_MEDIA.to_string(),
        output_description:
            "One of the literal strings 'positive', 'neutral', or 'negative'.".to_string(),
        is_sequence: false,
        streaming: false,
        metadata: None,
    });

    // Every cartridge advertises CAP_IDENTITY; the runtime auto-registers its handler.
    let identity = Cap::new(
        identity_urn(),
        "Identity".to_string(),
        vec!["identity".to_string()],
    );

    CapManifest::new(
        "__CARTRIDGE_NAME__".to_string(),
        "0.1.0".to_string(),
        CartridgeChannel::Nightly, // 'Release' or 'Nightly'; nightly for dev.
        None,                      // None => dev cartridge (installed locally).
        "Classify a piece of text as positive, neutral, or negative.".to_string(),
        vec![CapGroup {
            name: "default".to_string(),
            caps: vec![identity, cap],
            adapter_urns: Vec::new(),
        }],
    )
}

#[tokio::main]
async fn main() -> Result<()> {
    let mut runtime = CartridgeRuntime::with_manifest(build_manifest());
    runtime.register_op_type::<TagOp>(&cap_urn().to_string());
    // `?`: the runtime returns its own RuntimeError, which anyhow adopts.
    runtime.run().await?;
    Ok(())
}
