#ifndef PIXMAN_VERSION_H__
#define PIXMAN_VERSION_H__

#ifndef PIXMAN_H__
#error pixman-version.h should only be included by pixman.h
#endif

#define PIXMAN_VERSION_MAJOR 0
#define PIXMAN_VERSION_MINOR 46
#define PIXMAN_VERSION_MICRO 4
#define PIXMAN_VERSION_STRING "0.46.4"
#define PIXMAN_VERSION_ENCODE(major, minor, micro) (((major) * 10000) + ((minor) * 100) + (micro))
#define PIXMAN_VERSION PIXMAN_VERSION_ENCODE(PIXMAN_VERSION_MAJOR, PIXMAN_VERSION_MINOR, PIXMAN_VERSION_MICRO)

#ifndef PIXMAN_API
#define PIXMAN_API
#endif

#endif
