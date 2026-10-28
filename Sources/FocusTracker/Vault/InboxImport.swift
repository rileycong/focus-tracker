import Foundation

// Issue #50 (FocusVault FT-2) — the Inbox draft import layer. Contract:
// vault-sync `_docs/plan.md` §5.2 (pinned behaviors + do-not-shows), §2.3,
// §3 (the ownership table), §6.3/§6.8. A draft = `Inbox/*.md`, plain
// Markdown (written by the Hermes Lifebot, Working Copy on the iPhone, or
// a human); the import turns conforming drafts into schema-complete tasks
// through the SAME `VaultStore.create` code path that writes tasks
// everywhere, then REMOVES the draft (move, not copy — idempotent). The
// app remains the ONLY schema writer (contract §2.3): drafts carry title +
// body only, and the import alone assigns the UUID/category/status.

/// The typed failure vocabulary of the Inbox draft import (issue #50).
///
/// Two families, one shape: every case names the draft file (house rule —
/// field + value) so tests assert the exact case, and every failure keeps
/// the same anti-data-loss posture — **the draft stays in `Inbox/`**, is
/// counted in the "M problems" surface (the Vault-menu label; there is
/// deliberately NO in-app problem viewer — the pinned do-not-show), and is
/// never discarded, overwritten, or silently skipped.
///
/// - The **non-conforming** family is the issue's pinned conformance
///   contract: a draft must decode as UTF-8 text, be at most
///   `InboxDraftParser.maximumByteCount` (1 MiB) bytes, and be readable.
/// - The **operational** family reports failures mid-import (the
///   `Tasks/` write or the draft removal): create-then-remove means a
///   failed create leaves the draft untouched, and a failed removal
///   leaves the draft in place — a duplicate on a later import is
///   user-recoverable, a discarded draft is not.
public enum InboxImportError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Non-conforming: the draft exceeds the 1 MiB conformance limit
    /// (1_048_576 bytes). `byteCount` is the actual size, so the exact
    /// boundary is assertable.
    case tooLarge(fileName: String, byteCount: Int)
    /// Non-conforming: the draft's bytes do not decode as UTF-8 text
    /// (binary junk).
    case binaryJunk(fileName: String)
    /// Non-conforming: the draft could not be read at all (IO or
    /// permission failure). The underlying OS error is not carried (the
    /// draft stays; the pinned answer for inspecting it is
    /// Finder/Obsidian, not an in-app viewer).
    case unreadable(fileName: String)
    /// The schema-complete `Tasks/` write (the #50 same-code-path
    /// `VaultStore.create`) failed; the draft stays untouched and nothing
    /// was written for it.
    case taskCreationFailed(fileName: String, underlying: VaultStoreError)
    /// The draft's removal failed AFTER its task was successfully created
    /// (a rare IO error — e.g. `Inbox/` lost write permission). The draft
    /// stays and is counted as a problem: the next import would create a
    /// second task, which is user-recoverable (the #50 anti-data-loss
    /// posture — the reverse, a discarded draft, is not).
    case draftRemovalFailed(fileName: String)
    /// Defensive, unreachable by construction: a throwing path that is
    /// fully typed in practice (`TaskItem.init` throws only
    /// `ValidationError`, `VaultStore.create` only `VaultStoreError`)
    /// produced an unexpected error kind. Surfaced with its description
    /// rather than swallowed; the draft stays.
    case unexpectedTaskError(fileName: String, description: String)

    public var description: String {
        switch self {
        case .tooLarge(let fileName, let byteCount):
            return
                "\"\(fileName)\" is \(byteCount) bytes (limit \(InboxDraftParser.maximumByteCount)); "
                + "non-conforming draft stays in Inbox/"
        case .binaryJunk(let fileName):
            return "\"\(fileName)\" is not valid UTF-8 text; non-conforming draft stays in Inbox/"
        case .unreadable(let fileName):
            return "\"\(fileName)\" could not be read; non-conforming draft stays in Inbox/"
        case .taskCreationFailed(let fileName, let underlying):
            return "\"\(fileName)\" could not be imported: \(underlying); draft stays in Inbox/"
        case .draftRemovalFailed(let fileName):
            return
                "\"\(fileName)\" was imported but its draft could not be removed; "
                + "the draft stays (a duplicate re-import is user-recoverable)"
        case .unexpectedTaskError(let fileName, let description):
            return "\"\(fileName)\" failed unexpectedly (\(description)); draft stays in Inbox/"
        }
    }
}

