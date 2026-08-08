export {init, isInitialised, open, Game, Area, Location, CollisionGrid, Masks} from './game.ts';
export type {Difficulty, ActNumber, Point, Size, Room, Exit, WorldObject} from './game.ts';

export {
  route, walkableAt, snap, areasBetween, exitFrom, lineOfSight, Route,
} from './navigation.ts';
export type {Move, Leg, RouteOptions} from './navigation.ts';

export {Areas} from './areas.ts';
export type {AreaId} from './areas.ts';

export type {MoveKind} from './wasm.ts';
