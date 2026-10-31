import Foundation

public enum GitToolResolution: Equatable, Sendable {
    case available(path: String)
    case unavailable
}

/// Filesystem-only discovery. The compatibility sentinel is never executable.
/// Explicit selection fails closed; only the unselected fallback tries two layouts.
public struct GitToolResolver: Sendable {
    public struct FileSystem: Sendable {
        public var canonicalPath: @Sendable (String) -> String
        public var symbolicLinkTarget: @Sendable (String) -> String?
        public var isRegularExecutable: @Sendable (String) -> Bool

        public init(
            canonicalPath: @escaping @Sendable (String) -> String,
            symbolicLinkTarget: @escaping @Sendable (String) -> String?,
            isRegularExecutable: @escaping @Sendable (String) -> Bool
        ) {
            self.canonicalPath = canonicalPath
            self.symbolicLinkTarget = symbolicLinkTarget
            self.isRegularExecutable = isRegularExecutable
        }

        public static let live = FileSystem(
            canonicalPath: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            symbolicLinkTarget: { path in
                // attributesOfItem is lstat-like: a dangling selection is still a selection.
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                    attributes[.type] as? FileAttributeType == .typeSymbolicLink
                else { return nil }
                return (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? ""
            },
            isRegularExecutable: { path in
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                    attributes[.type] as? FileAttributeType == .typeRegular
                else { return false }
                return FileManager.default.isExecutableFile(atPath: path)
            })
    }

    private let environment: @Sendable () -> [String: String]
    private let fileSystem: FileSystem

    public init(
        environment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment },
        fileSystem: FileSystem = .live
    ) {
        self.environment = environment
        self.fileSystem = fileSystem
    }

    public func usesDefaultPolicy(gitBinary: String) -> Bool {
        gitBinary == ProcessGitRunner.defaultGitBinary
            || (gitBinary.hasPrefix("/")
                && fileSystem.canonicalPath(gitBinary) == ProcessGitRunner.defaultGitBinary)
    }

    public func resolve(gitBinary: String = ProcessGitRunner.defaultGitBinary) -> GitToolResolution {
        guard usesDefaultPolicy(gitBinary: gitBinary) else { return executable(gitBinary) }
        if let override = environment()["DEVELOPER_DIR"],
            !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard override.hasPrefix("/") else { return .unavailable }
            let developer = override.hasSuffix(".app") ? override + "/Contents/Developer" : override
            return executable(developer + "/usr/bin/git")
        }
        let selection = "/var/db/xcode_select_link"
        if let target = fileSystem.symbolicLinkTarget(selection) {
            guard !target.isEmpty else { return .unavailable }
            let developer = target.hasPrefix("/") ? target : "/var/db/" + target
            return executable(developer + "/usr/bin/git")
        }
        for developer in ["/Library/Developer/CommandLineTools", "/Applications/Xcode.app/Contents/Developer"] {
            if case .available(let path) = executable(developer + "/usr/bin/git") {
                return .available(path: path)
            }
        }
        return .unavailable
    }

    private func executable(_ requested: String) -> GitToolResolution {
        guard requested.hasPrefix("/") else { return .unavailable }
        let path = fileSystem.canonicalPath(requested)
        guard path.hasPrefix("/"), path != ProcessGitRunner.defaultGitBinary,
            fileSystem.isRegularExecutable(path)
        else { return .unavailable }
        return .available(path: path)
    }
}
