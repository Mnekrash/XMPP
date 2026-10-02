# S2 — push spike

Report and device runbook: [docs/spikes/S2-push.md](../../docs/spikes/S2-push.md)

- `server_tests.py`: ejabberd → gateway → APNs-compatible mock (dev only). Needs the dev stack, the gateway image,
  and `apns-mock` on the compose network (see the report §3).
- `NotificationEnvelope/`: Swift package used by the NSE; `swift test` (Linux or macOS).
- `ios/`: device spike app (XcodeGen). Not part of the product.