/// The parsed content of one conforming draft (issue #50): the derived
/// title and the verbatim Markdown body the import carries into the task
/// file. `Equatable` for exact assertions.
public struct InboxDraftContent: Equatable, Sendable {
    /// The draft's title: the text of the first `# ` level-1 heading line,
    /// trimmed — or the filename sans extension when the draft has no
    /// usable level-1 heading (issue #50 criterion 2).
    public let title: String
    /// The draft's body, **preserved verbatim** (CRLF included): the
    /// remainder of the file after the heading line when the title came
    /// from a heading, or the ENTIRE file content when the title came from
    /// the filename (the pinned reconciliation of "body = the remainder,
    /// preserved verbatim").
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// One draft file in the `Inbox/` snapshot (issue #50): identified by its
/// filename — references are by name, the same identity the filesystem
/// and the removal operate on. `Equatable`/`Sendable` so snapshots cross
/// isolation domains and tests assert them exactly.
public struct InboxDraftFile: Equatable, Sendable, CustomStringConvertible {
    /// The file's name inside `Inbox/` (a direct child, `.md` extension).
    public let fileName: String

    public init(fileName: String) {
        self.fileName = fileName
    }

    public var description: String { fileName }
}

/// The pure conformance + parse core of the import (issue #50): bytes →
/// derived `(title, body)` or the typed non-conforming failure. PURE over
/// its inputs (no I/O) so every derivation rule and conformance boundary
/// is unit-testable without files.
public enum InboxDraftParser {
    /// The conformance limit (issue #50, pinned): a draft larger than
    /// 1 MiB is non-conforming (stays in `Inbox/`, counted).
    public static let maximumByteCount = 1_048_576

    /// Conformance + parse of one draft's bytes (issue #50):
    ///
    /// 1. Size check first — more than `maximumByteCount` bytes is the
    ///    typed `.tooLarge` failure (also for files that would ALSO fail
    ///    the decode: the order is pinned so the exact case is
    ///    deterministic).
    /// 2. UTF-8 decode — a decode failure is the typed `.binaryJunk`
    ///    failure (binary junk fails decode).
    /// 3. The title/body derivation (see `parse(fileName:text:)`).
    public static func content(
        fileName: String, bytes: Data
    ) -> Result<InboxDraftContent, InboxImportError> {
        guard bytes.count <= maximumByteCount else {
            return .failure(.tooLarge(fileName: fileName, byteCount: bytes.count))
        }
        guard let text = String(data: bytes, encoding: .utf8) else {
            return .failure(.binaryJunk(fileName: fileName))
        }
        return .success(parse(fileName: fileName, text: text))
    }

    /// The title/body derivation (issue #50 criterion 2), pure:
    ///
    /// - **Title:** the FIRST line that is a level-1 heading — `# ` (one
    ///   hash followed by a space or tab; `## ` and deeper are NOT level
    ///   1). Leading/trailing whitespace on the line is tolerated for
    ///   detection (a trailing `\r` from CRLF drafts included) and the
    ///   heading text is returned trimmed. A heading whose text trims to
    ///   empty contributes no title — the filename fallback applies.
    /// - **Body (the pinned reconciliation of "the remainder, preserved
    ///   verbatim"):** everything after the heading line's terminating
    ///   newline, byte-for-byte (CRLF included) — pre-heading content is
    ///   not carried (the contract's draft model is heading-first
    ///   title + body, §2.3 / VS-3's `Inbox/<timestamp-slug>.md`
    ///   convention). With NO usable level-1 heading, the title is the
    ///   filename sans extension and the body is the ENTIRE file content.
    ///   A heading as the last line (no trailing newline) yields an empty
    ///   body.
    private static func parse(fileName: String, text: String) -> InboxDraftContent {
        // Line scan in the #4 `FrontmatterCodec.split` shape: each record
        // ends before its own line terminator; a final unterminated line
        // is its own record. Indices are kept against the ORIGINAL text
        // so the body slice below is verbatim — nothing is rebuilt from
        // trimmed lines. Line terminators are matched with `isNewline`
        // (NOT `== "\n"`): Swift clusters CRLF into ONE character, which
        // a "\n" comparison would never match (the AeroSpaceFloating
        // CRLF-clustering precedent) — CRLF-safe by construction.
        var lines: [(content: Substring, afterNewline: String.Index?)] = []
        var lineStart = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isNewline {
                lines.append((text[lineStart..<index], text.index(after: index)))
                lineStart = text.index(after: index)
            }
            index = text.index(after: index)
        }
        if lineStart < text.endIndex {
            lines.append((text[lineStart..<text.endIndex], nil))
        }

