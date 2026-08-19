import SwiftUI

struct PanelView: View {
    @Bindable var buds: Buds
    @State private var showingHelp = false

    var body: some View {
        GlassEffectContainer(spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                header
                if buds.isConnected {
                    batteryRow
                    noiseControlCard
                } else {
                    disconnectedNote
                }
                if let error = buds.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
        .frame(width: 340)
        // The popover re-adds this view to a window each time it opens, so onAppear is a
        // per-open hook: the panel always shows live state, not whatever it last rendered.
        .onAppear { buds.refreshConnectionState() }
        .animation(.smooth(duration: 0.28), value: buds.isConnected)
        .animation(.smooth(duration: 0.28), value: buds.battery.enclosure == nil)
        .animation(.smooth(duration: 0.28), value: buds.placement.left)
        .animation(.smooth(duration: 0.28), value: buds.placement.right)
        .animation(.smooth(duration: 0.28), value: buds.mode)
        .animation(.smooth(duration: 0.28), value: buds.ancLevel)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(buds.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(buds.isPaired ? (buds.isConnected ? "Connected" : "Disconnected")
                                   : "Not paired")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if buds.isBusy {
                ProgressView().controlSize(.small)
            }

            Toggle("Power", isOn: Binding(
                get: { buds.isConnected },
                set: { $0 ? buds.connect() : buds.disconnect() }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(buds.isBusy || !buds.isPaired)

            Menu {
                Button("Quit BudsBar") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var disconnectedNote: some View {
        Text(buds.isPaired
             ? "Take the earbuds out of the case, then switch on to connect."
             : "No paired earbuds speak this protocol. Pair your realme or OPPO buds in "
             + "Bluetooth settings first.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Battery

    private var batteryRow: some View {
        HStack(spacing: 0) {
            batteryCell("L", glyph: "l.circle", level: buds.battery.left,
                        placement: buds.placement.left)
            batteryCell("R", glyph: "r.circle", level: buds.battery.right,
                        placement: buds.placement.right)
            // The case reports 0% while it is shut or asleep, which `interpret` turns into
            // nil rather than a false flat battery. Nothing to show then, so the cell goes
            // away entirely — the buds keep theirs and read "—%".
            if buds.battery.enclosure != nil {
                // The charging-case glyph, same one the menu bar uses. `shippingbox` read as
                // a parcel rather than an earbud case.
                batteryCell("Case", glyph: "airpods.pro.chargingcase.wireless.fill",
                            level: buds.battery.enclosure)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// `placement` is nil for the case, and for a bud whose reported value we do not
    /// recognise — both mean "no idea", and the cell is drawn as it always was rather than
    /// guessing. A bud known to be in the case is dimmed — it is charging, not in use — but
    /// still shows its percentage while the case is awake and reporting. A shut case stops
    /// reporting, the reading it cleared on the way in is never refilled, and the cell then
    /// honestly reads "—%".
    private func batteryCell(_ title: String, glyph: String, level: Int?,
                             placement: BudsProtocol.BudPlacement? = nil) -> some View {
        let stowed = placement == .inCase
        let muted = stowed || level == nil
        return VStack(spacing: 6) {
            Image(systemName: glyph)
                .font(.system(size: 15, weight: .regular))
                .frame(width: 30, height: 30)
                .foregroundStyle(stowed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .glassEffect(.regular, in: .circle)

            HStack(spacing: 4) {
                // No glyph without a reading: a battery symbol would draw a level we do not
                // have.
                if let level {
                    Image(systemName: batterySymbol(for: level))
                        .font(.system(size: 13))
                        .foregroundStyle(muted ? .secondary : .primary)
                }
                Text(level.map { "\($0)%" } ?? "—%")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(muted ? .secondary : .primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                level.map { "\(title) battery \($0) percent\(stowed ? ", in the case" : "")" }
                     ?? "\(title) battery unknown")
        }
        .frame(maxWidth: .infinity)
    }

    private func batterySymbol(for level: Int?) -> String {
        guard let level else { return "battery.0percent" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    // MARK: - Noise control

    private var noiseControlCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Noise control")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { showingHelp.toggle() } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .popover(isPresented: $showingHelp, arrowEdge: .bottom) {
                    Text("Noise cancellation blocks outside sound — Max for planes and "
                       + "trains, Moderate for streets, Mild for home and office. "
                       + "Transparency lets sound through so you can hear your "
                       + "surroundings. Off does neither.")
                        .font(.callout)
                        .frame(width: 240)
                        .padding(12)
                }
            }

            HStack(spacing: 0) {
                ForEach(NoiseMode.allCases) { mode in
                    noiseButton(mode)
                }
            }
            .frame(maxWidth: .infinity)
            .disabled(!canSwitchModes)
            .opacity(canSwitchModes ? 1 : 0.45)

            if buds.mode == .noiseCancellation {
                ancLevelPicker
            }

            if let note = modeSwitchingNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    /// Shown only while noise cancellation is the active mode, since the level is
    /// meaningless otherwise. The selection is `ANCLevel?` so that Smart — which realme Link
    /// offers and this app does not — leaves every segment unselected instead of claiming a
    /// level the phone is not showing.
    private var ancLevelPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Hand-rolled rather than a segmented Picker: on macOS that control sizes itself
            // to its widest label and will not stretch, so the row never filled the card.
            HStack(spacing: 6) {
                ForEach(ANCLevel.allCases) { level in
                    levelSegment(level)
                }
            }
            .frame(maxWidth: .infinity)

            Text(buds.ancLevel?.detail ?? "Smart — the buds are choosing the level")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(!canSwitchModes)
        .opacity(canSwitchModes ? 1 : 0.45)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// One level, sized to an equal share of the row. Nothing is selected while the buds are
    /// on Smart, which is the honest reading — see `ANCLevel`.
    private func levelSegment(_ level: ANCLevel) -> some View {
        let selected = buds.ancLevel == level
        return Button {
            buds.set(ancLevel: level)
        } label: {
            Text(level.label)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .glassEffect(
                    selected ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                    in: .capsule)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(level.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var canSwitchModes: Bool { buds.isControlChannelOpen }

    private var modeSwitchingNote: String? {
        buds.isControlChannelOpen ? nil : "Waiting for the control channel…"
    }

    private func noiseButton(_ mode: NoiseMode) -> some View {
        let selected = buds.mode == mode
        return Button {
            buds.set(mode: mode)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .frame(width: 54, height: 54)
                    .glassEffect(
                        selected ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                        in: .circle)

                Text(mode.label)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
