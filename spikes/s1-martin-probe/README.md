# S1 — Martin probe (macOS only)

Measures options 1 and 4 of spike S1: does Martin 3.2.4 build with the current Xcode toolchain, and can it
hold a real session with our ejabberd? Martin cannot be built on Linux (`no such module 'Combine'`, measured).

```bash
cd spikes/s1-martin-probe
swift build 2>&1 | tee build.log                       # result 1: compiles? (Swift 5 language mode, tools 5.9)
PROBE_JID=alice@chat.staging.example.com PROBE_PASSWORD='…' PROBE_HOST=chat.staging.example.com \
PROBE_TO=bob@chat.staging.example.com swift run martin-probe | tee run.log   # result 2: real session
```

Run it against a server with a publicly trusted certificate (staging). The probe never disables certificate
validation. Attach `build.log` and `run.log` to `docs/spikes/S1-omemo-library.md`.

The probe code was written from Martin's 3.2.4 sources and **has not been compiled** (no macOS in the
spike environment). A compile error is itself a valid result for the report.
