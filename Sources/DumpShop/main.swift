import AppKit
import SwiftUI

let cliArgs = Array(CommandLine.arguments.dropFirst())
if cliArgs.contains("--selftest") {
    exit(SelfTest.run(cliArgs))
}
if cliArgs.contains("--dump") || cliArgs.contains("--store-dump")
    || cliArgs.contains("--store-search") {
    exit(Headless.run(cliArgs))
}

DumpShopApp.main()
