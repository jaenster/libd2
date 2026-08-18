// The public surface. Everything a caller should reach for, and nothing else.

export {init, isInitialised, open, Game} from './game/game.ts';
export type {Difficulty, ActNumber} from './game/game.ts';

export {Area} from './drlg/area.ts';
export {Location} from './drlg/location.ts';
export {CollisionGrid, WalkGrid, Walk} from './drlg/collision.ts';
export {Masks, Colbit} from './drlg/collision.flags.ts';
export type {Point, Size} from './drlg/point.ts';
export {objectName} from './drlg/room.ts';
export type {Room, WorldObject} from './drlg/room.ts';
export type {Exit, Border, Crossing} from './drlg/exit.ts';

export {route, walkableAt, snap, areasBetween, exitFrom, lineOfSight} from './navigation.ts';
export {Route} from './route.ts';
export type {Move, Leg, MoveKind, RouteOptions} from './route.ts';

export {Areas} from './areas.ts';
export type {AreaId} from './areas.ts';

export {rasterize, twoTone, View, Minimap, wallSegments, floorRuns, walkableBounds, EDGE_CAP} from './render.ts';
export type {Raster, Rgba, Paint} from './render.ts';
