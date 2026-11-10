import Foundation

public struct Complex: Sendable {
    public var real: Double
    public var imaginary: Double
    public init(real: Double, imaginary: Double) { self.real = real; self.imaginary = imaginary }
    public var magnitude: Double { hypot(real, imaginary) }
    public var phase: Double { atan2(imaginary, real) }
    public static func * (a: Self, b: Self) -> Self {
        Self(real: a.real * b.real - a.imaginary * b.imaginary, imaginary: a.real * b.imaginary + a.imaginary * b.real)
    }
    public static func + (a: Self, b: Self) -> Self { Self(real: a.real + b.real, imaginary: a.imaginary + b.imaginary) }
}

public struct Biquad: Equatable, Sendable {
    public var b0: Double
    public var b1: Double
    public var b2: Double
    public var a1: Double
    public var a2: Double
    public var values: [Double] { [b0, b1, b2, a1, a2] }
    public func response(frequency: Double, sampleRate: Double) -> Complex {
        let omega = -2 * Double.pi * frequency / sampleRate
        let nr = b0 + b1 * cos(omega) + b2 * cos(2 * omega)
        let ni = b1 * sin(omega) + b2 * sin(2 * omega)
        let dr = 1 + a1 * cos(omega) + a2 * cos(2 * omega)
        let di = a1 * sin(omega) + a2 * sin(2 * omega)
        let divisor = dr * dr + di * di
        return Complex(real: (nr * dr + ni * di) / divisor, imaginary: (ni * dr - nr * di) / divisor)
    }
}

public enum FilterMath {
    public static func coefficient(kind: FilterKind, frequency: Double, gainDB: Double = 0, q: Double, sampleRate: Double) -> Biquad {
        let w = 2 * Double.pi * frequency / sampleRate
        let c = cos(w), alpha = sin(w) / (2 * q), a = pow(10, gainDB / 40)
        let b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double
        switch kind {
        case .peak:
            (b0, b1, b2) = (1 + alpha * a, -2 * c, 1 - alpha * a)
            (a0, a1, a2) = (1 + alpha / a, -2 * c, 1 - alpha / a)
        case .highPass:
            (b0, b1, b2) = ((1 + c) / 2, -(1 + c), (1 + c) / 2)
            (a0, a1, a2) = (1 + alpha, -2 * c, 1 - alpha)
        case .lowPass:
            (b0, b1, b2) = ((1 - c) / 2, 1 - c, (1 - c) / 2)
            (a0, a1, a2) = (1 + alpha, -2 * c, 1 - alpha)
        case .lowShelf:
            let t = 2 * sqrt(a) * alpha
            (b0, b1, b2) = (a * ((a + 1) - (a - 1) * c + t), 2 * a * ((a - 1) - (a + 1) * c), a * ((a + 1) - (a - 1) * c - t))
            (a0, a1, a2) = ((a + 1) + (a - 1) * c + t, -2 * ((a - 1) + (a + 1) * c), (a + 1) + (a - 1) * c - t)
        case .highShelf:
            let t = 2 * sqrt(a) * alpha
            (b0, b1, b2) = (a * ((a + 1) + (a - 1) * c + t), -2 * a * ((a - 1) + (a + 1) * c), a * ((a + 1) + (a - 1) * c - t))
            (a0, a1, a2) = ((a + 1) - (a - 1) * c + t, 2 * ((a - 1) - (a + 1) * c), (a + 1) - (a - 1) * c - t)
        }
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    public static func coefficients(channel: ChannelSettings, sampleRate: Double) -> [Biquad] {
        var result: [Biquad] = []
        if channel.highPass.enabled {
            result += channel.highPass.shape.qualityFactors.map { coefficient(kind: .highPass, frequency: channel.highPass.frequency, q: $0, sampleRate: sampleRate) }
        }
        if channel.lowPass.enabled {
            result += channel.lowPass.shape.qualityFactors.map { coefficient(kind: .lowPass, frequency: channel.lowPass.frequency, q: $0, sampleRate: sampleRate) }
        }
        if channel.eqEnabled {
            result += channel.bands.filter(\.enabled).map { coefficient(kind: $0.kind, frequency: $0.frequency, gainDB: $0.gainDB, q: $0.q, sampleRate: sampleRate) }
        }
        return result
    }

    public static func response(channel: ChannelSettings, frequency: Double, sampleRate: Double, masterDB: Double = 0) -> Complex {
        var response = coefficients(channel: channel, sampleRate: sampleRate).reduce(Complex(real: 1, imaginary: 0)) { $0 * $1.response(frequency: frequency, sampleRate: sampleRate) }
        let gain = pow(10, (channel.gainDB + channel.preampDB + masterDB) / 20) * (channel.inverted ? -1 : 1)
        let frames = (channel.delayMS * sampleRate / 1000).rounded()
        let phase = -2 * Double.pi * frequency * frames / sampleRate
        response = response * Complex(real: gain * cos(phase), imaginary: gain * sin(phase))
        return response
    }

    public static func effectiveDelayMS(_ milliseconds: Double, sampleRate: Double) -> Double {
        (milliseconds * sampleRate / 1000).rounded() * 1000 / sampleRate
    }
}
