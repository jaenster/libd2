// The spine: init once, then everything synchronous.
//
// These assert the SHAPE and the seed-determinism, not particular room counts — the Zig side owns
// the golden values and already checks them cell for cell. What is worth checking here is that the
// object model reads the right bytes out of the right handles.

import {test} from 'node:test';
import assert from 'node:assert/strict';

import {init, open, Areas, route, walkableAt, snap, areasBetween} from '../src/index.ts';

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
