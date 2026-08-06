package drlg

import "fmt"

// Difficulty selects the difficulty a world is generated for. Nine levels change size with it.
type Difficulty int32

// The three difficulties, numbered as the engine numbers them.
const (
	Normal    Difficulty = 0
	Nightmare Difficulty = 1
	Hell      Difficulty = 2
)

func (d Difficulty) String() string {
	switch d {
	case Normal:
		return "normal"
	case Nightmare:
		return "nightmare"
	case Hell:
		return "hell"
	default:
		return fmt.Sprintf("Difficulty(%d)", int32(d))
	}
}

// Type is how a level's layout was generated.
type Type int32

// The three generator families.
const (
	Maze       Type = 1
	Preset     Type = 2
	Wilderness Type = 3
)

func (t Type) String() string {
	switch t {
	case Maze:
		return "maze"
	case Preset:
		return "preset"
	case Wilderness:
		return "wilderness"
	default:
		return fmt.Sprintf("Type(%d)", int32(t))
	}
}

// PresetKind is what a preset unit is.
type PresetKind int32

// The preset unit kinds the ABI defines. A generated Level only ever carries NPC and Object:
// warps come out as Adjacents, which say where each one leads as well as where it sits.
const (
	NPC    PresetKind = 1
	Object PresetKind = 2
	Exit   PresetKind = 5
)

func (k PresetKind) String() string {
	switch k {
	case NPC:
		return "npc"
	case Object:
		return "object"
	case Exit:
		return "exit"
	default:
		return fmt.Sprintf("PresetKind(%d)", int32(k))
	}
}

// Room is one generated room's world rectangle, in TILES.
//
// The field order and types mirror D2DrlgRoom exactly: the native side fills an array of these
// in place, so the layout is part of the ABI and must not be reordered.
type Room struct {
	X int32
	Y int32
	W int32
	H int32
	// Kind is RoomEx.nType.
	Kind int32
	// PresetKind is RoomEx.nPresetType.
	PresetKind int32
	// PickedFile is the preset's nPickedFile or an outdoor room's nSubThemePicked; -1 for neither.
	PickedFile int32
}

// PresetUnit is one npc, object or exit placed by the generator, in level-local SUBTILES.
//
// Mirrors D2DrlgPreset; layout is part of the ABI.
type PresetUnit struct {
	// Kind is what TxtFileNo indexes: a MonStats id, an Objects.txt row or a warp id.
	Kind PresetKind
	// TxtFileNo is the row this unit came from, meaning per Kind.
	TxtFileNo int32
	X         int32
	Y         int32
}

// Adjacent is one warp bridge tile: where a level's exit sits and what it leads to. Bridge
// coordinates are level-local SUBTILES.
//
// Mirrors D2DrlgAdjacent; layout is part of the ABI.
type Adjacent struct {
	DestLevelID int32
	BridgeX     int32
	BridgeY     int32
}

// Collision is a level's raw subtile CollMap: one Colbit set per subtile, row-major from the
// level's own top-left. Cells the generator never covered read Void.
type Collision struct {
	Width  int32
	Height int32
	Cells  []uint16
}

// At returns the collision flags at a level-local subtile, or Void when out of range.
func (c *Collision) At(x, y int32) uint16 {
	if c == nil || x < 0 || y < 0 || x >= c.Width || y >= c.Height {
		return Void
	}
	return c.Cells[y*c.Width+x]
}

// The engine's collision flags, as they appear in Collision.Cells.
const (
	// Wall blocks walking. The primary terrain bit.
	Wall uint16 = 0x01
	// Visible blocks line of sight.
	Visible uint16 = 0x02
	// MissileBarrier blocks missiles but not walking.
	MissileBarrier uint16 = 0x04
	// NoPlayer blocks players only; monsters path straight through it.
	NoPlayer uint16 = 0x08
	// PresetTile marks a preset tile. Not a movement blocker.
	PresetTile uint16 = 0x10
	// Blank marks real terrain with no floor tile. Not a movement blocker.
	Blank      uint16 = 0x20
	Missile    uint16 = 0x40
	Player     uint16 = 0x80
	MonsterBit uint16 = 0x100
	Item       uint16 = 0x200
	ObjectBit  uint16 = 0x400
	// Door is a door. Closed doors block; a host clears the bit when one opens.
	Door   uint16 = 0x800
	NoPath uint16 = 0x1000
	Pet    uint16 = 0x2000
	// Void is a cell the generator never covered — outside the level, not merely blocked.
	Void uint16 = 0xFFFF
)

// Walk is a level's derived walkability grid: one byte per subtile, 1 walkable, 0 blocked, with
// the same dimensions and origin as Collision. Ready to path on directly.
type Walk struct {
	Width  int32
	Height int32
	Cells  []uint8
}

// At reports whether a level-local subtile is walkable. Out of range is not walkable.
func (w *Walk) At(x, y int32) bool {
	if w == nil || x < 0 || y < 0 || x >= w.Width || y >= w.Height {
		return false
	}
	return w.Cells[y*w.Width+x] != 0
}

// Level is one generated level of an act.
//
// Origin and size are in TILES; rooms are in world tiles, while presets, adjacents and both
// grids are in level-local subtiles. Multiply the origin by 5 to convert between the two.
type Level struct {
	// ID is the Levels.txt id, stable across seeds.
	ID int32
	// Name is the in-game display name from Levels.txt.
	Name string
	Type Type
	// Placed reports whether the act placement graph positioned this level (a surface level),
	// as opposed to an interior with its own frame.
	Placed  bool
	OriginX int32
	OriginY int32
	Width   int32
	Height  int32

	Rooms     []Room
	Presets   []PresetUnit
	Adjacents []Adjacent

	// Collision is nil unless the act was generated WithCollision.
	Collision *Collision
	// Walk is nil unless the act was generated WithWalk.
	Walk *Walk
}

// SubtileOrigin is the level's origin in subtiles, the frame world positions use.
func (l *Level) SubtileOrigin() (x, y int32) { return l.OriginX * 5, l.OriginY * 5 }

// Act is a fully generated act: every level, with everything copied out of native memory. There
// is no handle to release and nothing that can be used after free.
type Act struct {
	Seed       uint32
	Difficulty Difficulty
	// Number is 0-based, as the engine numbers acts: 0 is Act I.
	Number int
	Levels []Level
}

// Level finds a level by its Levels.txt id, or nil when the act does not contain it.
func (a *Act) Level(id int32) *Level {
	for i := range a.Levels {
		if a.Levels[i].ID == id {
			return &a.Levels[i]
		}
	}
	return nil
}
