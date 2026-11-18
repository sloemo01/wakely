import Foundation

@main
struct GuideCoordinatorTests {
    @MainActor static func main() throws {
        let suite = "GuideCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = GuideCoordinator.progressKey
        precondition(key == "gettingStarted.progress.v1")
        let last = OnboardingProgress.lastStep
        let current = OnboardingProgress.currentVersion
        func clear() { defaults.removePersistentDomain(forName: suite) }
        func auto(_ c: GuideCoordinator) -> Bool {
            c.presentAutomatically(isNewUser: true, isLoginLaunch: false, receivedCommand: false)
        }
        func store(_ progress: OnboardingProgress) throws {
            defaults.set(try JSONEncoder().encode(progress), forKey: key)
        }
        let ephemeral = GuideCoordinator(defaults: defaults, persistenceEnabled: false)
        precondition(auto(ephemeral) && ephemeral.route == .onboarding)
        ephemeral.next(); ephemeral.dismiss()
        ephemeral.showOnboarding(restart: true)
        ephemeral.go(to: last); ephemeral.completeOnboarding()
        ephemeral.classifyExistingInstallation(true)
        precondition(defaults.object(forKey: key) == nil)
        precondition(!auto(ephemeral))
        ephemeral.showOnboarding(restart: true); ephemeral.dismiss()
        precondition(ephemeral.canResume)
        clear()
        let fresh = GuideCoordinator(defaults: defaults, persistenceEnabled: true)
        precondition(!fresh.presentAutomatically(isNewUser: true, isLoginLaunch: true, receivedCommand: false))
        precondition(!fresh.presentAutomatically(isNewUser: true, isLoginLaunch: false, receivedCommand: true))
        precondition(auto(fresh))
        precondition(defaults.data(forKey: key) != nil)
        for (index, step) in HighlightTourStep.allCases.enumerated() {
            fresh.go(to: index)
            precondition(fresh.currentTourStep == step)
            precondition(fresh.isMenuTour == step.isMenu)
            precondition(fresh.isPresented && fresh.route == .onboarding)
        }
        fresh.go(to: Int.min)
        precondition(fresh.currentTourStep == .welcome && !fresh.isMenuTour)
        fresh.go(to: Int.max)
        precondition(fresh.currentTourStep == .finish && !fresh.isMenuTour)
        fresh.go(to: 3); fresh.dismiss()
        precondition(fresh.returnFocusID == "gettingStarted" && fresh.returnFocusSerial == 1)
        let resumed = GuideCoordinator(defaults: defaults)
        precondition(resumed.canResume && resumed.progress.step == 3 && resumed.gettingStartedActionTitle == "Resume")
        precondition(!auto(resumed))
        resumed.showOnboarding(restart: false)
        precondition(resumed.progress.step == 3)
        resumed.back(); precondition(resumed.progress.step == 2)
        resumed.go(to: 0); resumed.back(); precondition(!resumed.isPresented)
        resumed.showOnboarding(restart: true); resumed.next(); resumed.previous()
        precondition(resumed.progress.step == 0)
        // Skip is dismissal, not completion, even at the final highlighted target.
        resumed.go(to: last); resumed.dismiss()
        let skipped = GuideCoordinator(defaults: defaults)
        precondition(skipped.canResume && skipped.progress.step == last && !auto(skipped))
        skipped.showOnboarding(restart: false)
        precondition(skipped.progress.step == last)
        skipped.dismiss()
        resumed.showOnboarding(restart: true)
        precondition(resumed.progress.step == 0)
        resumed.completeOnboarding()
        precondition(resumed.progress.step == last)
        precondition(!resumed.isPresented && resumed.progress.disposition == .completed)
        precondition(resumed.gettingStartedActionTitle == "Replay")
        precondition(GuideCoordinator(defaults: defaults).progress.disposition == .completed)
        clear()
        for malformed: Any in [Data("not json".utf8), "wrong storage type", Data("{}".utf8)] {
            defaults.set(malformed, forKey: key)
            let c = GuideCoordinator(defaults: defaults)
            precondition(c.progress.disposition == .dismissed && !auto(c))
        }
        clear()
        let existing = GuideCoordinator(defaults: defaults)
        existing.classifyExistingInstallation(true)
        precondition(existing.progress.disposition == .existingUser && !auto(existing))
        precondition(!existing.presentOnFirstMenuInteraction())
        precondition(GuideCoordinator(defaults: defaults).progress.disposition == .existingUser)
        clear()
        let backgroundFresh = GuideCoordinator(defaults: defaults)
        backgroundFresh.classifyExistingInstallation(false)
        precondition(backgroundFresh.presentOnFirstMenuInteraction())
        precondition(backgroundFresh.route == .onboarding && !auto(backgroundFresh))
        backgroundFresh.dismiss()
        precondition(!backgroundFresh.presentOnFirstMenuInteraction())
        for version in [0, 1, current + 1, Int.max] {
            for disposition in [OnboardingDisposition.unseen, .dismissed, .completed, .existingUser] {
                try store(OnboardingProgress(step: last, disposition: disposition, version: version))
                let stored = defaults.data(forKey: key)
                let c = GuideCoordinator(defaults: defaults)
                precondition(!auto(c) && !c.presentOnFirstMenuInteraction())
                c.classifyExistingInstallation(false)
                precondition(defaults.data(forKey: key) == stored)
                c.showOnboarding(restart: false)
                precondition(c.isPresented && c.progress.version == current && c.progress.step == 0)
                c.go(to: last); c.dismiss()
                c.showOnboarding(restart: true)
                precondition(c.progress.step == 0)
            }
        }
        clear()
        // Availability filters the itinerary, not the stable persisted indices.
        let filtered = GuideCoordinator(defaults: defaults, persistenceEnabled: false)
        precondition(filtered.menuKeepAwakeAvailable == nil)
        precondition(filtered.availableTourSteps == HighlightTourStep.allCases && filtered.displayedStepCount == 14)
        filtered.updateMenuKeepAwakeAvailability(false)
        precondition(filtered.availableTourSteps.count == 12 && filtered.displayedStepCount == 12)
        precondition(!filtered.availableTourSteps.contains(.menuKeepAwake))
        precondition(!filtered.availableTourSteps.contains(.menuDurations))
        filtered.showOnboarding(restart: true)
        precondition(filtered.displayedStep == 1)
        var forwardIndices: [Int] = [filtered.progress.step]
        for _ in 1..<filtered.displayedStepCount {
            filtered.next()
            forwardIndices.append(filtered.progress.step)
            precondition(filtered.displayedStep == forwardIndices.count)
        }
        precondition(forwardIndices == Array(0...9) + [12, 13])
        var backwardIndices: [Int] = [filtered.progress.step]
        for _ in 1..<filtered.displayedStepCount {
            filtered.previous()
            backwardIndices.append(filtered.progress.step)
        }
        precondition(backwardIndices == Array(forwardIndices.reversed()))
        filtered.go(to: 9)
        filtered.next()
        precondition(filtered.progress.step == 12 && filtered.currentTourStep == .menuNavigation && filtered.displayedStep == 11)
        filtered.previous()
        precondition(filtered.progress.step == 9 && filtered.displayedStep == 10)
        for excluded in [10, 11] {
            filtered.go(to: excluded)
            precondition(filtered.progress.step == 12 && filtered.displayedStep == 11)
            filtered.previewOnboarding(step: excluded)
            precondition(filtered.currentTourStep == .menuNavigation)
        }
        filtered.updateMenuKeepAwakeAvailability(true)
        precondition(filtered.progress.step == 12 && filtered.displayedStep == 13 && filtered.displayedStepCount == 14)
        filtered.previous()
        precondition(filtered.currentTourStep == .menuDurations && filtered.progress.step == 11)
        filtered.updateMenuKeepAwakeAvailability(true)
        precondition(filtered.progress.step == 11)
        for excluded in [10, 11] {
            filtered.go(to: excluded)
            var normalizedSteps: [HighlightTourStep] = []
            filtered.onTourStepChange = { normalizedSteps.append($0) }
            filtered.updateMenuKeepAwakeAvailability(false)
            precondition(filtered.currentTourStep == .menuNavigation && filtered.progress.step == 12)
            precondition(normalizedSteps == [.menuNavigation])
            filtered.updateMenuKeepAwakeAvailability(false)
            precondition(filtered.progress.step == 12)
            filtered.updateMenuKeepAwakeAvailability(true)
            precondition(filtered.progress.step == 12)
        }
        try store(OnboardingProgress(step: 11, disposition: .dismissed))
        let disabledResume = GuideCoordinator(defaults: defaults)
        disabledResume.updateMenuKeepAwakeAvailability(false)
        disabledResume.showOnboarding(restart: false)
        precondition(disabledResume.progress.step == 12 && disabledResume.displayedStep == 11)
        precondition(GuideCoordinator(defaults: defaults).progress.step == 12)
        disabledResume.previous()
        precondition(disabledResume.progress.step == 9)
        disabledResume.next()
        precondition(disabledResume.progress.step == 12)
        disabledResume.next()
        precondition(disabledResume.progress.step == 13 && disabledResume.displayedStep == 12)
        disabledResume.previous()
        precondition(disabledResume.progress.step == 12)
        clear()
        // Callbacks report navigation; no Settings or engine implementation is linked.
        let callbacks = GuideCoordinator(defaults: defaults, persistenceEnabled: false)
        var steps: [HighlightTourStep] = []
        var ends = 0
        callbacks.onTourStepChange = { steps.append($0) }
        callbacks.onTourEnd = { ends += 1 }
        precondition(steps.isEmpty && ends == 0)
        callbacks.showOnboarding(restart: true)
        precondition(steps.last == .welcome)
        callbacks.next(); precondition(steps.last == .componentCard)
        callbacks.previous(); precondition(steps.last == .welcome)
        callbacks.go(to: 8); precondition(steps.last == .menuOverview)
        callbacks.dismiss(); precondition(ends == 1 && !callbacks.isPresented)
        callbacks.showOnboarding(restart: false)
        precondition(steps.last == .menuOverview)
        callbacks.completeOnboarding(); precondition(ends == 2 && !callbacks.isPresented)
        callbacks.previewOnboarding(step: 12)
        precondition(steps.last == .menuNavigation)
        callbacks.dismiss(); precondition(ends == 3)
        precondition(defaults.object(forKey: key) == nil)
        defaults.set("untouched", forKey: "sentinel")
        let preview = GuideCoordinator(defaults: defaults)
        let before = defaults.persistentDomain(forName: suite)! as NSDictionary
        preview.previewOnboarding(step: 99)
        precondition(preview.progress.step == last)
        preview.configurePreview(beat: 99, reduceMotion: true)
        precondition(preview.previewBeat == 2 && preview.previewReduceMotion)
        preview.previous(); preview.next(); preview.dismiss()
        preview.previewOnboarding(step: -1); preview.completeOnboarding()
        preview.previewOnboarding(step: 2); preview.go(to: last); preview.dismiss()
        precondition(preview.progress.disposition == .dismissed)
        precondition(before.isEqual(to: defaults.persistentDomain(forName: suite)!))
        print("PASS: isolated persistence on/off, malformed records, existing users, resume/version policy, preview no writes and return focus")
        print("Scope: navigation/preferences only; no engine or system-effect implementation is linked")
    }
}
