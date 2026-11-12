import Foundation

/// A 3D colour lookup table as Core Image wants it: RGBA floats, red changing fastest.
struct CubeLUT {
    let name: String
    let dimension: Int
    let data: [Float]
}

struct CubeParseError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Parses Adobe/Resolve `.cube` files (the format Elgato Camera Hub, OBS and most LUT packs use).
enum CubeParser {
    static func parse(_ text: String, name: String) throws -> CubeLUT {
        var size = 0
        var domainMin: [Float] = [0, 0, 0]
        var domainMax: [Float] = [1, 1, 1]
        var values: [Float] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let head = parts.first else { continue }
            switch head.uppercased() {
            case "TITLE":
                continue
            case "LUT_3D_SIZE":
                guard parts.count >= 2, let n = Int(parts[1]), (2...65).contains(n) else {
                    throw CubeParseError(message: "Unsupported LUT size. Framelight supports 3D LUTs from 2 to 65 points per side.")
                }
                size = n
                values.reserveCapacity(n * n * n * 4)
            case "LUT_1D_SIZE":
                throw CubeParseError(message: "This is a 1D LUT. Framelight needs a 3D .cube LUT.")
            case "DOMAIN_MIN":
                domainMin = parts.dropFirst().compactMap(Float.init)
            case "DOMAIN_MAX":
                domainMax = parts.dropFirst().compactMap(Float.init)
            case "LUT_3D_INPUT_RANGE":
                if parts.count >= 3, let lo = Float(parts[1]), let hi = Float(parts[2]) {
                    domainMin = [lo, lo, lo]; domainMax = [hi, hi, hi]
                }
            default:
                guard parts.count >= 3, let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) else {
                    // Unknown keywords are allowed by the spec; skip them.
                    if Float(head) == nil { continue }
                    throw CubeParseError(message: "Couldn't read the line “\(line.prefix(40))”.")
                }
                values += [r, g, b, 1]
            }
        }

        guard size > 0 else { throw CubeParseError(message: "This file has no LUT_3D_SIZE, so it isn't a 3D .cube LUT.") }
        guard domainMin.count == 3, domainMax.count == 3, domainMin == [0, 0, 0], domainMax == [1, 1, 1] else {
            throw CubeParseError(message: "LUTs with a custom input domain (for log footage) aren't supported. Use a Rec.709 / sRGB LUT.")
        }
        let expected = size * size * size * 4
        guard values.count == expected else {
            throw CubeParseError(message: "The LUT says \(size)³ entries but has \(values.count / 4).")
        }
        // Outputs may slightly exceed 0…1 in some packs; keep them sane.
        let clamped = values.map { min(max($0, 0), 1) }
        return CubeLUT(name: name, dimension: size, data: clamped)
    }
}

/// Imported LUTs live in ~/Library/Application Support/Framelight/LUTs.
final class LUTLibrary: @unchecked Sendable {
    static let shared = LUTLibrary()

    private let lock = NSLock()
    private var cache: [String: CubeLUT] = [:]

    let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Framelight/LUTs", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    func names() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return files.filter { $0.lowercased().hasSuffix(".cube") }
            .map { String($0.dropLast(5)) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Validates and copies a .cube file into the library. Returns its name.
    @discardableResult
    func importLUT(from url: URL) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        let name = url.deletingPathExtension().lastPathComponent
        let lut = try CubeParser.parse(text, name: name)
        let dest = folder.appendingPathComponent(name + ".cube")
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try text.write(to: dest, atomically: true, encoding: .utf8)
        lock.lock(); cache[name] = lut; lock.unlock()
        return name
    }

    func remove(_ name: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name + ".cube"))
        lock.lock(); cache[name] = nil; lock.unlock()
    }

    func load(_ name: String) -> CubeLUT? {
        lock.lock()
        if let hit = cache[name] { lock.unlock(); return hit }
        lock.unlock()
        let url = folder.appendingPathComponent(name + ".cube")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let lut = try? CubeParser.parse(text, name: name) else { return nil }
        lock.lock(); cache[name] = lut; lock.unlock()
        return lut
    }
}
