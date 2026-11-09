import Foundation

/// What the menu shows: the menu bar icon, and the control panel with which of its parts can be used.
///
/// It's worked out from the logo's status and the user's choices, so the rules can be tested without
/// AppKit.
public struct PanelState: Equatable, Sendable {
    /// Whether this Mac has the illuminated logo.
    public var isSupported: Bool
    /// Whether the logo switch shows on: the setting asked for while a switch is under way, otherwise
    /// the current one. An unknown setting counts as on.
    public var isOn: Bool
    /// Waiting for a password or `sudo` (the fallback path, which can't take another change meanwhile).
    public var isBusy: Bool
    /// Whether the brightness and the effects are shown. They need direct control.
    public var showsAdjustments: Bool
    /// Whether the Sound effect is among them: the sound can be heard on this Mac (macOS 14.2 or later).
    public var showsSound: Bool
    public var effect: LogoEffect
    /// The brightness the slider shows: the chosen one, or the battery's charge while it's followed.
    public var brightness: Double
    /// Whether the brightness follows the battery's charge (the Battery switch).
    public var followsBattery: Bool
    /// The Morse message being sent, if any.
    public var morse: MorseMessage?
    /// Whether Morse code repeats until it's stopped (the loop switch).
    public var morseLoops: Bool
    /// The only text in the panel: why everything is disabled, on a Mac without the logo.
    public var message: String?
    /// The menu bar icon (an SF Symbols name), and what it means.
    public var symbolName: String
    public var symbolDescription: String

    /// `requested` is the setting asked for while a switch is under way, which the panel and the icon show
    /// straight away, so the rest of the panel follows the switch at once instead of when the fade ends.
    public init(status: LogoStatus, requested: LogoIllumination? = nil, canControlDirectly: Bool,
                canFollowSound: Bool = true, effect: LogoEffect, brightness: Double, followsBattery: Bool = false,
                isBusy: Bool = false, morse: MorseMessage? = nil, morseLoops: Bool = false) {
        let setting = requested ?? status.setting
        isSupported = status.isSupported
        isOn = status.isSupported && setting != .off
        self.isBusy = isBusy
        showsAdjustments = status.isSupported && canControlDirectly
        showsSound = showsAdjustments && canFollowSound
        self.effect = effect
        self.brightness = brightness
        self.followsBattery = followsBattery
        self.morse = canControlDirectly ? morse : nil
        self.morseLoops = morseLoops
        message = status.isSupported ? nil : "Needs a MacBook Pro with PROLED XDR Display"
        (symbolName, symbolDescription) = switch (status.isSupported, setting) {
        case (false, _): ("lightbulb.slash", "No illuminated logo on this Mac")
        case (true, .off): ("lightbulb.slash", "Logo illumination off")
        case (true, .on): ("lightbulb.fill", "Logo illumination on")
        case (true, nil): ("lightbulb", "Logo illumination unknown")
        }
    }

    /// Whether the logo switch takes clicks. It looks disabled otherwise.
    public var canSwitch: Bool { isSupported && !isBusy }

    /// Whether the brightness and the effects can be changed: only while the logo is (or is being
    /// turned) on. Otherwise they're greyed out, and keep their values for when it's back on.
    public var canAdjust: Bool { showsAdjustments && isOn }

    /// Whether the brightness slider can be moved: as for the rest, and not while the battery sets the
    /// brightness. It's greyed out then, showing the charge.
    public var canChangeBrightness: Bool { canAdjust && !followsBattery }

    /// Whether a Morse message is being sent, so the play button shows stop.
    public var isSendingMorse: Bool { morse != nil }
}
