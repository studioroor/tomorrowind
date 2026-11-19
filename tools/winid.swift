import CoreGraphics
import Foundation
// Prints the window id of the first on-screen window owned by a process whose name contains argv[1],
// or, when argv[1] is a number, by the process with that pid.
let needle = CommandLine.arguments.count > 1 ? CommandLine.arguments[1].lowercased() : "openmw"
let pid = Int(needle)
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
for w in list {
    let owner = (w[kCGWindowOwnerName as String] as? String ?? "").lowercased()
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let ownerPid = w[kCGWindowOwnerPID as String] as? Int ?? -1
    let matches = pid.map { $0 == ownerPid } ?? owner.contains(needle)
    if matches && layer == 0, let id = w[kCGWindowNumber as String] as? Int {
        print(id); exit(0)
    }
}
exit(1)
