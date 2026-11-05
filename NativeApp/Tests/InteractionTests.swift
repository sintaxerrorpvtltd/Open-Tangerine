import Foundation
import AppKit
final class UpdateResponse: URLProtocol {
    static var body = ""
    static var status = 200
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct InteractionTests {
    @MainActor static func main() async throws {
        precondition(!DragMonitor.acceptsDrag(hasFiles: false, types: [.string, NSPasteboard.PasteboardType("com.corel.vector")]), "Internal vector drags must not open the wheel")
        precondition(DragMonitor.acceptsDrag(hasFiles: true, types: []))
        precondition(DragMonitor.acceptsDrag(hasFiles: false, types: [.fileURL]))
        let excluded = ["test.design.app": "Design app"]
        precondition(DragMonitor.isExcluded("test.design.app", applications: excluded))
        precondition(!DragMonitor.isExcluded("com.apple.finder", applications: excluded))
        precondition(!DragMonitor.isExcluded(nil, applications: excluded))
        for count in [3, 6, 10] {
            let geometry = RadialGeometry(count: count)
            for index in 0..<count {
                let angles = geometry.angles(for: index)
                let angle = (angles.start + angles.end) / 2
                precondition(geometry.index(at: CGPoint(x: cos(angle) * geometry.labelRadius, y: sin(angle) * geometry.labelRadius)) == index)
            }
            precondition(geometry.index(at: .zero) == nil)
        }
        let settings = AppSettings.shared
        let oldStyle = settings.progressStyle
        settings.progressStyle = .pill
        let runner = JobRunner(presentsHUD: false)
        let completedJob = Job(title: "Test", detail: "test")
        runner.enqueue(completedJob) { _ in [] }
        await completedJob.task?.value
        runner.hoverResults(true)
        try await Task.sleep(nanoseconds: 2_300_000_000)
        precondition(runner.jobs.isEmpty, "Completed notch must dismiss even when hovered")
        settings.progressStyle = oldStyle
        print("PASS vector drag rejection, app exclusions, radial hit regions and two-second notch dismissal")
        precondition(AppVersion("0.1.10")! > AppVersion("0.1.9")!)
        precondition(AppVersion("v1.0.0")! == AppVersion("1.0.0")!)
        precondition(AppVersion("1.2.3-beta") == nil)
        precondition(AppVersion("1.2") == nil)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateResponse.self]
        let suite = "OpenTangerine-update-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var openedPage: URL?
        let checker = UpdateChecker(session: URLSession(configuration: config), defaults: defaults, currentVersion: "0.1.2", openPage: { openedPage = $0 })
        precondition(checker.downloadPage.absoluteString == "https://sintaxerrorpvtltd.github.io/Open-Tangerine/?version=0.1.2#download")
        await checker.check(interactive: true)
        precondition(openedPage == checker.downloadPage)
        precondition(UpdateResponse.requests == 1, "Manual checks also refresh the menu")
        UpdateResponse.body = #"{"tag_name":"v0.1.3","draft":false,"prerelease":false,"assets":[{"name":"Open-Tangerine-0.1.3-macOS.zip","state":"uploaded","browser_download_url":"https://github.com/sintaxerrorpvtltd/Open-Tangerine/releases/download/v0.1.3/Open-Tangerine-0.1.3-macOS.zip"}]}"#
        await checker.check(interactive: false)
        precondition(checker.availableVersion == "v0.1.3")
        defaults.removeObject(forKey: "lastUpdateCheck")
        UpdateResponse.body = #"{"tag_name":"v0.1.2","draft":false,"prerelease":false,"assets":[{"name":"Open-Tangerine-0.1.2-macOS.zip","state":"uploaded","browser_download_url":"https://github.com/sintaxerrorpvtltd/Open-Tangerine/releases/download/v0.1.2/Open-Tangerine-0.1.2-macOS.zip"}]}"#
        await checker.check(interactive: false)
        precondition(checker.availableVersion == nil)
        defaults.removeObject(forKey: "lastUpdateCheck")
        UpdateResponse.status = 404
        await checker.check(interactive: false)
        precondition(defaults.object(forKey: "lastUpdateCheck") == nil)
        print("PASS HTTP update detection, current version, unpublished release")
        let state = CompanionState.shared
        state.set(.watching)
        state.watch(label: "PNG", direction: 3)
        precondition(state.gaze == 1 && state.caption.contains("PNG"))
        let interrupted = state.transition(from: .received, to: .processing, after: 0.01)
        state.set(.failed)
        await interrupted.value
        precondition(state.phase == .failed, "Late animation must not overwrite error")
        let completed = state.transition(from: .delivering, to: .success, after: 0.01)
        await completed.value
        precondition(state.phase == .success)
        print("PASS version ordering, invalid version rejection, gaze bounds, interrupted and completion transitions")
    }
}
