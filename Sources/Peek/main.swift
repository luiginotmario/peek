import AppKit

setvbuf(stdout, nil, _IOLBF, 0)

// photos decodes images on the main run loop, so even the terminal commands run inside a real app
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// finder launches pass no arguments (or a -psn_ one); anything else is a terminal command
let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn") }
var menuBar: MenuBar?

if arguments.isEmpty {
    menuBar = MenuBar()
} else {
    // the engine and terminal commands are background-only: no dock icon, no menus, never active
    if arguments.first == "serve" { app.setActivationPolicy(.prohibited) }
    Task {
        do {
            try await Commands.run(Array(arguments))
            exit(0)
        } catch {
            Commands.fail("\(error)")
        }
    }
}
app.run()
