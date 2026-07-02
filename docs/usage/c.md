# libd2 from C

Download the native archive for your platform from a package's GitHub Release
(`drlg-vX.Y.Z`, `items-vX.Y.Z`, …) — it contains `include/d2<pkg>.h` and
`lib/libd2<pkg>.*`. See the [API reference](../../README.md#reference-api-the-drlg-map-generator).

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
#include "d2items.h"

D2ItemsCtx *ctx = d2items_create();
D2ItemsDrop drops[16];
int32_t n = d2items_roll(ctx, 12345, "Act 1 Equip A", 5, 0, drops, 16);
for (int i = 0; i < n && i < 16; i++)
    printf("drop %d: code=%.4s ilvl=%d\n", i, drops[i].item_code, drops[i].item_level);
d2items_destroy(ctx);
```

```sh
cc main.c -I./include -L./lib -ld2items -o demo && ./demo
```
