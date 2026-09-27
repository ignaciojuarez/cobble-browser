import AppKit
import WebKit
import XCTest
@testable import Cobble

@MainActor final class WebKitAudioMuteTests: XCTestCase {
    func testNativeAudioMuteKeepsVideoAndWebAudioRunningWithoutChangingPageControls() async throws {
        for isPrivate in [false, true] {
            let fixture = AudioMuteFixture(isPrivate: isPrivate)
            defer { fixture.close() }
            try await fixture.start()
            XCTAssertTrue(WebKitAudioMute.isAvailable)
            try await fixture.wait { WebKitAudioMute.isPlayingAudio(fixture.page.webView) }
            let before = try await fixture.sample()
            try fixture.page.setAudioMuted(true)
            XCTAssertTrue(fixture.page.state.isAudioMuted)
            XCTAssertTrue(WebKitAudioMute.isMuted(fixture.page.webView))
            try await Task.sleep(for: .milliseconds(350))
            let muted = try await fixture.sample()
            XCTAssertGreaterThan(try number(muted, "videoTime"), try number(before, "videoTime"))
            XCTAssertGreaterThan(try number(muted, "audioTime"), try number(before, "audioTime"))
            XCTAssertGreaterThan(try number(muted, "presentedFrames"), try number(before, "presentedFrames"))
            XCTAssertEqual(muted["paused"] as? Bool, false)
            XCTAssertEqual(muted["audioState"] as? String, "running")
            XCTAssertEqual(muted["elementMuted"] as? Bool, false)
            XCTAssertEqual(try number(muted, "volume"), 0.4, accuracy: 0.0001)
            // WebKit intentionally measures source activity before zeroing muted
            // output. This is not a measurement of sound at the speakers.
            XCTAssertTrue(WebKitAudioMute.isPlayingAudio(fixture.page.webView))

            // A new source started after the tab was muted must stay under the
            // native output mute; no script needs to find or modify that source.
            _ = try await fixture.page.webView.evaluateJavaScript("addTone(); video.pause(); true")
            XCTAssertTrue(WebKitAudioMute.isMuted(fixture.page.webView))
            let paused = try await fixture.sample()
            try fixture.page.setAudioMuted(false)
            try await fixture.wait { WebKitAudioMute.isPlayingAudio(fixture.page.webView) }
            try await Task.sleep(for: .milliseconds(150))
            let unmuted = try await fixture.sample()
            XCTAssertEqual(unmuted["paused"] as? Bool, true)
            XCTAssertEqual(try number(unmuted, "videoTime"), try number(paused, "videoTime"), accuracy: 0.05)
            XCTAssertEqual(try number(unmuted, "volume"), 0.4, accuracy: 0.0001)
            XCTAssertEqual(unmuted["elementMuted"] as? Bool, false)
            XCTAssertEqual(unmuted["audioState"] as? String, "running")
        }
    }

    func testAudioMuteDoesNotAffectAnotherTab() async throws {
        let first = AudioMuteFixture()
        let second = AudioMuteFixture()
        defer { first.close(); second.close() }
        try await first.start()
        try await second.start()
        try await second.wait { WebKitAudioMute.isPlayingAudio(second.page.webView) }
        try first.page.setAudioMuted(true)
        XCTAssertTrue(WebKitAudioMute.isMuted(first.page.webView))
        XCTAssertFalse(WebKitAudioMute.isMuted(second.page.webView))
        XCTAssertTrue(WebKitAudioMute.isPlayingAudio(second.page.webView))
        let secondState = try await second.sample()
        XCTAssertEqual(secondState["paused"] as? Bool, false)
    }

    func testCrossOriginAudioKeepsRunningUnderNativeTabMute() async throws {
        let child = try LocalHTTPFixture { _ in .init(body: """
            <script>
            const audio = new AudioContext(), tone = audio.createOscillator(), gain = audio.createGain();
            gain.gain.value = 0.001; tone.connect(gain).connect(audio.destination); tone.start(); audio.resume();
            setInterval(() => parent.postMessage({ audioTime: audio.currentTime, audioState: audio.state }, '*'), 50);
            </script>
            """) }
        try await child.start()
        defer { child.stop() }
        let childURL = child.url("/audio").absoluteString
        let parent = try LocalHTTPFixture { _ in .init(body: """
            <title>Cross-origin audio fixture</title><script>
            window.latest = null;
            addEventListener('message', event => { if (event.origin === new URL('\(childURL)').origin) latest = event.data; });
            window.sample = () => latest;
            </script><iframe src="\(childURL)" allow="autoplay"></iframe>
            """) }
        try await parent.start()
        defer { parent.stop() }
        let fixture = AudioMuteFixture()
        defer { fixture.close() }
        fixture.page.webView.load(URLRequest(url: parent.url("/parent")))
        try await fixture.wait { fixture.page.webView.title == "Cross-origin audio fixture" && !fixture.page.webView.isLoading }
        _ = try await fixture.page.webView.callAsyncJavaScript("""
            const end = Date.now() + 8000;
            while (!(latest?.audioTime > 0) && Date.now() < end) await new Promise(resolve => setTimeout(resolve, 20));
            if (!(latest?.audioTime > 0)) throw new Error('Child audio did not start');
            try { frames[0].document; throw new Error('Fixture must be cross-origin'); }
            catch (error) { if (error.name !== 'SecurityError') throw error; }
            return true;
            """, arguments: [:], in: nil, contentWorld: .page)
        try await fixture.wait { WebKitAudioMute.isPlayingAudio(fixture.page.webView) }
        let before = try await fixture.sample()
        try fixture.page.setAudioMuted(true)
        try await Task.sleep(for: .milliseconds(350))
        let muted = try await fixture.sample()
        XCTAssertTrue(WebKitAudioMute.isMuted(fixture.page.webView))
        XCTAssertGreaterThan(try number(muted, "audioTime"), try number(before, "audioTime"))
        XCTAssertEqual(muted["audioState"] as? String, "running")
        try fixture.page.setAudioMuted(false)
        XCTAssertFalse(WebKitAudioMute.isMuted(fixture.page.webView))
    }

