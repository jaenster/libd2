// The one thing `navigation.ts` needs from `game.ts` that is not part of the public surface: the
// instantiated module and its scratch region. Kept here rather than exported from `game.ts` so
// that "what a Game is" stays readable without the plumbing in the middle of it.

import type {Game} from './game/game.ts';
import {load, Scratch, type Exports} from './wasm.ts';

let runtime: {exports: Exports; scratch: Scratch} | null = null;

export function setRuntime(next: {exports: Exports; scratch: Scratch}): void {
  runtime ??= next;
}

export function runtimeOrNull(): {exports: Exports; scratch: Scratch} | null {
  return runtime;
}

/**
 * The engine behind a Game.
 *
 * It takes the Game rather than nothing so the signature stays honest — one process could hold
 * several games, and every one of them is a view onto the same module. Today that module is a
 * singleton, and the parameter is what lets that stop being true without changing a caller.
 */
export function engineFor(_game: Game): {exports: Exports; scratch: Scratch} {
  if (!runtime) throw new Error('libd2: call `await init()` before using a game');
  return runtime;
}

export async function initRuntime(): Promise<void> {
  const exports = await load();
  runtime ??= {exports, scratch: new Scratch(exports)};
}

/**
 * The module, for the places that need it before a Game exists.
 *
 * `engineFor` is the same thing with a Game to hand; this is what an Area reaches for while it is
 * still being built.
 */
export function engine(): {exports: Exports; scratch: Scratch} {
  if (!runtime) throw new Error('libd2: call `await init()` before opening a game');
  return runtime;
}
