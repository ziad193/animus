#if os(macOS)
import AppKit
import IOKit
import Observation
import QuartzCore
import SwiftUI

/// The numbers behind the performance meter: how many frames a second the
/// app is managing, and what it's using. Only runs while the meter shows.
@MainActor
@Observable
final class PerfMeter {
    static let shared = PerfMeter()

    /// Frames drawn in the last second.
    private(set) var fps = 0
    /// The most the screen can show (60 on most Macs, 120 on some).
    private(set) var maxFPS = 60
    /// The longest wait between two frames in the last second, in milliseconds.
    private(set) var slowestFrame = 0.0
    /// Processor use by Animus, as a share of one core.
    private(set) var cpu = 0.0
    /// Memory Animus is using, in megabytes.
    private(set) var memory = 0.0
    /// How busy the graphics chip is, for the whole Mac (macOS doesn't say per app).
    private(set) var gpu: Int?

    @ObservationIgnored private var frames = 0
    @ObservationIgnored private var lastFrame: CFTimeInterval = 0
    @ObservationIgnored private var windowStart: CFTimeInterval = 0
    @ObservationIgnored private var slowest: CFTimeInterval = 0
    @ObservationIgnored private var lastCPUTime = 0.0

    /// Called once for every frame the screen is ready to show. When Animus is
    /// too busy to answer in time, the call is skipped, and the count drops.
    func frame(screenMax: Int) {
        let now = CACurrentMediaTime()
        if windowStart == 0 {
            windowStart = now
            lastFrame = now
            lastCPUTime = Self.cpuTime()
            return
        }
        frames += 1
        slowest = max(slowest, now - lastFrame)
        lastFrame = now
        let elapsed = now - windowStart
        guard elapsed >= 1 else { return }

        fps = Int((Double(frames) / elapsed).rounded())
        maxFPS = max(screenMax, 1)
        slowestFrame = slowest * 1000
        let cpuNow = Self.cpuTime()
        cpu = (cpuNow - lastCPUTime) / elapsed * 100
        lastCPUTime = cpuNow
        memory = Self.memoryInUse()
        gpu = Self.gpuLoad()
        frames = 0
        slowest = 0
        windowStart = now
    }

    func reset() {
        windowStart = 0
        frames = 0
        slowest = 0
    }

    /// Seconds of processor time Animus has used so far.
    private static func cpuTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    }

    /// The same figure Activity Monitor shows under Memory.
    private static func memoryInUse() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    private static func gpuLoad() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var load: Int?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let all = properties?.takeRetainedValue() as? [String: Any],
                  let stats = all["PerformanceStatistics"] as? [String: Any],
                  let value = stats["Device Utilization %"] as? Int else { continue }
            load = max(load ?? 0, value)
        }
        return load
    }
}

/// The meter itself, in the bottom-left corner of the window when it's
/// switched on in Settings › General. Clicks go straight through it.
struct PerfMeterOverlay: View {
    @AppStorage(Pref.perfMeter) private var showing = false

    var body: some View {
        if showing { PerfMeterBox() }
    }
}

private struct PerfMeterBox: View {
    @State private var meter = PerfMeter.shared

    private var fpsColor: Color {
        let share = Double(meter.fps) / Double(meter.maxFPS)
        return share >= 0.92 ? .green : share >= 0.7 ? .yellow : .red
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
            row("FPS", "\(meter.fps) of \(meter.maxFPS)", fpsColor)
            row("Slowest frame", String(format: "%.0f ms", meter.slowestFrame),
                meter.slowestFrame > 2000.0 / Double(meter.maxFPS) ? .yellow : .white)
            row("Processor", String(format: "%.0f%%", meter.cpu), .white)
            row("Memory", String(format: "%.0f MB", meter.memory), .white)
            if let gpu = meter.gpu {
                row("Graphics (whole Mac)", "\(gpu)%", .white)
            }
        }
        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // A plain dark box, not frosted glass: the meter shouldn't cost frames itself.
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.78)))
        .background(FrameTicker())
        .padding(10)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func row(_ label: String, _ value: String, _ color: Color) -> some View {
        GridRow {
            Text(label).foregroundStyle(.white.opacity(0.65))
            Text(value).foregroundStyle(color).gridColumnAlignment(.trailing)
        }
    }
}

/// Asks the screen to call back once per frame, and passes each call on.
private struct FrameTicker: NSViewRepresentable {
    func makeNSView(context: Context) -> TickerView { TickerView() }
    func updateNSView(_ view: TickerView, context: Context) {}

    final class TickerView: NSView {
        private var link: CADisplayLink?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            link?.invalidate()
            link = nil
            PerfMeter.shared.reset()
            guard window != nil else { return }
            let link = displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        @objc private func tick() {
            PerfMeter.shared.frame(screenMax: window?.screen?.maximumFramesPerSecond ?? 60)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
