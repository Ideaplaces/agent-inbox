import AppKit
import Foundation

/// Opens the editor window for a session. A session on another machine opens
/// through VS Code's Remote-SSH, using the host label as the SSH host alias,
/// which is exactly what `HOST_LABEL` is documented to be.
enum SessionOpener {
    private static let candidates = [
        "/opt/homebrew/bin/code",
        "/usr/local/bin/code",
        "/opt/homebrew/bin/cursor",
        "/usr/local/bin/cursor",
    ]

    static var editorPath: String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func open(_ item: InboxItem, localHost: String) {
        guard let cwd = item.cwd, !cwd.isEmpty else { return }

        guard let editor = editorPath else {
            // No CLI editor installed: fall back to Finder for a local path.
            if FileManager.default.fileExists(atPath: cwd) {
                NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
            }
            return
        }

        // A path that also exists here is treated as local. On two machines
        // with the same layout that opens the local copy, which is the useful
        // default when you are sitting in front of one of them.
        let isLocal = item.isLocal(localHost: localHost)
            || FileManager.default.fileExists(atPath: cwd)
        let arguments = isLocal
            ? [cwd]
            : ["--folder-uri", "vscode-remote://ssh-remote+\(item.host)\(cwd)"]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: editor)
        process.arguments = arguments
        try? process.run()
    }
}
