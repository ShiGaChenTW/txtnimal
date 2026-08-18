import Foundation
import txtnimalCLICore

// Thin shim. Everything worth testing lives in txtnimalCLICore.
let output = CLIRunner.run(arguments: Array(CommandLine.arguments.dropFirst()), context: .live())

if !output.stdout.isEmpty { FileHandle.standardOutput.write(Data(output.stdout.utf8)) }
if !output.stderr.isEmpty { FileHandle.standardError.write(Data(output.stderr.utf8)) }
exit(output.exitCode)
