import SwiftUI

/// Slim handoff control rendered inside `DeviceInspector`.
///
/// The full attack workflow lives on the dedicated Arsenal page now. This
/// banner just stages the inspected device into `ArsenalStore` and flips
/// the tab. Keeps the inspector focused on identity / addressing while
/// the operator gets a real multi-pane workspace for tool selection,
/// learning content, target compatibility, and live output.
struct AttackActionPad: View {
    let device: Device
    @EnvironmentObject var store: AppStore
    @StateObject private var arsenal = ArsenalStore.shared

    var body: some View {
        Button(action: openInArsenal) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Brand.cut.opacity(0.18))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Brand.cut.opacity(0.6), lineWidth: 1))
                    Image(systemName: "burst.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Brand.cut)
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OPEN IN ARSENAL")
                        .font(BrandFont.heading(11, weight: .bold))
                        .tracking(2.0)
                        .foregroundStyle(Brand.cut)
                    Text("\(applicableCount) tools fit this device — pick one and run")
                        .bodyStyle(11, muted: true)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Brand.cut)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Brand.surfaceLo.opacity(0.8))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Brand.cut.opacity(0.4), lineWidth: 0.75))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var applicableCount: Int {
        AttackCatalog.attacks(for: device.kind).count
    }

    private func openInArsenal() {
        arsenal.setTarget(device)
        if arsenal.selectedAttack != nil {
            arsenal.setSelectedTargetAndPreview(device)
        }
        withAnimation(Motion.smooth) { store.tab = .arsenal }
    }
}
