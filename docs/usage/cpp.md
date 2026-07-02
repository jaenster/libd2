# libd2 from C++

The header is `extern "C"`-guarded, so it works unchanged from C++. Grab
`include/d2items.h` + `lib/libd2items.*` from the `items-vX.Y.Z` GitHub Release.
See the [API reference](../../README.md#reference-api-the-items-package).

```cpp
#include "d2items.h"
#include <cstdio>

int main() {
    auto *ctx = d2items_create();
    D2ItemsDrop d[16];
    int n = d2items_roll(ctx, 12345, "Act 1 Equip A", 5, 0, d, 16);
    for (int i = 0; i < n && i < 16; i++)
        std::printf("%.4s ilvl=%d\n", d[i].item_code, d[i].item_level);
    d2items_destroy(ctx);
}
```

Build:

```sh
c++ main.cpp -I./include -L./lib -ld2items -o demo && ./demo
```
