# Phase 0 item 4 — Packaging spike: decision record

Date: 2026-09-17
Build machine: MacBook (Apple Silicon), macOS 15.7.7, Docker Desktop VM is `aarch64` (so any `linux/amd64` container runs under QEMU/Rosetta emulation, not natively).
Spike code: `spikes/packaging/` (standalone Mix project, not part of the main app).

## Verdict

**Burrito 1.6.0 (current Hex release) does not work for Sprat's use case and should not be used as-is.** It fails to run the packaged application at all — see root cause below. This is a genuine upstream bug, not a Sprat configuration problem, and it is still present on Burrito's `main` branch as of this date (unmerged fix PRs exist).

**Fallback adopted: plain `mix release` with ERTS bundled, invoked via the release's own `eval` command.** This works end to end on macOS arm64 (the only target fully build-and-test capable on this machine): SQLite (exqlite precompiled NIF), HTTPS (Req/Finch + CA bundle), raw terminal mode, and CLI argv all work, with no Elixir/Erlang on the test PATH, and comfortably inside the 500ms p95 startup budget.

Revisit Burrito once burrito-elixir/burrito PRs #236 and #230 (or their fix) ship in a Hex release — the packaging *shape* Burrito promises (one file, no install step) is still the better outcome for end users, and nothing else about it looked broken (ERTS fetch, NIF cross-recompilation, Zig cross-linking all worked).

## Per-target results

| | macOS arm64 | macOS x86_64 | Linux x86_64 |
|---|---|---|---|
| Burrito: builds | ✅ | ✅ (cross-compiled from arm64 Mac) | ✅ (cross-compiled from arm64 Mac) |
| Burrito: runs the app | ❌ (see root cause) | ❌ (same bug, confirmed under Rosetta) | not testable here (see Docker note) |
| Plain release: builds | ✅ | not attempted (see gap below) | blocked — see Docker note |
| Plain release: runs with no Elixir/Erlang on PATH | ✅ (`env -i PATH=/usr/bin:/bin`) | — | — |
| sqlite (exqlite, WAL, create/insert-in-tx/read) | ✅ (3.53.4) | untested | untested |
| https GET (Req/Finch, CA bundle) | ✅ (200) | untested | untested |
| raw terminal mode (tmux) | ✅ | not attempted | n/a (needs a real terminal) |
| CLI args reach the app (`--version`, `doctor`, no-args) | ✅ (via plain release `eval`) | — | — |
| Startup p50 / p95 (20 runs) | 284ms / 328ms (plain release) | — | — |
| Binary/artifact size | 9.8MB (Burrito bin, non-functional) · 8.6MB (plain release tarball) | 12.4MB (Burrito bin, non-functional) | 19.2MB (Burrito bin, non-functional) |

