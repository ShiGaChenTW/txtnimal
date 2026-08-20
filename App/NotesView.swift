import SwiftUI
import txtnimalCore

/// Independent notes page (⌘7). Presentation kind comes from capture wrappers;
/// `#tag` chips filter and optionally group. `n` opens the same quick-add slot tasks use.
struct NotesView: View {
    @EnvironmentObject var store: TaskStore
    @State private var addVisible = false
    @State private var addText = ""
    @FocusState private var addFocused: Bool
    @State private var editKind: NoteKind = .plain
    @State private var editTags = ""
    @State private var editBody = ""
    @State private var pendingDelete: Note?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !store.allNoteTags.isEmpty { tagBar }
            if addVisible { addRow }
            if store.displayedNotes().isEmpty && !addVisible {
                emptyState
            } else if store.noteGroupByTag && store.noteTagFilter == nil {
                groupedList
            } else {
                flatList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: store.requestInlineAddNote) { req in
            if req { activateInlineAdd() }
        }
        .onChange(of: store.requestDeleteNote) { req in
            if req {
                pendingDelete = store.displayedNotes().first { $0.id == store.noteCursorID }
                store.requestDeleteNote = false
            }
        }
        .onAppear {
            if store.requestInlineAddNote { activateInlineAdd() }
        }
        .onDisappear {
            if addVisible { store.inlineAddActive = false }
            store.noteConfirmOpen = false
        }
        .sheet(isPresented: Binding(
            get: { store.editingNoteID != nil },
            set: { if !$0 { store.editingNoteID = nil } }
        )) { editSheet }
        .onChange(of: pendingDelete?.id) { store.noteConfirmOpen = $0 != nil }
        .confirmationDialog("刪除筆記", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("刪除", role: .destructive) {
                store.deleteSelectedNote()
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("「\(pendingDelete?.title ?? "")」會從 notes.txt 移除。")
        }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("筆記").foregroundColor(Theme.fg)
                Text("-條列-  \"引言\"  |區塊|  ·  yahoo,https://… 變超連結  ·  GitHub 顯示 Github:owner/repo")
                    .font(Theme.monoSmall).foregroundColor(Theme.dim)
            }
            Spacer()
            Button(store.noteGroupByTag ? "關閉分組" : "依 #Tag 分組") {
                store.noteGroupByTag.toggle()
            }
            .buttonStyle(.plain).font(Theme.monoSmall)
            .foregroundColor(store.noteGroupByTag ? store.accent : Theme.dim)
        }
        .font(Theme.mono)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var tagBar: some View {
        FlowLayout(spacing: 8) {
            Text("TAG").font(Theme.monoSmall).foregroundColor(Theme.cyan.opacity(0.75))
                .frame(minWidth: 38, alignment: .leading)
            ForEach(store.allNoteTags, id: \.self) { tag in
                let active = store.noteTagFilter == tag
                Text("#\(tag)").font(store.tagFont)
                    .foregroundColor(active ? Theme.bg : Theme.cyan)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Rectangle().fill(active ? Theme.cyan : Theme.cyan.opacity(0.13)))
                    .contentShape(Rectangle())
                    .onTapGesture { store.toggleNoteTagFilter(tag) }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("還沒有筆記").foregroundColor(Theme.dim)
            Text("按 n 或 ⌥N 快速輸入。-條列-  \"引言\"  |區塊|").font(Theme.monoSmall)
                .foregroundColor(Theme.dim.opacity(0.7))
        }
        .font(Theme.mono)
        .padding(.horizontal, 16).padding(.top, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var flatList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(store.displayedNotes()) { note in
                    noteRow(note)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var groupedList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(store.groupedNotes(), id: \.tag) { group in
                    sectionHeader(group.tag)
                    ForEach(group.notes) { note in
                        noteRow(note)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sectionHeader(_ tag: String) -> some View {
        Text(tag.isEmpty ? "未標籤" : "#\(tag)")
            .font(Theme.monoSmall)
            .foregroundColor(tag.isEmpty ? Theme.dim : Theme.cyan)
            .padding(.horizontal, 16)
            .padding(.top, store.density.sectionTop)
            .padding(.bottom, 6)
    }

    private func noteRow(_ note: Note) -> some View {
        let selected = store.noteCursorID == note.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(kindLabel(note.kind))
                    .font(Theme.monoSmall)
                    .foregroundColor(kindColor(note.kind))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .overlay(Rectangle().stroke(kindColor(note.kind).opacity(0.55)))
                Text(note.created).font(Theme.monoSmall).foregroundColor(Theme.dim)
                ForEach(note.tags, id: \.self) { tag in
                    Text("#\(tag)").font(store.tagFont).foregroundColor(Theme.cyan)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { store.noteCursorID = note.id }
            .onTapGesture(count: 2) {
                store.noteCursorID = note.id
                store.startEditingNote()
            }
            noteBody(note)
        }
        .padding(.horizontal, 16).padding(.vertical, store.density.rowPad + 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.cursorBg : Color.clear)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Theme.dim).frame(width: 3) }
        }
    }

    @ViewBuilder private func noteBody(_ note: Note) -> some View {
        switch note.kind {
        case .plain:
            NoteLinkText(text: note.body, font: store.taskFont, color: Theme.fg)
        case .list:
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(listItems(note.body).enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("·").foregroundColor(Theme.cyan)
                        NoteLinkText(text: item, font: store.taskFont, color: Theme.fg)
                    }
                    .font(store.taskFont)
                }
            }
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(Theme.yellow).frame(width: 3)
                NoteLinkText(text: note.body, font: store.taskFont, color: Theme.fg, italic: true)
            }
        case .block:
            NoteLinkText(text: note.body, font: Theme.mono, color: Theme.fg)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel)
                .overlay(Rectangle().stroke(Theme.border))
        }
    }

    private func listItems(_ body: String) -> [String] {
        body.split(whereSeparator: \.isNewline).map { line in
            var s = String(line).trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("- ") { s = String(s.dropFirst(2)) }
            return s
        }.filter { !$0.isEmpty }
    }

    private func kindLabel(_ kind: NoteKind) -> String {
        switch kind {
        case .plain: return "段落"
        case .list: return "條列"
        case .quote: return "引言"
        case .block: return "區塊"
        }
    }

    private func kindColor(_ kind: NoteKind) -> Color {
        switch kind {
        case .plain: return Theme.dim
        case .list: return Theme.cyan
        case .quote: return Theme.yellow
        case .block: return Theme.mag
        }
    }

    // MARK: inline add

    private var previewKind: String {
        guard let kind = NoteCapture.parse(addText)?.kind else { return "" }
        return kindLabel(kind)
    }

    private func activateInlineAdd() {
        addVisible = true
        store.inlineAddActive = true
        store.requestInlineAddNote = false
        DispatchQueue.main.async { addFocused = true }
    }

    private var addRow: some View {
        HStack(spacing: Theme.isTerminal ? 0 : 10) {
            if Theme.isTerminal {
                Text("❯ ").foregroundColor(Theme.green).fontWeight(.bold)
            } else {
                Text("+").foregroundColor(Theme.green)
            }
            ZStack(alignment: .leading) {
                if addText.isEmpty {
                    Text("新增筆記…  -條列-  \"引言\"  |區塊|  #tag")
                        .foregroundColor(Theme.dim.opacity(0.45))
                }
                TerminalInputField(text: $addText, onSubmit: submitInlineAdd, onCancel: closeInlineAdd,
                                   onFocusChange: { focused in
                                       store.inlineAddActive = focused
                                   })
                .frame(height: 20)
            }
            if !previewKind.isEmpty {
                Text(previewKind).font(Theme.monoSmall).foregroundColor(Theme.dim)
            }
        }
        .font(Theme.mono)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, store.density.rowPad)
        .background(Theme.isTerminal ? Theme.bg : Theme.cursorBg)
        .overlay(alignment: .leading) {
            if !Theme.isTerminal { Rectangle().fill(Theme.green).frame(width: 3) }
        }
        .onAppear { addFocused = true }
    }

    private func submitInlineAdd() {
        let text = addText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { store.addNote(from: text) }
        addText = ""
        addFocused = true
    }

    private func closeInlineAdd() {
        addText = ""
        addFocused = false
        addVisible = false
        store.inlineAddActive = false
        store.ensureNoteCursor()
    }

    // MARK: sheets

    private var editingNote: Note? {
        store.notes.first { $0.id == store.editingNoteID }
    }

    private var editSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("編輯筆記").font(Theme.monoSmall).foregroundColor(Theme.dim).tracking(1.2)
            Picker("呈現", selection: $editKind) {
                Text("段落").tag(NoteKind.plain)
                Text("條列").tag(NoteKind.list)
                Text("引言").tag(NoteKind.quote)
                Text("區塊").tag(NoteKind.block)
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 4) {
                Text("#Tag").font(Theme.monoSmall).foregroundColor(Theme.dim)
                TextField("work idea", text: $editTags)
                    .textFieldStyle(.plain)
                    .padding(7).background(Theme.panel).overlay(Rectangle().stroke(Theme.border))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("筆記內容").font(Theme.monoSmall).foregroundColor(Theme.dim)
                TextEditor(text: $editBody)
                    .font(Theme.mono).foregroundColor(Theme.fg)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 180)
                    .padding(6).background(Theme.panel).overlay(Rectangle().stroke(Theme.border))
            }
            HStack {
                Spacer()
                Button("取消") { store.editingNoteID = nil }.keyboardShortcut(.cancelAction)
                Button("儲存") { commitEdit() }.keyboardShortcut(.defaultAction)
                    .disabled(editBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .font(Theme.mono).padding(20).frame(width: 520)
        .background(Theme.bg).foregroundColor(Theme.fg)
        .onAppear { loadEdit() }
        .onChange(of: store.editingNoteID) { _ in loadEdit() }
    }

    private func loadEdit() {
        guard let note = editingNote else { return }
        editKind = note.kind
        editTags = note.tags.map { "#\($0)" }.joined(separator: " ")
        editBody = note.body
    }

    private func commitEdit() {
        guard var note = editingNote else { return }
        note.kind = editKind
        note.body = editBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = NoteCapture.extractTags(from: editTags)
        note.tags = parsed.tags.isEmpty
            ? Note.normalizedTags(editTags.split(whereSeparator: { $0 == " " || $0 == "#" }).map(String.init))
            : parsed.tags
        store.updateNote(note)
        store.editingNoteID = nil
    }
}
