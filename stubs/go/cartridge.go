// __CARTRIDGE_NAME__ — a CapDAG cartridge (Go), scaffolded by `capdag new`.
//
// Reads UTF-8 text on stdin and emits a single tag word: `positive`,
// `neutral`, or `negative`.
//
// The judgment is made by a REAL model: this cartridge does no inference
// itself, it PEER-CALLS the `classify-en` cap and whichever model cartridge the
// host has installed answers it. That is the shape most cartridges want — own
// the domain logic, delegate the model — and it is what makes this the smallest
// useful cartridge rather than a toy: one custom cap, one Op that calls a peer,
// one manifest, one main().
//
// Develop it with:
//
//	go build -buildvcs=false -o __CARTRIDGE_NAME__ .   # the entry the host launches
//	capdag dev-install .               # install/update under the local `dev` slug
//	echo "I love this" | capdag __CARTRIDGE_NAME__
//	# edit the labels or the peer cap, then rebuild + re-install to update
package main

import (
	"encoding/json"
	"fmt"
	"os"

	capdag "github.com/machinefabric/capdag-go"
	"github.com/machinefabric/capdag-go/bifaci"
	"github.com/machinefabric/capdag-go/cap"
	"github.com/machinefabric/capdag-go/urn"
)

// --- The peer cap this cartridge delegates to. ------------------------------

// classifyCap is `classify-en` — closed-set labeling by a real model, provided
// by whichever model cartridge the host has installed.
//
// The labels are token-level constrained to the set we pass, so the answer is
// always one of them: a hallucinated label is impossible by construction, and
// this cartridge does not have to defend against one.
const classifyCap = `cap:classify;constrained;in="media:enc=utf-8";language=en;out="media:fmt=json;record;semantic-judgment"`

// The item being classified, and the allowed labels — both addressed by MEDIA
// URN, which is how a peer call names its arguments.
const (
	classifyItemMedia   = "media:enc=utf-8"
	classifyLabelsMedia = "media:enc=utf-8;label-set"
	labels              = "positive,neutral,negative"
)

// --- Op — implements the cap. -----------------------------------------------

type TagOp struct{}

func (op *TagOp) Perform(req *bifaci.Request) error {
	// Drain the (finite) input stream and decode as UTF-8 text.
	text, err := collectText(req.Frames())
	if err != nil {
		return err
	}

	output := req.Output()
	if err := output.StartUnbounded(false); err != nil {
		return err
	}

	// Ask the model cartridge. Arguments are addressed by media URN, not by
	// position.
	peerFrames, err := req.Peer().Invoke(classifyCap, []cap.CapArgumentValue{
		cap.NewCapArgumentValue(classifyItemMedia, []byte(text)),
		cap.NewCapArgumentValue(classifyLabelsMedia, []byte(labels)),
	})
	if err != nil {
		return fmt.Errorf("classify peer call failed: %w", err)
	}

	// FORWARDING collector: inference is slow and the model reports progress as
	// it goes. A plain CollectBytes REJECTS those LOG frames rather than
	// discarding them silently, so a peer that talks must be collected through a
	// forwarder. The peer's 0..1 progress is rescaled into the 0.0..0.9 slice of
	// ours, leaving the last tenth for our own work below.
	judgment, err := bifaci.DemuxPeerResponse(peerFrames).CollectBytesForwarding(output, 0.0, 0.9)
	if err != nil {
		return err
	}

	// The judgment record is {"label", "confidence", "reason"}; the label is one
	// of the labels we asked for.
	var record struct {
		Label string `json:"label"`
	}
	if err := json.Unmarshal(judgment, &record); err != nil {
		return fmt.Errorf("classify returned something that is not a semantic-judgment record: %w", err)
	}
	if record.Label == "" {
		return fmt.Errorf("the semantic-judgment record has no string `label` field")
	}

	output.Finish(1.0, fmt.Sprintf("classified as %s", record.Label))
	return output.EmitCbor(record.Label)
}

// collectText reassembles the request's CHUNK payloads, stopping at END.
func collectText(frames <-chan bifaci.Frame) (string, error) {
	var payload []byte
	for frame := range frames {
		switch frame.FrameType {
		case bifaci.FrameTypeChunk:
			if err := bifaci.VerifyChunkChecksum(&frame); err != nil {
				return "", fmt.Errorf("corrupted data: %w", err)
			}
			if frame.Payload == nil {
				continue
			}
			chunk, err := bifaci.DecodeChunkPayload(frame.Payload)
			if err != nil {
				return "", err
			}
			payload = append(payload, chunk...)
		case bifaci.FrameTypeEnd:
			return string(payload), nil
		}
	}
	return string(payload), nil
}

// --- URN + manifest. Media/cap URNs are seeded from the project name so they -
//     are unique per project and never collide with the published fabric. -----

const (
	inMedia  = "media:enc=utf-8;__CARTRIDGE_NAME__-input"
	outMedia = "media:enc=utf-8;__CARTRIDGE_NAME__-tag"
)

// capURN builds the cap URN ONCE via the builder, so the string we register
// with matches the runtime's canonical (alphabetically-sorted) byte form.
func capURN() *urn.CapUrn {
	built, err := urn.NewCapUrnBuilder().
		Marker("__CARTRIDGE_NAME__").
		InSpec(inMedia).
		OutSpec(outMedia).
		Build()
	if err != nil {
		panic(fmt.Sprintf("BUG: the scaffolded cap URN is invalid: %v", err))
	}
	return built
}

func buildManifest() *bifaci.CapManifest {
	c := cap.NewCap(capURN(), "__CARTRIDGE_NAME__", []string{"__CARTRIDGE_NAME__"})
	c.CapDescription = cap.StringPtr("Classify a piece of text as positive, neutral, or negative.")
	stdin := inMedia
	position := 0
	c.Args = []cap.CapArg{{
		MediaUrn: inMedia,
		Required: true,
		Sources: []cap.ArgSource{
			{Stdin: &stdin},
			{Position: &position},
		},
		ArgDescription: cap.StringPtr("UTF-8 text to classify."),
	}}
	c.Output = &cap.CapOutput{
		MediaUrn:          outMedia,
		OutputDescription: "One of the literal strings 'positive', 'neutral', or 'negative'.",
	}

	// Every cartridge advertises CAP_IDENTITY; the runtime auto-registers its handler.
	identityURN, err := urn.NewCapUrnFromString(capdag.CapIdentity)
	if err != nil {
		panic(fmt.Sprintf("BUG: CapIdentity is invalid: %v", err))
	}
	identity := cap.NewCap(identityURN, "Identity", []string{"identity"})

	return capdag.NewCapManifest(
		"__CARTRIDGE_NAME__",
		"1.112.1059",
		"nightly", // 'nightly' or 'release'; nightly for dev.
		nil,       // nil => dev cartridge (installed locally).
		"Classify a piece of text as positive, neutral, or negative.",
		[]capdag.CapGroup{capdag.DefaultGroup([]cap.Cap{*identity, *c})},
	)
}

func main() {
	runtime, err := capdag.NewCartridgeRuntimeWithManifest(buildManifest())
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to create runtime: %v\n", err)
		os.Exit(1)
	}
	runtime.RegisterOp(capURN().String(), &TagOp{})
	if err := runtime.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "runtime error: %v\n", err)
		os.Exit(1)
	}
}
