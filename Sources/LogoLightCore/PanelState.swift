import Foundation

/// What the menu shows: the menu bar icon, and the control panel with which of its parts can be used.
///
/// It's worked out from the logo's status and the user's choices, so the rules can be tested without
/// AppKit.
public struct PanelState: Equatable, Sendable {
    /// Whether this Mac has the illuminated logo.
    public var isSupported: Bool
    /// Whether the logo switch shows on. An unknown setting counts as on.
    public var isOn: Bool
    /// A change is under way (e.g. waiting for the password dialog).
    public var isBusy: Bool
    /// Whether the brightness and the effects are shown. They need direct control.
    public var showsAdjustments: Bool
    public var effect: LogoEffect
    public var brightness: Double
    /// The only text in the panel: why everything is disabled, on a Mac without the logo.
    public var message: String?
    /// The menu bar icon (an SF Symbols name), and what it means.
    public var symbolName: String
    public var symbolDescription: String

    public init(status: LogoStatus, canControlDirectly: Bool, effect: LogoEffect, brightness: Double,
                isBusy: Bool = false) {
        isSupported = status.isSupported
        isOn = status.isSupported && status.setting != .off
        self.isBusy = isBusy
        showsAdjustments = status.isSupported && canControlDirectly
        self.effect = effect
        self.brightness = brightness
        message = status.isSupported ? nil : "Needs a MacBook Pro with PROLED XDR Display"
        (symbolName, symbolDescription) = switch (status.isSupported, status.setting) {
        case (false, _): ("lightbulb.slash", "No illuminated logo on this Mac")
        case (true, .off): ("lightbulb.slash", "Logo illumination off")
        case (true, .on): ("lightbulb.fill", "Logo illumination on")
        case (true, nil): ("lightbulb", "Logo illumination unknown")
        }
    }

    /// Whether the brightness and the effects can be changed. Otherwise they're greyed out, and keep
    /// their values for when the logo is back on.
    public var canAdjust: Bool { showsAdjustments && isOn && !isBusy }
}
