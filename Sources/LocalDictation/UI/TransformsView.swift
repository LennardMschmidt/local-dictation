import AppKit
import DictationCore
import SwiftUI

/// Transforms, laid out like Wispr Flow's page: switch and shortcut hint at the top, the banner,
/// auto apply, and the transform cards with their ⌥ shortcuts.
struct TransformsView: View {
    @ObservedObject var model: AppModel
    @State private var editing: Transform?
    @State private var confirmReset = false
    @State private var showingTry = false
    @State private var showingHowItWorks = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                header
                TransformsBanner(tryIt: { showingTry = true }, howItWorks: { showingHowItWorks = true })
                autoApply
                HStack(alignment: .center) {
                    Text("My Transforms").font(.system(size: 21, design: .serif))
                    Spacer()
                    Button { confirmReset = true } label: {
                        Label("Reset to defaults", systemImage: "arrow.counterclockwise").font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 13)
                    Button { editing = Transform(name: "", instruction: "") } label: {
                        Text("Create New")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 18)
                            .frame(height: 35)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.text))
                            .foregroundStyle(Theme.panel)
                    }
                    .buttonStyle(.plain)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18),
                                    GridItem(.flexible(), spacing: 18)], spacing: 18) {
                    ForEach(Array(model.settings.transforms.enumerated()), id: \.element.id) { index, transform in
                        TransformCard(shortcut: index < 9 ? "\(index + 1)" : nil, title: transform.name,
                                      subtitle: transform.summary.isEmpty ? "Custom transform shortcut" : transform.summary) {
                            editing = transform
                        }
                    }
                    TransformCard(shortcut: nil, title: "Create your own", subtitle: "Write your own prompt", plus: true) {
                        editing = Transform(name: "", instruction: "")
                    }
                }
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 38)
            // A centred column, like Wispr Flow's Transforms page.
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $editing) { transform in
            TransformEditor(model: model, transform: transform) { editing = nil }
        }
        .sheet(isPresented: $showingTry) { TryTransformSheet(model: model) { showingTry = false } }
        .sheet(isPresented: $showingHowItWorks) { HowTransformsWork { showingHowItWorks = false } }
        .confirmationDialog("Are you sure you want to reset?", isPresented: $confirmReset) {
            Button("Yes", role: .destructive) {
                model.settings.transforms = Transform.presets
                model.settings.autoTransformID = ""
                model.settings.autoTransformEnabled = false
            }
        } message: {
            Text("Built-in transforms are restored to their defaults, and all custom transforms are removed.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Transforms").font(.system(size: 22, weight: .medium))
            Text("Beta")
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.text))
                .foregroundStyle(Theme.panel)
            Spacer()
            Text("Opt in").font(.system(size: 13))
            InfoButton("Switches Transforms on. While it is on, ⌥1 to ⌥9 apply the transform with that number: to the selected text, or to your last dictation when nothing is selected. ⌥O shows what the last transform changed. While it is off, these shortcuts do nothing.")
            Toggle("", isOn: $model.settings.transformsEnabled).labelsHidden().toggleStyle(.switch)
            HStack(spacing: 4) {
                KeyCapView(label: "⌥ Opt")
                KeyCapView(label: "o")
                Text("to view changes").font(.system(size: 12))
            }
            .padding(.horizontal, 8)
            .frame(height: 35)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().strokeBorder(Theme.border))
        }
    }

    private var autoApply: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Auto Apply After Dictation").font(.system(size: 13, weight: .medium))
                Text("Run a transform on everything you dictate, automatically.").font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            InfoButton("When this is on, every dictation runs through the chosen transform before it is pasted. It takes about a second longer.")
            SelectBox(options: model.settings.transforms.map { ($0.id.uuidString, $0.name.isEmpty ? "Unnamed" : $0.name, nil) },
                      selection: $model.settings.autoTransformID, placeholder: "Choose a transform", width: 226)
                .disabled(!model.settings.autoTransformEnabled)
                .opacity(model.settings.autoTransformEnabled ? 1 : 0.55)
            .help(model.settings.autoTransformEnabled ? "" : "Turn on Auto Apply to choose a transform.")
            Toggle("", isOn: $model.settings.autoTransformEnabled).labelsHidden().toggleStyle(.switch)
        }
    }
}

struct KeyCapView: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 8)
            .frame(height: 23)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.selection))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border))
    }
}

