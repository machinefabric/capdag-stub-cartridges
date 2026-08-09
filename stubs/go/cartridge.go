// __CARTRIDGE_NAME__ — a MachineFabric cartridge (Go), scaffolded by `capdag new`.
//
// Reads UTF-8 text on stdin and emits a single tag word: `positive`,
// `neutral`, or `negative`. This is the smallest useful shape of a cartridge:
// one custom cap, one Op, one manifest, one main(). Replace classify() and
// the input/output media URNs to build your own capability.
//
// Develop it with:
//
//	go build -o __CARTRIDGE_NAME__ .   # the entry the host launches
//	capdag dev-install .               # install/update under the local `dev` slug
//	echo "I love this" | capdag __CARTRIDGE_NAME__
//	# edit classify(), then re-run `go build` + `capdag dev-install .` to update
package main

import (
	"fmt"
	"os"
	"strings"

	capdag "github.com/machinefabric/capdag-go"
	"github.com/machinefabric/capdag-go/bifaci"
	"github.com/machinefabric/capdag-go/cap"
	"github.com/machinefabric/capdag-go/urn"
)

// --- Domain logic — pure Go, no MachineFabric awareness. --------------------

var positiveWords = map[string]bool{
	"good": true, "great": true, "love": true, "happy": true, "excellent": true,
	"wonderful": true, "amazing": true, "fantastic": true, "delightful": true,
}

var negativeWords = map[string]bool{
	"bad": true, "terrible": true, "hate": true, "sad": true, "awful": true,
	"disappointing": true, "horrible": true, "miserable": true, "broken": true,
}

// classify returns one of `positive`, `neutral`, `negative` for the input.
//
// Case-insensitive whole-word match against two small word lists. Replace
// this with a real model when you graduate from `getting started`.
func classify(text string) string {
	pos, neg := 0, 0
	for _, token := range strings.Fields(text) {
		token = strings.ToLower(strings.Trim(token, ".,!?;:"))
		if positiveWords[token] {
			pos++
		}
		if negativeWords[token] {
			neg++
		}
	}
	if pos > neg {
		return "positive"
	}
	if neg > pos {
		return "negative"
	}
	return "neutral"
}

// --- Op — implements the cap. -----------------------------------------------

type TagOp struct{}

func (op *TagOp) Perform(req *bifaci.Request) error {
	// Drain the (finite) input stream and decode as UTF-8 text.
	text, err := collectText(req.Frames())
	if err != nil {
		return err
	}
	// EmitCbor writes one CHUNK frame; the runtime emits END for us.
	return req.Output().EmitCbor(classify(text))
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
		"0.1.0",
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
