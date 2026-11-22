import Foundation
import PhoneHubKit

let args = CommandLine.arguments
do {
    if args.count == 4 && args[1] == "unwrap" {
        print(try SelfTest.unwrapHex(keyHex: args[2], blobHex: args[3]))
    } else {
        try SelfTest.run()
    }
} catch {
    print("FAILED: \(error)")
    exit(1)
}
