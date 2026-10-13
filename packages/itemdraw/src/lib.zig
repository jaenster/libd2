//! d2-itemdraw: an item drawn as Diablo II 1.14d draws it.
//!
//!     var assets = itemdraw.Assets.init(gpa);
//!     try assets.addArchive(patch_d2); try assets.addArchive(d2exp); try assets.addArchive(d2data);
//!     const d = try itemdraw.Drawer.init(gpa, &assets, .{});
//!     const records = try itemdraw.parseRecords(arena, bytes, 7);   // host, then its socketed records
//!     var card = try d.card(records, .{});                           // icon + tooltip, as on hover
//!     const png = try card.png(gpa);
//!
//! The art (item sprites, colour maps, the palette, Font16) comes from the caller; libd2 ships none.
//! The text comes from `d2-item`'s `itemdesc`, over the d2-data tables.

const std = @import("std");
const item = @import("d2-item");

pub const assets = @import("assets.zig");
pub const image = @import("image.zig");
pub const icon = @import("icon.zig");
pub const draw = @import("draw.zig");
pub const layout = @import("layout.zig");
pub const raster = @import("raster.zig");

pub const Assets = assets.Assets;
pub const Image = image.Image;
pub const Drawer = draw.Drawer;
pub const Layout = layout.Layout;
pub const Providers = raster.Providers;
pub const GlyphProvider = raster.GlyphProvider;
pub const SpriteProvider = raster.SpriteProvider;
pub const Tile = raster.Tile;
pub const rasterize = raster.rasterize;
pub const Options = draw.Options;
pub const IconOptions = icon.Options;
pub const Background = icon.Background;
pub const itemdesc = item.itemdesc;
pub const Viewer = itemdesc.Viewer;
pub const DescOptions = itemdesc.Options;
pub const Desc = itemdesc.Desc;
pub const parseRecords = itemdesc.parseRecords;

test {
    _ = assets;
    _ = image;
    _ = icon;
    _ = draw;
    _ = layout;
    _ = raster;
    _ = @import("capi.zig");
    _ = @import("golden.zig");
}
