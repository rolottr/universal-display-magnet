import AppKit
import CoreGraphics
import UniversalDisplayMagnetCore
import IOKit
import IOKit.graphics

/// A display that is connected and active right now.
struct LiveDisplay: Identifiable, Hashable {
    let id: CGDirectDisplayID
    var identity: DisplayIdentity
    /// Global frame in points (`CGDisplayBounds`).
    var frame: IRect
    var isMain: Bool
    var mode: DisplayModeSpec?
    /// Position among connected displays sharing the same hardware key
    /// (identical monitors without serials), ordered left-to-right.
    var ordinal: Int

    var placement: DisplayPlacement {
        DisplayPlacement(identity: identity, frame: frame, mode: mode, isMain: isMain)
    }
}

enum DisplayService {
    // MARK: - Enumeration

    /// Every active display, built-in or not. Mirror-set secondaries are left
    /// out: they can't be positioned on their own.
    static func activeDisplays() -> [LiveDisplay] {
        if DemoRenderer.isActive { return DemoRenderer.localDisplays }
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(max(count, 1)))
        CGGetActiveDisplayList(count, &ids, &count)
        let attributes = ioDisplayAttributes()
        let screenNames = Dictionary(
            NSScreen.screens.compactMap { s -> (CGDirectDisplayID, String)? in
                guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                    return nil
                }
                return (n.uint32Value, s.localizedName)
            }, uniquingKeysWith: { a, _ in a })

        var displays: [LiveDisplay] = ids.prefix(Int(count)).compactMap { id in
            let mirrorOf = CGDisplayMirrorsDisplay(id)
            guard mirrorOf == kCGNullDirectDisplay else { return nil }
            let vendor = CGDisplayVendorNumber(id)
            let model = CGDisplayModelNumber(id)
            let serial = CGDisplaySerialNumber(id)
            let io = attributes.first { $0.vendor == vendor && $0.product == model && $0.serial == serial }
            let builtin = CGDisplayIsBuiltin(id) != 0
            let name = screenNames[id] ?? io?.name ?? (builtin ? "Built-in Display" : "Display \(id)")
            let identity = DisplayIdentity(
                vendor: vendor, model: model, serial: serial, alphanumericSerial: io?.alphanumericSerial,
                name: name, isBuiltin: builtin, uuid: uuidString(for: id))
            return LiveDisplay(
                id: id, identity: identity, frame: IRect(CGDisplayBounds(id)), isMain: CGDisplayIsMain(id) != 0,
                mode: currentMode(id), ordinal: 0)
        }

        // Ordinals for identical hardware keys, left-to-right then top-to-bottom.
        let groups = Dictionary(grouping: displays.indices, by: { displays[$0].identity.hardwareKey })
        for (_, indices) in groups where indices.count > 1 {
            let sorted = indices.sorted {
                (displays[$0].frame.x, displays[$0].frame.y) < (displays[$1].frame.x, displays[$1].frame.y)
            }
            for (ordinal, i) in sorted.enumerated() { displays[i].ordinal = ordinal }
        }
        return displays.sorted { ($0.frame.x, $0.frame.y) < ($1.frame.x, $1.frame.y) }
    }

    static func uuidString(for id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func currentMode(_ id: CGDirectDisplayID) -> DisplayModeSpec? {
        guard let m = CGDisplayCopyDisplayMode(id) else { return nil }
        return DisplayModeSpec(m)
    }

    static func availableModes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
    }

    /// Closest available mode to `target`, or nil when nothing is reasonably close.
    static func bestMode(for target: DisplayModeSpec, on id: CGDirectDisplayID) -> CGDisplayMode? {
        let modes = availableModes(id)
        func distance(_ m: CGDisplayMode) -> (Int, Int, Double) {
            (
                abs(m.pixelWidth - target.pixelWidth) + abs(m.pixelHeight - target.pixelHeight),
                abs(m.width - target.width) + abs(m.height - target.height),
                abs(m.refreshRate - target.refreshRate)
            )
        }
        guard let best = modes.min(by: { distance($0) < distance($1) }) else { return nil }
        let d = distance(best)
        // Never force a wildly different mode: stay within 15% of the target.
        guard d.0 <= (target.pixelWidth + target.pixelHeight) * 15 / 100,
            d.1 <= (target.width + target.height) * 15 / 100
        else { return nil }
        return best
    }

    // MARK: - Applying

    enum ApplyError: LocalizedError {
        case begin(CGError), complete(CGError)

        var errorDescription: String? {
            switch self {
            case .begin(let e): return "Could not start display configuration (\(e.rawValue))"
            case .complete(let e): return "macOS rejected the display configuration (\(e.rawValue))"
            }
        }
    }

    /// Change resolutions in their own transaction, so origins can be
    /// computed afterwards against the new point sizes.
    static func applyModes(_ modes: [CGDirectDisplayID: CGDisplayMode]) throws {
        let changes = modes.filter { id, mode in
            guard let cur = CGDisplayCopyDisplayMode(id) else { return true }
            return DisplayModeSpec(cur) != DisplayModeSpec(mode)
        }
        guard !changes.isEmpty else { return }
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success else { throw ApplyError.begin(begin) }
        for (id, mode) in changes { CGConfigureDisplayWithDisplayMode(config, id, mode, nil) }
        let done = CGCompleteDisplayConfiguration(config, .permanently)
        guard done == .success else { throw ApplyError.complete(done) }
    }

    /// Move displays to the given origins in one transaction. The display at
    /// (0,0) becomes the main display.
    static func applyOrigins(_ origins: [CGDirectDisplayID: (x: Int, y: Int)]) throws {
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success else { throw ApplyError.begin(begin) }
        for (id, o) in origins { CGConfigureDisplayOrigin(config, id, Int32(o.x), Int32(o.y)) }
        let done = CGCompleteDisplayConfiguration(config, .permanently)
        guard done == .success else { throw ApplyError.complete(done) }
    }

    // MARK: - Change notifications

    private static var onChange: (() -> Void)?

    /// Calls `handler` on the main queue after any display is added, removed,
    /// moved or changes mode.
    static func observeChanges(_ handler: @escaping () -> Void) {
        onChange = handler
        CGDisplayRegisterReconfigurationCallback(
            { _, flags, _ in
                guard !flags.contains(.beginConfigurationFlag) else { return }
                DispatchQueue.main.async { DisplayService.onChange?() }
            }, nil)
    }

    // MARK: - IOKit (EDID serials)

    struct IOAttributes {
        var vendor: UInt32
        var product: UInt32
        var serial: UInt32
        var alphanumericSerial: String?
        var name: String?
    }

    /// Product attributes for every connected panel. Apple silicon exposes them
    /// on IOMobileFramebuffer; Intel Macs on IODisplayConnect (EDID parsed here).
    static func ioDisplayAttributes() -> [IOAttributes] {
        var result: [IOAttributes] = []
        forEachService(matching: "IOMobileFramebuffer") { service in
            guard
                let attrs = IORegistryEntryCreateCFProperty(
                    service, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                let p = attrs["ProductAttributes"] as? [String: Any]
            else { return }
            result.append(
                IOAttributes(
                    vendor: (p["LegacyManufacturerID"] as? NSNumber)?.uint32Value ?? 0,
                    product: (p["ProductID"] as? NSNumber)?.uint32Value ?? 0,
                    serial: (p["SerialNumber"] as? NSNumber)?.uint32Value ?? 0,
                    alphanumericSerial: p["AlphanumericSerialNumber"] as? String,
                    name: p["ProductName"] as? String))
        }
        guard result.isEmpty else { return result }

        forEachService(matching: "IODisplayConnect") { service in
            guard
                let info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName))?
                    .takeRetainedValue() as? [String: Any]
            else { return }
            let edid = info[kIODisplayEDIDKey] as? Data
            result.append(
                IOAttributes(
                    vendor: (info[kDisplayVendorID] as? NSNumber)?.uint32Value ?? 0,
                    product: (info[kDisplayProductID] as? NSNumber)?.uint32Value ?? 0,
                    serial: (info[kDisplaySerialNumber] as? NSNumber)?.uint32Value ?? 0,
                    alphanumericSerial: edid.flatMap { edidDescriptor($0, tag: 0xFF) },
                    name: (info[kDisplayProductName] as? [String: String])?.values.first))
        }
        return result
    }

    /// Text of an EDID display descriptor (0xFF serial, 0xFC name).
    static func edidDescriptor(_ edid: Data, tag: UInt8) -> String? {
        let bytes = [UInt8](edid)
        guard bytes.count >= 128 else { return nil }
        for offset in stride(from: 54, through: 108, by: 18)
        where bytes[offset] == 0 && bytes[offset + 1] == 0 && bytes[offset + 3] == tag {
            let text = bytes[(offset + 5)..<(offset + 18)].prefix { $0 != 0x0A }
            return String(bytes: text, encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func forEachService(matching className: String, _ body: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            body(service)
            IOObjectRelease(service)
        }
    }
}

extension IRect {
    init(_ r: CGRect) {
        self.init(
            x: Int(r.origin.x.rounded()), y: Int(r.origin.y.rounded()), width: Int(r.width.rounded()),
            height: Int(r.height.rounded()))
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

extension DisplayModeSpec {
    init(_ m: CGDisplayMode) {
        self.init(
            width: m.width, height: m.height, pixelWidth: m.pixelWidth, pixelHeight: m.pixelHeight,
            refreshRate: m.refreshRate)
    }
}
