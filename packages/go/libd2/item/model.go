package item

import (
	"bytes"
	"fmt"
)

// Kind is what a drop turned out to be.
type Kind uint8

// The drop kinds.
const (
	Nothing  Kind = 0
	Gold     Kind = 1
	Item     Kind = 2
	Quiver   Kind = 3
	BodyPart Kind = 4
)

func (k Kind) String() string {
	switch k {
	case Nothing:
		return "nothing"
	case Gold:
		return "gold"
	case Item:
		return "item"
	case Quiver:
		return "quiver"
	case BodyPart:
		return "bodypart"
	default:
		return fmt.Sprintf("Kind(%d)", uint8(k))
	}
}

// Quality is an item's quality tier.
type Quality uint8

// The quality tiers, numbered as the engine numbers them.
const (
	Invalid  Quality = 0
	Low      Quality = 1
	NormalQ  Quality = 2
	Superior Quality = 3
	Magic    Quality = 4
	Set      Quality = 5
	Rare     Quality = 6
	Unique   Quality = 7
	Crafted  Quality = 8
	Tempered Quality = 9
)

func (q Quality) String() string {
	switch q {
	case Invalid:
		return "invalid"
	case Low:
		return "low"
	case NormalQ:
		return "normal"
	case Superior:
		return "superior"
	case Magic:
		return "magic"
	case Set:
		return "set"
	case Rare:
		return "rare"
	case Unique:
		return "unique"
	case Crafted:
		return "crafted"
	case Tempered:
		return "tempered"
	default:
		return fmt.Sprintf("Quality(%d)", uint8(q))
	}
}

// Drop is a single rolled drop.
//
// The field order and types mirror D2ItemDrop exactly: the native side fills an array of these
// in place, so the layout is part of the ABI and must not be reordered. TestDropLayout guards it.
//
// Which of the id fields carry anything depends on Quality: a rare has RarePrefixIDs /
// RareSuffixIDs and a name from RarePrefixName / RareSuffixName, a unique has UniqueID, a magic
// item has PrefixID / SuffixID, and so on. Every id is a 1-based row in the table its name says.
type Drop struct {
	Kind Kind
	// ItemCode is the base item's code, space- or NUL-padded to four bytes. Use Code.
	ItemCode [4]byte
	Quality  Quality

	PrefixID uint16
	SuffixID uint16

	RarePrefixIDs [3]uint16
	RareSuffixIDs [3]uint16
	// RarePrefixName and RareSuffixName are the item's NAME, not mods.
	RarePrefixName uint16
	RareSuffixName uint16

	UniqueID uint16
	SetID    uint16
	// QualityID is a QualityItems.txt row, superior only.
	QualityID uint16
	// LowQualityID is a LowQualityItems.txt row, low quality only.
	LowQualityID uint16
	// AutoPrefixID is the base item's automagic affix.
	AutoPrefixID uint16

	Sockets  uint8
	Ethereal uint8

	// Quantity is a gold amount or a stack size.
	Quantity  int32
	ItemLevel int32
	// ItemSeed is the low word of the item's mod seed, which replays its property rolls.
	ItemSeed uint32
}

// Code is the base item's code as a string, with the padding removed.
func (d *Drop) Code() string {
	return string(bytes.TrimRight(d.ItemCode[:], "\x00 "))
}

// IsEthereal reports whether the item rolled ethereal.
func (d *Drop) IsEthereal() bool { return d.Ethereal != 0 }

func (d *Drop) String() string {
	switch d.Kind {
	case Gold:
		return fmt.Sprintf("%d gold", d.Quantity)
	case Item, Quiver:
		s := fmt.Sprintf("%s %s ilvl %d", d.Quality, d.Code(), d.ItemLevel)
		if d.Sockets > 0 {
			s += fmt.Sprintf(" %ds", d.Sockets)
		}
		if d.IsEthereal() {
			s += " eth"
		}
		return s
	default:
		return d.Kind.String()
	}
}
