# __CARTRIDGE_NAME__

A MachineFabric cartridge scaffolded by `capdag new`. It reads UTF-8 text on
stdin and emits `positive`, `neutral`, or `negative`.

## Develop

```bash
# 1. Build the entry the host launches:
go mod tidy
go build -o __CARTRIDGE_NAME__ .

# 2. Install this cartridge under the local `dev` slug:
capdag dev-install .

# 3. Run your cap through the capdag host:
echo "I love this" | capdag __CARTRIDGE_NAME__
# => positive

# 4. Edit classify() in cartridge.go, then re-run steps 1-2 to update the install:
go build -o __CARTRIDGE_NAME__ . && capdag dev-install .
```

Unlike the Python cartridge, the entry here is a COMPILED binary, so an edit
does not reach the host until you rebuild. `capdag dev-install` installs the
binary named in the manifest, not the sources.

The cap is a *dev* cap: it is not published to the fabric, so you can develop
and run it locally as long as its alias (`__CARTRIDGE_NAME__`) does not collide
with a published cap.
