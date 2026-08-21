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
            return failure(message(for: error), code: exitCode(for: error), json: invocation.global.json)
        }
    }

    /// A query that will not parse, or a name that collides, is something the caller fixes
    /// by retyping the command — the same class of problem as a bad flag, so it shares the
    /// parser's exit code 2. "No such task" and "no such view" are about state rather than
    /// usage and stay at 1.
    private static func exitCode(for error: Error) -> Int32 {
        if error is TaskQuery.ParseError { return 2 }
        if let error = error as? SavedViewsError {
            switch error {
            case .duplicateName, .invalidName: return 2
            case .notFound, .unreadable: return 1
            }
        }
        return 1
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
        case .focus(let target):
            return try focus(target, invocation.global, context)
        case .viewSave(let options):
            return try saveView(options, invocation.global, context)
        case .viewList:
            return try listViews(invocation.global, context)
        case .viewRun(let options):
            return try runView(options, invocation.global, context)
        case .viewDelete(let name):
            return try deleteView(name, invocation.global, context)
        }
    }

    // MARK: - Commands

    private static func list(_ options: ListOptions, _ global: GlobalOptions, _ context: CLIContext) throws -> CLIOutput {
        // Build the expression before touching the file, so a malformed `--filter` is
        // reported as such even when there is no tasks.txt to read.
        let expression = try TaskFilter.expression(for: options, today: context.today, calendar: context.calendar)

        let file = tasksFile(global, context)
        // A missing file is an empty task list, not a failure — `list` must never be the
        // command that creates state.
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            return CLIOutput(stdout: global.json ? encode(["tasks": []]) : "")
        }
        let lines = TasksDocument.parse(text)
        let indices = TaskFilter.matchingIndices(in: lines, matching: expression,
                                                 includeDone: options.includeDone)
        return render(lines, indices: indices, json: global.json)
    }

    /// The one place `list`-shaped output is produced, so `view run` cannot drift from it.
    private static func render(_ lines: [TaskLine], indices: [Int], json: Bool) -> CLIOutput {
        let identities = PluginSnapshotBuilder.identityMap(for: lines)
        if json {
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
        // owns the decision. This is deliberately unlike the GUI's confirm-before-delete —
        // and it is trash.txt that makes it safe: the task is recoverable, not destroyed.
        let handle = TaskHandle(generation: snapshot.generation, index: index)
        _ = try store.trashTask(handle, deletedYMD: todayYMD(context),
                                expectedGeneration: snapshot.generation)

        return CLIOutput(stdout: global.json
            ? encode(["id": id, "deleted": true, "trashed": true, "title": title])
            : "deleted \(id)  \(title)  (moved to trash.txt)\n")
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

    // MARK: - focus

    /// Focus is single-valued across the whole file. The clear-others half of that is not
    /// reimplemented here: `TasksDocument.setFocus` is the same enforcement the GUI's
    /// `TaskStore.toggleFocus()` relies on, so the CLI cannot invent a second answer to
    /// "how many tasks may be focused at once".
    private static func focus(_ target: String?, _ global: GlobalOptions, _ context: CLIContext) throws -> CLIOutput {
        let (store, snapshot) = try openForWriting(global, context)

        var index: Int?
        var id = ""
        var title = ""
        if let target {
            let located = try locate(target, in: snapshot.lines)
            index = located.index
            id = located.id
            title = snapshot.lines[located.index].title
        }

        let updated = TasksDocument.setFocus(snapshot.lines, onIndex: index)
        // Re-focusing the already-focused task, or clearing when nothing is focused, is a
        // no-op — and a no-op must not rewrite the file, bump its generation, or hand a
        // watching GUI a change event for nothing.
        let changed = TasksDocument.serialize(updated) != TasksDocument.serialize(snapshot.lines)
        if changed {
            _ = try store.save(lines: updated, expectedGeneration: snapshot.generation)
        }

        guard target != nil else {
            return CLIOutput(stdout: global.json
                ? encode(["focused": false, "cleared": true, "changed": changed])
                : (changed ? "focus cleared\n" : "no task was focused\n"))
        }
        return CLIOutput(stdout: global.json
            ? encode(["id": id, "title": title, "focused": true, "changed": changed])
            : "focus \(id)  \(title)\n")
    }

    // MARK: - Saved views

    private static func saveView(_ options: SaveViewOptions, _ global: GlobalOptions,
                                 _ context: CLIContext) throws -> CLIOutput {
        let name = try SavedViewStore.validated(name: options.name)
        // Validate before persisting. A stored view that cannot run is worse than no view:
        // it fails later, somewhere else, in whatever script depends on it.
        _ = try TaskQuery.parse(options.query, today: context.today, calendar: context.calendar)

        let file = viewsFile(global, context)
        var views = try SavedViewStore.load(from: file)
        let replaced: Bool

        if let existing = SavedViewStore.index(of: name, in: views) {
            guard options.force else { throw SavedViewsError.duplicateName(views[existing].name) }
            // Keep the original creation date — replacing the query does not make this a
            // different view, and the date records when the name started existing.
            views[existing] = SavedView(name: name, query: options.query,
                                        createdYMD: views[existing].createdYMD)
            replaced = true
        } else {
            views.append(SavedView(name: name, query: options.query, createdYMD: todayYMD(context)))
            replaced = false
        }
        try SavedViewStore.save(views, to: file)

        return CLIOutput(stdout: global.json
            ? encode(["name": name, "query": options.query, "saved": true, "replaced": replaced])
            : "\(replaced ? "replaced" : "saved") view \(name)  \(options.query)\n")
    }

    private static func listViews(_ global: GlobalOptions, _ context: CLIContext) throws -> CLIOutput {
        let views = try SavedViewStore.load(from: viewsFile(global, context))
        if global.json {
            let payload = views.map { ["name": $0.name, "query": $0.query, "createdYMD": $0.createdYMD] }
            return CLIOutput(stdout: encode(["views": payload]))
        }
        guard !views.isEmpty else { return CLIOutput(stdout: "") }
        let width = views.map(\.name.count).max() ?? 0
        let rows = views.map { view in
            view.name.padding(toLength: max(view.name.count, width), withPad: " ", startingAt: 0)
                + "  " + view.query
        }
        return CLIOutput(stdout: rows.joined(separator: "\n") + "\n")
    }

    /// Runs the stored query text through the ordinary `list` path — same filtering, same
    /// columns, same JSON shape. The query is re-parsed here rather than at save time, so
    /// a view holding `due:today` means today, every time it runs.
    private static func runView(_ options: RunViewOptions, _ global: GlobalOptions,
                                _ context: CLIContext) throws -> CLIOutput {
        let views = try SavedViewStore.load(from: viewsFile(global, context))
        guard let view = SavedViewStore.find(options.name, in: views) else {
            throw SavedViewsError.notFound(options.name)
        }
        return try list(ListOptions(filter: view.query, includeDone: options.includeDone), global, context)
    }

    private static func deleteView(_ name: String, _ global: GlobalOptions,
                                   _ context: CLIContext) throws -> CLIOutput {
        let file = viewsFile(global, context)
        var views = try SavedViewStore.load(from: file)
        guard let index = SavedViewStore.index(of: name, in: views) else {
            throw SavedViewsError.notFound(name)
        }
        let removed = views.remove(at: index)
        try SavedViewStore.save(views, to: file)

        return CLIOutput(stdout: global.json
            ? encode(["name": removed.name, "deleted": true])
            : "deleted view \(removed.name)\n")
    }

    // MARK: - File access

    private static func viewsFile(_ global: GlobalOptions, _ context: CLIContext) -> URL {
        SavedViewStore.url(besideTasksFile: tasksFile(global, context))
    }

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
      delete <id-prefix>       Move a task to trash.txt — no confirmation, the caller owns this
      focus <id-prefix>        Make this the one focused task (clears focus everywhere else)
      focus --clear            Clear focus with no replacement
      view save <name> <query> Store a query under a name (--force replaces an existing one)
      view list                Print saved view names and their queries
      view run <name>          List the tasks a saved view selects
      view delete <name>       Forget a saved view

    OPTIONS
      --due <date>             2026-10-10, today, tomorrow, 3d, 2w, mon…  (add only)
      --project <name>         Attach +name          (add: repeatable; list: filter)
      --context <name>         Attach @name          (add: repeatable; list: filter)
      --note <text>            Attach note:"text"    (add only)
      --query <text>           Filter by title/note substring, case-insensitive (list only)
      --filter <query>         Filter with the query language below (list only)
      --all                    Include completed tasks (list, view run)
      --json                   Machine-readable output on stdout; errors as JSON on stderr
      --dir <path>             Directory holding tasks.txt
      --help, --version

    FILTER QUERIES
      Terms                    +list  @tag  due:<date>  done:true|false  focus:true|false
                               q:word, or a bare word — substring of the title and note
      Comparisons              due:2026-10-10  due:<today  due:<=1w  due:>mon  due:>=3d
                               A task with no due: matches no due: comparison at all.
      Operators                AND (or just a space), OR, NOT (or a leading -), ( )
                               NOT binds tightest, then AND, then OR. Case-insensitive.
      Example                  txtnimal list --filter "done:false (+work OR @home) due:<=1w"

      --filter combines with --project/--context/--query: every filter given must match.
      A query mentioning done: overrides the default of hiding completed tasks.

    TASK FILE RESOLUTION (first match wins)
      1. --dir <path>
      2. $TXTNIMAL_DIR
      3. the txtnimal app's saved file/folder, if you have moved it in the GUI
      4. ~/Documents/txtnimal/tasks.txt

    IDS
      Every task carries a short id: token — stamped on creation, and backfilled into any
      older line the next time its file is saved. A line that has not been saved since is
      addressed by the content-derived legacy-… id the app's plugin host uses instead.
      Run `txtnimal list` to see the current id for any task. Any unique prefix works.

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
