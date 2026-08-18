import Foundation
import txtnimalCore

public enum CLIRunner {

    public static let version = "0.3.0"

    /// Exit codes: 0 success, 2 usage error, 1 everything else. Diagnostics always go to
    /// stderr so `--json` on stdout stays machine-readable even when a command fails.
    public static func run(arguments: [String], context: CLIContext) -> CLIOutput {
        let invocation: ParsedInvocation
        do {
            invocation = try CLIParser.parse(arguments)
        } catch {
            let json = arguments.contains("--json")
            return failure(message(for: error), code: 2, json: json)
        }

        do {
            return try execute(invocation, context: context)
        } catch {
            return failure(message(for: error), code: 1, json: invocation.global.json)
        }
    }

    // MARK: - Dispatch

    private static func execute(_ invocation: ParsedInvocation, context: CLIContext) throws -> CLIOutput {
        switch invocation.command {
        case .help:
            return CLIOutput(stdout: helpText)
        case .version:
            return CLIOutput(stdout: version + "\n")
        case .list(let options):
            return try list(options, invocation.global, context)
        case .add(let options):
            return try add(options, invocation.global, context)
        case .done(let prefix):
            return try complete(prefix, invocation.global, context)
        case .delete(let prefix):
            return try delete(prefix, invocation.global, context)
        case .listEnsure(let name):
            return try ensure(name: name, marker: "+", invocation.global, context)
        case .tagEnsure(let name):
            return try ensure(name: name, marker: "@", invocation.global, context)
        }
    }

    // MARK: - Commands

    private static func list(_ options: ListOptions, _ global: GlobalOptions, _ context: CLIContext) throws -> CLIOutput {
        let file = tasksFile(global, context)
        // A missing file is an empty task list, not a failure — `list` must never be the
        // command that creates state.
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            return CLIOutput(stdout: global.json ? encode(["tasks": []]) : "")
        }
        let lines = TasksDocument.parse(text)
        let identities = PluginSnapshotBuilder.identityMap(for: lines)
        let indices = TaskFilter.matchingIndices(in: lines, options: options)

