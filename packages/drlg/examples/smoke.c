/*
 * d2drlg C-ABI smoke test.
 *
 * Build the shared lib + header first:
 *     zig build            # from packages/drlg
 *
 * Then compile + run this against the shared lib (from packages/drlg):
 *     zig cc -I include examples/smoke.c -o /tmp/d2drlg_smoke \
 *         -L zig-out/lib -ld2drlg -Wl,-rpath,zig-out/lib
 *     /tmp/d2drlg_smoke
 */
#include <stdio.h>
#include <stdint.h>
#include "d2drlg.h"

int main(void) {
    printf("d2drlg ABI version: %u\n", d2drlg_abi_version());

    D2DrlgCtx *ctx = d2drlg_ctx_create();
    if (!ctx) {
        fprintf(stderr, "d2drlg_ctx_create failed\n");
        return 1;
    }

    uint32_t seed = 305419896u; /* 0x12345678 */
    D2DrlgAct *act = d2drlg_gen_act(ctx, seed, /*difficulty=*/0, /*act_no=*/0);
    if (!act) {
        fprintf(stderr, "d2drlg_gen_act failed\n");
        d2drlg_ctx_destroy(ctx);
        return 1;
    }

    int32_t nlevels = d2drlg_act_level_count(act);
    printf("act 0, seed %u, normal: %d levels\n", seed, nlevels);

    if (nlevels > 0) {
        int32_t lid = d2drlg_act_level_id(act, 0);
        int32_t nrooms = d2drlg_act_level_room_count(act, 0);
        int32_t dtype = d2drlg_act_level_drlg_type(act, 0);
        printf("level[0]: id=%d drlgType=%d rooms=%d\n", lid, dtype, nrooms);

        if (nrooms > 0) {
            D2DrlgRoom rooms[512];
            int32_t got = d2drlg_act_rooms(act, 0, rooms, 512);
            printf("first room: x=%d y=%d w=%d h=%d nType=%d nPresetType=%d (full count %d)\n",
                   rooms[0].x, rooms[0].y, rooms[0].w, rooms[0].h,
                   rooms[0].n_type, rooms[0].n_preset_type, got);
        }
    }

    d2drlg_act_free(act);
    d2drlg_ctx_destroy(ctx);
    return 0;
}
