import Foundation

/// The day/night and weather clock, and the colours it grades the world to.
///
/// This is the half of the sky that the simulation reads — fizzlers ask it
/// whether it is night, crops whether it is raining, the save file what time
/// it is. It has no idea how a sky is drawn: `SkyController` paints it on
/// the Mac, `SDLSky` on everything else, and both read the colours from
/// `grade()`.
final class SkyClock {
    /// Seconds of real time for one full day. the original's is 20 minutes;
    /// this is faster so a play session actually sees a sunset.
    static let dayLength: Double = 600

    /// 0 = dawn, 0.25 = noon, 0.5 = dusk, 0.75 = midnight.
    private(set) var timeOfDay: Double = 0.18

    /// How many times `timeOfDay` has wrapped back to dawn this session.
    /// `timeOfDay` itself resets to `[0, 1)` every single day — that is what
    /// lets a clock reading double as "morning" or "midnight" without a
    /// separate day counter — so it cannot carry `weatherPeriod`'s multi-day
    /// span on its own. This is the day counter, kept only where `isRaining`
    /// reads it: nowhere else needs to know what day it is.
    private var dayIndex = 0

    /// Colour keys the cycle is interpolated between.
    ///
    /// The sky is a vertical gradient, so each key carries both ends of it.
    /// `horizon` does double duty: it is the bottom of the sky gradient
    /// *and* the colour distant terrain fogs into, which is what lets the
    /// two meet without a seam — so it is always the paler, warmer of the
    /// pair by day, and the fire at dawn and dusk.
    ///
    /// Components are sRGB, because these same numbers are also written
    /// straight into the sky gradient texture as sRGB bytes: one space for
    /// both paths is what keeps the fogged terrain and the sky behind it the
    /// same colour.
    private struct Key {
        let time: Double
        /// Straight overhead.
        let zenith: SIMD3<Float>
        /// The skyline, and the fog colour with it.
        let horizon: SIMD3<Float>
        /// Multiplied over every block texture.
        let daylight: SIMD3<Float>
    }

    /// One blend of the keys: everything a renderer needs to paint the sky
    /// and grade the terrain under it.
    struct Grade {
        var zenith: SIMD3<Float>
        var horizon: SIMD3<Float>
        var daylight: SIMD3<Float>
    }

    private static func rgb(_ red: Float, _ green: Float, _ blue: Float) -> SIMD3<Float> {
        SIMD3(red, green, blue)
    }

    private static let keys: [Key] = [
        // Sunrise: the sun is exactly on the horizon at 0.0.
        Key(time: 0.00,
            zenith: rgb(0.36, 0.35, 0.58),
            horizon: rgb(1.00, 0.60, 0.34),
            daylight: rgb(0.92, 0.74, 0.62)),
        // The daytime horizons are the colours the flat sky used to be, to
        // the byte: the fog is exactly what it always was, and the gradient
        // is built upward from it into a deeper blue overhead.
        Key(time: 0.10,
            zenith: rgb(0.38, 0.63, 0.94),
            horizon: rgb(0.67, 0.84, 0.97),
            daylight: rgb(0.98, 0.96, 0.93)),
        Key(time: 0.25,
            zenith: rgb(0.30, 0.58, 0.99),
            horizon: rgb(0.63, 0.82, 0.99),
            daylight: rgb(1, 1, 1)),
        Key(time: 0.40,
            zenith: rgb(0.38, 0.62, 0.94),
            horizon: rgb(0.67, 0.84, 0.97),
            daylight: rgb(0.98, 0.95, 0.90)),
        // Golden hour. The old flat sky was this orange everywhere; now it
        // is the horizon only, under a dusty violet zenith.
        Key(time: 0.50,
            zenith: rgb(0.54, 0.34, 0.62),
            horizon: rgb(0.98, 0.50, 0.26),
            daylight: rgb(0.84, 0.60, 0.47)),
        Key(time: 0.58,
            zenith: rgb(0.19, 0.13, 0.31),
            horizon: rgb(0.40, 0.26, 0.42),
            daylight: rgb(0.42, 0.46, 0.62)),
        Key(time: 0.75,
            zenith: rgb(0.02, 0.03, 0.10),
            horizon: rgb(0.07, 0.10, 0.22),
            daylight: rgb(0.30, 0.34, 0.50)),
        Key(time: 0.92,
            zenith: rgb(0.20, 0.20, 0.38),
            horizon: rgb(0.52, 0.34, 0.44),
            daylight: rgb(0.62, 0.55, 0.58)),
        Key(time: 1.00,
            zenith: rgb(0.36, 0.35, 0.58),
            horizon: rgb(1.00, 0.60, 0.34),
            daylight: rgb(0.92, 0.74, 0.62)),
    ]

    // MARK: The light on the Moon

    /// True on the Moon: a black sky by day as well as by night, no
    /// weather, and the home world hanging where the Moon would be.
    var isLunar = false
    /// True once the storyline is over. The beacon stops asking and simply
    /// shines, and the home world shows a light of its own.
    var beaconSteady = false
    /// Seconds the clock has run, for the blink.
    private(set) var elapsed: Double = 0

    /// How bright the point of light on the other body is, 0…1.
    ///
    /// From home it blinks the garden's request — three short, one long —
    /// until the story is over. From the Moon the home world shows nothing
    /// until then, and a steady light after.
    var beacon: Float {
        if beaconSteady { return 1 }
        if isLunar { return 0 }
        return SkyClock.blink(at: elapsed)
    }

