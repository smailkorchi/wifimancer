import SwiftUI
import Charts

struct ThroughputView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var coord: AppCoordinator
    @EnvironmentObject var helper: HelperClient
    @State private var running = false
    @State private var deltaText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(
                "Throughput",
                subtitle: "Live link usage · pre-cut vs now",
                trailing: AnyView(speedTestButton)
            )

            if !helper.connected {
                HelperDownBanner()
            }

            HStack(spacing: 14) {
                // The previous "Live down" / "Live up" split was meaningless:
                // the underlying pcap counter credits BOTH src and dst MAC
                // for every Ethernet frame, so selfMAC and gatewayMAC
                // accumulate the same total — both buckets equal the link
                // throughput, which is why the two cards always read the
                // same value. Until we split tx/rx in the C layer, show a
                // single honest "Live link" number that doesn't pretend.
                metricCard(title: "Live link",
                           value: liveLinkMbps,
                           unit: "Mbps", color: Brand.info)
                metricCard(title: "Speed test",
                           value: store.lastSpeed?.downloadMbps ?? 0,
                           unit: "Mbps", color: Brand.trust)
                metricCard(title: "Latency",
                           value: store.lastSpeed?.latencyMs ?? 0,
                           unit: "ms", color: Brand.warning)
                metricCard(title: "Loss",
                           value: store.lastSpeed?.lossPct ?? 0,
                           unit: "%", color: Brand.cut)
            }

            if let delta = deltaText {
                BrandCard(padding: 16) {
                    HStack(spacing: 14) {
                        Image(systemName: "bolt.heart.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Brand.cut)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Reclaimed bandwidth")
                                .bodyStyle(12, weight: .semibold, muted: true)
                            Text(delta).display(22, weight: .semibold)
                        }
                        Spacer()
                    }
                }
            }

            BrandCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Live link · Mbps").bodyStyle(12, weight: .semibold, muted: true)
                    Chart(store.throughputHistory) { tick in
                        // Halve the per-MAC sum because pcap credits both
                        // src and dst per frame — without this the chart
                        // showed 2x the real link throughput.
                        let mbps = (tick.downBps + tick.upBps) / 2 * 8 / 1_000_000
                        AreaMark(
                            x: .value("t", tick.timestamp),
                            y: .value("Mbps", mbps)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(
                            LinearGradient(colors: [Brand.info.opacity(0.55), Brand.info.opacity(0.05)],
                                           startPoint: .top, endPoint: .bottom)
                        )
                        LineMark(
                            x: .value("t", tick.timestamp),
                            y: .value("Mbps", mbps)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(Brand.info)
                    }
                    .frame(height: 220)
                    .chartXAxis(.hidden)
                }
            }
        }
    }

    private var speedTestButton: AnyView {
        AnyView(
            Button {
                Task {
                    running = true
                    let pre = store.lastSpeed?.downloadMbps ?? 0
                    await coord.runSpeedTest()
                    let post = store.lastSpeed?.downloadMbps ?? 0
                    if pre > 0 && post > pre {
                        deltaText = String(format: "+%.1f Mbps", post - pre)
                    }
                    running = false
                }
            } label: {
                HStack(spacing: 6) {
                    if running { ProgressView().controlSize(.small) }
                    else { Image(systemName: "speedometer") }
                    Text("Run speed test")
                }
            }
            .buttonStyle(PrimaryButton(tint: Brand.info))
            .disabled(running)
        )
    }

    /// Single honest number for "what's the link doing right now". Halves
    /// the per-MAC sum because the C layer counts both src and dst for
    /// each frame. Average over the last 3 ticks so the card doesn't
    /// strobe between burst bytes and idle gaps.
    private var liveLinkMbps: Double {
        let recent = store.throughputHistory.suffix(3)
        guard !recent.isEmpty else { return 0 }
        let avgBps = recent.map { ($0.downBps + $0.upBps) / 2 }
                           .reduce(0, +) / Double(recent.count)
        return avgBps * 8 / 1_000_000
    }

    private func metricCard(title: String, value: Double, unit: String, color: Color) -> some View {
        BrandCard(padding: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).bodyStyle(11, weight: .semibold, muted: true)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%.1f", value))
                        .display(28, weight: .semibold)
                        .foregroundStyle(color)
                    Text(unit).bodyStyle(12, muted: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
