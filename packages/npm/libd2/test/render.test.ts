// The renderer decides nothing, which is what these check: given the same grid and different
// paints, it produces different pictures, and the frames convert back to where they started.

import {test} from 'node:test';
import assert from 'node:assert/strict';

import {
  init, open, Areas, rasterize, twoTone, View, Masks, Walk,
  wallSegments, floorRuns, walkableBounds, Minimap,
} from '../src/index.ts';

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

test('the walk grid separates void from blocked, which the wall tracer depends on', () => {
  using game = open({seed: 1337});
  const walk = game.area(Areas.ColdPlains).walk;
  assert.ok(walk.width > 0 && walk.height > 0);

  const counts = [0, 0, 0];
  for (const cell of walk.cells) counts[cell] = (counts[cell] ?? 0) + 1;
  assert.ok(counts[Walk.open]! > 0, 'somewhere is walkable');
  assert.ok(counts[Walk.blocked]! > 0, 'something is a wall');
  assert.ok(counts[Walk.void]! > 0, 'an outdoor level is not a full rectangle');
});

test('wall lines trace open-meets-blocked, and merging keeps them countable', () => {
  using game = open({seed: 1337});
  const walk = game.area(Areas.ColdPlains).walk;

  const segments = wallSegments(walk);
  assert.ok(segments, 'the Cold Plains is not too fragmented for lines');
  assert.equal(segments.length % 4, 0);

  const lines = segments.length / 4;
  assert.ok(lines > 0);
  // Merging collinear edges is the whole reason this is drawable: without it a level this size is
  // tens of thousands of one-cell segments.
  assert.ok(lines < walk.cells.length / 10, `${lines} lines for ${walk.cells.length} cells`);

  // Every segment is axis-aligned — they are cell boundaries, not diagonals.
  for (let i = 0; i < segments.length; i += 4) {
    assert.ok(segments[i] === segments[i + 2] || segments[i + 1] === segments[i + 3]);
  }
});

test('floor runs cover exactly the walkable cells', () => {
  using game = open({seed: 1337});
  const walk = game.area(Areas.ColdPlains).walk;

  const runs = floorRuns(walk);
  let covered = 0;
  for (let i = 0; i < runs.length; i += 4) covered += runs[i + 2]!;

  let openCells = 0;
  for (const cell of walk.cells) if (cell === Walk.open) openCells++;
  assert.equal(covered, openCells);
});

test('the minimap projection is the engine\'s, and it inverts exactly', () => {
  const map = new Minimap({k: 4, ox: 100, oy: 50});

  // sx = (x - y)k + ox,  sy = (x + y)k/2 + oy
  assert.deepEqual(map.project(10, 4), {x: (10 - 4) * 4 + 100, y: (10 + 4) * 2 + 50});

  const back = map.unproject(...Object.values(map.project(37, 19)) as [number, number]);
  assert.ok(Math.abs(back.x - 37) < 1e-9 && Math.abs(back.y - 19) < 1e-9);

  // The matrix is the same transform, so a canvas applying it agrees with `project`.
  const [a, b, c, d, e, f] = map.matrix;
  const viaMatrix = {x: a * 37 + c * 19 + e, y: b * 37 + d * 19 + f};
  assert.deepEqual(viaMatrix, map.project(37, 19));
});

test('fitting a level centres it, and centring on a point puts it in the middle', () => {
  using game = open({seed: 1337});
  const walk = game.area(Areas.ColdPlains).walk;
  const box = walkableBounds(walk);

  const fitted = Minimap.fit(800, 600, box.x0, box.y0, box.x1, box.y1);
  const middle = fitted.project((box.x0 + box.x1) / 2, (box.y0 + box.y1) / 2);
  assert.ok(Math.abs(middle.x - 400) < 1 && Math.abs(middle.y - 300) < 1);

  const centred = fitted.centredOn({x: box.x0, y: box.y0}, 800, 600);
  const at = centred.project(box.x0, box.y0);
  assert.ok(Math.abs(at.x - 400) < 1 && Math.abs(at.y - 300) < 1);
});
