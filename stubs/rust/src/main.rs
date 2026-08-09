//! __CARTRIDGE_NAME__ — a MachineFabric cartridge (Rust), scaffolded by `capdag new`.
//!
//! Reads UTF-8 text on stdin and emits a single tag word: `positive`,
//! `neutral`, or `negative`. This is the smallest useful shape of a cartridge:
//! one custom cap, one Op, one manifest, one main(). Replace `classify()` and
//! the input/output media URNs to build your own capability.
//!
//! Develop it with:
//!     cargo build --release                     # the entry the host launches
//!     capdag dev-install .                      # install under the local `dev` slug
//!     echo "I love this" | capdag __CARTRIDGE_NAME__
//!     # edit classify(), then re-run both to update

use anyhow::Result;
use capdag::standard::caps::identity_urn;
use capdag::{
    async_trait, ArgSource, Cap, CapArg, CapGroup, CapManifest, CapOutput, CapUrn, CapUrnBuilder,
    CartridgeChannel, CartridgeRuntime, DryContext, Op, OpError, OpMetadata, OpResult, Request,
    WetContext, WET_KEY_REQUEST,
};
use std::sync::Arc;

// --- Domain logic — pure Rust, no MachineFabric awareness. ------------------

const POSITIVE_WORDS: [&str; 9] = [
    "good", "great", "love", "happy", "excellent", "wonderful", "amazing", "fantastic",
    "delightful",
];
const NEGATIVE_WORDS: [&str; 9] = [
    "bad", "terrible", "hate", "sad", "awful", "disappointing", "horrible", "miserable", "broken",
];

/// Return one of `positive`, `neutral`, `negative` for the input.
///
/// Case-insensitive whole-word match against two small word lists. Replace
/// this with a real model when you graduate from `getting started`.
fn classify(text: &str) -> &'static str {
    let mut pos = 0usize;
    let mut neg = 0usize;
    for token in text.split_whitespace() {
        let token = token.trim_matches(|c| ".,!?;:".contains(c)).to_lowercase();
        if POSITIVE_WORDS.contains(&token.as_str()) {
            pos += 1;
        }
        if NEGATIVE_WORDS.contains(&token.as_str()) {
            neg += 1;
        }
    }
    if pos > neg {
        "positive"
    } else if neg > pos {
        "negative"
    } else {
        "neutral"
    }
}

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
        let text = String::from_utf8_lossy(&bytes);

        // emit_cbor writes one CHUNK frame; the runtime emits END for us.
        let output = req.output();
        output
            .start(false, None)
            .map_err(|e| OpError::ExecutionFailed(e.to_string()))?;
        output
            .emit_cbor(&ciborium::Value::Text(classify(&text).to_string()))
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
