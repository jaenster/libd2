/*
 * d2items C-ABI smoke test.
 *
 * Build the libs + header first (from packages/items):
 *     zig build
 *
 * Then compile & run this, linking the shared lib:
 *     zig cc -I zig-out/include examples/smoke.c -L zig-out/lib -ld2items \
 *         -Wl,-rpath,zig-out/lib -o zig-out/smoke && ./zig-out/smoke
 *
 * (Or with clang instead of `zig cc` — identical flags.)
 */
#include <stdio.h>
#include "d2items.h"

int main(void) {
    printf("d2items ABI version: %u\n", d2items_abi_version());

    D2ItemsCtx *ctx = d2items_create();
    if (!ctx) {
        fprintf(stderr, "d2items_create failed\n");
        return 1;
    }

    D2ItemsDrop drops[16];
    int32_t n = d2items_roll(ctx, 12345u, "Act 1 Equip A", 5, 0, drops, 16);
    printf("roll returned %d drop(s)\n", n);

    if (n > 0) {
        D2ItemsDrop *d = &drops[0];
        printf("first drop: kind=%u code=%c%c%c%c quality=%u sockets=%u ilvl=%d\n",
               d->kind,
               d->item_code[0] ? d->item_code[0] : ' ',
               d->item_code[1] ? d->item_code[1] : ' ',
               d->item_code[2] ? d->item_code[2] : ' ',
               d->item_code[3] ? d->item_code[3] : ' ',
               d->quality, d->sockets, d->item_level);
    }

    d2items_destroy(ctx);
    printf("ok\n");
    return 0;
}
