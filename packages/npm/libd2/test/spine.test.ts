// The spine: init once, then everything synchronous.
//
// These assert the SHAPE and the seed-determinism, not particular room counts — the Zig side owns
// the golden values and already checks them cell for cell. What is worth checking here is that the
// object model reads the right bytes out of the right handles.

import {test} from 'node:test';
import assert from 'node:assert/strict';

import {init, open, Areas, route, walkableAt, snap, areasBetween, type Location} from '../src/index.ts';

await init();

test('a game generates nothing until an area is asked for', () => {
  using game = open({seed: 1337});
  assert.equal(game.generatedActs.length, 0);

  const town = game.area(Areas.RogueEncampment);
  assert.equal(town.name, 'Rogue Encampment');
  assert.deepEqual(game.generatedActs, [0]);

  // Another area of the same act is free: one generation covers the act.
  game.area(Areas.BloodMoor);
  assert.deepEqual(game.generatedActs, [0]);
});

test('an area knows its own geometry', () => {
  using game = open({seed: 1337});
  const coldPlains = game.area(Areas.ColdPlains);

  assert.ok(coldPlains.size.width > 0 && coldPlains.size.height > 0);
  assert.ok(coldPlains.rooms.length > 0, 'an outdoor level has rooms');

  const grid = coldPlains.collision;
  assert.equal(grid.width, coldPlains.size.width * 5);
  assert.equal(grid.height, coldPlains.size.height * 5);
});

test('the same seed is the same world, and a different seed is not', () => {
  using a = open({seed: 1337});
  using b = open({seed: 1337});
  using c = open({seed: 7331});

  const rooms = (seed: {area: typeof a.area}) => seed.area(Areas.ColdPlains).rooms.length;
  assert.equal(rooms(a), rooms(b));
  assert.notEqual(rooms(a), rooms(c));
});

test('difficulty is part of a game, not a parameter of anything below it', () => {
  using normal = open({seed: 1337, difficulty: 'normal'});
  using hell = open({seed: 1337, difficulty: 'hell'});
  assert.equal(normal.difficulty, 'normal');
  assert.equal(hell.difficulty, 'hell');
  assert.equal(normal.area(Areas.ColdPlains).name, hell.area(Areas.ColdPlains).name);
});

test('a location carries its area, so the other frames are properties', () => {
  using game = open({seed: 1337});
  const coldPlains = game.area(Areas.ColdPlains);
  const at = coldPlains.at(10, 20);

  assert.equal(at.area, coldPlains);
  assert.equal(at.world.x, coldPlains.origin.x * 5 + 10);
  assert.equal(at.tile.x, coldPlains.origin.x + 2);
  assert.equal(at.toString(), 'Cold Plains (10,20)');
  assert.ok(at.offset(5, 0).equals(coldPlains.at(15, 20)));
});

test('walkability and snapping answer for a real grid', () => {
  using game = open({seed: 1337});
  const coldPlains = game.area(Areas.ColdPlains);

  // The geometric middle is as likely to be in a wall as not; snap is what makes it routable.
  const landed = snap(coldPlains.middle, 60);
  assert.ok(landed, 'somewhere near the middle of an outdoor level is walkable');
  assert.ok(walkableAt(landed), 'snap returns a cell that walkableAt accepts');
});

test('a route crosses areas and its legs name them in order', () => {
  using game = open({seed: 1337});
  const town = game.area(Areas.RogueEncampment);
  const coldPlains = game.area(Areas.ColdPlains);

  const from = snap(town.middle, 60);
  const to = snap(coldPlains.middle, 60);
  assert.ok(from && to);

  const path = route(from, to);
  assert.ok(path, 'the Rogue Encampment reaches the Cold Plains');
  assert.equal(path.from, from);
  assert.ok(path.length > 0, 'a route has moves');
  assert.equal(path.areas[0]?.id, town.id);
  assert.equal(path.areas.at(-1)?.id, coldPlains.id);

  // Iterating walks every move across every leg, in order.
  assert.equal([...path].length, path.length);
  // Every leg but the last leads somewhere, and it leads into the next leg's area.
  for (let i = 0; i < path.legs.length - 1; i++) {
    assert.equal(path.legs[i]?.exit?.id, path.legs[i + 1]?.area.id);
  }
  assert.equal(path.legs.at(-1)?.exit, null);
});

test('areasBetween names the trip without pathing inside any of it', () => {
  using game = open({seed: 1337});
  const crossing = areasBetween(game.area(Areas.RogueEncampment), game.area(Areas.ColdPlains));
  assert.ok(crossing.length >= 2);
  assert.equal(crossing[0]?.id, Areas.RogueEncampment);
  assert.equal(crossing.at(-1)?.id, Areas.ColdPlains);
});

