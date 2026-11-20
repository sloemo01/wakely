import Foundation

@main
struct UpdateVersionTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { fatalError(message) }
    }

    static func main() {
        check(UpdateVersion.normalizedTag("v2.0.7") == "2.0.7", "v prefix stripped")
        check(UpdateVersion.normalizedTag("V2.0.7") == "2.0.7", "capital V stripped")
        check(UpdateVersion.normalizedTag("2.0.7") == "2.0.7", "plain version kept")

        check(UpdateVersion.isNewer("2.0.7", than: "2.0.6"), "patch bump is newer")
        check(UpdateVersion.isNewer("v2.1.0", than: "2.0.9"), "minor bump beats higher patch")
        check(UpdateVersion.isNewer("3.0.0", than: "2.9.9"), "major bump is newer")
        check(!UpdateVersion.isNewer("2.0.6", than: "2.0.7"), "older release is not newer")
        check(!UpdateVersion.isNewer("2.0.7", than: "2.0.7"), "same version is not newer")
        check(!UpdateVersion.isNewer("2.0", than: "2.0.0"), "missing components equal zero")
        check(UpdateVersion.isNewer("2.0.1", than: "2.0"), "trailing zero still older")

        check(UpdateVersion.parse("2.0.7-beta") == [2, 0, 7], "build suffix tolerated")
        check(UpdateVersion.parse("not-a-version") == nil, "garbage rejected")
        check(UpdateVersion.parse("") == nil, "empty rejected")

        check(UpdateVersion.compare("2.0.10", "2.0.9") == .orderedDescending, "numeric not lexicographic")
        check(UpdateVersion.compare("2.0.6", "v2.0.7") == .orderedAscending, "tag prefix ignored")

        check(UpdateVersion.version(fromDownloadName: "Wakely-2.0.6-r9.dmg") == "2.0.6", "release filename parsed")
        check(UpdateVersion.version(fromDownloadName: "Wakely-2.0.7.dmg") == "2.0.7", "unrevisioned filename parsed")
        check(UpdateVersion.version(fromDownloadName: "other-2.0.6.dmg") == nil, "foreign name rejected")
        check(UpdateVersion.version(fromDownloadName: "Wakely-2.0.6-r9.zip") == nil, "non-dmg rejected")
        check(UpdateVersion.version(fromDownloadName: "Wakely-latest.dmg") == nil, "non-version rejected")

        print("update-version: \(checks) checks passed")
    }
}