/// The dark banner with the app icons, like Wispr Flow's "Transform works anywhere you write".
private struct TransformsBanner: View {
    let tryIt: () -> Void
    let howItWorks: () -> Void

    /// Apps whose icons decorate the banner, when installed.
    private static let apps = ["com.anthropic.claudefordesktop", "com.microsoft.teams2", "md.obsidian", "com.apple.Notes",
                               "com.microsoft.Outlook", "com.microsoft.VSCode", "com.apple.mail"]

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 13)
                .fill(LinearGradient(colors: [Color(red: 0.20, green: 0.27, blue: 0.33), Color(red: 0.10, green: 0.08, blue: 0.07),
                                              Color(red: 0.36, green: 0.35, blue: 0.30)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            icons
            VStack(alignment: .leading, spacing: 9) {
                Text("Transform works anywhere you write")
                    .font(.system(size: 23, design: .serif))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: 440, alignment: .leading)
                Text("Apply a Transform to rewrite, clean up, or\nrestructure text after you dictate.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.9))
                HStack(spacing: 20) {
                    Button(action: tryIt) {
                        Text("Try it out")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 20)
                            .frame(height: 36)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.94)))
                    }
                    .buttonStyle(.plain)
                    Button("How it works", action: howItWorks)
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                }
                .padding(.top, 13)
            }
            .padding(.horizontal, 40)
        }
        .frame(height: 176)
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }

    private var icons: some View {
        let icons = Self.apps.compactMap { id -> NSImage? in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
        let positions: [CGPoint] = [CGPoint(x: 0.76, y: 0.12), CGPoint(x: 0.9, y: 0.12), CGPoint(x: 0.7, y: 0.5),
                                    CGPoint(x: 0.83, y: 0.5), CGPoint(x: 0.96, y: 0.5), CGPoint(x: 0.76, y: 0.9),
                                    CGPoint(x: 0.9, y: 0.9)]
        return GeometryReader { geometry in
            ForEach(Array(icons.prefix(positions.count).enumerated()), id: \.offset) { index, icon in
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 42, height: 42)
                    .padding(8)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.25)))
                    .position(x: geometry.size.width * positions[index].x, y: geometry.size.height * positions[index].y)
            }
        }
    }
}

