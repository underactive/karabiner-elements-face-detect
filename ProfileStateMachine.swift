// ProfileStateMachine.swift
// Pure state machine for face-presence profile switching.
// Decoupled from I/O (camera, HID, karabiner_cli) for testability.

public struct ProfileStateMachine {
    public let profileKeyboard: String
    public let profileGhost: String
    public let pollInterval: Double
    public let noFaceTimeout: Double

    public private(set) var cachedProfile: String? = nil
    public private(set) var noFaceStreak: Double = 0

    public enum Action: Equatable {
        case switchProfile(String)
        case none
    }

    public init(
        profileKeyboard: String = "⌨️",
        profileGhost: String = "👻",
        pollInterval: Double = 30,
        noFaceTimeout: Double = 300
    ) {
        self.profileKeyboard = profileKeyboard
        self.profileGhost = profileGhost
        self.pollInterval = pollInterval
        self.noFaceTimeout = noFaceTimeout
    }

    public mutating func onFaceDetected() -> Action {
        noFaceStreak = 0
        return selectProfile(profileKeyboard)
    }

    public mutating func onNoFace(elapsed: Double? = nil) -> Action {
        noFaceStreak += elapsed ?? pollInterval
        if noFaceStreak >= noFaceTimeout {
            return selectProfile(profileGhost)
        }
        return .none
    }

    public mutating func onHIDEvent() -> Action {
        noFaceStreak = 0
        return selectProfile(profileKeyboard)
    }

    public mutating func onSwitchFailed(forProfile profile: String) {
        if cachedProfile == profile {
            cachedProfile = nil
        }
    }

    private mutating func selectProfile(_ profile: String) -> Action {
        guard cachedProfile != profile else { return .none }
        cachedProfile = profile
        return .switchProfile(profile)
    }
}
