// FanBoost — system screen-capture detection. GPL-2.0.
//
// Private SkyLight API (the state behind the menu-bar capture indicator);
// verified on macOS 26. If a future macOS removes the symbol, the probe
// reports .unavailable and the app fails safe to automatic fans.
import Foundation

enum CaptureState {
    case capturing
    case idle
    case unavailable
}

final class CaptureProbe {
    private let isWatched: (@convention(c) () -> Int32)?

    init() {
        var fn: (@convention(c) () -> Int32)?
        if let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) {
            for symbol in ["SLSIsScreenWatcherPresent", "CGSIsScreenWatcherPresent"] {
                if let sym = dlsym(handle, symbol) {
                    fn = unsafeBitCast(sym, to: (@convention(c) () -> Int32).self)
                    break
                }
            }
        }
        isWatched = fn
    }

    func check() -> CaptureState {
        guard let isWatched else { return .unavailable }
        return isWatched() != 0 ? .capturing : .idle
    }
}