private struct TransformCard: View {
    let shortcut: String?
    let title: String
    let subtitle: String
    var plus = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                if let shortcut {
                    HStack(spacing: 3) {
                        KeyCapView(label: "⌥ Opt")
                        KeyCapView(label: shortcut)
                    }
                } else if plus {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Theme.selection))
                } else {
                    Color.clear.frame(height: 23)
                }
                Text(title.isEmpty ? "Unnamed" : title).font(.system(size: 14, weight: .medium)).padding(.top, 9)
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(23)
            .frame(maxWidth: .infinity, minHeight: 144, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 13).fill(hovering ? Theme.card : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Create or edit a transform, laid out like Wispr Flow's editor: name, shortcut, description and
/// an example on the left; shortcut and prompt on the right. Changes to an existing transform
/// are saved as they are typed.
struct TransformEditor: View {
    @ObservedObject var model: AppModel
    @State var transform: Transform
    let done: () -> Void
    /// The transform as it was when the editor opened, for Reset of a custom transform.
    @State private var original: Transform?
    @State private var confirmDelete = false
    @State private var tryResult: (original: String, result: String)?
    @State private var trying = false

    private static let trySample = "so I wanted to quickly say that the demo tomorrow is moved to three and uh we also need to send the slides to Mia before"

    private var isNew: Bool { !model.settings.transforms.contains { $0.id == transform.id } }
    private var index: Int? { model.settings.transforms.firstIndex { $0.id == transform.id } }
    private var position: Int { index ?? model.settings.transforms.count }
    private var preset: Transform? { Transform.presets.first { $0.id == transform.id } }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView { left.padding(.horizontal, 40).padding(.vertical, 44) }
                .frame(width: 380)
                .background(Theme.panel)
            ScrollView { right.padding(.horizontal, 28).padding(.vertical, 32) }
                .frame(maxWidth: .infinity)
                .background(Theme.card.opacity(0.5))
        }
        .frame(width: 960, height: 660)
        .onAppear { if original == nil { original = transform } }
        .onChange(of: transform) { _, changed in
            guard !isNew, let index else { return }
            model.settings.transforms[index] = changed
        }
        .confirmationDialog("Delete \(transform.name.isEmpty ? "this transform" : transform.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                model.settings.transforms.removeAll { $0.id == transform.id }
                done()
            }
        }
    }

    private var left: some View {
        VStack(alignment: .leading, spacing: 22) {
            TextField("Name your transform", text: $transform.name, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 32, design: .serif))
            HStack(spacing: 5) {
                if position < 9 {
                    KeyCapView(label: "⌥ Opt")
                    KeyCapView(label: "\(position + 1)")
                    Text("to use").font(.system(size: 15))
                } else {
                    Text("No shortcut").font(.system(size: 15)).foregroundStyle(Theme.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().strokeBorder(Theme.border))
            TextField("What does this transform do?", text: $transform.summary, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .lineSpacing(5)
            Divider().overlay(Theme.border)
            Text("Example of transformed text").font(.system(size: 17, weight: .medium))
            if let example = tryResult ?? Transform.examples[transform.id] {
                ExampleDiff(original: example.original, result: example.result)
            } else {
                Text("Try this transform on a sample sentence to see what it changes.")
                    .font(.system(size: 14)).foregroundStyle(Theme.secondary)
            }
            if preset == nil {
                Button { tryIt() } label: {
                    Label(trying ? "Working…" : "Try it on a sample", systemImage: "wand.and.stars")
                        .font(.system(size: 14, weight: .medium))
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.selection))
                }
                .buttonStyle(.plain)
                .disabled(trying || transform.instruction.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var right: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 22) {
                Spacer()
                if isNew {
                    Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                    Button { create() } label: {
                        Text("Create")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.panel)
                            .padding(.horizontal, 16).frame(height: 34)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.text))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canCreate)
                    .opacity(canCreate ? 1 : 0.4)
                } else {
                    Text("Autosave On").font(.system(size: 14)).foregroundStyle(Theme.secondary)
                    Button { reset() } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise").font(.system(size: 16, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .help(preset == nil ? "Back to how it was when you opened it" : "Back to the built-in version")
                    Button("Done", action: done).keyboardShortcut(.cancelAction)
                }
            }

            EditorCard(title: "Choose a keyboard shortcut") {
                HStack(spacing: 5) {
                    if position < 9 {
                        KeyCapView(label: "⌥ Opt")
                        KeyCapView(label: "\(position + 1)")
                    } else {
                        Text("No shortcut").foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    if !isNew {
                        Menu {
                            ForEach(0..<min(9, model.settings.transforms.count), id: \.self) { slot in
                                Button("⌥\(slot + 1)\(slot == position ? "  (current)" : "")") { move(to: slot) }
                            }
                        } label: {
                            Image(systemName: "pencil").font(.system(size: 16))
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Change the shortcut")
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 46)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                Text("Changing the number moves the transform to that place; the others shift by one.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }

            EditorCard(title: "Customize prompt. (This is the instruction the local model follows)") {
                TextEditor(text: $transform.instruction)
                    .font(.system(size: 16))
                    .lineSpacing(5)
                    .scrollContentBackground(.hidden)
                    .padding(14)
                    .frame(minHeight: 280)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                    .overlay(alignment: .topLeading) {
                        if transform.instruction.isEmpty {
                            Text("How do you want this Transform to change your text?")
                                .font(.system(size: 16)).foregroundStyle(Theme.secondary)
                                .padding(19).allowsHitTesting(false)
                        }
                    }
            }

            if !isNew {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Delete transform", systemImage: "trash").font(.system(size: 14, weight: .medium)).foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var canCreate: Bool {
        !transform.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !transform.instruction.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func create() {
        model.settings.transforms.append(transform)
        done()
    }

    private func reset() {
        if let preset {
            transform = preset
        } else if let original {
            transform = original
        }
        tryResult = nil
    }

    private func move(to slot: Int) {
        guard let index, slot != index else { return }
        var list = model.settings.transforms
        let item = list.remove(at: index)
        list.insert(item, at: slot)
        model.settings.transforms = list
    }

    private func tryIt() {
        guard let run = model.runTransform else { return }
        trying = true
        let instruction = transform.instruction
        Task {
            let result = (try? await run(Self.trySample, instruction)) ?? "The local AI model did not answer."
            await MainActor.run {
                tryResult = (Self.trySample, result)
                trying = false
            }
        }
    }
}

private struct EditorCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 16, weight: .medium))
            content
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
    }
}

/// Removed words struck through, added words highlighted in green, like Wispr's example.
private struct ExampleDiff: View {
    let original: String
    let result: String

    var body: some View {
        Text(attributed)
            .font(.system(size: 15))
            .lineSpacing(8)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    /// Word by word when most words stay; for a rewrite, the whole original struck through and
    /// then the whole result, since interleaved words would be hard to read.
    private var parts: [WordDiff.Part] {
        let parts = WordDiff.diff(original, result)
        let kept = parts.filter { $0.kind == .same }.map(\.text).joined().count
        guard Double(kept) < Double(result.count) * 0.5 else { return parts }
        return [WordDiff.Part(text: original, kind: .removed), WordDiff.Part(text: "\n\n", kind: .same),
                WordDiff.Part(text: result, kind: .added)]
    }

    private var attributed: AttributedString {
        var text = AttributedString()
        for part in parts {
            var piece = AttributedString(part.text)
            switch part.kind {
            case .same:
                piece.foregroundColor = Theme.text
            case .removed:
                piece.strikethroughStyle = .single
                piece.foregroundColor = Theme.secondary
                piece.backgroundColor = Theme.card
            case .added:
                piece.foregroundColor = Theme.tealDark
                piece.backgroundColor = Theme.tealPale
            }
            text += piece
        }
        return text
    }
}

/// Try a transform on sample text inside the app.
private struct TryTransformSheet: View {
    @ObservedObject var model: AppModel
    let done: () -> Void
    @State private var sample = "make a blog post about our new cold brew coffee, mention its smooth and less acidic, keep it casual and fun"
    @State private var output = ""
    @State private var chosen: UUID?
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try it out").font(.system(size: 20, design: .serif))
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Theme.sectionLabel("Original")
                    TextEditor(text: $sample)
                        .font(.system(size: 10))
                        .frame(height: 136)
                        .scrollContentBackground(.hidden)
                        .padding(5)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Theme.sectionLabel(chosenTransform?.name ?? "Result")
                    ScrollView {
                        Text(running ? "Working…" : (output.isEmpty ? "The transformed text appears here." : output))
                            .font(.system(size: 10))
                            .foregroundStyle(output.isEmpty ? Theme.secondary : Theme.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 147)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.tealPale.opacity(0.45)))
                }
            }
            HStack {
                Picker("Transform", selection: $chosen) {
                    ForEach(model.settings.transforms) { transform in
                        Text(transform.name.isEmpty ? "Unnamed" : transform.name).tag(Optional(transform.id))
                    }
                }
                .frame(width: 191)
                Button("Apply") { apply() }.disabled(running || chosenTransform == nil || sample.isEmpty)
                Spacer()
                Button("Done", action: done).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 559)
        .background(Theme.panel)
        .onAppear { chosen = model.settings.transforms.first?.id }
    }

    private var chosenTransform: Transform? { model.settings.transforms.first { $0.id == chosen } }

    private func apply() {
        guard let transform = chosenTransform, let run = model.runTransform else { return }
        running = true
        Task {
            let result: String
            do {
                result = try await run(sample, transform.instruction)
            } catch {
                result = "The local AI model did not answer: \(error)"
            }
            await MainActor.run {
                output = result
                running = false
            }
        }
    }
}

private struct HowTransformsWork: View {
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            (Text("Transform").foregroundStyle(Theme.tealDark) + Text(" your text to\n") + Text("sound however you want").italic())
                .font(.system(size: 20, design: .serif))
            VStack(alignment: .leading, spacing: 8) {
                step("1", "Select text in any app, or dictate something.")
                step("2", "Press ⌥1 for your first transform, ⌥2 for the second, and so on. Without a selection the last dictation is transformed.")
                step("3", "The text is replaced. Press ⌥O to see what changed.")
                step("4", "Or hold ctrl + fn and say what should happen, like \"make this friendlier\" or a transform's name.")
            }
            Text("Reword for clarity · Make more concise · Reorder for readability · Add structure · Maintain your tone · Translate · Optimize text for an AI")
                .font(.callout)
                .foregroundStyle(Theme.secondary)
            HStack { Spacer(); Button("Got it", action: done).keyboardShortcut(.defaultAction) }
        }
        .padding(22)
        .frame(width: 410)
        .background(Theme.panel)
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number).font(.system(size: 9, weight: .bold)).frame(width: 18, height: 18).background(Circle().fill(Theme.tealPale))
            Text(text).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
