/* browse -- the file player's folders (docs/player.md P2): a folder's sub-folders and video files,
 * sorted for people (folders first, then files; case ignored, numbers by value: "Episode 2"
 * before "Episode 10"), and the roots the browser starts from. */
#ifndef PLAYER_BROWSE_H
#define PLAYER_BROWSE_H

struct listing {
    char *path;               /* the folder ("" the roots) */
    unsigned n, n_dirs;       /* entries; the first n_dirs are folders */
    char **names;             /* each entry's name (a root's: its full path) */
    char **rows;              /* what the list shows: "name/" for a folder, "name" for a file */
};

/* the extensions the player offers (the containers its FFmpeg reads: docs/player.md) */
int browse_is_video(const char *name);
/* a folder's entries; 0, or -errno. Hidden entries (".name") are left out. */
int browse_read(struct listing *l, const char *path);
/* the roots: those of `roots` (n) that exist as folders -- a /media/usbN only when something is
 * mounted there (not empty) */
int browse_roots(struct listing *l, const char *const *roots, unsigned n);
void browse_free(struct listing *l);
/* the entry called name (-1 none) */
int browse_find(const struct listing *l, const char *name);
/* a path's last component, and its folder (both in buffers of n bytes) */
void browse_split(const char *path, char *dir, char *base, unsigned n);

#endif
