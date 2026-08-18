// The engine's collision bits, by their own names, and the masks that mean something.

/**
 * The engine's own collision bits, from `d2-core`'s `Colbit`. One flag per meaning, so a caller
 * that wants to draw doors differently from walls can ask rather than guess.
 */
export const Colbit = {
  /** Blocks walking. The primary terrain bit. */
  wall: 0x01,
  /** Blocks line of sight. */
  visible: 0x02,
  missileBarrier: 0x04,
  /** Blocks players only — monsters path straight through. Town borders use it. */
  noPlayer: 0x08,
  preset: 0x10,
  /** "No floor tile here": the engine's own marker for outside the level. Not a movement blocker. */
  blank: 0x20,
  missile: 0x40,
  player: 0x80,
  monster: 0x100,
  item: 0x200,
  object: 0x400,
  /** A closed door blocks; a host clears the bit when it opens. */
  door: 0x800,
  noPath: 0x1000,
} as const;

/**
 * The engine's own movement models, from `d2-core`'s `Colmask` — the same names the producer of a
 * grid uses, so the two cannot drift apart.
 */
export const Masks = {
  /** A walking player. The default everywhere a mask is optional. */
  playerPath: 0x1c09,
  playerFlying: 0x804,
  monsterPath: 0x3c01,
  monsterMissile: 0x101,
  /** `COLBIT_MISSILE_BARRIER | COLBIT_WALL`, as SKILL_CheckMissileCollisionAtTarget spells it. */
  missileFlight: 0x1001,
  spawn: 0x3e01,
  placement: 0x3f11,
  any: 0xffff,
} as const;
