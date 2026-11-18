import AppKit
import SwiftUI

@MainActor
final class GlassPolicy: ObservableObject {
    typealias Style = GlassSurfacePolicy.Style
    static let shared = GlassPolicy()
    @Published private(set) var style: Style
    @Published private(set) var increaseContrast: Bool
    private var observer: NSObjectProtocol?

    private init() {
        style = Self.resolve(force: ProcessInfo.processInfo.environment["WAKELY_GLASS"])
        increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let next = Self.resolve(force: ProcessInfo.processInfo.environment["WAKELY_GLASS"])
                    if self.style != next { self.style = next }
                    let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                    if self.increaseContrast != contrast { self.increaseContrast = contrast }
                }
            }
    }
    var usesMaterial: Bool { style != .opaque }
    static func resolve(force: String?) -> Style {
        let nativeAvailable: Bool
        if #available(macOS 26.0, *) { nativeAvailable = true } else { nativeAvailable = false }
        return GlassSurfacePolicy.resolve(
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            force: force, nativeAvailable: nativeAvailable)
    }
}

/// A real system material owns the content, not an opaque sibling hierarchy.
/// Allocate its compositor surface once for the reserved canvas. Animating the
/// Goo mask alone avoids rebuilding NSGlassEffectView at every spring sample;
/// content layout and native material allocation stay stable during the morph.
@MainActor
final class GlassBackdropView: NSView {
    let contentHost = NSView()
    private let maskLayer = CAShapeLayer()
    private var materialView: NSView?
    private var materialContainer: NSView?
    private var appliedStyle: GlassPolicy.Style?
    private var materialRect = CGRect.zero

    var usesMaterial: Bool { GlassPolicy.shared.usesMaterial }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        maskLayer.fillRule = .nonZero
        maskLayer.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.mask = maskLayer
        contentHost.wantsLayer = true
        applyStyle()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged),
            name: .wakelyAppearanceDidChange, object: nil)
    }
    required init?(coder: NSCoder) { nil }
    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    func setShape(_ path: CGPath) {
        maskLayer.frame = bounds
        maskLayer.path = path
        if materialRect != bounds {
            materialRect = bounds
            layoutMaterial()
        }
    }
    override func layout() { super.layout(); layoutMaterial() }

    private func layoutMaterial() {
        if let materialView {
            if materialView.frame != materialRect { materialView.frame = materialRect }
            if materialContainer?.frame != materialView.bounds { materialContainer?.frame = materialView.bounds }
            let retainedFrame = CGRect(origin: CGPoint(x: -materialRect.minX, y: -materialRect.minY),
                                       size: bounds.size)
            if contentHost.frame != retainedFrame { contentHost.frame = retainedFrame }
        } else if contentHost.frame != bounds {
            contentHost.frame = bounds
        }
    }

    private func applyStyle() {
        let style = GlassPolicy.shared.style
        guard appliedStyle != style else { updatePalette(); return }
        contentHost.removeFromSuperview()
        materialView?.removeFromSuperview()
        materialView = nil
        materialContainer = nil
        appliedStyle = style
        switch style {
        case .opaque:
            addSubview(contentHost)
        case .native:
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView(frame: materialRect)
                glass.cornerRadius = 12
                let container = NSView(frame: glass.bounds)
                container.autoresizingMask = [.width, .height]
                glass.contentView = container
                container.addSubview(contentHost)
                materialContainer = container
                materialView = glass
                addSubview(glass)
            } else { installFallback() }
        case .fallback:
            installFallback()
        }
        updatePalette()
        layoutMaterial()
    }

    private func installFallback() {
        let effect = NSVisualEffectView(frame: materialRect)
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.addSubview(contentHost)
        materialView = effect
        addSubview(effect)
    }

    private func updatePalette() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = appliedStyle == .opaque ? Theme.windowColor.cgColor : NSColor.clear.cgColor
            if #available(macOS 26.0, *), let glass = materialView as? NSGlassEffectView {
                let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                glass.tintColor = Theme.windowColor.withAlphaComponent(dark ? 0.06 : 0.16)
            }
        }
        // A rectangular layer border would trace the reserved canvas instead
        // of Goo's silhouette. Native glass supplies its own optical highlight.
        layer?.borderWidth = 0
        materialView?.needsDisplay = true
    }

    @objc private func appearanceChanged() { updatePalette() }
    @objc private func accessibilityOptionsChanged() { applyStyle() }
}
