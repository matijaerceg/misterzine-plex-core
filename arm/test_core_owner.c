/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <assert.h>
#include <stdio.h>

#include "core_owner.h"

/* A synthetic app name: what an app's build of the core would put first in
 * its CONF_STR and pass as --core-name. */
#define APP "Example App Core"

struct fake_cleanup { unsigned pause, settings; };

static void guarded_cleanup(struct jfplay_core_owner *owner, const char *name,
                            struct fake_cleanup *writes)
{
    if (!jfplay_core_owner_check(owner, name, 1, 99, 4000, 100)) return;
    ++writes->pause;
    ++writes->settings;
}

int main(void)
{
    assert(jfplay_core_name_owned("H264\n", NULL));
    assert(jfplay_core_name_owned("H264\n", ""));
    /* Given an app name, the upstream core is another app's. */
    assert(!jfplay_core_name_owned("H264\n", APP));
    assert(jfplay_core_name_owned(APP "\r\n", APP));
    assert(!jfplay_core_name_owned(APP "\n", NULL));
    assert(!jfplay_core_name_owned(APP "\n", ""));
    assert(!jfplay_core_name_owned(APP "\n", "Example App"));
    assert(!jfplay_core_name_owned("Example App\n", APP));
    assert(!jfplay_core_name_owned(NULL, APP));
    assert(!jfplay_core_name_owned("", APP));
    assert(!jfplay_core_name_owned("Other Core\n", APP));
    assert(!jfplay_core_name_owned("H264 extra\n", APP));

    struct jfplay_core_owner owner = {0};
    assert(jfplay_core_owner_check(&owner, "H264\n", 1, 10, 1000, 100));
    assert(!owner.lost);
    /* Pausing media leaves raster frames running, so advancing beat remains owned. */
    assert(jfplay_core_owner_check(&owner, "H264\n", 1, 11, 1050, 100));
    assert(jfplay_core_owner_check(&owner, "H264\n", 1, 12, 1100, 100));
    assert(!owner.lost);

    owner = (struct jfplay_core_owner){ .app_name = APP };
    struct fake_cleanup writes = {0};
    guarded_cleanup(&owner, "Other Core\n", &writes);
    assert(owner.lost);
    assert(writes.pause == 0 && writes.settings == 0);
    guarded_cleanup(&owner, APP "\n", &writes);
    assert(writes.pause == 0 && writes.settings == 0);

    /* Without an app name only the upstream name is owned. */
    owner = (struct jfplay_core_owner){0};
    assert(!jfplay_core_owner_check(&owner, APP "\n", 1, 7, 2000, 100));
    assert(owner.lost);

    /* With one, an upstream core loaded in its place is not owned. */
    owner = (struct jfplay_core_owner){ .app_name = APP };
    writes = (struct fake_cleanup){0};
    guarded_cleanup(&owner, "H264\n", &writes);
    assert(owner.lost);
    assert(writes.pause == 0 && writes.settings == 0);

    owner = (struct jfplay_core_owner){ .app_name = APP };
    assert(jfplay_core_owner_check(&owner, APP "\n", 1, 7, 2000, 100));
    assert(jfplay_core_owner_check(&owner, APP "\n", 1, 7, 2100, 100));
    assert(!jfplay_core_owner_check(&owner, APP "\n", 1, 7, 2101, 100));
    writes = (struct fake_cleanup){0};
    guarded_cleanup(&owner, APP "\n", &writes);
    assert(writes.pause == 0 && writes.settings == 0);

    owner = (struct jfplay_core_owner){0};
    assert(jfplay_core_owner_check(&owner, "H264\n", 0, 0, 3000, 100));
    assert(jfplay_core_owner_check(&owner, "H264\n", 0, 0, 3100, 100));
    assert(!jfplay_core_owner_check(&owner, "H264\n", 0, 0, 3101, 100));
    assert(owner.lost);

    puts("core ownership, raster heartbeat, and cleanup guard tests passed");
    return 0;
}
