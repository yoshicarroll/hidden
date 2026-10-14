// Repro for the macOS 27 status item port leak (see docs/ARCHITECTURE.md, macOS 27).
// Usage: swiftc -O tools/statusitem-port-probe.swift -o /tmp/probe && /tmp/probe 10
// then unplug and replug a display and compare the logged port counts.
// Holds N zero-length status items and logs its own Mach port count and
// footprint every 2s, plus each screen-parameter change, to stdout.
import AppKit
let n = Int(CommandLine.arguments[1])!
func ports() -> Int {
    var names: mach_port_name_array_t? = nil; var types: mach_port_type_array_t? = nil
    var nc: mach_msg_type_number_t = 0; var tc: mach_msg_type_number_t = 0
    mach_port_names(mach_task_self_, &names, &nc, &types, &tc); return Int(nc)
}
func footprintKB() -> Int {
    var info = task_vm_info_data_t(); var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return Int(info.phys_footprint) / 1024
}
let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
func say(_ s: String) { print("\(f.string(from: Date())) n=\(n) \(s)"); fflush(stdout) }
setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var items: [NSStatusItem] = []
for i in 0..<n { let it = NSStatusBar.system.statusItem(withLength: 0); it.autosaveName = "rcprobe\(n)_\(i)"; items.append(it) }
NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
    say("screens \(NSScreen.screens.map { "\(Int($0.frame.minX))+\(Int($0.frame.width))" }) ports=\(ports())")
}
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in say("ports=\(ports()) fpKB=\(footprintKB())") }
app.run()
