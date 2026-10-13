//! The item drawing wrapper against the fixtures the Zig side writes through the same C ABI
//! (testdata/itemdraw/bindings at the repository root).

use libd2::itemdraw::{Context, GlyphProvider, GlyphRef, Kind, TextMode, Tile, Viewer};
use std::path::PathBuf;

fn fixtures() -> Option<PathBuf> {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../testdata/itemdraw/bindings");
    p.exists().then_some(p)
}

fn strip_colors(s: &str) -> String {
    let mut out = String::new();
    let mut skip = false;
    for c in s.chars() {
        match c {
            '{' => skip = true,
            '}' if skip => skip = false,
            _ if !skip => out.push(c),
            _ => {}
        }
    }
    out
}

#[test]
fn text_matches_the_fixtures() {
    let Some(dir) = fixtures() else { return };
    let c = Context::new().unwrap();
    let viewer = Viewer { class: 1, level: 80, strength: 100, dexterity: 50 };
    let mut n = 0;
    for e in std::fs::read_dir(&dir).unwrap() {
        let p = e.unwrap().path();
        if p.extension().and_then(|x| x.to_str()) != Some("items") {
            continue;
        }
        let records = std::fs::read(&p).unwrap();
        let want = std::fs::read_to_string(p.with_extension("txt")).unwrap();
        assert_eq!(c.text(&records, None, TextMode::Colored).unwrap(), want, "{p:?}");
        let want_v = std::fs::read_to_string(p.with_extension("viewer.txt")).unwrap();
        assert_eq!(c.text(&records, Some(viewer), TextMode::Colored).unwrap(), want_v, "{p:?}");
        assert_eq!(c.alt_text(&records, None, 0).unwrap(), strip_colors(&want), "{p:?}");
        assert!(c.alt_text(&records, None, 20).unwrap().len() <= 20);
        n += 1;
    }
    assert_eq!(n, 5);
}

struct Boxes(usize);

impl GlyphProvider for Boxes {
    fn draw_glyph(&mut self, g: &GlyphRef, scale: u32, tile: Tile<'_>) -> bool {
        assert_eq!(tile.w, g.cell.w as u32 * scale);
        self.0 += 1;
        for px in tile.rgba.chunks_mut(4) {
            px.copy_from_slice(&[g.rgb[0], g.rgb[1], g.rgb[2], 255]);
        }
        true
    }
}

#[test]
fn layout_json_and_a_rust_provider_at_scale_2_and_4() {
    let (Some(dir), Ok(d2)) = (fixtures(), std::env::var("D2_DIR")) else { return };
    let mut c = Context::new().unwrap();
    for m in ["Patch_D2.mpq", "d2exp.mpq", "d2data.mpq"] {
        c.add_archive(&std::fs::read(PathBuf::from(&d2).join(m)).unwrap()).unwrap();
    }
    let records = std::fs::read(dir.join("griffons-eye.items")).unwrap();
    let l = c.layout(&records, None, Kind::Card).unwrap();
    assert_eq!(l.json, std::fs::read_to_string(dir.join("griffons-eye.layout.json")).unwrap());
    for scale in [2, 4] {
        let mut b = Boxes(0);
        let img = c.rasterize(&l, Some(&mut b), None, scale).unwrap();
        assert_eq!(img.width as i32, l.width * scale as i32);
        assert!(b.0 > 100);
    }
}
