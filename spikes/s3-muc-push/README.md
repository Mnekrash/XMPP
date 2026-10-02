# S3 — group push measurements

Report: [docs/spikes/S3-muc-push.md](../../docs/spikes/S3-muc-push.md). Uses the S2 harness (`../s2-push/server_tests.py`)
and the same dev stack + gateway + APNs mock.

```bash
ENV_FILE=deploy/.env python spikes/s3-muc-push/group_tests.py
```
