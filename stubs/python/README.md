# __CARTRIDGE_NAME__

A MachineFabric cartridge scaffolded by `capdag new`. It reads UTF-8 text on
stdin and emits `positive`, `neutral`, or `negative`.

## Develop

```bash
# 1. Install capdag (the cartridge runtime) so `cartridge.py` can import it:
pip install capdag

# 2. Install this cartridge under the local `dev` slug:
capdag dev-install .

# 3. Run your cap through the capdag host:
echo "I love this" | capdag __CARTRIDGE_NAME__
# => positive

# 4. Edit the labels or the peer cap in cartridge.py, then re-run step 2:
capdag dev-install .
```

## It needs the host

This cartridge does not classify anything itself — it PEER-CALLS `classify-en`
and a model cartridge answers. Peer calls are routed by the capdag host, so
running the built entry directly (`./__CARTRIDGE_NAME__ __CARTRIDGE_NAME__`)
fails with `Peer invocation not supported in this context`. That is correct, not
a bug: run it through `capdag __CARTRIDGE_NAME__`, which hosts the cartridge and
routes the call.

A model cartridge providing `classify-en` must be installed. The first run
downloads the model, which is why the peer reports progress and why this
cartridge forwards it.

The cap is a *dev* cap: it is not published to the fabric, so you can develop
and run it locally as long as its alias (`__CARTRIDGE_NAME__`) does not collide
with a published cap.
