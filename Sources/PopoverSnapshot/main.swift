import AppKit
import SwiftUI
import TallyCore
import TallyUI

// Usage: swift run PopoverSnapshot <output.png> [light|dark]
@MainActor
func render(to path: String, scheme: ColorScheme) async throws {
    let client = GitHubClient(tokens: TokenProvider())
    let store = TallyStore { try await client.fetchSnapshot() }
    await store.refresh()
    let view = PopoverView(store: store)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, scheme)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.cgImage,
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: URL(fileURLWithPath: path))
    print("\(store.menuBarTitle) -> \(path)")
}

let arguments = CommandLine.arguments
try await render(
    to: arguments.count > 1 ? arguments[1] : "popover.png",
    scheme: arguments.count > 2 && arguments[2] == "dark" ? .dark : .light
)
