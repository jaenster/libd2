//! An item drawn the way Diablo II 1.14d draws it: the grid icon, the hover tooltip, and the two
//! together as on hover, from the item's save-form records.
//!
//! The art is yours: add the game's MPQs (Patch_D2, d2exp, d2data, in that order). The text needs
//! none of it.
//!
//! ```no_run
//! use libd2::itemdraw::{Context, Kind};
//!
//! # fn main() -> Result<(), libd2::Error> {
//! let mut c = Context::new()?;
//! for m in ["Patch_D2.mpq", "d2exp.mpq", "d2data.mpq"] {
//!     c.add_archive(&std::fs::read(m).unwrap())?;
//! }
//! let records: Vec<u8> = std::fs::read("item.bin").unwrap();
//! println!("{}", c.alt_text(&records, None, 1024)?);
//! let layout = c.layout(&records, None, Kind::Card)?; // the display list, also as JSON
//! let card = c.rasterize(&layout, None, None, 2)?;     // libd2's own art at twice the size
//! std::fs::write("card.png", card.png).unwrap();
//! # Ok(())
//! # }
//! ```
//!
//! A [`GlyphProvider`] or [`SpriteProvider`] draws in place of libd2's DC6 art: each paints one tile,
//! the glyph cell or the sprite's rectangle at the scale, so the layout is the same whatever draws it.

use crate::sys::d2itemdraw as sys;
use crate::Error;
use core::ffi::{c_char, c_void};
use std::ffi::CString;

/// Who looks at the item. `None` everywhere is the neutral character: every requirement met, no
/// class, per-level stats at level 99.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Viewer {
    /// 0 Amazon, 1 Sorceress, 2 Necromancer, 3 Paladin, 4 Barbarian, 5 Druid, 6 Assassin.
    pub class: i32,
    /// Character level.
    pub level: i32,
    /// Strength the requirement is checked against.
    pub strength: i32,
    /// Dexterity the requirement is checked against.
    pub dexterity: i32,
}

/// The form of [`Context::text`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TextMode {
    /// The game's own string: first line at the bottom, colour codes `ÿcN`.
    Engine = 0,
    /// Top to bottom, no colours.
    Plain = 1,
    /// Top to bottom, each colour run as `{N}text`.
    Colored = 2,
}

/// What a layout covers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    /// The grid icon (no tint, no sockets).
    Icon = sys::D2ITEMDRAW_KIND_ICON as isize,
    /// The tooltip box.
    Tooltip = sys::D2ITEMDRAW_KIND_TOOLTIP as isize,
    /// Both, as on hover.
    Card = sys::D2ITEMDRAW_KIND_CARD as isize,
}

/// A drawn picture.
#[derive(Clone, Debug)]
pub struct Image {
    /// Width in pixels.
    pub width: u32,
    /// Height in pixels.
    pub height: u32,
    /// `width * height * 4` bytes, straight-alpha RGBA, rows top-down.
    pub rgba: Vec<u8>,
    /// The same as a PNG file.
    pub png: Vec<u8>,
}

/// A rectangle in layout pixels.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rect {
    /// Left.
    pub x: i32,
    /// Top.
    pub y: i32,
    /// Width.
    pub w: i32,
    /// Height.
    pub h: i32,
}

/// One glyph to paint.
#[derive(Clone, Debug)]
pub struct GlyphRef {
    /// The font (`font16`).
    pub font: String,
    /// Code point.
    pub code: char,
    /// The Font16 DC6 frame the game draws.
    pub frame: u32,
    /// Text colour id, 0..12.
    pub color: u32,
    /// Its nominal RGB.
    pub rgb: [u8; 3],
    /// The glyph cell.
    pub cell: Rect,
}

/// One inventory frame to paint.
#[derive(Clone, Debug)]
pub struct SpriteRef {
    /// The DC6's game path.
    pub path: String,
    /// The frame.
    pub frame: u32,
    /// The item colour map (`InvTrans` file, row), if any.
    pub colormap: Option<(i32, i32)>,
    /// 0 item, 1 socket frame, 2 socketed filler.
    pub role: i32,
    /// Drawn at half opacity by the rasterizer.
    pub ethereal: bool,
    /// Its rectangle.
    pub rect: Rect,
}

