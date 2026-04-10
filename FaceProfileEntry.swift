import Foundation
import os

@main
struct FaceProfileEntry {
    static func main() {
        NSSetUncaughtExceptionHandler { exception in
            let logger = Logger(subsystem: "com.user.face-profile-daemon", category: "crash")
            logger.critical("Uncaught exception: \(exception.name.rawValue, privacy: .public) — \(exception.reason ?? "no reason", privacy: .public)")
        }
        let daemon = FaceProfileDaemon()
        daemon.run()
    }
}
