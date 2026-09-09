import AppKit
import SwiftUI
import TermeowKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var fonts: [MonospacedFontChoice] = []

    var body: some View {
        Form {
            Section("Terminal") {
                Picker("Color Scheme", selection: colorSchemeID) {
                    ForEach(TerminalColorSchemeID.allCases) { id in
                        Text(LocalizedStringKey(id.title)).tag(id)
                    }
                }
                Picker("Font", selection: fontName) {
                    Text("System Monospaced").tag("")
                    if !model.typography.fontName.isEmpty,
                       !fonts.contains(where: { $0.postScriptName == model.typography.fontName }) {
                        Text(model.typography.fontName).tag(model.typography.fontName)
                    }
                    Divider()
                    ForEach(fonts) { font in
                        Text(font.displayName).tag(font.postScriptName)
                    }
                }
                LabeledContent("Size") {
                    Stepper(value: fontSize, in: TerminalTypography.minFontSize...TerminalTypography.maxFontSize, step: 1) {
                        Text(verbatim: "\(Int(model.typography.fontSize.rounded())) pt")
                            .monospacedDigit()
                    }
                }
                LabeledContent("Line Height") {
                    HStack(spacing: 10) {
                        Slider(
                            value: lineHeight,
                            in: TerminalTypography.minLineHeight...TerminalTypography.maxLineHeight,
                            step: 0.05
                        )
                        Text(verbatim: String(format: "%.2f", model.typography.lineHeight))
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                LabeledContent("Scrollback Lines") {
                    Stepper(
                        value: scrollbackLines,
                        in: TerminalScrollback.minLines...TerminalScrollback.maxLines,
                        step: 500
                    ) {
                        Text(model.scrollback.lines, format: .number.grouping(.automatic))
                            .monospacedDigit()
                            .frame(minWidth: 64, alignment: .trailing)
                    }
                }
                .help("Limits how many off-screen terminal lines are retained.")
                Button("Reset to Default") {
                    model.setTypography(.default)
                    model.setColorSchemeID(.dark)
                    model.setScrollback(.default)
                }
                .disabled(
                    model.typography == .default
                        && model.colorSchemeID == .dark
                        && model.scrollback == .default
                )
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear {
            fonts = MonospacedFontChoice.all
        }
    }

    private var colorSchemeID: Binding<TerminalColorSchemeID> {
        Binding(
            get: { model.colorSchemeID },
            set: { model.setColorSchemeID($0) }
        )
    }

    private var fontName: Binding<String> {
        Binding(
            get: { model.typography.fontName },
            set: { name in
                var value = model.typography
                value.fontName = name
                model.setTypography(value)
            }
        )
    }

    private var fontSize: Binding<Double> {
        Binding(
            get: { model.typography.fontSize },
            set: { size in
                var value = model.typography
                value.fontSize = size
                model.setTypography(value)
            }
        )
    }

    private var lineHeight: Binding<Double> {
        Binding(
            get: { model.typography.lineHeight },
            set: { height in
                var value = model.typography
                value.lineHeight = height
                model.setTypography(value)
            }
        )
    }

    private var scrollbackLines: Binding<Int> {
        Binding(
            get: { model.scrollback.lines },
            set: { model.setScrollback(TerminalScrollback(lines: $0)) }
        )
    }
}

private struct MonospacedFontChoice: Hashable, Identifiable {
    var postScriptName: String
    var displayName: String
    var id: String { postScriptName }

    static var all: [MonospacedFontChoice] {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        var seen = Set<String>()
        var choices: [MonospacedFontChoice] = []
        for name in names {
            guard let font = NSFont(name: name, size: 13) else { continue }
            let traits = NSFontManager.shared.traits(of: font)
            if traits.contains(.boldFontMask) || traits.contains(.italicFontMask) { continue }
            let displayName = font.displayName ?? name
            guard seen.insert(displayName).inserted else { continue }
            choices.append(MonospacedFontChoice(postScriptName: name, displayName: displayName))
        }
        return choices.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}
