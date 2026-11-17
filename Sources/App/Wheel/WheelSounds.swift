import AppKit

/// Settings → Wheel → sounds: three quiet packs built from the system
/// sounds, off by default (BRIEF.md).
enum WheelSounds {
    enum Event { case open, hover, choose, cancel }

    static let packs: [(id: String, name: String)] = [("off", "Off"), ("soft", "Soft"), ("click", "Click"), ("glass", "Glass")]

    /// System sound name and volume per event; nil = silent.
    static func sound(_ event: Event, pack: String) -> (String, Float)? {
        switch (pack, event) {
        case ("soft", .open): ("Blow", 0.15)
        case ("soft", .choose): ("Pop", 0.35)
        case ("soft", .cancel): ("Bottle", 0.2)
        case ("click", .hover): ("Tink", 0.18)
        case ("click", .choose): ("Morse", 0.35)
        case ("click", .cancel): ("Tink", 0.25)
        case ("glass", .open): ("Glass", 0.15)
        case ("glass", .hover): ("Purr", 0.12)
        case ("glass", .choose): ("Glass", 0.4)
        case ("glass", .cancel): ("Funk", 0.15)
        default: nil
        }
    }

    private static var cache: [String: NSSound] = [:]

    static func play(_ event: Event, pack: String) {
        guard let (name, volume) = sound(event, pack: pack) else { return }
        let sound = cache[name] ?? NSSound(named: NSSound.Name(name))
        guard let sound else { return }
        cache[name] = sound
        sound.stop()
        sound.volume = volume
        sound.play()
    }
}