        for line in lines {
            if let title = levelOneHeadingTitle(in: line.content) {
                let body: String
                if let afterNewline = line.afterNewline {
                    body = String(text[afterNewline...])
                } else {
                    body = ""
                }
                return InboxDraftContent(title: title, body: body)
            }
        }
        return InboxDraftContent(title: fileNameStem(of: fileName), body: text)
    }

    /// The level-1 heading title carried by ONE line, or nil when the line
    /// is not a `# ` heading: `## `/`#### ` (two or more hashes) are not
    /// level 1, a lone `#` or `# ` with empty text yields nil (the
    /// filename fallback covers it). Leading/trailing whitespace is
    /// tolerated and the returned title is trimmed. (A trailing `\r` is
    /// stripped defensively too — the scanner never includes terminators
    /// in a line's content, but this stays safe if that ever changes.)
    private static func levelOneHeadingTitle(in line: Substring) -> String? {
        var content = Substring(line)
        if content.hasSuffix("\r") { content = content.dropLast() }
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        let afterHash = trimmed.dropFirst()
        // Exactly one hash, followed by whitespace or end-of-line — never
        // a second hash (that is `## `, a deeper level).
        guard afterHash.isEmpty || afterHash.hasPrefix(" ") || afterHash.hasPrefix("\t")
        else { return nil }
        let title = afterHash
            .drop(while: { $0 == " " || $0 == "\t" })
            .trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    /// The filename fallback title: the name sans its `.md` extension
    /// (matched case-insensitively — APFS is commonly case-insensitive).
    /// A name that is exactly the extension (a pathological `.md`)
    /// stays as-is.
    private static func fileNameStem(of fileName: String) -> String {
        guard fileName.count > 3, fileName.lowercased().hasSuffix(".md") else {
            return fileName
        }
        return String(fileName.dropLast(3))
    }
}

/// The count snapshot the Vault menu's label derives from (issue #50
/// criterion 4): N = importable (conforming) drafts, M = non-conforming
/// drafts that stay in `Inbox/` and are counted. `Equatable` for exact
/// assertions.
public struct InboxScanSummary: Equatable, Sendable {
    /// Conforming drafts importable right now (the label's N).
    public let importableDraftCount: Int
    /// Non-conforming drafts (the label's "M problems").
    public let problemCount: Int

    public init(importableDraftCount: Int, problemCount: Int) {
        self.importableDraftCount = importableDraftCount
        self.problemCount = problemCount
    }
}

/// The typed outcome of one import run (issue #50): how many tasks were
/// created, and one `InboxImportError` per draft that still needs
/// attention. `Equatable` for exact assertions. A run NEVER throws —
/// every failure is a counted problem with the draft retained.
public struct InboxImportSummary: Equatable, Sendable {
    /// Tasks successfully created in `Tasks/`. Includes a draft whose
    /// creation succeeded but whose REMOVAL then failed (that draft also
    /// appears in `problems` — the anti-data-loss double report).
    public let importedCount: Int
    /// One entry per draft that was not cleanly moved: non-conforming
    /// (stays in `Inbox/`), create-failed (stays untouched), or
    /// removal-failed (stays; the duplicate risk is user-recoverable).
    public let problems: [InboxImportError]

