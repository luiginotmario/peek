import AppKit

setvbuf(stdout, nil, _IOLBF, 0)

// photos decodes images on the main run loop, so even the terminal commands run inside a real app
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task {
    do {
        try await Commands.run(Array(CommandLine.arguments.dropFirst()))
        exit(0)
    } catch {
        Commands.fail("\(error)")
    }
}
app.run()
