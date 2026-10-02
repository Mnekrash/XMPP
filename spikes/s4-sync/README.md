# S4 — message identity + ingest engine (SyncCore)

Report: [docs/spikes/S4-mam-reconnect-dedup.md](../../docs/spikes/S4-mam-reconnect-dedup.md)

```bash
docker build -t omemo-swift-dev -f ../s1-omemo/Dockerfile.dev ../s1-omemo   # Swift 6.2 + sqlite headers
docker run --rm -v $PWD:/src -w /src omemo-swift-dev swift test            # unit tests
docker run --rm -v $PWD:/src -w /src omemo-swift-dev swift build           # builds sync-cli
python3 -m venv .venv && .venv/bin/pip install slixmpp==1.17.0
XMPP_CA=/path/to/caddy-root.crt .venv/bin/python harness/s4.py             # 14 scenarios against the dev stack
```

The harness resets the accounts alice/bob on the **development** server.
