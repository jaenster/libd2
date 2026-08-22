# Security

## Reporting

Report anything exploitable privately: use
[GitHub's private advisory form](https://github.com/jaenster/libd2/security/advisories/new), or
reach `jaenster` on [Discord](https://discord.gg/MHK2Dg9). Please do not open a public issue for a
memory-safety bug in the parsers.

Expect a first answer within a few days. This is a spare-time project and there is no bounty.

## What is in scope

libd2 parses untrusted input by design — a save file, an MPQ archive, a packet off the wire — and
is embedded in other people's programs through the C ABI, npm, crates.io and NuGet. So:

- a crafted `.d2s`, `.ds1`, `.dt1`, `.dc6`, `.mpq` or packet that reads or writes out of bounds,
  or that panics a host program in release mode
- anything reachable through the C ABI that corrupts the caller's memory rather than returning an
  error
- a wasm build that escapes its own linear memory

## What is not

- **Wrong results.** A generator that disagrees with the game is a correctness bug — file it in the
  open, with the seed.
- **Anything about running a game server.** That lives in
  [d2-dedicated-server](https://github.com/jaenster/d2-dedicated-server).
- Panics from a debug build asserting on input it documents as trusted.

## Supported

The tip of `main` and the newest `vX.Y.Z` release. The language bindings are on their own version
tracks; a fix may need a release on both.
