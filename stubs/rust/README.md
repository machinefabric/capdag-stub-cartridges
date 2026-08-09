# __CARTRIDGE_NAME__

A MachineFabric cartridge scaffolded by `capdag new`. It reads UTF-8 text on
stdin and emits `positive`, `neutral`, or `negative`.

## Develop

```bash
# 1. Build the entry the host launches:
cargo build --release

# 2. Install this cartridge under the local `dev` slug:
capdag dev-install .

# 3. Run your cap through the capdag host:
echo "I love this" | capdag __CARTRIDGE_NAME__
# => positive

# 4. Edit classify() in src/main.rs, then re-run steps 1-2 to update the install:
cargo build --release && capdag dev-install .
```

Unlike the Python cartridge, the entry here is a COMPILED binary, so an edit
does not reach the host until you rebuild.

## `.cargo/config.toml`

The `capdag` crate's build script bakes two versions into the crate and treats
both as mandatory: `MFR_FABRIC_MANIFEST_VERSION` (which fabric manifest this
cartridge is compiled against) and `MFR_CARTRIDGE_REGISTRY_VERSION` (which
cartridge registry regime). Without them `cargo build` fails with a message
telling you to build through `dx`, which is the MachineFabric workspace's own
tool — not something a cartridge project has.

`.cargo/config.toml` sets them, which is what makes a plain `cargo build` work
here. Change them only together with the `capdag` version in `Cargo.toml`.

The cap is a *dev* cap: it is not published to the fabric, so you can develop
and run it locally as long as its alias (`__CARTRIDGE_NAME__`) does not collide
with a published cap.