    /// Three short flashes and one long one, every five seconds.
    static func blink(at time: Double) -> Float {
        let phase = time.truncatingRemainder(dividingBy: 5)
        switch phase {
        case 0..<0.3, 0.6..<0.9, 1.2..<1.5: return 1
        case 2.1..<3.3: return 1
        default: return 0
        }
    }

    /// Advances the clock by `dt` seconds of real time.
    func advance(dt: Double) {
        elapsed += dt
        timeOfDay += dt / SkyClock.dayLength
        if timeOfDay >= 1 {
            timeOfDay -= 1
            dayIndex += 1
        }
    }

    func setTimeOfDay(_ value: Double) {
        timeOfDay = value.truncatingRemainder(dividingBy: 1)
        if timeOfDay < 0 { timeOfDay += 1 }
        jumps += 1
    }

    /// Bumped by every `setTimeOfDay`. A renderer that grades the world a
    /// slice of the day at a time watches this to know its grade is stale
    /// even though the clock may have landed inside the same slice.
    private(set) var jumps = 0

    /// Restores the day counter `isRaining` reads — the one piece of the
    /// weather clock `timeOfDay` cannot carry itself, so unlike everything
    /// else `setTimeOfDay` resets, this needs its own setter and its own
    /// line in the save file.
    func setWeatherDayIndex(_ value: Int) {
        dayIndex = max(0, value)
    }

    /// What to write back out at save time.
    var weatherDayIndex: Int { dayIndex }

    /// True between dusk and dawn — this is what gates hostile spawning,
    /// standing in for a real light-level calculation.
    var isNight: Bool { SkyClock.isNight(at: timeOfDay) }

    /// The same question about a clock reading that is not this object's.
    /// Beds ask it, and the headless check that proves a night slept
    /// through lands in daylight.
    static func isNight(at time: Double) -> Bool {
        time > 0.52 || time < 0.02
    }

    /// How many days one stretch of clear-then-rain takes, counted in whole
    /// days plus the fraction `timeOfDay` is through the current one — see
    /// `dayIndex`. Long enough that a session sees real dry spells, not a
    /// flicker every few minutes.
    static let weatherPeriod: Double = 2.0
    /// The fraction of one weather period that rains, at the start of it —
    /// the last quarter of a longer dry spell reads as "the weather turned"
    /// rather than as noise.
    static let rainFraction: Double = 0.25

    /// True while it is raining — see `weatherPeriod`. `timeOfDay` alone
    /// repeats every single day, which would make it rain the same hours
    /// every day forever; `dayIndex` is what turns that into an actual
    /// multi-day cycle.
    var isRaining: Bool { !isLunar && SkyClock.isRaining(at: Double(dayIndex) + timeOfDay) }

    /// The same question about a clock reading that is not this object's —
    /// crop growth asks it from a headless check.
    static func isRaining(at time: Double) -> Bool {
        let phase = time.truncatingRemainder(dividingBy: weatherPeriod)
        let wrapped = phase < 0 ? phase + weatherPeriod : phase
        return wrapped < weatherPeriod * rainFraction
    }

    /// A clock reading, in the original's 24h scale. Shared with `clockText`
    /// so the debug overlay and anything else describing a time agree.
    static func clockText(at time: Double) -> String {
        let hours = (time * 24 + 6).truncatingRemainder(dividingBy: 24)
        let minutes = Int((hours - hours.rounded(.down)) * 60)
        return String(format: "%02d:%02d", Int(hours), minutes)
    }

    /// A readable clock for the debug overlay, in the original's 24h scale.
    var clockText: String { SkyClock.clockText(at: timeOfDay) }

    /// Blends the two keys bracketing the current time. Pure component
    /// arithmetic — no allocation, so it is free to call every frame.
    func grade() -> Grade {
        let keys = SkyClock.keys
        var lower = keys[0]
        var upper = keys[keys.count - 1]
        for index in 0..<(keys.count - 1) where timeOfDay >= keys[index].time && timeOfDay <= keys[index + 1].time {
            lower = keys[index]
            upper = keys[index + 1]
            break
        }
        let span = max(0.0001, upper.time - lower.time)
        let t = Float(min(1, max(0, (timeOfDay - lower.time) / span)))
        let graded = Grade(
            zenith: lower.zenith + (upper.zenith - lower.zenith) * t,
            horizon: lower.horizon + (upper.horizon - lower.horizon) * t,
            daylight: lower.daylight + (upper.daylight - lower.daylight) * t
        )
        if isLunar {
            // No air to scatter the light: the sky is black at noon, and
            // the sun falls on the ground white rather than gold.
            let white = SIMD3<Float>(repeating: (graded.daylight.x + graded.daylight.y + graded.daylight.z) / 3)
            return Grade(
                zenith: SIMD3<Float>(0.01, 0.01, 0.025),
                horizon: SIMD3<Float>(0.03, 0.03, 0.05),
                daylight: white
            )
        }
        guard isRaining else { return graded }
        // Rain grades the same three colours toward a flat overcast grey
        // rather than drawing anything new — the whole sky and every block
        // texture darken together in the one assignment a renderer already
        // makes, the same reason the day/night cycle needed no new render
        // path either.
        return Grade(
            zenith: SkyClock.rained(graded.zenith),
            horizon: SkyClock.rained(graded.horizon),
            daylight: SkyClock.rained(graded.daylight)
        )
    }

    /// Blends a graded colour toward flat overcast grey.
    private static func rained(_ colour: SIMD3<Float>) -> SIMD3<Float> {
        let overcast = SIMD3<Float>(0.48, 0.50, 0.53)
        return colour + (overcast - colour) * 0.55
    }
}
