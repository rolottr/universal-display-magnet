import Foundation

/// A display mode in public-API terms (`CGDisplayMode`).
public struct DisplayModeSpec: Codable, Hashable, Sendable {
    /// "Looks like" size in points.
    public var width: Int
    public var height: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var refreshRate: Double

    public init(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refreshRate: Double) {
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
    }

    public var isHiDPI: Bool { pixelWidth > width }

    public var label: String {
        let hz = refreshRate > 0 ? " @ \(Int(refreshRate.rounded()))Hz" : ""
        return "\(width)×\(height)\(isHiDPI ? " HiDPI" : "")\(hz)"
    }
}

/// Where one display sits in a saved arrangement.
public struct DisplayPlacement: Codable, Hashable, Sendable {
    public var identity: DisplayIdentity
    /// Global frame in points; the main display is at (0,0).
    public var frame: IRect
    public var mode: DisplayModeSpec?
    public var isMain: Bool

    public init(identity: DisplayIdentity, frame: IRect, mode: DisplayModeSpec? = nil, isMain: Bool) {
        self.identity = identity
        self.frame = frame
        self.mode = mode
        self.isMain = isMain
    }
}

/// A named arrangement for one display setup.
public struct ArrangementProfile: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var setupKey: String
    public var displays: [DisplayPlacement]
    /// Re-apply automatically whenever this setup connects or macOS reshuffles it.
    public var autoApply: Bool
    /// Also restore each display's resolution / refresh rate.
    public var restoreModes: Bool
    public var deviceID: String
    public var deviceName: String
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString, name: String, setupKey: String, displays: [DisplayPlacement],
        autoApply: Bool = true, restoreModes: Bool = false, deviceID: String, deviceName: String,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.setupKey = setupKey
        self.displays = displays
        self.autoApply = autoApply
        self.restoreModes = restoreModes
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.updatedAt = updatedAt
    }

    public var setupLabel: String { DisplaySetup.label(for: displays.map(\.identity)) }
}

/// One window as captured.
public struct WindowSnapshot: Codable, Hashable, Sendable {
    public var bundleID: String
    public var appName: String
    public var title: String
    /// CoreGraphics window number; only meaningful while the app keeps running.
    public var windowNumber: UInt32?
    /// `DisplayIdentity.hardwareKey` of the display the window was on.
    public var displayKey: String
    /// Ordinal among displays sharing `displayKey` (identical monitors without serials).
    public var displayOrdinal: Int
    /// Frame relative to its display's top-left corner, so it survives the
    /// arrangement changing around it.
    public var frame: IRect
    /// 1-based Desktop number on that display (regular desktops only).
    public var spaceIndex: Int?
    public var isFullscreen: Bool
    public var isMinimized: Bool
    /// Stacking order when captured (0 = front-most); nil if unknown.
    public var z: Int?
    /// 1-based position of the window's Space in its display's row of Spaces
    /// (Desktops and full-screen apps, Mission Control order).
    public var spacePosition: Int?
    /// It was on the Space the display was showing when captured.
    public var onVisibleSpace: Bool?
    /// Assigned to all Desktops.
    public var onAllDesktops: Bool?

    public init(
        bundleID: String, appName: String, title: String, windowNumber: UInt32?, displayKey: String,
        displayOrdinal: Int = 0, frame: IRect, spaceIndex: Int?, isFullscreen: Bool = false,
        isMinimized: Bool = false, z: Int? = nil, spacePosition: Int? = nil, onVisibleSpace: Bool? = nil,
        onAllDesktops: Bool? = nil
    ) {
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.windowNumber = windowNumber
        self.displayKey = displayKey
        self.displayOrdinal = displayOrdinal
        self.frame = frame
        self.spaceIndex = spaceIndex
        self.isFullscreen = isFullscreen
        self.isMinimized = isMinimized
        self.z = z
        self.spacePosition = spacePosition
        self.onVisibleSpace = onVisibleSpace
        self.onAllDesktops = onAllDesktops
    }

    /// Equality that ignores volatile fields, for "did anything change?" checks.
    public var placementSignature: String {
        "\(bundleID)|\(title)|\(displayKey)#\(displayOrdinal)|\(frame)|\(spaceIndex ?? 0)|\(isFullscreen)|\(isMinimized)"
    }
}

/// A global keyboard shortcut (Carbon key code + modifier mask).
public struct HotkeySpec: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    /// "⌥⌘D"
    public var display: String

    public init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }
}

/// A saved set of window positions for one display setup on one Mac.
public struct WindowLayout: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var setupKey: String
    public var deviceID: String
    public var deviceName: String
    /// Rolling snapshot the app keeps up to date on its own.
    public var isAutosave: Bool
    /// Set for a workspace: the monitor arrangement saved together with these
    /// windows, applied before they are restored.
    public var arrangementID: String?
    /// Restores this layout from anywhere.
    public var hotkey: HotkeySpec?
    public var windows: [WindowSnapshot]
    public var displays: [DisplayPlacement]
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString, name: String, setupKey: String, deviceID: String, deviceName: String,
        isAutosave: Bool = false, arrangementID: String? = nil, hotkey: HotkeySpec? = nil, windows: [WindowSnapshot],
        displays: [DisplayPlacement], updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.setupKey = setupKey
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.isAutosave = isAutosave
        self.arrangementID = arrangementID
        self.hotkey = hotkey
        self.windows = windows
        self.displays = displays
        self.updatedAt = updatedAt
    }

    public var isWorkspace: Bool { arrangementID != nil }

    public static func autosaveID(deviceID: String, setupKey: String) -> String {
        "autosave:\(deviceID):\(setupKey)"
    }
}

/// What a Mac publishes about itself to its peers.
public struct DeviceStatus: Codable, Hashable, Sendable, Identifiable {
    public var id: String { deviceID }
    public var deviceID: String
    public var name: String
    public var model: String
    public var displays: [DisplayPlacement]
    public var setupKey: String
    public var lastSeen: Date
    /// Ethernet / Wi-Fi hardware addresses, for Wake-on-LAN.
    public var macAddresses: [String]?
    /// Small JPEG of each display's wallpaper (same order as `displays`).
    public var wallpapers: [Data?]?

    public init(
        deviceID: String, name: String, model: String, displays: [DisplayPlacement], setupKey: String,
        lastSeen: Date = Date(), macAddresses: [String]? = nil, wallpapers: [Data?]? = nil
    ) {
        self.deviceID = deviceID
        self.name = name
        self.model = model
        self.displays = displays
        self.setupKey = setupKey
        self.lastSeen = lastSeen
        self.macAddresses = macAddresses
        self.wallpapers = wallpapers
    }
}