/// The buffer a provider paints: `w * h * 4` bytes of straight-alpha RGBA, zeroed.
pub struct Tile<'a> {
    /// Width in pixels.
    pub w: u32,
    /// Height in pixels.
    pub h: u32,
    /// The pixels.
    pub rgba: &'a mut [u8],
}

/// Paints glyphs. Returning `false` leaves a glyph to libd2's own 1.14d font.
pub trait GlyphProvider {
    /// Pixels the tile extends past the glyph cell on each side (outlines, anti-aliasing).
    fn pad(&self) -> u32 {
        0
    }
    /// Paint `glyph` into `tile`: the cell at `scale`, plus `pad` on every side.
    fn draw_glyph(&mut self, glyph: &GlyphRef, scale: u32, tile: Tile<'_>) -> bool;
}

/// Paints inventory frames. Returning `false` leaves a frame to libd2's own 1.14d art.
pub trait SpriteProvider {
    /// Paint the frame `sprite` into `tile` (its rectangle at `scale`), opaque: the draw mode's alpha
    /// is the rasterizer's.
    fn draw_sprite(&mut self, sprite: &SpriteRef, scale: u32, tile: Tile<'_>) -> bool;
}

/// A display list: where everything goes, in the game's pixels.
pub struct Layout {
    h: *mut sys::D2ItemDrawLayout,
    /// Width in layout pixels.
    pub width: i32,
    /// Height in layout pixels.
    pub height: i32,
    /// The whole list as JSON: the box, each line's colour runs and glyph cells, the icon and the
    /// socket frames.
    pub json: String,
}

impl Layout {
    /// The layout's lines as plain text, whole lines up to `limit` bytes (0: 1024).
    pub fn text(&self, limit: usize) -> String {
        let mut buf = vec![0u8; 4096];
        let n = unsafe { sys::d2itemdraw_layout_text(self.h, limit as i32, buf.as_mut_ptr(), buf.len()) };
        buf.truncate(n.clamp(0, 4096) as usize);
        String::from_utf8_lossy(&buf).into_owned()
    }
}

impl Drop for Layout {
    fn drop(&mut self) {
        unsafe { sys::d2itemdraw_layout_free(self.h) }
    }
}

/// The tables, the archives you added and the art loaded from them.
pub struct Context {
    ctx: *mut sys::D2ItemDrawCtx,
    archives: Vec<(*mut u8, usize)>,
}

fn options(viewer: Option<Viewer>) -> sys::D2ItemDrawOptions {
    match viewer {
        None => sys::D2ItemDrawOptions { has_viewer: 0, class_id: 0, level: 99, strength: 0, dexterity: 0, act: 1 },
        Some(v) => sys::D2ItemDrawOptions { has_viewer: 1, class_id: v.class, level: v.level, strength: v.strength, dexterity: v.dexterity, act: 1 },
    }
}

impl Context {
    /// Loads the tables.
    pub fn new() -> Result<Self, Error> {
        let found = unsafe { sys::d2itemdraw_abi_version() };
        if found != sys::EXPECTED_ABI {
            return Err(Error::AbiMismatch { expected: sys::EXPECTED_ABI, found });
        }
        let ctx = unsafe { sys::d2itemdraw_create() };
        if ctx.is_null() {
            return Err(Error::Unavailable);
        }
        Ok(Context { ctx, archives: Vec::new() })
    }

    /// Adds an MPQ, searched after those added before it. Copied into native memory kept until drop.
    pub fn add_archive(&mut self, mpq: &[u8]) -> Result<(), Error> {
        let p = unsafe { sys::d2itemdraw_alloc(mpq.len()) };
        if p.is_null() {
            return Err(Error::Unavailable);
        }
        unsafe { core::ptr::copy_nonoverlapping(mpq.as_ptr(), p, mpq.len()) };
        self.archives.push((p, mpq.len()));
        match unsafe { sys::d2itemdraw_add_archive(self.ctx, p, mpq.len()) } {
            0 => Ok(()),
            code => Err(Error::Native { call: "d2itemdraw_add_archive", code }),
        }
    }

