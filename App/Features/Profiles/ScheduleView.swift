import SwiftUI

struct ScheduleView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader("Schedule",
                          subtitle: "Cut strangers automatically during these hours on \(store.profile.ssid)")

            BrandCard(padding: 22) {
                VStack(alignment: .leading, spacing: 22) {
                    // ── Master switch
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Schedule")
                                .font(BrandFont.heading(15, weight: .semibold))
                            Text(scheduleSummary)
                                .bodyStyle(12, muted: true)
                        }
                        Spacer()
                        BrandSwitch(
                            isOn: Binding(
                                get: { store.profile.schedule.enabled },
                                set: { store.profile.schedule.enabled = $0; store.upsertCurrentProfile() }),
                            onColor: Brand.cut, offColor: Brand.mutedDim,
                            label: ("Auto-cut", "Off"),
                            compact: false
                        )
                    }

                    Divider().background(Brand.hairline)

                    // ── Days of week
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Active days").bodyStyle(11, weight: .semibold, muted: true)
                        HStack(spacing: 8) {
                            ForEach(1...7, id: \.self) { d in
                                DayChip(label: shortDay(d),
                                        full: fullDay(d),
                                        selected: store.profile.schedule.weekdays.contains(d),
                                        enabled: store.profile.schedule.enabled) {
                                    if store.profile.schedule.weekdays.contains(d) {
                                        store.profile.schedule.weekdays.remove(d)
                                    } else {
                                        store.profile.schedule.weekdays.insert(d)
                                    }
                                    store.upsertCurrentProfile()
                                }
                            }
                            Spacer()
                            Button("Weekdays") {
                                store.profile.schedule.weekdays = [1,2,3,4,5]
                                store.upsertCurrentProfile()
                            }.buttonStyle(GhostButton())
                            Button("All") {
                                store.profile.schedule.weekdays = [1,2,3,4,5,6,7]
                                store.upsertCurrentProfile()
                            }.buttonStyle(GhostButton())
                        }
                    }

                    Divider().background(Brand.hairline)

                    // ── Hour range
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Active hours").bodyStyle(11, weight: .semibold, muted: true)
                            Spacer()
                            Text("\(timeLabel(store.profile.schedule.startMinute)) – \(timeLabel(store.profile.schedule.endMinute))")
                                .mono(13)
                                .foregroundStyle(Brand.cut)
                        }

                        HourRangeSlider(
                            start: Binding(
                                get: { store.profile.schedule.startMinute },
                                set: { store.profile.schedule.startMinute = $0; store.upsertCurrentProfile() }),
                            end: Binding(
                                get: { store.profile.schedule.endMinute },
                                set: { store.profile.schedule.endMinute = $0; store.upsertCurrentProfile() })
                        )
                        .frame(height: 56)
                        .opacity(store.profile.schedule.enabled ? 1.0 : 0.45)
                    }
                }
            }
        }
    }

    private var scheduleSummary: String {
        let s = store.profile.schedule
        guard s.enabled else { return "Off — strangers stay until you toggle Engage" }
        let days = s.weekdays.count == 7 ? "every day" :
                   s.weekdays == [1,2,3,4,5] ? "weekdays" :
                   s.weekdays.isEmpty ? "no days picked" :
                   "\(s.weekdays.count) days"
        return "Cuts \(days), \(timeLabel(s.startMinute))–\(timeLabel(s.endMinute))"
    }

    private func shortDay(_ d: Int) -> String {
        ["", "M", "T", "W", "T", "F", "S", "S"][d]
    }
    private func fullDay(_ d: Int) -> String {
        ["", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"][d]
    }
    private func timeLabel(_ m: Int) -> String {
        String(format: "%02d:%02d", m / 60, m % 60)
    }
}

// MARK: Day chip

private struct DayChip: View {
    let label: String
    let full: String
    let selected: Bool
    let enabled: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(BrandFont.heading(12, weight: .bold))
                .frame(width: 36, height: 36)
                .foregroundStyle(selected ? Brand.light : Brand.muted)
                .background(
                    Circle()
                        .fill(selected ? Brand.cut : (hover ? Brand.surfaceHi : Color.clear))
                        .overlay(Circle().stroke(selected ? Brand.cut : Brand.hairline, lineWidth: 1.2))
                )
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1.0 : 0.5)
        .help(full)
        .onHover { hover = $0 }
        .animation(Motion.snap, value: selected)
        .animation(Motion.snap, value: hover)
    }
}

// MARK: Range slider

private struct HourRangeSlider: View {
    @Binding var start: Int   // minutes 0..1440
    @Binding var end: Int

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h: CGFloat = 8
            let pxPerMin = w / 1440.0
            let s = CGFloat(start) * pxPerMin
            let e = CGFloat(end)   * pxPerMin

            ZStack(alignment: .leading) {
                // track
                Capsule().fill(Brand.surfaceHi)
                    .frame(height: h)
                // hour ticks
                ForEach(Array(stride(from: 0, through: 24, by: 6)), id: \.self) { hr in
                    let x = CGFloat(hr) * 60 * pxPerMin
                    Rectangle().fill(Brand.hairline)
                        .frame(width: 1, height: 14)
                        .offset(x: x, y: -3)
                    Text(String(format: "%02d", hr))
                        .mono(9, muted: true)
                        .offset(x: x - 8, y: 16)
                }
                // selected range fill
                Capsule()
                    .fill(LinearGradient(colors: [Brand.cut, Brand.cut.opacity(0.7)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, e - s), height: h)
                    .offset(x: s)
                // start handle
                handle(x: s, total: w) { absX in
                    let m = clamp(Int(absX / pxPerMin), 0, end - 15)
                    start = (m / 5) * 5
                }
                // end handle
                handle(x: e, total: w) { absX in
                    let m = clamp(Int(absX / pxPerMin), start + 15, 1440)
                    end = (m / 5) * 5
                }
            }
            .frame(height: h)
            .offset(y: 16)
            .coordinateSpace(name: "hr-track")
        }
    }

    private func handle(x: CGFloat, total: CGFloat, drag: @escaping (CGFloat) -> Void) -> some View {
        Circle()
            .fill(Brand.cut)
            .overlay(Circle().stroke(Brand.light.opacity(0.3), lineWidth: 1.5))
            .frame(width: 20, height: 20)
            .shadow(color: Brand.cut.opacity(0.4), radius: 6)
            .offset(x: x - 10, y: -6)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("hr-track"))
                    .onChanged { v in
                        drag(min(max(v.location.x, 0), total))
                    }
            )
    }

    private func clamp<T: Comparable>(_ v: T, _ a: T, _ b: T) -> T {
        min(max(v, a), b)
    }
}
