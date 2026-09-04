# Control-plane canary receipt — preflight

Plan provenance: `docs/LOCAL_ACCEPTANCE_AND_CONTROL_PLANE_TEST_PLAN.md`
(L3.3, L2.5, L3.7, L4.2, L4.3). Receipt shape: plan §1.3.

## Object under test

```
recorded_at: 2026-09-04T02:58:25Z
repo_head: 9c635987e8184cd3a0b24b4a1223c58d90f3256e
repo_branch: main
repo_dirty: True
installed_app_sha256: f36a70658b2a2e57c0502669e488a95b72939a43c57895a9112ccb18551d4d26
installed_app_present: True
macos: 26.5.2
arch: arm64
tmux: tmux 3.6b
shell: /bin/zsh
running_from: installed app
listener: http://127.0.0.1:8750 up=True (HTTP 200)
enableSessionAPIWrites: False
```

## Outcome

BLOCKED — write gate disabled; no write attempted.
