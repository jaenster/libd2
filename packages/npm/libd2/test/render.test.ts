// The renderer decides nothing, which is what these check: given the same grid and different
// paints, it produces different pictures, and the frames convert back to where they started.

import {test} from 'node:test';
import assert from 'node:assert/strict';

import {init, open, Areas, rasterize, twoTone, View, Masks} from '../src/index.ts';

await init();

test('a rasterised level is one pixel per subtile, and its shape is the level, not a rectangle', () => {
  using game = open({seed: 1337});
  const area = game.area(Areas.ColdPlains);
  const raster = rasterize(area.collision, twoTone(0x2b2b2bff, 0x808080ff));

  assert.equal(raster.width, area.collision.width);
  assert.equal(raster.height, area.collision.height);
  assert.equal(raster.pixels.length, raster.width * raster.height * 4);

  // Outdoor levels are not full rectangles, so some cells are VOID and stay transparent.
  let transparent = 0;
  for (let i = 3; i < raster.pixels.length; i += 4) if (raster.pixels[i] === 0) transparent++;
  assert.ok(transparent > 0, 'an outdoor level has void outside its silhouette');
});

test('paint is the caller\'s decision, and the caller can read the flags', () => {
  using game = open({seed: 1337});
  const grid = game.area(Areas.ColdPlains).collision;

  const plain = rasterize(grid, twoTone(0xffffffff, 0x000000ff));
  const inverted = rasterize(grid, twoTone(0x000000ff, 0xffffffff));
  assert.notDeepEqual(plain.pixels.slice(0, 4096), inverted.pixels.slice(0, 4096));

  // A paint that distinguishes line-of-sight blockers from walls sees a third colour.
  const shaded = rasterize(grid, (cell) => {
    if (cell === 0xffff) return 0x00000000;
    if ((cell & Masks.playerPath) === 0) return 0x202020ff;
    return cell & 0x0002 ? 0x904040ff : 0x606060ff;
  });
  const colours = new Set<number>();
  for (let i = 0; i < shaded.pixels.length; i += 4) {
    colours.add((shaded.pixels[i]! << 16) | (shaded.pixels[i + 1]! << 8) | shaded.pixels[i + 2]!);
  }
  assert.ok(colours.size >= 3, 'reading the flags gives more than two tones');
});

test('the three frames round-trip', () => {
  using game = open({seed: 1337});
  const area = game.area(Areas.ColdPlains);
  const view = new View(area, {scale: 3});

  const local = area.at(40, 25);
  const pixel = view.toScreen(local);
  assert.deepEqual(pixel, {x: 120, y: 75});
  assert.ok(view.toLocation(pixel).equals(local));

  // A world position — the frame the server speaks — lands in the same place.
  assert.deepEqual(view.toScreen(local.world, 'world'), pixel);

  // Panning moves the picture, not the world.
  const centred = view.centredOn(local, 800, 600);
  assert.deepEqual(centred.toScreen(local), {x: 400, y: 300});
  assert.ok(centred.toLocation({x: 400, y: 300}).equals(local));
});
