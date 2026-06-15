# Performance fork maintenance — quic-go / outbound

This repo's "aggressive" build replaces dae's QUIC + outbound deps with
performance forks. Upstream (olicesx) has gone quiet, so this file is the
self-maintenance playbook: what the perf delta actually is, and how to refresh
it ourselves when needed.

Pins live in `ci/pins.env`; the build pulls them from the `kenzok8/*` mirrors
(synced from `olicesx/*` by `.github/workflows/auto-bump.yml`).

## Dependency lineage

```
official quic-go (v0.60.x, moves weekly)
        │  (dae uses a very old, heavily-patched base — APIs differ by ~38 minor versions)
        ▼
daeuniverse/quic-go  branch "sid"  (2025-02, the maintained dae base)
        │  olicesx cherry-picks newer upstream fixes on top
        ▼
olicesx/quic-go  branch "enhanced-with-fixes"  (base ~2026-02, module renamed github.com/olicesx/quic-go)
        │  + 3 perf commits
        ▼
olicesx/quic-go  branch "perf/node-pooling-v2"  ← what we pin (QUICGO_COMMIT)
```

Key facts that shape any "update":

- `olicesx/quic-go` is **not** a GitHub fork of `quic-go/quic-go` (`fork:false`,
  `parent:null`, module renamed). Its history does **not** share commits with
  official quic-go, so you cannot `git rebase` onto an official tag — refreshing
  means **cherry-picking / backporting specific upstream fixes** onto
  `enhanced-with-fixes`, not moving the base.
- There is **no fresher ready-made base** in the dae→olicesx chain:
  `enhanced-with-fixes` (2026-02) is already ahead of `daeuniverse/quic-go@sid`
  (2025-02). To go fresher you must do the cherry-pick work yourself.
- dae-core (`kdae`) is tied to this old quic-go API. Bumping to official v0.60
  would mean porting dae-core, not just the dep — out of scope.

## The perf delta we must preserve

`olicesx/quic-go`  `main` → `perf/node-pooling-v2` = **4 commits, 5 files**:

| commit | date | what |
|--------|------|------|
| `bb65418` | 2026-02-26 | fix: improve UDP GSO handling (single-segment sends) — this is the `enhanced-with-fixes` HEAD |
| `254bec0d` | 2026-04-28 | perf: B-tree node pooling + frame sorter optimizations |
| `7d0a3176` | 2026-04-28 | fix: return stream frames to pool on cancellations |
| `e0d255ff` | 2026-04-28 | fix: only generate RTT sample for last ack-eliciting packet |

Files touched (the entire perf surface):

```
frame_sorter.go
internal/ackhandler/sent_packet_handler.go
internal/utils/tree/tree.go            (B-tree pool — the big one, +57/-25)
send_stream.go
sys_conn_oob.go                        (UDP GSO)
```

Because the surface is tiny and self-contained, reapplying these 3 perf commits
on top of any refreshed `enhanced-with-fixes` is a ~1h job.

### outbound

`olicesx/outbound` `main` (= `daeuniverse/outbound@main`, 2025-07) →
`perf/complete-optimizations` = **130 commits, 215 files** (sticky-ip, ss2022,
anytls, reality fixes, memory-safety, …). This is a large, living fork and
`daeuniverse/outbound` upstream is itself near-dormant (newest branch 2026-02),
so self-rebasing outbound is **high effort, low value** — ride olicesx, do not
maintain locally.

## How to refresh quic-go ourselves (when a real fix lands)

Trigger: a security/correctness fix in official quic-go that matters to us, or
auto-bump's staleness alert (see below) firing for a long time.

1. Clone our mirror and branch from the perf tip:
   ```sh
   git clone https://github.com/kenzok8/quic-go && cd quic-go
   git checkout -b refresh perf/node-pooling-v2
   ```
2. Backport the wanted upstream fix(es) as a patch (not cherry-pick — no shared
   history). Find the official commit, take its diff, apply to the matching file
   here, resolve by hand. Keep changes minimal.
3. Re-apply nothing for the 3 perf commits — they are already at the tip; the
   backport goes **under** them only if you reset the base, otherwise just add
   the backport as a new commit on top. Verify the 5 perf files above still carry
   the optimizations.
4. Build-verify before pinning (this is mandatory — never pin an unbuilt tree):
   - push the branch, set `QUICGO_COMMIT` to its SHA in a staging branch,
   - run `assemble-daed-src.yml` then `test-daed-build.yml` (or the gated path in
     `auto-bump.yml`) — it must `go build` dae-core+wing clean.
5. Only after a green build: fast-forward `perf/node-pooling-v2` (or repoint the
   pin) and let auto-bump pick it up.

## Staleness / CVE alert

`auto-bump.yml` emits a warning (and opens a tracking issue) when the olicesx
perf branches have not moved for a long time while official quic-go has new
releases — so we notice instead of silently aging. Treat a fired alert as
"check whether the new upstream release carries a fix worth backporting per the
steps above," not "must act immediately."
