// The item drawing wrapper against the fixtures the Zig side writes through the same C ABI
// (testdata/itemdraw/bindings at the repository root).

import {test} from 'node:test';
import assert from 'node:assert/strict';
import {existsSync, readFileSync, readdirSync} from 'node:fs';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';

import {ItemDrawer, rasterizeLayout, type GlyphProvider} from '../src/index.ts';

const fixtures = fileURLToPath(new URL('../../../../testdata/itemdraw/bindings', import.meta.url));
const sorc = {classId: 1, level: 80, strength: 100, dexterity: 50};

test('text and alt text match the fixtures', {skip: !existsSync(fixtures)}, async () => {
  const d = await ItemDrawer.create();
  try {
    const items = readdirSync(fixtures).filter((f) => f.endsWith('.items'));
    assert.equal(items.length, 5);
    for (const f of items) {
      const records = new Uint8Array(readFileSync(join(fixtures, f)));
      const base = join(fixtures, f.slice(0, -'.items'.length));
      const want = readFileSync(`${base}.txt`, 'utf8');
      assert.equal(d.text(records, undefined, 'colored'), want, f);
      assert.equal(d.text(records, sorc, 'colored'), readFileSync(`${base}.viewer.txt`, 'utf8'), f);
      assert.equal(d.altText(records), want.replace(/\{\d+\}/g, ''), f);
      assert.ok(new TextEncoder().encode(d.altText(records, undefined, 20)).length <= 20);
    }
  } finally {
    d.destroy();
  }
});

const d2 = process.env.D2_DIR;

test('layout JSON, default raster and a JS provider at scale 2 and 4', {skip: !d2 || !existsSync(fixtures)}, async () => {
  const d = await ItemDrawer.create();
  try {
    for (const m of ['Patch_D2.mpq', 'd2exp.mpq', 'd2data.mpq']) d.addArchive(new Uint8Array(readFileSync(join(d2!, m))));
    const records = new Uint8Array(readFileSync(join(fixtures, 'griffons-eye.items')));
    const l = d.layout(records, 'card');
    try {
      assert.equal(l.json, readFileSync(join(fixtures, 'griffons-eye.layout.json'), 'utf8'));
      assert.deepEqual(d.rasterize(l).png, d.card(records).png);
      assert.equal(d.rasterize(l, 2).width, l.data.width * 2);
      for (const scale of [2, 4]) {
        let n = 0;
        const boxes: GlyphProvider = {
          drawGlyph(_font, glyph, _color, rgb, s, tile) {
            assert.equal(tile.w, glyph.w * s);
            n++;
            for (let i = 0; i < tile.rgba.length; i += 4) tile.rgba.set([rgb[0], rgb[1], rgb[2], 255], i);
            return true;
          },
        };
        const img = rasterizeLayout(l.data, {glyph: boxes}, scale);
        assert.equal(img.width, l.data.width * scale);
        assert.ok(n > 100);
        // a glyph pixel is the provider's colour, opaque over the box
        const g = l.data.lines.at(-1)!.spans[0]!.glyphs[0]!;
        const o = ((g.y * scale) * img.width + g.x * scale) * 4;
        const rgb = l.data.textColors[l.data.lines.at(-1)!.spans[0]!.color]!;
        assert.deepEqual([...img.rgba.slice(o, o + 4)], [...rgb, 255]);
        // a tinted cell below the box is its fill at the fill's alpha over nothing
        const c = l.data.cells.at(-1)!;
        const oc = (((c.y + c.h) * scale - 1) * img.width + c.x * scale) * 4;
        assert.deepEqual([...img.rgba.slice(oc, oc + 4)], [...c.rgb, c.alpha]);
        // and one under the box is the box laid over it: black at 192 over the tint at 64
        const t = l.data.cells[0]!;
        const ot = ((t.y * scale) * img.width + t.x * scale) * 4;
        assert.deepEqual([...img.rgba.slice(ot, ot + 4)], [2, 8, 1, 208]);
      }
    } finally {
      l.free();
    }
  } finally {
    d.destroy();
  }
});