    public init(importedCount: Int, problems: [InboxImportError]) {
        self.importedCount = importedCount
        self.problems = problems
    }
}

/// The import engine (issue #50, FocusVault FT-2). An **actor** (the
/// `VaultStore` concurrency-shape precedent, engineer's choice
/// documented): the scan/parse/removal I/O runs on the importer's own
/// executor — off the interaction path (the menu action and the launch
/// import `await` it; the main-actor timer UI never blocks) — and
/// concurrent runs serialize.
///
/// **Ownership (issue #50 criterion 5, contract §3):** the import touches
/// ONLY `Inbox/` reads, `Tasks/` creation (through the given
/// `VaultStore` — the SAME code path that writes tasks everywhere, so the
/// #49 `onVaultWrite` push debounce rides for free) and the draft removal.
/// It never reads or writes `Lifebot/`, never touches existing tasks,
/// logs, or anything else under the vault.
///
/// **Concurrency (criterion 8):** the draft list is a per-run SNAPSHOT —
/// a draft appearing mid-run is simply not in the snapshot and stays for
/// the next import (no crash, no duplicate). The `scanDrafts` /
/// `importDrafts` split below is the documented test seam for exactly
/// that: a test scans, mutates `Inbox/`, then imports the captured
/// snapshot.
public actor InboxImporter {
    /// The category every imported task is assigned (issue #50, engineer's
    /// choice per the pinned criteria): `TaskItem` requires ≥1 category
    /// (PRD §6.3 — the decoder rejects a missing categories field, so the
    /// task must be schema-complete), while drafts carry title + body
    /// only. `Inbox` names the source folder and is as editable as every
    /// other field — the user re-categorizes in the app afterward (the
    /// pinned "no priority/deadline/project from drafts" posture).
    public static let defaultCategoryName = "Inbox"

    /// The draft-removal writer (the #5 atomic-delete discipline for the
    /// one vault mutation the import owns outside `VaultStore`).
    private let fileWriter = AtomicFileWriter()

    public init() {}

    // MARK: - Scanning (the per-run snapshot)

    /// Snapshots the draft list of `Inbox/` (issue #50): direct-child
    /// `.md` files (extension matched case-insensitively — the APFS
    /// precedent from `VaultStore`'s layout rules), filename-sorted for
    /// deterministic runs. Directories and dotfiles are not drafts and
    /// are ignored silently (the `VaultStore` layout-rule precedent); a
    /// MISSING or EMPTY `Inbox/` is legitimate and yields the empty
    /// snapshot — N=0, M=0, no errors. An `Inbox/` that exists but cannot
    /// be listed degrades to the empty snapshot too (the
    /// `VaultStore.readInventory` unlistable-directory posture): the menu
    /// action's rescan is the retry path.
    public func scanDrafts(in inboxURL: URL) -> [InboxDraftFile] {
        var isDirectory: ObjCBool = false
        let path = inboxURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return [] }
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: inboxURL, includingPropertiesForKeys: [.isDirectoryKey])
        } catch {
            return []
        }
        return entries
            .filter { entry in
                var entryIsDirectory: ObjCBool = false
                FileManager.default.fileExists(
                    atPath: entry.path(percentEncoded: false),
                    isDirectory: &entryIsDirectory)
                if entryIsDirectory.boolValue { return false }
                let name = entry.lastPathComponent
                if name.hasPrefix(".") { return false }
                return name.lowercased().hasSuffix(".md")
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { InboxDraftFile(fileName: $0.lastPathComponent) }
    }

    /// The count snapshot (issue #50 criterion 4): N = conforming drafts,
    /// M = non-conforming ones — the pure inputs of the Vault-menu label
    /// derivation. Runs the SAME conformance pipeline as the import
    /// (read → size → decode) so the counts can never disagree with what
    /// an import would do.
    public func scanSummary(in inboxURL: URL) -> InboxScanSummary {
        var importable = 0
        var problems = 0
        for draft in scanDrafts(in: inboxURL) {
            let url = inboxURL.appendingPathComponent(draft.fileName, isDirectory: false)
            do {
                let bytes = try Data(contentsOf: url)
                if case .failure = InboxDraftParser.content(
                    fileName: draft.fileName, bytes: bytes)
                {
                    problems += 1
                } else {
                    importable += 1
                }
            } catch {
                problems += 1
            }
        }
        return InboxScanSummary(
            importableDraftCount: importable, problemCount: problems)
    }

    // MARK: - Importing

    /// The one-call import (issue #50): scan + import the snapshot. The
    /// pinned pull-before-import is the CALLER's duty (`AppModel` owns the
    /// #49 seam: the launch import runs after the launch pull, the menu
    /// action pulls first) — this engine never talks to git.
    public func run(
        in inboxURL: URL, through store: VaultStore
    ) async -> InboxImportSummary {
        await importDrafts(
            scanDrafts(in: inboxURL), in: inboxURL, through: store)
    }

    /// Imports the GIVEN snapshot (issue #50) — the scan/import split that
    /// makes the per-run snapshot semantics explicit (and the documented
    /// test seam for the mid-run-arrival criterion). For each draft, in
    /// snapshot (filename-sorted) order:
    ///
    /// 1. **Read + conformance** — an IO failure is `.unreadable`, over
    ///    1 MiB is `.tooLarge`, an undecodable file is `.binaryJunk`. The
    ///    draft stays, is counted, and the run continues.
    /// 2. **Task construction** — a fresh UUID, the derived title, the
    ///    single default category `Inbox` (see `defaultCategoryName`),
    ///    status `.toDo` (the `TaskItem` default), everything else
    ///    nil/empty — no priority/deadline/project/notes/order/subtasks,
    ///    no sessions, no timestamps of its own (the pinned schema).
    /// 3. **Create** through `VaultStore.create(_:body:)` — the SAME code
    ///    path that writes tasks everywhere (the #50 same-code-path pin;
    ///    the #49 `onVaultWrite` hook fires for free, so pushes ride the
    ///    sync debounce with no new push wiring). The body passed is the
    ///    draft's verbatim remainder, prefixed with the fixture-style
    ///    leading blank line (added only when there IS a body — the
    ///    fixture separator between `---` and the Markdown, so a
    ///    load→update cycle preserves it byte-for-byte). A failure is
    ///    `.taskCreationFailed` — the draft stays untouched.
    /// 4. **Remove** the draft (create-THEN-remove, pinned): a failure is
    ///    `.draftRemovalFailed` — the draft stays and is counted, the
    ///    created task remains (a duplicate re-import is
    ///    user-recoverable; a discarded draft is not).
    ///
    /// Idempotence falls out (§6.8): the removed draft cannot re-import; a
    /// LATER same-name draft is a new snapshot entry → a new task with a
    /// fresh UUID (the store's slug-collision suffix handles the filename).
    public func importDrafts(
        _ drafts: [InboxDraftFile], in inboxURL: URL, through store: VaultStore
    ) async -> InboxImportSummary {
        var imported = 0
        var problems: [InboxImportError] = []
        for draft in drafts {
            let draftURL = inboxURL.appendingPathComponent(
                draft.fileName, isDirectory: false)

            // 1. Read + conformance.
            let bytes: Data
            do {
                bytes = try Data(contentsOf: draftURL)
            } catch {
                problems.append(.unreadable(fileName: draft.fileName))
                continue
            }
            let content: InboxDraftContent
            switch InboxDraftParser.content(fileName: draft.fileName, bytes: bytes) {
            case .failure(let failure):
                problems.append(failure)
                continue
            case .success(let parsed):
                content = parsed
            }

            // 2. Task construction (fresh UUID via TaskItem's default).
            let task: TaskItem
            do {
                task = try TaskItem(
                    title: content.title,
                    categories: [Category(name: Self.defaultCategoryName)])
            } catch let error as TaskItem.ValidationError {
                problems.append(
                    .unexpectedTaskError(
                        fileName: draft.fileName, description: String(describing: error)))
                continue
            } catch {
                problems.append(
                    .unexpectedTaskError(
                        fileName: draft.fileName, description: String(describing: error)))
                continue
            }

            // 3. The SAME code path that writes tasks everywhere. The body
            //    carries the fixture-style leading blank line when there
            //    is a body to separate.
            let body = content.body.isEmpty ? "" : "\n" + content.body
            do {
                _ = try await store.create(task, body: body)
            } catch let error as VaultStoreError {
                problems.append(
                    .taskCreationFailed(fileName: draft.fileName, underlying: error))
                continue
            } catch {
                problems.append(
                    .unexpectedTaskError(
                        fileName: draft.fileName, description: String(describing: error)))
                continue
            }
            imported += 1

            // 4. Create-then-remove: the draft leaves Inbox/ only after
            //    its task write SUCCEEDED.
            do {
                try fileWriter.delete(draftURL)
            } catch {
                problems.append(.draftRemovalFailed(fileName: draft.fileName))
            }
        }
        return InboxImportSummary(importedCount: imported, problems: problems)
    }
}
