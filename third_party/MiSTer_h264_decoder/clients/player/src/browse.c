/* browse -- folders and roots (browse.h). */
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include "browse.h"

int browse_is_video(const char *name)
{
    /* (0.15) and the containers of the codecs decoded on the ARM (docs/player.md "Other codecs"): AVI
     * (DivX / Xvid), MPEG program and elementary streams (.mpg, .vob, .m2v), ASF (WMV), Ogg (Theora), 3GP */
    static const char *const ext[] = {".mkv", ".mp4", ".m4v", ".mov", ".ts", ".m2ts", ".mts", ".264", ".h264",
                                      ".avi", ".divx", ".mpg", ".mpeg", ".m1v", ".m2v", ".vob", ".wmv", ".asf",
                                      ".ogv", ".3gp"};
    const char *dot = strrchr(name, '.');
    if (!dot) return 0;
    for (unsigned i = 0; i < sizeof ext / sizeof ext[0]; i++)
        if (!strcasecmp(dot, ext[i])) return 1;
    return 0;
}

/* case ignored, a run of digits compared by its value */
static int natcmp(const char *a, const char *b)
{
    while (*a && *b) {
        if (isdigit((unsigned char)*a) && isdigit((unsigned char)*b)) {
            while (*a == '0' && isdigit((unsigned char)a[1])) a++;
            while (*b == '0' && isdigit((unsigned char)b[1])) b++;
            size_t na = 0, nb = 0;
            while (isdigit((unsigned char)a[na])) na++;
            while (isdigit((unsigned char)b[nb])) nb++;
            if (na != nb) return na < nb ? -1 : 1;
            int c = strncmp(a, b, na);
            if (c) return c;
            a += na; b += nb;
            continue;
        }
        int ca = tolower((unsigned char)*a), cb = tolower((unsigned char)*b);
        if (ca != cb) return ca < cb ? -1 : 1;
        a++; b++;
    }
    return *a ? 1 : *b ? -1 : 0;
}

struct ent { char *name; int dir; };

static int ent_cmp(const void *x, const void *y)
{
    const struct ent *a = x, *b = y;
    if (a->dir != b->dir) return a->dir ? -1 : 1;
    int c = natcmp(a->name, b->name);
    return c ? c : strcmp(a->name, b->name);
}

static int is_dir(const char *path)
{
    struct stat st;
    return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

static int fill(struct listing *l, struct ent *e, unsigned n, const char *path)
{
    l->path = strdup(path);
    l->names = calloc(n + 1, sizeof *l->names);
    l->rows = calloc(n + 1, sizeof *l->rows);
    if (!l->path || !l->names || !l->rows) return -ENOMEM;
    for (unsigned i = 0; i < n; i++) {
        size_t k = strlen(e[i].name);
        l->names[i] = e[i].name;
        e[i].name = NULL;
        l->rows[i] = malloc(k + 2);
        if (!l->rows[i]) return -ENOMEM;
        memcpy(l->rows[i], l->names[i], k);
        if (e[i].dir) l->rows[i][k++] = '/';
        l->rows[i][k] = 0;
        l->n = i + 1;
        if (e[i].dir) l->n_dirs = i + 1;
    }
    return 0;
}

int browse_read(struct listing *l, const char *path)
{
    memset(l, 0, sizeof *l);
    DIR *d = opendir(path);
    if (!d) return -errno;
    struct ent *e = NULL;
    unsigned n = 0, cap = 0;
    int rc = 0;
    for (struct dirent *de; (de = readdir(d));) {
        if (de->d_name[0] == '.') continue;
        char full[4096];
        snprintf(full, sizeof full, "%s/%s", path, de->d_name);
        int dir = de->d_type == DT_DIR || ((de->d_type == DT_UNKNOWN || de->d_type == DT_LNK) && is_dir(full));
        if (!dir && !browse_is_video(de->d_name)) continue;
        if (n == cap) {
            cap = cap ? cap * 2 : 64;
            struct ent *ne = realloc(e, cap * sizeof *e);
            if (!ne) { rc = -ENOMEM; break; }
            e = ne;
        }
        if (!(e[n].name = strdup(de->d_name))) { rc = -ENOMEM; break; }
        e[n++].dir = dir;
    }
    closedir(d);
    if (!rc) {
        qsort(e, n, sizeof *e, ent_cmp);
        rc = fill(l, e, n, path);
    }
    for (unsigned i = 0; i < n; i++) free(e[i].name);
    free(e);
    if (rc) browse_free(l);
    return rc;
}

static int mounted(const char *path)
{
    DIR *d = opendir(path);
    if (!d) return 0;
    int any = 0;
    for (struct dirent *de; !any && (de = readdir(d));)
        any = strcmp(de->d_name, ".") && strcmp(de->d_name, "..");
    closedir(d);
    return any;
}

int browse_roots(struct listing *l, const char *const *roots, unsigned n)
{
    memset(l, 0, sizeof *l);
    struct ent *e = calloc(n + 1, sizeof *e);
    unsigned k = 0;
    int rc = e ? 0 : -ENOMEM;
    for (unsigned i = 0; !rc && i < n; i++) {
        if (!is_dir(roots[i])) continue;
        if (!strncmp(roots[i], "/media/usb", 10) && !mounted(roots[i])) continue;
        if (!(e[k].name = strdup(roots[i]))) rc = -ENOMEM;
        else e[k++].dir = 1;
    }
    if (!rc) rc = fill(l, e, k, "");      /* in the order given */
    for (unsigned i = 0; e && i < k; i++) free(e[i].name);
    free(e);
    if (rc) browse_free(l);
    return rc;
}

void browse_free(struct listing *l)
{
    for (unsigned i = 0; i < l->n; i++) {
        if (l->names) free(l->names[i]);
        if (l->rows) free(l->rows[i]);
    }
    free(l->names);
    free(l->rows);
    free(l->path);
    memset(l, 0, sizeof *l);
}

int browse_find(const struct listing *l, const char *name)
{
    for (unsigned i = 0; i < l->n; i++)
        if (!strcmp(l->names[i], name)) return (int)i;
    return -1;
}

void browse_split(const char *path, char *dir, char *base, unsigned n)
{
    const char *s = strrchr(path, '/');
    if (!s) { snprintf(dir, n, "."); snprintf(base, n, "%s", path); return; }
    snprintf(base, n, "%s", s + 1);
    snprintf(dir, n, "%.*s", s == path ? 1 : (int)(s - path), path);
}
