#if os(macOS)
import Foundation
import PortalTestSupport

// `--prepare-hold <seconds>` (screenshots): reports 360 of 1000 while preparing and shows no picture for that long.
let args = CommandLine.arguments
let usage = "usage: portal-fakegame --socket <path> [--prepare-hold <seconds>]\n"
var hold: TimeInterval = 0
guard args.count == 3 || args.count == 5, args[1] == "--socket" else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}
if args.count == 5 {
    guard args[3] == "--prepare-hold", let s = Double(args[4]), s > 0, s <= 3600 else {
        FileHandle.standardError.write(Data(usage.utf8))
        exit(2)
    }
    hold = s
}
let steps = hold > 0 ? [FakeGame.PrepareStep(phase: 1, done: 360, total: 1000)] : []
do { try await FakeGame(socketPath: args[2], prepareSteps: steps, stall: hold).run() } catch {
    FileHandle.standardError.write(Data("portal-fakegame: \(error)\n".utf8))
    exit(1)
}
#endif
