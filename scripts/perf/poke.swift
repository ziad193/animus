import Foundation
// usage: poke <word> [<word> ...] : sends each word to Animus Dev, 1.5 s apart
for w in CommandLine.arguments.dropFirst() {
    DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.ziad.animus.dev.perf"), object: w, userInfo: nil, deliverImmediately: true)
    Thread.sleep(forTimeInterval: w == "scroll" ? 4 : 1.5)
}
