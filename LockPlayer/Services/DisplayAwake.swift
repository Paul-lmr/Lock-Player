import Foundation
import IOKit.pwr_mgt

/// Empêche l'écran de s'éteindre (comme un lecteur vidéo) tant que l'assertion est active.
final class DisplayAwake {
    private var assertionID: IOPMAssertionID = 0
    private(set) var isActive = false

    func set(_ active: Bool) {
        guard active != isActive else { return }
        if active {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "LockPlayer : musique affichée sur l'écran verrouillé" as CFString,
                &assertionID
            )
            isActive = result == kIOReturnSuccess
        } else {
            IOPMAssertionRelease(assertionID)
            isActive = false
        }
    }

    deinit { set(false) }
}
