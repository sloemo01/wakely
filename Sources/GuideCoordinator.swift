import AppKit
import Combine
import Carbon

/// The guide owns navigation and tutorial preferences only. It never starts a
/// component, requests permission, invokes the helper, or changes power state.
@MainActor
final class GuideCoordinator: ObservableObject {
    enum Route: Equatable {
        case onboarding
    }
    static let shared = GuideCoordinator()
    static let progressKey = "gettingStarted.progress.v1"

    @Published private(set) var route: Route?
    @Published private(set) var progress: OnboardingProgress
    @Published private(set) var generation = 0
    @Published private(set) var previewBeat: Int?
    @Published private(set) var previewReduceMotion = false
    @Published private(set) var returnFocusID: String?
    @Published private(set) var returnFocusSerial = 0
    /// Presentation callbacks are installed by the UI host, never by the policy model.
    var onTourStepChange: ((HighlightTourStep) -> Void)?
    var onTourEnd: (() -> Void)?
    @Published var demoMinutes = 60
    @Published var creationPreviewOpened = false
    /// The real menu, not a synthetic tutorial row, is authoritative here.
    @Published private(set) var menuKeepAwakeAvailable: Bool?
    var availableTourSteps: [HighlightTourStep] {
        HighlightTourStep.allCases.filter {
            menuKeepAwakeAvailable != false || ($0 != .menuKeepAwake && $0 != .menuDurations)
        }
    }
    var displayedStepCount: Int { availableTourSteps.count }
    var displayedStep: Int {
        (availableTourSteps.firstIndex(of: currentTourStep) ?? max(0, availableTourSteps.count - 1)) + 1
    }

    func updateMenuKeepAwakeAvailability(_ available: Bool) {
        if menuKeepAwakeAvailable != available { menuKeepAwakeAvailable = available }
        // Availability can change while a step is visible. Advance past it;
        // don't replace it with a tutorial about an unavailable component.
        if isPresented, !availableTourSteps.contains(currentTourStep) { go(to: progress.step) }
    }

    private func normalizedStep(_ requested: Int) -> Int {
        let start = min(OnboardingProgress.lastStep, max(0, requested))
        return (start...OnboardingProgress.lastStep).first {
            availableTourSteps.contains(HighlightTourStep.allCases[$0])
        } ?? OnboardingProgress.lastStep
    }
    var currentTourStep: HighlightTourStep {
        HighlightTourStep.allCases[min(OnboardingProgress.lastStep, max(0, progress.step))]
    }
    var isMenuTour: Bool { isPresented && currentTourStep.isMenu }
    var isPreviewing: Bool { preview }

    private let defaults: UserDefaults
    private let persistenceEnabled: Bool
    private var preview = false
    private var autoPresented = false
    private var freshInstallation = false
    private let hadRecord: Bool

    init(defaults: UserDefaults = .standard, persistenceEnabled: Bool = true) {
        self.defaults = defaults
        self.persistenceEnabled = persistenceEnabled
        let data = defaults.data(forKey: Self.progressKey)
        hadRecord = data != nil || defaults.object(forKey: Self.progressKey) != nil
        if let data, let saved = try? JSONDecoder().decode(OnboardingProgress.self, from: data) {
            progress = saved
        } else {
            // A corrupt or wrongly typed record is not a fresh install.
            progress = OnboardingProgress(disposition: hadRecord ? .dismissed : .unseen)
        }
        freshInstallation = !hadRecord
    }

    var isPresented: Bool { route != nil }
    var canResume: Bool { progress.disposition == .dismissed }
    var gettingStartedActionTitle: String {
        canResume ? "Resume" : (progress.disposition == .completed ? "Replay" : "Start tour")
    }

    func classifyExistingInstallation(_ existing: Bool) {
        guard !hadRecord, progress.disposition == .unseen else { return }
        freshInstallation = !existing
        if !existing { return }
        progress.disposition = .existingUser
        save()
    }

    @discardableResult
    func presentAutomatically(isNewUser: Bool, isLoginLaunch: Bool, receivedCommand: Bool) -> Bool {
        guard route == nil,
              OnboardingLaunchPolicy.shouldAutoPresent(isNewUser: isNewUser,
                  isLoginLaunch: isLoginLaunch, receivedCommand: receivedCommand,
                  hasPresented: autoPresented, progress: progress) else { return false }
        autoPresented = true
        showOnboarding(restart: false)
        return true
    }