    /// Adds one file under its game path (`data/global/items/invamu1.dc6`); it wins over archives.
    pub fn add_file(&mut self, name: &str, data: &[u8]) -> Result<(), Error> {
        let n = CString::new(name).map_err(|_| Error::Native { call: "d2itemdraw_add_file", code: -2 })?;
        match unsafe { sys::d2itemdraw_add_file(self.ctx, n.as_ptr(), data.as_ptr(), data.len()) } {
            0 => Ok(()),
            code => Err(Error::Native { call: "d2itemdraw_add_file", code }),
        }
    }

    /// The item's tooltip text.
    pub fn text(&self, records: &[u8], viewer: Option<Viewer>, mode: TextMode) -> Result<String, Error> {
        let o = options(viewer);
        let n = unsafe { sys::d2itemdraw_text(self.ctx, records.as_ptr(), records.len(), &o, mode as i32, core::ptr::null_mut(), 0) };
        if n < 0 {
            return Err(Error::Native { call: "d2itemdraw_text", code: n });
        }
        let mut buf = vec![0u8; n as usize];
        unsafe { sys::d2itemdraw_text(self.ctx, records.as_ptr(), records.len(), &o, mode as i32, buf.as_mut_ptr(), buf.len()) };
        Ok(String::from_utf8_lossy(&buf).into_owned())
    }

    /// The description as alt text: top to bottom, whole lines up to `limit` bytes (0: 1024).
    pub fn alt_text(&self, records: &[u8], viewer: Option<Viewer>, limit: usize) -> Result<String, Error> {
        let o = options(viewer);
        let mut buf = vec![0u8; 4096];
        let n = unsafe { sys::d2itemdraw_alt_text(self.ctx, records.as_ptr(), records.len(), &o, limit as i32, buf.as_mut_ptr(), buf.len()) };
        if n < 0 {
            return Err(Error::Native { call: "d2itemdraw_alt_text", code: n });
        }
        buf.truncate((n as usize).min(4096));
        Ok(String::from_utf8_lossy(&buf).into_owned())
    }

    fn image(img: *mut sys::D2ItemDrawImage, call: &'static str) -> Result<Image, Error> {
        if img.is_null() {
            return Err(Error::Native { call, code: -1 });
        }
        unsafe {
            let width = sys::d2itemdraw_image_width(img);
            let height = sys::d2itemdraw_image_height(img);
            let px = sys::d2itemdraw_image_rgba(img);
            let rgba = core::slice::from_raw_parts(px, (width * height * 4) as usize).to_vec();
            let mut len = 0usize;
            let p = sys::d2itemdraw_image_png(img, &mut len);
            let png = if p.is_null() { Vec::new() } else { core::slice::from_raw_parts(p, len).to_vec() };
            sys::d2itemdraw_image_free(img);
            Ok(Image { width, height, rgba, png })
        }
    }

    /// The hover card: icon, sockets and tooltip as the game shows them on hover.
    pub fn card(&self, records: &[u8], viewer: Option<Viewer>) -> Result<Image, Error> {
        let o = options(viewer);
        Self::image(unsafe { sys::d2itemdraw_card(self.ctx, records.as_ptr(), records.len(), &o) }, "d2itemdraw_card")
    }

    /// The display list of an item.
    pub fn layout(&self, records: &[u8], viewer: Option<Viewer>, kind: Kind) -> Result<Layout, Error> {
        let o = options(viewer);
        let h = unsafe { sys::d2itemdraw_layout(self.ctx, records.as_ptr(), records.len(), &o, kind as i32, 0, 0) };
        if h.is_null() {
            return Err(Error::Native { call: "d2itemdraw_layout", code: -1 });
        }
        unsafe {
            let mut len = 0usize;
            let p = sys::d2itemdraw_layout_json(h, &mut len);
            let json = String::from_utf8_lossy(core::slice::from_raw_parts(p, len)).into_owned();
            Ok(Layout { h, width: sys::d2itemdraw_layout_width(h), height: sys::d2itemdraw_layout_height(h), json })
        }
    }