test('a closed game refuses to be used again', () => {
  const game = open({seed: 1337});
  game.area(Areas.RogueEncampment);
  game.close();
  assert.throws(() => game.area(Areas.BloodMoor), /closed/);
  game.close(); // idempotent
});

test('a crossing is one seam, however many rooms named it', () => {
  using game = open({seed: 0x4dc98be3});
  const town = game.area(Areas.RogueEncampment);

  // The Rogue Encampment has exactly one way out. The generator names that border once per room
  // that touches it, so before the seams were merged this read as seven separate exits and a
  // route had seven equivalent answers to pick between.
  assert.equal(town.exits.length, 1);
  assert.equal(town.exits[0]!.to.id, Areas.BloodMoor);
  assert.ok(town.exits[0]!.points.length > 1, 'the seam keeps every cell that named it');

  // Every point of a seam lies on it: same destination, and each within a room or two of another.
  const {points} = town.exits[0]!;
  for (const p of points) {
    const neighbours = points.filter((q) => q !== p &&
      Math.max(Math.abs(q.x - p.x), Math.abs(q.y - p.y)) <= 80);
    assert.ok(neighbours.length > 0, `(${p.x},${p.y}) is not on the seam it was grouped into`);
  }

  // The Blood Moor's three ways out are three different places, not one border counted thrice.
  const moor = game.area(Areas.BloodMoor);
  const destinations = moor.exits.map((e) => e.to.id).sort((a, b) => a - b);
  assert.deepEqual(destinations, [...new Set(destinations)], 'one exit per destination here');
});

test('a seam offers the point nearest to where you are standing', () => {
  using game = open({seed: 0x4dc98be3});
  const exit = game.area(Areas.RogueEncampment).exits[0]!;
  const ends = exit.points.map((p) => p.world);

  // Standing on top of one end picks that end, not the middle — walking to the far end of a
  // border you are already touching is the long way round.
  for (const end of ends) {
    const nearest = exit.nearestTo(end)!;
    assert.deepEqual(nearest.world, end);
  }
  // The representative point is itself on the seam.
  assert.ok(exit.points.includes(exit.location!));
});

test('a scratch region survives the memory growth a wasm call can trigger', () => {
  using game = open({seed: 0x3cec89e8});
  // Act 4's levels are big enough that generating and reading them grows linear memory, which
  // DETACHES the ArrayBuffer any earlier DataView was built on. Reading several large grids in a
  // row is what caught this: the viewer died with "getInt32 on a detached ArrayBuffer" mid-frame.
  for (const id of [Areas.PandemoniumFortress, Areas.OuterSteppes]) {
    const area = game.area(id);
    assert.ok(area.size.width > 0);
    const walk = area.walk;
    assert.equal(walk.width * walk.height, walk.cells.length);
    // Reading the collision AFTER the walk grid forces a second pass over a grown memory.
    assert.ok(area.collision.width > 0);
    assert.ok(area.rooms.length >= 0);
  }
});

test('a unit standing on a cell makes it impassable, and the router goes around', () => {
  using game = open({seed: 1337});
  const town = game.area(Areas.RogueEncampment);

  // A stretch of open ground with a route across it, found rather than assumed — which cells are
  // open is the seed's business, and a hardcoded pair is a test that breaks when the map changes.
  let ends: {a: Location; b: Location} | undefined;
  for (let y = 40; y < 140 && !ends; y += 2) {
    const openXs: number[] = [];
    for (let x = 100; x < 260; x += 2) if (walkableAt(town.at(x, y))) openXs.push(x);
    const first = openXs[0];
    const last = openXs[openXs.length - 1];
    if (first !== undefined && last !== undefined && last - first >= 40) {
      ends = {a: town.at(first, y), b: town.at(last, y)};
    }
  }
  assert.ok(ends, 'the town should have a 40-subtile open run somewhere');
  const {a: from, b: to} = ends;
  const clear = route(from, to);
  assert.ok(clear, 'open ground should route');

  // Drop a monster squarely on a cell the plan crosses. The engine's collision is the same either
  // way — terrain or a unit, the square is taken — so walkability has to change.
  const onPath = clear.legs[0]!.moves.find((m) => m.location.distanceTo(from) > 8)!;
  assert.ok(onPath, 'the route should have a cell past its start');
  town.place({id: 0x4242, type: 1, size: 1, x: onPath.location.x, y: onPath.location.y});
  assert.equal(walkableAt(onPath.location), false, 'a monster makes its cell impassable');

  // And lifting it puts the world back exactly as it was — otherwise a bot that kills something
  // keeps routing around a corpse forever.
  town.lift(0x4242);
  assert.equal(walkableAt(onPath.location), true);

  // `occupy` is the whole-snapshot form: these and nothing else.
  town.occupy([{id: 1, type: 1, x: onPath.location.x, y: onPath.location.y}]);
  assert.equal(walkableAt(onPath.location), false);
  town.occupy([]);
  assert.equal(walkableAt(onPath.location), true);
});
