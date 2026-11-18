// ComponentKitLauncher — writes the `sdk/bin/wakely-component` shim that the
// installed component kit uses. The shim points at the tool inside this app, so
// an installed kit never depends on any other installed copy of the app.

import Foundation

enum ComponentKitLauncher {
    /// Bumped whenever the installed kit's sdk, launcher or documents change.
    /// 3: the bundled shim is `sdk/bin/wakely-component` (it was named after the
    /// old product), so an installed kit must be refreshed to get it.
    /// 4: the kit documents are refreshed with the sdk, so an installed kit picks
    /// up the current component instructions.
    static let kitVersion = "4"

    /// A POSIX sh launcher for `helperPath`, or nil when the path cannot be
    /// embedded safely. The path must be absolute, free of newlines and NULs,
    /// and name the component helper exactly.
    static func script(helperPath: String) -> String? {
        guard helperPath.hasPrefix("/"),
              !helperPath.contains("\n"),
              !helperPath.contains("\0"),
              helperPath.hasSuffix("/wakely-component") else {
            return nil
        }
        let quoted = "'" + helperPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        #!/bin/sh
        # Runs the Wakely component checker; written by the app, safe to overwrite.
        HELPER=\(quoted)
        if [ ! -x "$HELPER" ]; then
          echo "wakely-component: the checker was not found at $HELPER." >&2
          echo "Reinstall or reopen Wakely.app so it can refresh this kit." >&2
          exit 2
        fi
        exec "$HELPER" "$@"
        """
    }
}
