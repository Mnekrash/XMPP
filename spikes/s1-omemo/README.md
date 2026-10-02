# S1 — OMEMO 2 protocol layer prototype (OMEMOKit)

Report: [docs/spikes/S1-omemo-library.md](../../docs/spikes/S1-omemo-library.md)

## Build and unit tests (Linux, Docker)

```bash
docker build -t omemo-swift-dev -f Dockerfile.dev .
docker run --rm -v $PWD:/src -w /src omemo-swift-dev swift test
```

On macOS: `brew install libsodium pkg-config && swift test`.

## Interop against python-omemo/twomemo through ejabberd

```bash
python3 -m venv .venv && .venv/bin/pip install -r harness/requirements.txt
# dev stack running (scripts/dev-smoke.sh), Caddy root CA exported to $XMPP_CA
XMPP_CA=/path/to/root.crt .venv/bin/python harness/scenarios.py          # all 13 scenarios
XMPP_CA=/path/to/root.crt .venv/bin/python harness/scenarios.py s11 s13  # selected
```

The scenarios reset the test accounts alice/bob/carol/dave on the **development** server.

`Sources/OMEMOKit/twomemo.pb.swift` is generated from `Proto/twomemo.proto` with protoc-gen-swift 1.38.1.