    func testCaptureMuteFlagsAndHistoryAreNeverOverwrittenByAudioMute() async throws {
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        defer { page.close() }
        _ = page.webView
        for kind in [PermissionKind.microphone, .camera] {
            page.setCapture(kind, .muted)
            let before = try XCTUnwrap(page.webView.value(forKey: "_mediaMutedState") as? NSNumber)
            XCTAssertNotEqual(before.uintValue & 2, 0, "Native capture mute intent exists even without an active track")
            XCTAssertNoThrow(try page.setAudioMuted(true))
            XCTAssertEqual(page.webView.value(forKey: "_mediaMutedState") as? NSNumber, before)
            XCTAssertFalse(page.state.isAudioMuted)
            page.setCapture(kind, .active)
        }
        // Even after capture ends, native getters can hide latent capture state.
        page.webView.loadHTMLString("<title>After capture</title>", baseURL: nil)
        XCTAssertNoThrow(try page.setAudioMuted(true))
        XCTAssertFalse(WebKitAudioMute.isMuted(page.webView))

        let alreadyMuted = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        defer { alreadyMuted.close() }
        try alreadyMuted.setAudioMuted(true)
        alreadyMuted.setCapture(.microphone, .muted)
        let flags = alreadyMuted.webView.value(forKey: "_mediaMutedState") as? NSNumber
        XCTAssertTrue(WebKitAudioMute.isMuted(alreadyMuted.webView))
        XCTAssertNoThrow(try alreadyMuted.setAudioMuted(false))
        XCTAssertEqual(alreadyMuted.webView.value(forKey: "_mediaMutedState") as? NSNumber, flags)
    }

    private func number(_ sample: [String: Any], _ key: String) throws -> Double {
        try XCTUnwrap(sample[key] as? NSNumber, key).doubleValue
    }
}

@MainActor private final class AudioMuteFixture {
    let page: WebKitPage
    private let window: NSWindow
    init(isPrivate: Bool = false) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        page = WebKitPage(tabID: UUID(), dataStore: configuration.websiteDataStore,
            configuration: configuration, isPrivate: isPrivate) { _, _, _ in }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page.webView
        window.orderFront(nil)
    }
    func close() { page.close(); window.contentView = nil; window.close() }
    func start() async throws {
        page.webView.loadHTMLString("""
            <title>Local audio mute fixture</title><canvas id="canvas" width="160" height="90"></canvas>
            <video id="video" width="160" height="90" playsinline></video><script>
            window.audio = new AudioContext();
            const streamAudio = audio.createMediaStreamDestination();
            window.addTone = () => {
                const oscillator = audio.createOscillator(), gain = audio.createGain();
                gain.gain.value = 0.001;
                oscillator.connect(gain).connect(audio.destination); oscillator.start();
                gain.connect(streamAudio);
            };
            const context = canvas.getContext('2d'); let frame = 0;
            setInterval(() => { context.fillStyle = (++frame % 2) ? 'red' : 'blue';
                context.fillRect(0, 0, 160, 90); }, 50);
            video.srcObject = new MediaStream([...canvas.captureStream(20).getTracks(), ...streamAudio.stream.getTracks()]);
            video.volume = 0.4;
            window.presentedFrames = 0;
            const observeFrame = () => video.requestVideoFrameCallback(() => { presentedFrames++; observeFrame(); });
            window.start = async () => { addTone(); await audio.resume(); await video.play(); observeFrame(); };
            window.sample = () => ({ videoTime: video.currentTime, audioTime: audio.currentTime,
                frames: video.getVideoPlaybackQuality().totalVideoFrames, paused: video.paused,
                presentedFrames, elementMuted: video.muted, volume: video.volume, audioState: audio.state });
            </script>
            """, baseURL: URL(string: "https://audio-fixture.example.test"))
        try await wait { self.page.webView.title == "Local audio mute fixture" && !self.page.webView.isLoading }
        _ = try await page.webView.callAsyncJavaScript("await start(); return true", arguments: [:], in: nil, contentWorld: .page)
        _ = try await page.webView.callAsyncJavaScript("""
            const end = Date.now() + 8000;
            while (presentedFrames == 0 && Date.now() < end) await new Promise(resolve => setTimeout(resolve, 20));
            if (presentedFrames == 0) throw new Error('Fixture did not present a video frame');
            return true;
            """, arguments: [:], in: nil, contentWorld: .page)
    }
    func sample() async throws -> [String: Any] {
        let value = try await page.webView.evaluateJavaScript("sample()")
        return try XCTUnwrap(value as? [String: Any])
    }
    func wait(file: StaticString = #filePath, line: UInt = #line,
              _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Timed out waiting for local media state (muted: \(WebKitAudioMute.isMuted(page.webView)), playing audio: \(WebKitAudioMute.isPlayingAudio(page.webView)))", file: file, line: line)
    }
}
