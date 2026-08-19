// iscaptured — exits 0 and prints "1" if some process is actively
// capturing/watching the screen (the state behind the macOS menu-bar
// capture indicator), else prints "0" and exits 1.
// Uses the private SkyLight call SLSIsScreenWatcherPresent; if it is
// missing on this macOS build we fail loudly (exit 2) so the watcher
// script can tell "no capture" apart from "probe broken".
#include <stdio.h>
#include <dlfcn.h>

int main(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    if (!h) { fprintf(stderr, "dlopen failed\n"); return 2; }
    int (*isWatched)(void) = dlsym(h, "SLSIsScreenWatcherPresent");
    if (!isWatched) isWatched = dlsym(h, "CGSIsScreenWatcherPresent");
    if (!isWatched) { fprintf(stderr, "symbol not found\n"); return 2; }
    int r = isWatched();
    printf("%d\n", r ? 1 : 0);
    return r ? 0 : 1;
}
