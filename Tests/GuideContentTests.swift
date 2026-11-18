import Foundation

@main
struct GuideContentTests {
    static func main() {
        func beats(_ beats: [GuideBeat]) {
            precondition(beats.count == 3)
            for beat in beats {
                precondition(!beat.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                precondition(!beat.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        let pages = OnboardingCatalog.pages
        precondition(pages.count == 5 && Set(pages.map(\.id)).count == 5)
        precondition(pages.map(\.scene) == [.welcome, .awakeModes, .components, .permissions, .ready])
        precondition(pages.first?.title == "Meet Wakely")
        for page in pages {
            precondition(!page.title.isEmpty && !page.body.isEmpty)
            precondition(!page.body.contains("{value}"))
            beats(page.beats)
        }
        precondition(pages[1].body.contains("lid-open only"))
        precondition(pages[4].body.contains("Nothing is armed"))
        print("PASS: five onboarding pages with complete three-beat content")
    }
}