Target for startup was <500ms p95; the plain release measured 284/328ms p50/p95, well inside budget. (Burrito's binary launches faster still — ~214/257ms p50/p95 — but that number is not meaningful since the app underneath never actually starts; see below.)

## Burrito root cause (confirmed, reproducible)

Burrito's Zig wrapper (`src/erlang_launcher.zig` in burrito 1.6.0) invokes `erl` with this literal argv list:

```
erl -elixir ansi_enabled true -noshell -s elixir start_cli "-mode embedded" -setcookie <cookie> -boot <path> -boot_var RELEASE_LIB <path> -args_file <path> -config <path> -extra <user args...>
```

`"-mode embedded"` is passed as **one argv element containing a space**, not two separate elements (`-mode`, `embedded`). `erl`'s argument parser does not split on spaces inside a single argv token, so it never recognizes `-mode` as a flag. Empirically, on this build (OTP 28.3.1 / Elixir 1.19.5), this corrupts the rest of the boot sequence enough that the app's own release boot script never runs at all — no application in the release starts, including `SpratSpike.Application`. Evidence:

- Added an unconditional `File.write!/2` at the top of `SpratSpike.Application.start/2` (the very first line executed). It fired every time when running the plain `mix release` (`bin/sprat_spike start`), but **never fired once** when running any of the three Burrito-built binaries, with any argv (`--version`, `doctor`, no args). The application simply never boots inside the Burrito wrapper.
- Instead, the trailing argv falls through to Elixir's *generic* CLI parser (`elixir_cli:start_cli`, which is what plain `elixir <args>` does), explaining the exact symptoms observed:
  - `sprat_spike_macos_arm64 --version` → prints the standard `elixir --version` Erlang/Elixir banner and exits 0 (not our `CLI.main/1` version string).
  - `sprat_spike_macos_arm64 doctor` → `No file named doctor` and exit 1 — Elixir's CLI treating `doctor` as a script filename to run, exactly like `elixir doctor` would.
  - `sprat_spike_macos_arm64` (no args) → silent exit 0 (empty stdin to a bare `elixir` session).
- Confirmed the release itself is fine: `_build/prod/rel/sprat_spike/releases/0.1.0/*.rel` lists `sprat_spike` as a `permanent` app, and running the same release directly (`bin/sprat_spike start`, no Burrito) starts `SpratSpike.Application` correctly.
- Confirmed this is upstream, not local misconfiguration: fetched `burrito-elixir/burrito` from GitHub `main` (not just the Hex 1.6.0 tarball) — the same single-string `"-mode embedded"` token is still present in `src/erlang_launcher.zig` on `main` as of 2026-09-17.
- A web search turned up two open, unmerged Burrito PRs describing this exact defect: **#236** ("splitting `-mode embedded` into separate argv elements" — because `erl` boots in `interactive` mode instead of `embedded` and doesn't recognize the flag) and **#230** ("stop Elixir's CLI from consuming app arguments and halting the VM"), i.e. maintainers are aware and mid-fix, but nothing has shipped to Hex.

This affects **every** target, not just Linux/cross-compiled ones — the arm64 native build (no cross-compilation involved at all) shows the identical failure. It is not a Zig-version or cross-compilation problem.

## What did work with Burrito (worth keeping in mind for a retry later)

- Correct Zig version pin resolved fast: the Burrito 1.6.0 `README` on GitHub's `main` branch currently says Zig `0.15.2`, but the **actually enforced** requirement (checked at build time by `Burrito.check_zig_version/0`) is **Zig 0.16.0** — the README is stale relative to the Hex-published version. Installed via `brew install zig` (formula `zig`, stable channel, resolved to 0.16.0). `brew install zig@0.15` was tried first per the stale README and had to be replaced.
- `xz` (Burrito's payload compressor) was already present via Homebrew (5.8.3).
- ERTS fetch worked cleanly: Burrito downloaded a prebuilt "Beam Machine" universal macOS ERTS and a Linux x86_64 ERTS (OTP 28.3.1) with no local Erlang/Elixir install needed on the target.
- **exqlite NIF cross-recompilation worked**: building for `macos_x86_64` and `linux_x86_64` from this arm64 Mac, Burrito's patch phase printed `Going to recompile NIF for cross-build: exqlite -> x86_64-macos` / `-> x86_64-linux` and both succeeded (`Successfully re-built exqlite for ...!`), using the Zig cross-linker. This is the hardest part of the whole spike and it worked. If the argv bug is fixed, Burrito's cross-compilation story for a NIF-using app looks solid.
- Build matrix confirmed macOS (Apple Silicon) as a host can target macOS x86_64, macOS arm64, and Linux x86_64 without needing separate build machines or Docker.

## Pinned versions used

| Component | Version | Notes |
|---|---|---|
| Elixir | 1.19.5-otp-28 | via asdf, matches repo `.tool-versions` |
| Erlang/OTP | 28.3.1 | via asdf |
| Zig | 0.16.0 | required by Burrito 1.6.0 at build time (`brew install zig`); note the stale README says 0.15.2 |
| burrito | 1.6.0 (Hex) | latest; same bug confirmed present on GitHub `main` too |
| exqlite | 0.40.0 | precompiled NIF; cross-recompile via Burrito's patch phase confirmed working for x86_64-macos and x86_64-linux |
| req | 0.7.4 | via Finch; used for the HTTPS smoke test |

## Fallback: plain `mix release` (what's actually recommended right now)

`mix.exs` defines a second release, `sprat_spike_plain` (`steps: [:assemble, :tar]`, `include_erts: true`), alongside the Burrito one. Built and tested on macOS arm64:

```
env -i PATH=/usr/bin:/bin HOME=$HOME TERM=$TERM \
  ./_build/prod/rel/sprat_spike_plain/bin/sprat_spike_plain \
  eval 'Application.ensure_all_started(:sprat_spike); SpratSpike.CLI.main(System.argv())' \
  doctor
```

- `env -i PATH=/usr/bin:/bin` strips every toolchain (no `elixir`, `erl`, or asdf shims on PATH) — the release's bundled `elixir`/`erl`/ERTS at `_build/prod/rel/sprat_spike_plain/erts-*/` is what actually runs. Confirmed working for `--version`, `doctor`, `smoke` (sqlite + https), and no-args.
- The plain release has **no built-in mechanism to forward CLI argv the way Burrito's `Burrito.Util.Args.argv()` does**. The `eval` command with a trailing `-- ARGS` (or, as found empirically, without the extra `--`, since the release script already inserts one) is the standard Elixir-release way to get `System.argv()` populated for a one-shot script; `start`/`daemon` don't accept passthrough args. A real Sprat release would want a thin wrapper script (see the Homebrew formula sketch) so `sprat doctor` doesn't require typing `eval '...'` — this is exactly what a Homebrew formula's `bin.write_exec_script`-style wrapper is for.
- `Application.ensure_all_started(:sprat_spike)` is required before calling into the app because `eval` boots from the release's "clean" boot script, which does not auto-start the release's own OTP application the way `start`/`daemon` do.
- Tarball size: 8.6MB (`_build/prod/sprat_spike_plain-0.1.0.tar.gz`), comparable to the (non-functional) Burrito binaries.
- Startup timing (20 runs, `--version`, clean env, `time.time()` wall clock around each `env -i ... eval ...` invocation): **p50 284ms, p95 328ms, min 268ms, max 387ms** — well inside the spec's <500ms p95 target. This includes `Application.ensure_all_started/1` overhead for `:sprat_spike` and its deps (`req`, `exqlite`, etc.), so real-world Sprat startup (only the roles/tools actually used) should be at least this good.

### Gaps not covered by this fallback (documented, not built — see "Blockers" below for why)

- **macOS x86_64 plain release**: not built. A plain `mix release` doesn't cross-compile — it needs to run under an actual x86_64 Erlang/Elixir toolchain (e.g. asdf under Rosetta), which is disproportionate setup for a throwaway spike. Untested but expected to behave identically to arm64 once built, since exqlite ships a precompiled darwin-x86_64 NIF and the code has no other platform branches beyond `Paths` (which is CPU-arch-agnostic, only OS-family-conditional).
- **Linux x86_64 plain release**: attempted, blocked by the local Docker environment — see below, not a Sprat/exqlite/Req problem.

## Blockers and surprises

1. **Burrito's `-mode embedded` argv bug** (above) — the headline finding. Confirmed root cause, confirmed present on Hex 1.6.0 and GitHub `main`, confirmed upstream awareness (open PRs #236, #230, both unmerged as of 2026-09-17).
2. **Burrito's README is stale on the Zig version.** `main`'s README says `0.15.2`; the actual Hex 1.6.0 package enforces `0.16.0` at build time (`Burrito.check_zig_version/0` hard-fails otherwise, with a clear error naming both versions). Cost about 5 minutes to discover and fix (`brew install zig` instead of `zig@0.15`).
3. **Docker Desktop on this Apple Silicon Mac cannot run `--platform linux/amd64` OTP 28 containers at all**, blocking any Linux x86_64 test/build in Docker on this machine specifically:
   - `hexpm/elixir:1.19.5-erlang-28.0.4-ubuntu-jammy-*` and `-28.3.3-*`, and the official `elixir:1.19.5` image, all crash identically on **any** invocation that starts an interactive Erlang shell (`elixir --version`, `elixir -e ...`, and even bare `mix --version`): `prim_tty:isatty/1` raises `undefined function erlang:nif_error/1`, cascading into `{shutdown,{failed_to_start_child,user,nouser}}` and killing the VM. This reproduces with `elixir:1.19.5` (Debian trixie) and `hexpm/elixir` Ubuntu-jammy images alike, so it's a property of the OTP 28 `prim_tty` NIF under this emulation, not the base image.
   - Switching to `hexpm/elixir:1.19.5-erlang-27.1.3-ubuntu-jammy-*` avoids that specific crash (`elixir --version` works), but compiling this project's own code inside that container then crashes the compiler (`elixir_def:store_definition` badmatch on a garbled binary literal) partway through `sprat_spike`'s own compile step — a second, different emulation-related fault.
   - Root cause for both: `docker info` shows the Docker Desktop VM itself is `aarch64` — every `linux/amd64` container here runs under QEMU (or Rosetta) emulation, not on real x86_64 silicon. Ubuntu 22.04 with the distro's own (much older) `apt install elixir` — Erlang 24.2 / Elixir 1.12, x86_64, same emulated container — did **not** crash on `elixir --version`, which narrows this to something OTP 26+'s `prim_tty`/JIT does under this specific emulation layer, not a Docker-wide issue.
   - **This needs verification on real x86_64 hardware or a native x86_64 CI runner** (e.g. GitHub Actions' `ubuntu-22.04`/`ubuntu-24.04` runners, which are native amd64, not emulated) before drawing any conclusion about Linux x86_64 itself — nothing here points at a Sprat, exqlite, or Burrito defect; it's specific to emulating x86_64 on this Apple Silicon Mac via Docker Desktop.
   - Per the task's instructions, Docker *is* available on this machine (`docker ps` reachable, daemon healthy, other unrelated containers running fine), so this is reported as a blocking finding rather than a "tool not installed" gap.
4. **No first-run extraction delay observed for Burrito** (since the app never actually starts, this couldn't be meaningfully measured — noted as an open question for the retry once the argv bug is fixed).
5. **NIF loading from a Burrito-extracted payload**: not directly observable either, for the same reason — but Burrito's own patch-phase log messages (`Overwriting NIF library .../asn1rt_nif.so`, `Installed NIF library`) show it does relink/copy `.so`/`.dylib` NIFs into the extracted payload tree, and the `exqlite` NIF cross-recompilation completing successfully is indirect evidence this mechanism itself is sound.
6. **Gate correctness matters for dev ergonomics.** The first version of `SpratSpike.Application.start/2` unconditionally ran the CLI and called `System.halt/1` — harmless for a Burrito binary, but it also runs every time `mix test`/`mix run`/`iex -S mix` boots the app in dev, silently killing those sessions. Fixed by gating on `Burrito.Util.running_standalone?/0` (true only inside a Burrito-wrapped binary, via the `__BURRITO` env var Burrito's wrapper sets) so dev/test get an idle no-op supervisor instead.

## Signing and notarization (not performed — notes only, per task scope)

- **Plain release** (adopted path): the bundled `erl`, BEAM `.so`/`.dylib` NIFs (including exqlite's), and any binary in the tarball would each need `codesign --sign "Developer ID Application: ..." --options runtime` (hardened runtime) for Gatekeeper to allow execution on a machine with Gatekeeper enabled, and the assembled `.tar.gz` (or better, a signed installer/pkg) would need `xcrun notarytool submit ... --wait` + `xcrun stapler staple`. This is standard for any bundled-ERTS Elixir release; nothing about Sprat's use of exqlite/Req changes it.
- **Burrito's self-extracting payload** is a specific extra risk, independent of whether the argv bug above gets fixed: the payload's ERTS binaries and NIFs are extracted to `~/Library/Application Support/.burrito/...` **at first run**, then `execve`'d. Gatekeeper's on-first-launch check applies to the outer wrapper binary itself (needs signing + notarization + stapling, same as any distributed Mach-O binary), but the *extracted* inner binaries are not launched via Launch Services (they're `execve`'d directly by the already-running, already-approved wrapper process), so they likely don't need their own separate Gatekeeper approval the way a double-clicked `.app` would — but they do still need valid code signatures if the hardened-runtime/library-validation entitlement is set on the wrapper, or NIF loading itself can fail with a codesign-related error on newer macOS. This wasn't testable here since Burrito's binaries don't reach the point of loading application NIFs at all (root-cause bug above) — flagging as an open question for whoever revisits Burrito once the argv bug is fixed, rather than a confirmed finding.
- Homebrew distribution (see `homebrew-formula.rb.sample`) sidesteps first-run Gatekeeper quarantine friction somewhat, since `brew install` doesn't set the `com.apple.quarantine` xattr the way a browser download does — but the binaries inside still benefit from being signed/notarized for defense in depth and for users who `curl`/`tar` the release archive directly from GitHub Releases instead of via Homebrew.

## Files in this spike

- `spikes/packaging/mix.exs` — deps (`exqlite`, `req`, `burrito`) and two release configs (`sprat_spike` = Burrito-wrapped, `sprat_spike_plain` = plain tarball fallback)
- `spikes/packaging/lib/sprat_spike/application.ex` — entry point; gates CLI-and-halt on `Burrito.Util.running_standalone?/0`
- `spikes/packaging/lib/sprat_spike/cli.ex` — `--version`, `doctor`, `smoke`, no-args dispatch
- `spikes/packaging/lib/sprat_spike/db.ex` — exqlite WAL create/insert-in-transaction/read smoke test
- `spikes/packaging/lib/sprat_spike/http_check.ex` — Req HTTPS GET smoke test
- `spikes/packaging/lib/sprat_spike/raw_mode.ex` — `:shell.start_interactive({:noshell, :raw})` key read
- `spikes/packaging/lib/sprat_spike/paths.ex` — platform app-data dir (spec §13 layout, app name `sprat-spike`)
- `spikes/packaging/test/sprat_spike_test.exs` — one test covering the DB smoke test
- `spikes/packaging/homebrew-formula.rb.sample` — sketch only, no tap created
- `spikes/packaging/.tool-versions` — pins this dir to Erlang 28.3.1 / Elixir 1.19.5-otp-28 via asdf
