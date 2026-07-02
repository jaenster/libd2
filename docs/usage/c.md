# libd2 from C

Download the native archive for your platform from the package's GitHub Release
(`items-vX.Y.Z`) — it contains `include/d2items.h` and `lib/libd2items.*`. See the
[API reference](../../README.md#reference-api-the-items-package).

```c
#include <stdio.h>
#include "d2items.h"

int main(void) {
    D2ItemsCtx *ctx = d2items_create();
    D2ItemsDrop drops[16];
    int32_t n = d2items_roll(ctx, 12345, "Act 1 Equip A", 5, 0, drops, 16);
    for (int i = 0; i < n && i < 16; i++)
        printf("drop %d: code=%.4s ilvl=%d\n", i, drops[i].item_code, drops[i].item_level);
    d2items_destroy(ctx);
}
```

Build — shared or static:

```sh
cc main.c -I./include -L./lib -ld2items -o demo && ./demo
cc main.c -I./include ./lib/libd2items.a -o demo   # static
```
