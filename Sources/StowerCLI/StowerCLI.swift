import ArgumentParser

/// The permanent `stower` command: index, search, and eval over local Messages.
@main
internal struct StowerCLI: AsyncParsableCommand {
    internal static let configuration = CommandConfiguration(
        commandName: "stower",
        abstract: "Always-local recall over your Messages: index, search, and eval.",
        subcommands: [IndexCommand.self, SearchCommand.self, EvalCommand.self, NoReplyCommand.self]
    )
}

/// Shared `--index-dir` / `--model-path` options for every subcommand.
internal struct StowerSharedOptions: ParsableArguments {
    @Option(
        name: .customLong("index-dir"),
        help: "Index directory (defaults under Application Support)."
    )
    internal var indexDirectory: String?

    @Option(
        name: .customLong("model-path"),
        help: "Converted model directory (defaults to Models/default)."
    )
    internal var modelPath: String?

    internal func locations() -> StowerLocations {
        stowerResolveLocations(indexDirectory: indexDirectory, modelPath: modelPath)
    }
}
