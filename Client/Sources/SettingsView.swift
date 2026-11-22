import GameController
import PortalPlayer
import SwiftUI

/// Device-wide settings in grouped glass (`§ screen-settings`): two columns on a regular-width iPad, one elsewhere. Saved at
/// once. The ceiling and the numbers level reach an open session as they change; size and frame rate apply the next time
/// the app connects (each group's footer says so).
struct SettingsView: View {
    let model: ClientModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var width
    @State private var confirmForget = false
    #if os(iOS)
    @State private var showsAcknowledgements = false
    #endif
    private var p: LookPalette { Theme.palette }

    private var twoColumns: Bool {
        #if os(iOS)
        width == .regular
        #else
        false
        #endif
    }
    private var columnWidth: CGFloat? {
        #if os(tvOS)
        1000
        #else
        twoColumns ? nil : 560
        #endif
    }

    var body: some View {
        @Bindable var model = model
        ZStack {
            Theme.color(p.background).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text(Strings.settingsTitle).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    Spacer()
                    #if !os(tvOS)
                    Button { dismiss() } label: { Text(Strings.done).font(.headline).padding(.horizontal, 20).frame(minHeight: 44) }
                        .buttonStyle(.portal(.button, fill: p.fill2, text: p.text))
                    #endif
                }
                .padding(.horizontal, 24).padding(.vertical, 16)
                ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if twoColumns {
                            HStack(alignment: .top, spacing: 24) {
                                VStack(alignment: .leading, spacing: 22) { device($model); picture($model); numbers($model); sound($model) }
                                VStack(alignment: .leading, spacing: 22) { controls($model); controller($model).id("controller"); touch($model); macs; about.id("about") }
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 22) {
                                device($model); picture($model); numbers($model); sound($model); controls($model); controller($model).id("controller"); touch($model); macs; about.id("about")
                            }
                        }
                    }
                    .frame(maxWidth: columnWidth)
                    .padding(.horizontal, 24).padding(.bottom, 32)
                    .frame(maxWidth: .infinity)
                }
                #if DEBUG
                .onAppear {
                    if let id = Automation.settingsScroll {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { proxy.scrollTo(id, anchor: .top) }
                    }
                }
                #endif
                }
            }
        }
        .foregroundStyle(Theme.color(p.text))
        .onChange(of: model.settings) { _, new in SavedSettings.save(new) }
        .onChange(of: model.settings.bitrateMbps) { model.applyLive() }
        .onChange(of: model.settings.statsLevel) { model.applyLive() }
        #if os(iOS)
        .sheet(isPresented: $showsAcknowledgements) { AcknowledgementsView() }
        #endif
        .confirmationDialog(Strings.forgetConfirmTitle, isPresented: $confirmForget, titleVisibility: .visible) {
            Button(Strings.forgetPairedMacs, role: .destructive) { Task { await model.resetStore() } }
            Button(Strings.cancel, role: .cancel) {}
        } message: {
            Text(Strings.forgetConfirmMessage)
        }
    }

    /// This device's name for the Macs: empty = the model's name -> `DeviceNameText`.
    private func device(_ m: Bindable<ClientModel>) -> some View {
        FormGroup(title: Strings.deviceGroup, footer: Strings.deviceNameFooter) {
            TextRow(label: Strings.deviceNameTitle, placeholder: Strings.deviceNamePlaceholder(), text: m.settings.deviceName)
        }
    }

    private func picture(_ m: Bindable<ClientModel>) -> some View {
        FormGroup(title: Strings.picture, footer: Strings.pictureFooter) {
            ChoiceRow(label: Strings.maxSize, note: Strings.sizeNote(model.sizeNote(for: model.gameState?.titleID)) ?? Strings.maxSizeNote,
                      selection: m.settings.size, choices: Choices.sizeChoices(model.settings),
                      disabled: Choices.sizesOff(model, for: model.gameState?.titleID))
            ChoiceRow(label: Strings.maxFps, selection: m.settings.maxFps, choices: Choices.rateChoices(model.settings))
            ChoiceRow(label: Strings.bitrate, note: Strings.bitrateNote, selection: m.settings.bitrateMbps, choices: Choices.bitrateChoices(model.settings))
            SwitchRow(label: Strings.smoothPicture, note: Strings.smoothPictureNote, isOn: m.settings.smooth)
        }
    }

    private func numbers(_ m: Bindable<ClientModel>) -> some View {
        FormGroup(title: Strings.numbersTitle) {
            LevelRow(level: m.settings.statsLevel)
            SwitchRow(label: Strings.recordSessions, note: Strings.recordSessionsNote, isOn: m.settings.recordSessions)
        }
    }

    private func sound(_ m: Bindable<ClientModel>) -> some View {
        FormGroup(title: Strings.sound) {
            SwitchRow(label: Strings.playSound, isOn: m.settings.playSound)
            ChoiceRow(label: Strings.soundBuffer, selection: soundBuffer(m.settings),
                      choices: [(0, Strings.soundBufferAutomatic)]
                          + Choices.bufferChoices(model.settings))
        }
    }

    private func controls(_ m: Bindable<ClientModel>) -> some View {
        FormGroup(title: Strings.controls, footer: Strings.appliesNext) {
            ChoiceRow(label: Strings.padLayout, selection: m.settings.padLayout, choices: [
                (ClientSettings.PadLayout.auto, Strings.layoutAuto), (.byLabel, Strings.layoutByLabel), (.byPosition, Strings.layoutByPosition)])
            ChoiceRow(label: Strings.deviceMotion, selection: m.settings.deviceMotion, choices: [
                (ClientSettings.DeviceMotion.auto, Strings.motionAuto), (.always, Strings.motionAlways), (.never, Strings.motionNever)])
        }
    }

    private func controller(_ m: Bindable<ClientModel>) -> some View {
        FormGroup(title: Strings.controllerGroup) {
            SwitchRow(label: Strings.menuChord, note: Strings.menuChordNote,
                      isOn: Binding(get: { model.settings.menuChord == .plusMinus },
                                    set: { model.settings.menuChord = $0 ? .plusMinus : .off }))
        }
    }

    /// iPhone and iPad: the on-screen controller's defaults.
    @ViewBuilder private func touch(_ m: Bindable<ClientModel>) -> some View {
        #if os(iOS)
        FormGroup(title: Strings.touchGroup) {
            SwitchRow(label: Strings.touchHaptics, note: Strings.touchHapticsNote, isOn: m.settings.touchHaptics)
            if Strings.showsTouchLayoutRow(gameControllers: GCController.controllers().filter { $0.extendedGamepad != nil }.count) {
                ChoiceRow(label: Strings.layoutForNewGames, note: Strings.touchLayoutNote, selection: m.settings.touchLayoutDefault,
                          choices: Strings.touchLayoutChoices)
            }
        }
        #endif
    }

    private var macs: some View {
        FormGroup(title: Strings.macsGroup, footer: Strings.forgetConfirmMessage) {
            Button(role: .destructive) { confirmForget = true } label: {
                HStack { Text(Strings.forgetPairedMacs).foregroundStyle(Theme.color(p.destructive)); Spacer() }
                    .padding(.horizontal, 16).frame(minHeight: 52).contentShape(Rectangle())
            }
            .buttonStyle(.portal(.row))
            .disabled(model.busy)
        }
    }

    private var about: some View {
        let info = Bundle.main.infoDictionary
        return FormGroup(title: Strings.aboutTitle) {
            FormRow(label: Strings.versionLabel) {
                Text(Strings.version(info?["CFBundleShortVersionString"] as? String ?? "1.0", build: info?["CFBundleVersion"] as? String ?? "1"))
                    .foregroundStyle(Theme.color(p.secondaryText))
            }
            #if os(iOS)
            Button { showsAcknowledgements = true } label: {
                HStack { Text(Strings.acknowledgements); Spacer(); Image(systemName: "chevron.right").foregroundStyle(Theme.color(p.tertiaryText)) }
                    .padding(.horizontal, 16).frame(minHeight: 52).contentShape(Rectangle())
            }
            .buttonStyle(.portal(.row))
            #endif
        }
    }

    /// 0 = automatic; a fixed value turns automatic off.
    private func soundBuffer(_ settings: Binding<ClientSettings>) -> Binding<Int> {
        Binding(get: { settings.wrappedValue.audioBufferAuto ? 0 : settings.wrappedValue.audioBufferMs },
                set: { if $0 == 0 { settings.wrappedValue.audioBufferAuto = true } else { settings.wrappedValue.audioBufferAuto = false; settings.wrappedValue.audioBufferMs = $0 } })
    }
}
