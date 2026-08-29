import ArgumentParser
import TetherKit

@main
struct Tether: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tether",
        abstract: "tether command-line tool.",
        version: "0.1.0",
        subcommands: [Run.self]
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Default subcommand. Replace with real commands."
    )

    func run() throws {
        print("Hello from tether!")
    }
}