        if global.json {
            let tasks = indices.map { payload(for: lines[$0], id: identity(at: $0, in: identities), line: $0) }
            return CLIOutput(stdout: encode(["tasks": tasks]))
        }
        let ids = indices.map { identity(at: $0, in: identities) }
        // Width from the rows actually printed — a single long `legacy-…` id would
        // otherwise knock every following column out of alignment.
        let width = ids.map(\.count).max() ?? 0
        let rows = zip(indices, ids).map { describe(lines[$0], id: $1, width: width) }
        return CLIOutput(stdout: rows.isEmpty ? "" : rows.joined(separator: "\n") + "\n")
    }

    private static func add(_ options: AddOptions, _ global: GlobalOptions, _ context: CLIContext) throws -> CLIOutput {
        let title = TaskLine.sanitizedTitle(options.title)
        guard !title.isEmpty else {
            throw CLIRunError.invalidInput("title is empty after removing todo.txt control tokens")
        }
        // Resolve the due date before opening the file — a bad date must not leave a
        // half-applied write behind.
        var due: String?
        if let raw = options.due {
            guard let parsed = DueDateParser.parse(raw, today: context.today, calendar: context.calendar) else {
                throw CLIRunError.invalidInput("could not read --due \"\(raw)\" (try 2026-10-10, today, tomorrow, 3d, 2w, mon)")
            }
            due = parsed
        }

        let (store, snapshot) = try openForWriting(global, context)
        var line = TaskLine(title)
        for project in options.projects where !project.isEmpty { line.addTag("+" + project) }
        for tag in options.contexts where !tag.isEmpty { line.addTag("@" + tag) }
        if let due { line.setDue(due) }
        line.setStableID(TaskIdentity.generateID(existing: TaskIdentity.existingIDs(in: snapshot.lines),
                                                 random: context.randomIDFactory))
        line.setValue(todayYMD(context), forKey: "created")
        if let note = options.note, !note.isEmpty { line.setNote(note) }

        var lines = snapshot.lines
        lines.insert(line, at: insertionIndex(in: lines))
        _ = try store.save(lines: lines, expectedGeneration: snapshot.generation)

        let id = line.stableID ?? ""
        return CLIOutput(stdout: global.json
            ? encode(payload(for: line, id: id, line: nil))
            : "added \(id)  \(line.title)\n")
    }

    private static func complete(_ prefix: String, _ global: GlobalOptions, _ context: CLIContext) throws -> CLIOutput {
        let (store, snapshot) = try openForWriting(global, context)
        let (index, id) = try locate(prefix, in: snapshot.lines)

        // Already done is success. `toggleDone` would otherwise re-open the task, which is
        // the opposite of what a scripted `done` means.
        guard !snapshot.lines[index].isDone else {
            return CLIOutput(stdout: global.json
                ? encode(["id": id, "done": true, "changed": false])
                : "already done \(id)  \(snapshot.lines[index].title)\n")
        }

        // Routed through TaskWorkspace rather than `setDone` so completing a `rec:` task
        // emits its next occurrence exactly as the GUI does.
        let handle = TaskHandle(generation: snapshot.generation, index: index)
        let updated = try TaskWorkspace.apply(.toggleDone(handle), to: snapshot,
                                              todayYMD: todayYMD(context), calendar: context.calendar)
        _ = try store.save(lines: updated, expectedGeneration: snapshot.generation)

        let successor = updated.count > snapshot.lines.count
        return CLIOutput(stdout: global.json
            ? encode(["id": id, "done": true, "changed": true, "recurrenceCreated": successor])
            : "done \(id)  \(snapshot.lines[index].title)\n"
                + (successor ? "  next occurrence created\n" : ""))
    }

    private static func delete(_ prefix: String, _ global: GlobalOptions, _ context: CLIContext) throws -> CLIOutput {
        let (store, snapshot) = try openForWriting(global, context)
        let (index, id) = try locate(prefix, in: snapshot.lines)
        let title = snapshot.lines[index].title

        // No confirmation prompt on purpose: a CLI is non-interactive, and the caller
        // owns the decision. This is deliberately unlike the GUI's confirm-before-delete.
        let handle = TaskHandle(generation: snapshot.generation, index: index)
        let updated = try TaskWorkspace.apply(.delete(handle), to: snapshot,
                                              todayYMD: todayYMD(context), calendar: context.calendar)
        _ = try store.save(lines: updated, expectedGeneration: snapshot.generation)

        return CLIOutput(stdout: global.json
            ? encode(["id": id, "deleted": true, "title": title])
            : "deleted \(id)  \(title)\n")
    }

    /// Idempotent: guarantees at least one task carries the tag. Already satisfied is a
    /// successful no-op, never an error.
    ///
    /// Scope note — the GUI can hold a *description-only* list with zero tasks, stored in
    /// its `listDescriptions` UserDefaults key rather than in tasks.txt. This command does
    /// not create those; it only guarantees the tag exists on a task in the file.
    private static func ensure(name rawName: String, marker: Character,
                               _ global: GlobalOptions, _ context: CLIContext) throws -> CLIOutput {
        var name = rawName
        if name.first == marker { name = String(name.dropFirst()) }
        guard !name.isEmpty, !name.contains(" ") else {
            throw CLIRunError.invalidInput("\"\(rawName)\" is not a usable name")
        }
        let kind = marker == "+" ? "list" : "tag"

        let (store, snapshot) = try openForWriting(global, context)
        let needle = name.lowercased()
        let present = snapshot.lines.contains { line in
            let values = marker == "+" ? line.projects : line.contexts
            return values.contains { $0.lowercased() == needle }
        }
        if present {
            return CLIOutput(stdout: global.json
                ? encode(["name": name, "kind": kind, "created": false])
                : "\(kind) \(name) already exists\n")
        }

        var line = TaskLine(TaskLine.sanitizedTitle(name).isEmpty ? kind : TaskLine.sanitizedTitle(name))
        line.addTag(String(marker) + name)
        line.setStableID(TaskIdentity.generateID(existing: TaskIdentity.existingIDs(in: snapshot.lines),
                                                 random: context.randomIDFactory))
        line.setValue(todayYMD(context), forKey: "created")

        var lines = snapshot.lines
        lines.insert(line, at: insertionIndex(in: lines))
        _ = try store.save(lines: lines, expectedGeneration: snapshot.generation)

        let id = line.stableID ?? ""
        return CLIOutput(stdout: global.json
            ? encode(["name": name, "kind": kind, "created": true, "id": id])
            : "\(kind) \(name) created (placeholder task \(id))\n")
    }

    // MARK: - File access

    private static func tasksFile(_ global: GlobalOptions, _ context: CLIContext) -> URL {
        PathResolver.resolveTasksFile(dirFlag: global.dir,
                                      environment: context.environment,
                                      defaults: context.defaults,
                                      home: context.home)
    }

    /// Reuses `FileSystemTaskDocumentStore` — the same store the GUI writes through. Its
    /// commit is a journal write followed by `write(to:atomically:true)` (temp file +
    /// rename), which is exactly the atomicity this CLI needs, already under test.
    private static func openForWriting(_ global: GlobalOptions,
                                       _ context: CLIContext) throws -> (FileSystemTaskDocumentStore, TaskDocumentSnapshot) {
        let file = tasksFile(global, context)
        let store = try FileSystemTaskDocumentStore(directory: file.deletingLastPathComponent(),
                                                   tasksFilename: file.lastPathComponent)
        try store.bootstrap(sample: "")
        return (store, try store.load())
    }

    private static func locate(_ prefix: String, in lines: [TaskLine]) throws -> (index: Int, id: String) {
        switch TaskIdentity.resolve(prefix: prefix, in: lines) {
        case .unique(let index, let id):
            return (index, id)
        case .notFound:
            throw CLIRunError.notFound(prefix)
        case .ambiguous(let candidates):
            throw CLIRunError.ambiguous(prefix, candidates)
        }
    }

    /// Insert after the last real task, so an existing trailing newline stays a trailing
    /// newline instead of the new task landing after a blank line.
    static func insertionIndex(in lines: [TaskLine]) -> Int {
        guard let last = lines.lastIndex(where: { !$0.isBlank }) else { return 0 }
        return last + 1
    }

    private static func todayYMD(_ context: CLIContext) -> String {
        // Reuses the shared parser's formatter rather than introducing a second one.
        DueDateParser.parse("today", today: context.today, calendar: context.calendar) ?? ""
    }

    private static func identity(at index: Int, in map: [String: Int]) -> String {
        map.first { $0.value == index }?.key ?? ""
    }

    // MARK: - Rendering

    private static func payload(for line: TaskLine, id: String, line index: Int?) -> [String: Any] {
        var object: [String: Any] = [
            "id": id,
            "title": line.title,
            "done": line.isDone,
            "due": line.due ?? NSNull(),
            "note": line.note ?? NSNull(),
            "projects": line.projects,
            "contexts": line.contexts,
            "raw": line.raw,
        ]
        if let index { object["line"] = index + 1 }
        return object
    }

    private static func describe(_ line: TaskLine, id: String, width: Int) -> String {
        var parts = [id.padding(toLength: max(id.count, width), withPad: " ", startingAt: 0),
                     line.isDone ? "[x]" : "[ ]",
                     line.title]
        let tags = line.projects.map { "+" + $0 } + line.contexts.map { "@" + $0 }
        if !tags.isEmpty { parts.append(tags.joined(separator: " ")) }
        if let due = line.due { parts.append("due:" + due) }
        return parts.joined(separator: "  ")
    }

    private static func encode(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}\n"
        }
        return text + "\n"
    }

    private static func failure(_ message: String, code: Int32, json: Bool) -> CLIOutput {
        CLIOutput(stderr: json ? encode(["error": message]) : "txtnimal: " + message + "\n", exitCode: code)
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    // MARK: - Help

    static let helpText = """
    txtnimal \(version) — non-interactive interface to a txtnimal tasks.txt

    USAGE
      txtnimal <command> [options]

    COMMANDS
      add <title>              Create a task (stamps a short stable id: token)
      list                     Print open tasks
      list ensure <name>       Guarantee at least one task carries +<name>  (idempotent)
      tag ensure <name>        Guarantee at least one task carries @<name>  (idempotent)
      done <id-prefix>         Mark a task complete (recurring tasks roll forward)
      delete <id-prefix>       Remove a task — no confirmation, the caller owns this

    OPTIONS
      --due <date>             2026-10-10, today, tomorrow, 3d, 2w, mon…  (add only)
      --project <name>         Attach +name          (add: repeatable; list: filter)
      --context <name>         Attach @name          (add: repeatable; list: filter)
      --note <text>            Attach note:"text"    (add only)
      --query <text>           Filter by title/note substring, case-insensitive (list only)
      --all                    Include completed tasks (list only)
      --json                   Machine-readable output on stdout; errors as JSON on stderr
      --dir <path>             Directory holding tasks.txt
      --help, --version

    TASK FILE RESOLUTION (first match wins)
      1. --dir <path>
      2. $TXTNIMAL_DIR
      3. the txtnimal app's saved file/folder, if you have moved it in the GUI
      4. ~/Documents/txtnimal/tasks.txt

    IDS
      Tasks created here carry a short id: token. Tasks created in the GUI have none, and
      are addressed by the same content-derived legacy-… id the app's plugin host uses —
      run `txtnimal list` to see the current id for any task. Any unique prefix works.

    EXIT CODES
      0 success   1 runtime error   2 usage error

    """
}

// MARK: - Runtime errors

enum CLIRunError: Error, LocalizedError, Equatable {
    case invalidInput(String)
    case notFound(String)
    case ambiguous(String, [String])

    var errorDescription: String? {
        switch self {
        case .invalidInput(let detail):
            return detail
        case .notFound(let prefix):
            return "no task matches \"\(prefix)\" — run `txtnimal list` to see current ids"
        case .ambiguous(let prefix, let candidates):
            return "\"\(prefix)\" matches \(candidates.count) tasks: \(candidates.joined(separator: ", "))"
        }
    }
}
