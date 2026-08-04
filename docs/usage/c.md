# libd2 from C

Download the native archive for your platform from a package's GitHub Release
(`drlg-vX.Y.Z`, `items-vX.Y.Z`, …) — it contains `include/d2<pkg>.h` and
`lib/libd2<pkg>.*`. The full API is at the bottom of this page.

## drlg — generate a map from a seed

```c
#include <stdio.h>
#include "d2drlg.h"

int main(void) {
    D2DrlgCtx *ctx = d2drlg_ctx_create();
    D2DrlgAct *act = d2drlg_gen_act(ctx, 305419896, 0, 0);  // seed, normal, Act I
    printf("act I: %d levels\n", d2drlg_act_level_count(act));

    D2DrlgRoom rooms[128];
    int32_t n = d2drlg_act_rooms(act, 0, rooms, 128);       // rooms of level 0
    printf("level 0: %d rooms; first at (%d,%d) %dx%d\n",
           n, rooms[0].x, rooms[0].y, rooms[0].w, rooms[0].h);

    d2drlg_act_free(act);
    d2drlg_ctx_destroy(ctx);
}
```

```sh
cc main.c -I./include -L./lib -ld2drlg -o demo && ./demo
cc main.c -I./include ./lib/libd2drlg.a -o demo   # static
```

## items — roll a drop

```c
#include "d2item.h"

D2ItemCtx *ctx = d2item_create();
D2ItemDrop drops[16];
int32_t n = d2item_roll(ctx, 12345, "Act 1 Equip A", 5, 0, drops, 16);
for (int i = 0; i < n && i < 16; i++)
    printf("drop %d: code=%.4s ilvl=%d\n", i, drops[i].item_code, drops[i].item_level);
d2item_destroy(ctx);
```

```sh
cc main.c -I./include -L./lib -ld2item -o demo && ./demo
```

## Reference: the `drlg` C API

Given a seed it generates an entire act's room layout.

```c
typedef struct D2DrlgCtx D2DrlgCtx;   // loaded game tables
typedef struct D2DrlgAct D2DrlgAct;   // a generated act
typedef struct D2DrlgRoom { int32_t x, y, w, h, n_type, n_preset_type; } D2DrlgRoom;
typedef struct D2DrlgShrine { int32_t class_id, x, y; } D2DrlgShrine;  // x/y are subtiles (÷5 for tiles)

D2DrlgCtx *d2drlg_ctx_create(void);
void       d2drlg_ctx_destroy(D2DrlgCtx *ctx);
// generate a whole act. difficulty 0/1/2; act_no 0..4. NULL on error.
D2DrlgAct *d2drlg_gen_act(D2DrlgCtx *ctx, uint32_t seed, int32_t difficulty, int32_t act_no);
void       d2drlg_act_free(D2DrlgAct *act);
int32_t    d2drlg_act_level_count(D2DrlgAct *act);
int32_t    d2drlg_act_level_id(D2DrlgAct *act, int32_t level_index);
int32_t    d2drlg_act_level_room_count(D2DrlgAct *act, int32_t level_index);
// writes up to `cap` rooms of a level into `out`; returns full count (may exceed cap) or <0.
int32_t    d2drlg_act_rooms(D2DrlgAct *act, int32_t level_index, D2DrlgRoom *out, int32_t cap);
// writes up to `cap` of a level's seeded outdoor shrines/wells; returns full count or <0.
int32_t    d2drlg_level_shrines(D2DrlgCtx *ctx, uint32_t seed, int32_t difficulty,
                                int32_t level_id, D2DrlgShrine *out, int32_t cap);
uint32_t   d2drlg_abi_version(void);
```

Both C APIs follow the same shape: `d2<pkg>_create`/`_destroy` (or `_ctx_create`), typed
`extern struct` records, and caller-provided output buffers. The headers ship in each
release and live at `packages/<pkg>/include/`.
