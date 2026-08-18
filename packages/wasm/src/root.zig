//! The combined libd2 WebAssembly module: every subsystem's C ABI in one wasm.
//!
//! The exports live in each package's own capi.zig. Importing a module does not by itself emit
//! its exports — Zig only emits what it analyses — so this `comptime` block is what pulls them
//! in. Adding a subsystem here is the whole job of adding it to the module.
//!
//! Why one module rather than one per package: d2pf routes over an act d2drlg generated, and
//! two wasm modules have two linear memories. Separate modules would mean copying a level's
//! whole collision grid across the boundary for every query. Here d2pf_world_create simply
//! takes the pointer d2drlg_ctx_core returns, and both halves address the same bytes. d2net
//! joins them for the same reason: a bot decodes a packet, then routes over the map that same
//! stream is describing.

const opts = @import("build_options");

comptime {
    if (opts.with_drlg) _ = @import("d2drlg-capi");
    if (opts.with_pf) _ = @import("d2pf-capi");
    if (opts.with_item) _ = @import("d2item-capi");
    if (opts.with_net) _ = @import("d2net-capi");
}
