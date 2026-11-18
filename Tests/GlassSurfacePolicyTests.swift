import Foundation

@main
struct GlassSurfacePolicyTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) {
        checks += 1
        if !value { fatalError(message) }
    }
    static func main() {
        check(GlassSurfacePolicy.resolve(reduceTransparency: true, force: "native", nativeAvailable: true) == .opaque,
              "Reduce Transparency beats a native request")
        check(GlassSurfacePolicy.resolve(reduceTransparency: true, force: "fallback", nativeAvailable: false) == .opaque,
              "Reduce Transparency beats fallback")
        check(GlassSurfacePolicy.resolve(reduceTransparency: false, force: "native", nativeAvailable: true) == .native,
              "native is used only when available")
        check(GlassSurfacePolicy.resolve(reduceTransparency: false, force: "native", nativeAvailable: false) == .fallback,
              "forcing native on an old OS fails safe")
        check(GlassSurfacePolicy.resolve(reduceTransparency: false, force: "off", nativeAvailable: true) == .opaque,
              "off gives the opaque product surface")
        check(GlassSurfacePolicy.resolve(reduceTransparency: false, force: nil, nativeAvailable: false) == .fallback,
              "old systems get the visual-effect fallback")
        check(GlassSurfacePolicy.resolve(reduceTransparency: false, force: nil, nativeAvailable: true) == .native,
              "supported systems get native glass by default")
        check(GlassSurfacePolicy.resolve(reduceTransparency: false, force: "fallback", nativeAvailable: true) == .fallback,
              "fallback can be forced for visual QA")
        print("PASS: \(checks) glass policy precedence checks")
    }
}
