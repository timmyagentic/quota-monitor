import AppKit
import Foundation
import WebKit

@MainActor
final class Renderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let window: NSWindow
    private let payload: String
    private let outputURL: URL
    private var finished = false

    init(payload: String, outputURL: URL) {
        self.payload = payload
        self.outputURL = outputURL
        let configuration = WKWebViewConfiguration()
        self.webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 920, height: 600),
            configuration: configuration)
        self.window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        super.init()
        webView.navigationDelegate = self
        window.contentView = webView
        window.orderFrontRegardless()
    }

    func render(_ fixtureURL: URL) {
        webView.loadFileURL(
            fixtureURL,
            allowingReadAccessTo: fixtureURL.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            do {
                _ = try await webView.evaluateJavaScript(payload)
                try await Task.sleep(for: .milliseconds(250))
                _ = try await webView.evaluateJavaScript(
                    "document.getElementById('quota-monitor-codex-sidebar')"
                        + ".dispatchEvent(new PointerEvent('pointerenter'))")
                try await Task.sleep(for: .milliseconds(180))
                let image = try await webView.takeSnapshot(
                    configuration: nil)
                guard let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(
                        using: .png,
                        properties: [:])
                else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try png.write(to: outputURL, options: .atomic)
                finish(exitCode: 0)
            } catch {
                FileHandle.standardError.write(
                    Data("render failed: \(error)\n".utf8))
                finish(exitCode: 1)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        FileHandle.standardError.write(Data("navigation failed: \(error)\n".utf8))
        finish(exitCode: 1)
    }

    private func finish(exitCode: Int32) {
        guard !finished else { return }
        finished = true
        Foundation.exit(exitCode)
    }
}

@main
@MainActor
struct Main {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else {
            FileHandle.standardError.write(
                Data("usage: render fixture renderer.swift output.png\n".utf8))
            Foundation.exit(64)
        }

        let fixtureURL = URL(fileURLWithPath: arguments[1])
        let sourceURL = URL(fileURLWithPath: arguments[2])
        let outputURL = URL(fileURLWithPath: arguments[3])
        let swiftSource = try String(contentsOf: sourceURL, encoding: .utf8)
        guard let start = swiftSource.range(of: "static let source = #\"\"\""),
              let end = swiftSource.range(
                of: "\n    \"\"\"#",
                range: start.upperBound..<swiftSource.endIndex)
        else {
            FileHandle.standardError.write(Data("renderer payload not found\n".utf8))
            Foundation.exit(65)
        }
        let payload = String(swiftSource[start.upperBound..<end.lowerBound])

        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let renderer = Renderer(payload: payload, outputURL: outputURL)
        renderer.render(fixtureURL)
        application.run()
    }
}
