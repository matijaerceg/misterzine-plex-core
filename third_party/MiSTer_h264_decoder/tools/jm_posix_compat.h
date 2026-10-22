/* POSIX stand-ins for the MSVC calls JM 18.4's ldecod uses unguarded (fastnn.c,
 * image.c's residual-dump path). Injected by tools/jm_build.sh with `-include`; never
 * part of the core. */
#ifndef JM_POSIX_COMPAT_H
#define JM_POSIX_COMPAT_H
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/types.h>

#define __int64 long long
#define _fseeki64 fseeko
#define _ftelli64 ftello
#define _chsize ftruncate
#define _fileno fileno
#define _aligned_free free

static inline void *_aligned_malloc(size_t size, size_t align)
{
    void *p = NULL;
    if (posix_memalign(&p, align, size ? size : align))
        return NULL;
    return p;
}
#endif
