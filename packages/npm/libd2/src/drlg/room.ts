// What the generator placed: the rectangles it laid down and the objects it stood in them.

import {engine} from '../internal.ts';
import {readString} from '../wasm.ts';
import type {Area} from './area.ts';
import type {Location} from './location.ts';

/** A rectangle of an area, in world tiles. */
export interface Room {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
  /** RoomEx.nType */
  readonly type: number;
  /** 1 outdoor/maze, 2 preset. */
  readonly presetType: number;
  /** Preset nPickedFile, or outdoor nSubThemePicked. -1 when neither. */
  readonly pickedFile: number;
}

/**
 * What Objects.txt calls this class.
 *
 * The server never sends object names — a unit arrives as a class id and nothing else — so this is
 * the only way to know that the thing standing there is a waypoint rather than a barrel. Reading it
 * from the table beats a transcribed list of ids: "Waypoint" is sixteen different rows, one per
 * act's art plus town and wilderness variants, and a hardcoded id works until it doesn't.
 */
export function objectName(classId: number): string {
  const {exports, scratch} = engine();
  const {ptr} = scratch.take(64);
  const n = exports.d2drlg_object_name(classId, ptr, 64);
  return readString(scratch, ptr, n);
}

/** Something the generator placed: a preset object, by its Objects.txt id. */
export interface WorldObject {
  readonly area: Area;
  readonly location: Location;
  /** Objects.txt row. */
  readonly classId: number;
  /** Objects.txt name, or "" when the row has none. */
  readonly name: string;
}
