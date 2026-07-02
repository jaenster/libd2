# libd2 from C++

The headers are `extern "C"`-guarded, so they work unchanged from C++. Grab
`include/d2<pkg>.h` + `lib/libd2<pkg>.*` from the package's GitHub Release. See the
[API reference](../../README.md#reference-api-the-drlg-map-generator).

## drlg — generate a map from a seed

```cpp
#include "d2drlg.h"
#include <cstdio>
#include <vector>

int main() {
    auto *ctx = d2drlg_ctx_create();
    auto *act = d2drlg_gen_act(ctx, 305419896, 0, 0);   // seed, normal, Act I
    int levels = d2drlg_act_level_count(act);
    std::printf("act I: %d levels\n", levels);

    std::vector<D2DrlgRoom> rooms(d2drlg_act_level_room_count(act, 0));
    d2drlg_act_rooms(act, 0, rooms.data(), (int)rooms.size());
    for (auto &r : rooms)
        std::printf("room (%d,%d) %dx%d type=%d\n", r.x, r.y, r.w, r.h, r.n_type);

    d2drlg_act_free(act);
    d2drlg_ctx_destroy(ctx);
}
```

```sh
c++ main.cpp -I./include -L./lib -ld2drlg -o demo && ./demo
```

## items — roll a drop

```cpp
#include "d2items.h"
auto *ctx = d2items_create();
D2ItemsDrop d[16];
int n = d2items_roll(ctx, 12345, "Act 1 Equip A", 5, 0, d, 16);
// … use d[0..n] …
d2items_destroy(ctx);
```
