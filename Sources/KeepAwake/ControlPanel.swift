import AppKit
import SwiftUI

final class AppState: ObservableObject {
    @Published var battery: Int?
    @Published var batteryError: String?
    @Published var batteryUpdated: Date?
    @Published var refreshingBattery = false
    @Published var powerMode = PowerMode.system
    @Published var powerError: String?
    @Published var automatic = false
    @Published var screenAvailable = true
    @Published var screenStatus = "正在检测内置屏幕"
    @Published var screenError: String?
    @Published var screenBusy = false
    @Published var exporting = false
    @Published var quitting = false
    @Published var logError: String?
    @Published var detailed = false
    @Published var notice: String?
    var choosePower: (PowerMode) -> Void = { _ in }
    var chooseAutomatic: (Bool) -> Void = { _ in }
    var refreshBattery: () -> Void = {}
    var quit: () -> Void = {}
}

private struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct ControlPanel: View {
    @ObservedObject var state: AppState
    @State private var showDetails = false
    @State private var contentHeight: CGFloat = 260
    private var errorText: String? {
        let errors = [state.powerError, state.screenError, state.batteryError, state.logError].compactMap { $0 }.filter { !$0.isEmpty }
        return errors.isEmpty ? nil : errors.joined(separator: "\n")
    }
    var body: some View {
        ScrollView(.vertical) {
            content.background(GeometryReader { geometry in
                Color.clear.preference(key: PanelHeightKey.self, value: geometry.size.height)
            })
        }
        .frame(width: 360, height: min(contentHeight, max(240, (NSScreen.main?.visibleFrame.height ?? 800) - 80)))
        .onPreferenceChange(PanelHeightKey.self) { if $0 > 0 { contentHeight = $0 } }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "computermouse").foregroundStyle(.secondary)
                Text(state.battery.map { "Logitech \($0)%" } ?? (state.refreshingBattery ? "正在读取电量" : "Logitech 电量不可用"))
                    .monospacedDigit()
                    .accessibilityValue(state.batteryUpdated.map { "最后更新：\($0.formatted(date: .omitted, time: .shortened))" } ?? "尚未更新")
                Spacer(minLength: 4)
                if state.refreshingBattery { ProgressView().controlSize(.small).frame(width: 18, height: 18) }
                else {
                    Button(action: state.refreshBattery) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).accessibilityLabel("刷新电池电量")
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("保持唤醒").font(.headline)
                Picker("电源模式", selection: Binding(get: { state.powerMode }, set: state.choosePower)) {
                    ForEach(PowerMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented).labelsHidden().disabled(state.quitting)
                Text(state.powerMode.explanation).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("内置屏幕").font(.headline)
                Toggle(isOn: Binding(get: { state.automatic }, set: state.chooseAutomatic)) {
                    Label("外接时关闭内屏", systemImage: "display.2")
                }
                .toggleStyle(.switch)
                .disabled(state.quitting || (!state.screenAvailable && !state.automatic))
                HStack(alignment: .top, spacing: 6) {
                    if state.screenBusy { ProgressView().controlSize(.mini).frame(width: 10, height: 12) }
                    else { Circle().fill(state.screenError != nil ? Color.orange : (state.screenStatus.contains("已关闭") ? Color.green : Color.secondary)).frame(width: 6, height: 6).padding(.top, 4) }
                    Text(state.screenStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("关闭此开关即可恢复内屏").font(.caption2).foregroundStyle(.secondary)
            }
            if let errorText {
                DisclosureGroup("查看问题详情", isExpanded: $showDetails) {
                    Text(Diagnostics.sanitize(errorText)).font(.caption).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                }.font(.caption).foregroundStyle(.secondary)
            }
            if let notice = state.notice {
                HStack(alignment: .top) {
                    Text(notice).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { state.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).accessibilityLabel("关闭提示")
                }.foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Spacer()
                Button(action: state.quit) {
                    Label(state.quitting ? "正在退出…" : "退出", systemImage: "power")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("退出 Keep Awake")
            }
        }
        .font(.system(size: 13))
        .padding(16)
        .frame(width: 360)
        .disabled(state.quitting)
    }
}
