// ComponentCatalog — every component the shipped app has, by name, category and copy.
// Names, taglines and descriptions come from the app's own localized strings and
// from its UI; ids match the folder naming convention of the component SDK.

import Foundation

enum ComponentCategory: String, CaseIterable {
    case agents = "AGENTS"
    case keyboard = "KEYBOARD"
    case security = "SECURITY"
    case power = "POWER"
    case connections = "CONNECTIONS"
}

struct ComponentDefinition: Identifiable, Hashable {
    let id: String
    let name: String
    let tagline: String
    let detail: String
    let category: ComponentCategory
    let icon: String
    /// Some components drive privileged settings (SMC, pmset, NVRAM). The shipped
    /// app gates those behind one optional helper; this build reports the same
    /// state honestly and leaves the rest working without it.
    let needsHelper: Bool

    static func == (lhs: ComponentDefinition, rhs: ComponentDefinition) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum ComponentCatalog {
    static let all: [ComponentDefinition] = [
        // MARK: Agents
        ComponentDefinition(id: "agentScreen", name: "Agent Screen",
            tagline: "Agents can use the screen with the lid closed.",
            detail: "Keeps the built-in display awake while an agent is working, so computer-use agents and screenshots still have a screen with the lid shut. Turns the display off {value} after they stop.",
            category: .agents, icon: "agentScreen", needsHelper: false),
        ComponentDefinition(id: "agentStatus", name: "Agent Status",
            tagline: "See what your agents are doing from the menu bar.",
            detail: "A menu bar row shows how many Claude Code and Codex agents are working or waiting on you. Open it to see each one by name, and click one to bring its app forward. Nothing in your agents is set up or changed.",
            category: .agents, icon: "agentStatus", needsHelper: false),
        ComponentDefinition(id: "finishWorkThenSleep", name: "Finish Work, Then Sleep",
            tagline: "Let your agents finish, then let your Mac sleep.",
            detail: "Keeps the Mac awake with the lid closed while any agent works. When the last one finishes, Wakely waits {value} and then disarms, so the Mac sleeps normally, but never stays awake longer than {hours} at a stretch.",
            category: .agents, icon: "finishWorkThenSleep", needsHelper: false),
        ComponentDefinition(id: "agentNotifications", name: "Agent Notifications",
            tagline: "Know when an agent needs you or is done.",
            detail: "A notification {sound} when one of your agents stops for your approval or a question, or finishes longer work. Nothing pops up while that app is already in front.",
            category: .agents, icon: "agentNotifications", needsHelper: false),
        ComponentDefinition(id: "agentLight", name: "Agent Light",
            tagline: "Your agents' state on a light you can see across the room.",
            detail: "With the lid open or closed, the Wakely mark in the menu bar lights up while agents work and keeps showing done for {value} after they finish, so one glance tells you the room.",
            category: .agents, icon: "agentLight", needsHelper: false),
        ComponentDefinition(id: "sleepUntilReset", name: "Sleep Until Reset",
            tagline: "Sleep through a usage limit and wake when it resets.",
            detail: "A little after each of your accounts resets, your Mac wakes and stays awake while any agent works. If nothing works for {value}, or an agent sits waiting on you for 15 minutes, it sleeps until the next reset.",
            category: .agents, icon: "sleepUntilReset", needsHelper: true),

        // MARK: Keyboard
        ComponentDefinition(id: "capsLock", name: "Caps Lock",
            tagline: "The Caps Lock light shows your Mac is staying awake.",
            detail: "Turn Caps Lock on and Wakely arms itself; turn it off and Wakely disarms. The light on the key is the indicator, so you can see across the room that the Mac will stay awake.",
            category: .keyboard, icon: "capsLock", needsHelper: false),
        ComponentDefinition(id: "cleaningLock", name: "Cleaning Lock",
            tagline: "Lock the keyboard for a minute while you wipe it.",
            detail: "Lock for Cleaning covers every screen for {value} with a countdown and blocks keyboard and pointer input. Hold Escape for three seconds to exit, and the cover ends early if Wakely arms.",
            category: .keyboard, icon: "cleaningLock", needsHelper: false),
        ComponentDefinition(id: "lidCloseSound", name: "Lid-Close Sound",
            tagline: "A soft sound confirms your Mac is staying awake.",
            detail: "Plays one of the eight soft sounds when you close the lid with Wakely armed, so you know the session started without opening the screen.",
            category: .keyboard, icon: "lidCloseSound", needsHelper: false),
        ComponentDefinition(id: "quietClose", name: "Quiet Close",
            tagline: "Closing the lid mutes your Mac.",
            detail: "Closing the lid mutes your Mac; opening it brings the sound back, at the level it was. Nothing plays while the lid is shut.",
            category: .keyboard, icon: "quietClose", needsHelper: false),

        // MARK: Security
        ComponentDefinition(id: "passwordAfterClose", name: "Password After Close",
            tagline: "Close the lid and the next unlock needs your password.",
            detail: "Closing the lid {display} locks the screen {timing} and turns Touch ID for unlocking off. The next unlock needs your password or your Apple Watch; Touch ID comes back right after it, or when Wakely quits.",
            category: .security, icon: "passwordAfterClose", needsHelper: true),
        ComponentDefinition(id: "bagCheck", name: "Bag Check",
            tagline: "Warns you if your Mac didn't sleep in your bag.",
            detail: "If your Mac stays awake with the lid closed while Wakely is off, it shows up here: a notification after a minute in the bag, before the battery has to pay for it.",
            category: .security, icon: "bagCheck", needsHelper: false),

        // MARK: Power
        ComponentDefinition(id: "alwaysOnPluggedIn", name: "Always On While Plugged In",
            tagline: "Stays armed whenever your Mac is plugged in.",
            detail: "While your Mac is plugged in, Wakely arms by itself, so you can close the lid. Keep the screen {screen} while it is plugged in. Unplugging releases this component's hold; any separate manual or component hold is preserved.",
            category: .power, icon: "alwaysOnPluggedIn", needsHelper: false),
        ComponentDefinition(id: "homeServer", name: "Home Server",
            tagline: "Always armed, lid closed, for a Mac that serves.",
            detail: "Always armed while on the charger with the lid closed, for a Mac that serves. A login item brings Wakely back after a restart or login and re-arms it, at most five times an hour; automatic rearm never wakes a sleeping Mac.",
            category: .power, icon: "homeServer", needsHelper: false),
        ComponentDefinition(id: "lowPowerWhileClosed", name: "Low Power While Closed",
            tagline: "Run longer on battery with the lid closed.",
            detail: "Switches the Mac to low power mode for the closed session and back afterwards, so a closed Mac on battery runs longer.",
            category: .power, icon: "lowPowerWhileClosed", needsHelper: true),
        ComponentDefinition(id: "batteryBudget", name: "Battery Budget",
            tagline: "Uses up to a set share of battery, then sleeps.",
            detail: "A closed session uses only {value} of battery, then sleeps, so a long night off the charger cannot drain the Mac.",
            category: .power, icon: "batteryBudget", needsHelper: false),
        ComponentDefinition(id: "keepAwake", name: "Keep Awake",
            tagline: "Your Mac stays awake with the lid open.",
            detail: "Use the menu bar to keep your Mac awake with the lid open indefinitely, or for 1, 2 or 4 hours. Keep the screen {screen} while it is awake. Closing the lid ends Keep Awake without arming a closed session. A separate Arm Wakely request is preserved.",
            category: .power, icon: "keepAwake", needsHelper: false),
        ComponentDefinition(id: "sleepMeansSleep", name: "Sleep Means Sleep",
            tagline: "No surprise wakes while asleep on battery.",
            detail: "While enabled, the helper switches off battery Power Nap, proximity wake and Wake-on-LAN so a closed Mac in a bag is less likely to wake itself. Turning it off restores the saved values. Other apps' scheduled wake events are left alone.",
            category: .power, icon: "sleepMeansSleep", needsHelper: true),
        ComponentDefinition(id: "stayOffWhenOpened", name: "Stay Off When Opened",
            tagline: "A shut-down Mac stays off when you open the lid.",
            detail: "A shut-down Mac stays off when you open the lid or plug it in. It does not come back on until you press the power button.",
            category: .power, icon: "stayOffWhenOpened", needsHelper: true),
        ComponentDefinition(id: "finishJobsThenSleep", name: "Finish Jobs, Then Sleep",
            tagline: "Downloads and backups finish, then your Mac sleeps.",
            detail: "Keeps the Mac awake with the lid closed while a download, export or backup runs, then lets it sleep once the network has been quiet for {value}, and gives up after {hours} at most.",
            category: .power, icon: "finishJobsThenSleep", needsHelper: false),
        ComponentDefinition(id: "sleepWhenIdle", name: "Sleep When Idle",
            tagline: "A closed Mac sleeps once nothing is working.",
            detail: "A closed Mac sleeps once nothing has been working for {value}: no agents, no downloads, no connected sessions. If any of those start again, Wakely arms again.",
            category: .power, icon: "sleepWhenIdle", needsHelper: false),
        ComponentDefinition(id: "sleepTimer", name: "Sleep Timer",
            tagline: "Sleep in 30 minutes, fading the music out.",
            detail: "Sleep in 30 minutes, fading the music out over the last minute so it does not cut off mid-song.",
            category: .power, icon: "sleepTimer", needsHelper: false),
        ComponentDefinition(id: "fanBoost", name: "Fan Boost",
            tagline: "Fans spin up when a closed Mac works hard.",
            detail: "While a closed Mac works hard, the fans run at {value} and return to automatic when it rests. Uses the optional helper.",
            category: .power, icon: "fanBoost", needsHelper: true),
        ComponentDefinition(id: "ejectOnSleep", name: "Eject on Sleep",
            tagline: "Drives eject when your closed Mac sleeps.",
            detail: "Drives eject when your closed Mac sleeps, so the next unplug does not surprise a mounted volume. When it wakes the drives you left connected {drive}; if one cannot be ejected, Wakely tells you which.",
            category: .power, icon: "ejectOnSleep", needsHelper: false),

        // MARK: Connections
        ComponentDefinition(id: "bluetoothOffWhileClosed", name: "Bluetooth Off While Closed",
            tagline: "Bluetooth turns off while your closed Mac sleeps.",
            detail: "Bluetooth turns off while your closed Mac sleeps, and comes back when you open the lid. Asleep means asleep, and the battery agrees.",
            category: .connections, icon: "bluetoothOffWhileClosed", needsHelper: false),
        ComponentDefinition(id: "awakeWhileConnected", name: "Awake While Connected",
            tagline: "Stays awake while you're connected to it.",
            detail: "Stays awake while you're connected to it: an SSH session or another remote login keeps the closed Mac awake until the last connection drops, then for {value} more.",
            category: .connections, icon: "awakeWhileConnected", needsHelper: false),
        ComponentDefinition(id: "lidShortcuts", name: "Lid Shortcuts",
            tagline: "Run your own Shortcut when you close or open the lid.",
            detail: "Runs the Shortcut you choose every time you close or open the lid. Write its name once and it runs in the background.",
            category: .connections, icon: "lidShortcuts", needsHelper: false),
        ComponentDefinition(id: "armWhileAppRuns", name: "Arm While an App Runs",
            tagline: "Stays awake while the app you choose runs.",
            detail: "Wakely arms while this app runs, and lets your Mac sleep normally when it quits.",
            category: .connections, icon: "armWhileAppRuns", needsHelper: false),
        ComponentDefinition(id: "armOnWiFi", name: "Arm on a Wi-Fi Network",
            tagline: "Arms itself when plugged in on your Wi-Fi.",
            detail: "While your Mac is on this Wi-Fi network and plugged in, Wakely arms by itself and posts one notification. It arms only with the lid open, and stays armed until your Mac joins another network or you unplug it.",
            category: .connections, icon: "armOnWiFi", needsHelper: false),
        ComponentDefinition(id: "armOnSchedule", name: "Arm on a Schedule",
            tagline: "Arms itself during the hours you choose.",
            detail: "Wakely arms between these times while your Mac is plugged in. It arms at the start time, or when you open the lid during those hours, and never wakes a sleeping Mac.",
            category: .connections, icon: "armOnSchedule", needsHelper: false),
        ComponentDefinition(id: "armWhenDriveConnects", name: "Arm When a Drive Connects",
            tagline: "Stays awake while your backup drive is connected.",
            detail: "Wakely arms while this drive is connected, and lets the Mac sleep once you eject it.",
            category: .connections, icon: "armWhenDriveConnects", needsHelper: false)
    ]

    static func definition(for id: String) -> ComponentDefinition? {
        all.first { $0.id == id }
    }
}
