/*
 * d2item C-ABI smoke test.
 *
 * Build the libs + header first (from packages/item):
 *     zig build
 *
 * Then compile & run this, linking the shared lib:
 *     zig cc -I zig-out/include examples/smoke.c -L zig-out/lib -ld2item \
 *         -Wl,-rpath,zig-out/lib -o zig-out/smoke && ./zig-out/smoke
 *
 * (Or with clang instead of `zig cc` — identical flags.)
 */
#include <stdio.h>
#include "d2item.h"

int main(void) {
    printf("d2item ABI version: %u\n", d2item_abi_version());

    D2ItemCtx *ctx = d2item_create();
    if (!ctx) {
        fprintf(stderr, "d2item_create failed\n");
        return 1;
    }

    D2ItemDrop drops[16];
    int32_t n = d2item_roll(ctx, 12345u, "Act 1 Equip A", 5, 0, drops, 16);
    printf("roll returned %d drop(s)\n", n);

    if (n > 0) {
        D2ItemDrop *d = &drops[0];
        printf("first drop: kind=%u code=%c%c%c%c quality=%u sockets=%u ilvl=%d\n",
               d->kind,
               d->item_code[0] ? d->item_code[0] : ' ',
               d->item_code[1] ? d->item_code[1] : ' ',
               d->item_code[2] ? d->item_code[2] : ' ',
               d->item_code[3] ? d->item_code[3] : ' ',
               d->quality, d->sockets, d->item_level);
    }

    d2item_destroy(ctx);
    printf("ok\n");
    return 0;
}