    func showOnboarding(restart: Bool) {
        preview = false
        autoPresented = true
        previewBeat = nil
        previewReduceMotion = false
        if restart || progress.version != OnboardingProgress.currentVersion {
            progress = OnboardingProgress()
        }
        demoMinutes = 60
        creationPreviewOpened = false
        progress.version = OnboardingProgress.currentVersion
        progress.go(to: normalizedStep(progress.step))
        // Record presentation immediately: a quit/crash is not permission to
        // take over the user's next launch. Only the final action completes it.
        if progress.disposition != .completed { progress.dismiss() }
        save()
        generation += 1
        route = .onboarding
        onTourStepChange?(currentTourStep)
    }

    func go(to step: Int) {
        creationPreviewOpened = false
        progress.go(to: normalizedStep(step)); save()
        if isPresented { onTourStepChange?(currentTourStep) }
    }
    func next() { go(to: min(OnboardingProgress.lastStep, progress.step + 1)) }
    func previous() {
        let previousIndex = HighlightTourStep.allCases.indices.last {
            $0 < progress.step && availableTourSteps.contains(HighlightTourStep.allCases[$0])
        } ?? 0
        go(to: previousIndex)
    }

    func completeOnboarding() {
        progress.complete()
        save()
        route = nil
        creationPreviewOpened = false
        onTourEnd?()
    }

    func dismiss() {
        let wasOnboarding = route == .onboarding
        if wasOnboarding, progress.disposition != .completed {
            progress.dismiss()
            save()
        }
        route = nil
        if wasOnboarding {
            returnFocusID = "gettingStarted"
            returnFocusSerial += 1
            creationPreviewOpened = false
            onTourEnd?()
        }
    }

    /// A background first launch cannot discover a window on the user's behalf.
    /// The first explicit click on the menu-bar mark gets the same introduction.
    func presentOnFirstMenuInteraction() -> Bool {
        guard freshInstallation, !autoPresented, route == nil,
              progress.disposition == .unseen,
              progress.version == OnboardingProgress.currentVersion else { return false }
        autoPresented = true
        showOnboarding(restart: false)
        return true
    }

    /// Window-level Back/Escape is consumed before the ordinary Settings route.
    func back() {
        if route == .onboarding && progress.step > 0 { previous() }
        else { dismiss() }
    }

    /// Isolated screenshot seam: no preferences, app actions or permissions.
    func previewOnboarding(step: Int) {
        preview = true
        progress = OnboardingProgress(step: normalizedStep(step), disposition: .dismissed)
        demoMinutes = 60
        creationPreviewOpened = false
        generation += 1
        route = .onboarding
        onTourStepChange?(currentTourStep)
    }

    func configurePreview(beat: Int?, reduceMotion: Bool) {
        previewBeat = beat.map { min(2, max(0, $0)) }
        previewReduceMotion = reduceMotion
    }

    private func save() {
        guard persistenceEnabled, !preview, let data = try? JSONEncoder().encode(progress) else { return }
        defaults.set(data, forKey: Self.progressKey)
    }
}

/// Native launch evidence, captured before delayed presentation. Unknown and
/// background launches fail closed; General always offers a manual tour.
struct GuideLaunchContext {
    let foregroundOpen: Bool
    let loginOrBackground: Bool

    @MainActor static func current() -> GuideLaunchContext {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let login = event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
        let arguments = ProcessInfo.processInfo.arguments
        let background = arguments.contains("--background") || arguments.contains("--login")
        let nativeOpen = event?.eventID == AEEventID(kAEOpenApplication)
        return .init(foregroundOpen: nativeOpen && !login && !background,
                     loginOrBackground: login || background)
    }

    /// Capture before launch writes a diagnostics line or starts an engine.
    @MainActor static func hasExistingInstallation(defaults: UserDefaults = .standard,
                                        bundleID: String = Bundle.main.bundleIdentifier ?? "dev.wakely.app",
                                        diagnosticsExisted: Bool) -> Bool {
        if diagnosticsExisted { return true }
        let domain = defaults.persistentDomain(forName: bundleID) ?? [:]
        return domain.keys.contains { key in
            key != GuideCoordinator.progressKey && !key.hasPrefix("NS") && !key.hasPrefix("Apple")
        }
    }
}