    /// Draws a layout at `scale` (1 is the game's size) through the providers; `None`, or a provider
    /// returning `false`, uses libd2's own 1.14d art from the archives.
    pub fn rasterize<'a>(
        &self,
        layout: &Layout,
        glyph: Option<&'a mut (dyn GlyphProvider + 'a)>,
        sprite: Option<&'a mut (dyn SpriteProvider + 'a)>,
        scale: u32,
    ) -> Result<Image, Error> {
        let pad = glyph.as_ref().map(|g| g.pad()).unwrap_or(0);
        let mut user = User { glyph, sprite };
        let prov = sys::D2ItemDrawProviders {
            user: &mut user as *mut User as *mut c_void,
            glyph: if user.glyph.is_some() { Some(glyph_trampoline) } else { None },
            sprite: if user.sprite.is_some() { Some(sprite_trampoline) } else { None },
            glyph_pad: pad,
        };
        let img = unsafe { sys::d2itemdraw_rasterize(self.ctx, layout.h, &prov, scale) };
        Self::image(img, "d2itemdraw_rasterize")
    }
}

impl Drop for Context {
    fn drop(&mut self) {
        unsafe {
            sys::d2itemdraw_destroy(self.ctx);
            for &(p, n) in &self.archives {
                sys::d2itemdraw_free(p, n);
            }
        }
    }
}

struct User<'a> {
    glyph: Option<&'a mut (dyn GlyphProvider + 'a)>,
    sprite: Option<&'a mut (dyn SpriteProvider + 'a)>,
}

unsafe fn c_str(p: *const c_char) -> String {
    if p.is_null() {
        return String::new();
    }
    std::ffi::CStr::from_ptr(p).to_string_lossy().into_owned()
}

fn rect(r: &sys::D2ItemDrawRect) -> Rect {
    Rect { x: r.x, y: r.y, w: r.w, h: r.h }
}

unsafe extern "C" fn glyph_trampoline(user: *mut c_void, g: *const sys::D2ItemDrawGlyphRef, scale: u32, w: u32, h: u32, rgba: *mut u8) -> i32 {
    let user = &mut *(user as *mut User);
    let Some(p) = user.glyph.as_deref_mut() else { return 0 };
    let g = &*g;
    let r = GlyphRef {
        font: c_str(g.font),
        code: char::from_u32(g.code).unwrap_or('\u{fffd}'),
        frame: g.frame,
        color: g.color,
        rgb: [(g.rgb >> 16) as u8, (g.rgb >> 8) as u8, g.rgb as u8],
        cell: rect(&g.cell),
    };
    let tile = Tile { w, h, rgba: core::slice::from_raw_parts_mut(rgba, (w * h * 4) as usize) };
    p.draw_glyph(&r, scale, tile) as i32
}

unsafe extern "C" fn sprite_trampoline(user: *mut c_void, s: *const sys::D2ItemDrawSpriteRef, scale: u32, w: u32, h: u32, rgba: *mut u8) -> i32 {
    let user = &mut *(user as *mut User);
    let Some(p) = user.sprite.as_deref_mut() else { return 0 };
    let s = &*s;
    let r = SpriteRef {
        path: c_str(s.path),
        frame: s.frame,
        colormap: if s.colormap_set < 0 { None } else { Some((s.colormap_set, s.colormap_row)) },
        role: s.role,
        ethereal: s.ethereal != 0,
        rect: rect(&s.rect),
    };
    let tile = Tile { w, h, rgba: core::slice::from_raw_parts_mut(rgba, (w * h * 4) as usize) };
    p.draw_sprite(&r, scale, tile) as i32
}
