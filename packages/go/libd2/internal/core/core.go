// Package core carries the loaded-game-tables pointer between subsystems.
//
// d2pf routes over a world d2drlg generated and takes that generator's tables directly, so the
// two share one set of loaded tables rather than each holding its own copy. That pointer has to
// cross a package boundary, but it is not something a caller should ever hold: keeping the type
// in an internal package means the public API can pass it around without publishing a uintptr.
package core

// Ptr is what d2drlg_ctx_core returns. It is owned by the generator that produced it and is
// valid only for that generator's lifetime.
type Ptr uintptr
