import XCTest
@testable import QuantSwarmAlphaZero

final class UpdateCheckerTests: XCTestCase {
    private let source = Data(#"""
    {"name":"FMLAB","identifier":"fmlab.quantswarm","apps":[
      {"name":"Altro","bundleIdentifier":"com.altro","versions":[{"version":"9.9.9","buildVersion":"999","downloadURL":"https://x/a.ipa"}]},
      {"name":"QuantSwarm","bundleIdentifier":"com.quantswarm.alphazero","versions":[
        {"version":"1.1.0","buildVersion":"102","downloadURL":"https://github.com/cipherdesk007-max/quantswarm-releases/releases/download/v1.1.0/QuantSwarm-Alpha-Zero.ipa","localizedDescription":"note"},
        {"version":"1.2.0","buildVersion":"120","downloadURL":"https://github.com/cipherdesk007-max/quantswarm-releases/releases/download/v1.2.0/QuantSwarm-Alpha-Zero.ipa"},
        {"version":"0.9","buildVersion":"50","downloadURL":"http://insicuro/a.ipa"}
      ]}]}
    """#.utf8)

    func testPicksHighestBuildForThisApp() throws {
        let latest = try XCTUnwrap(UpdateChecker.latest(from: source))
        XCTAssertEqual(latest.version, "1.2.0")
        XCTAssertEqual(latest.build, 120)
    }

    func testNewerOnlyWhenBuildIsHigher() throws {
        let latest = try XCTUnwrap(UpdateChecker.latest(from: source))
        XCTAssertTrue(UpdateChecker.isNewer(latest, than: 102))
        XCTAssertFalse(UpdateChecker.isNewer(latest, than: 120))
        XCTAssertFalse(UpdateChecker.isNewer(latest, than: nil))
    }

    func testBadOrForeignSourceGivesNothing() {
        XCTAssertNil(UpdateChecker.latest(from: Data("non json".utf8)))
        XCTAssertNil(UpdateChecker.latest(from: Data(#"{"apps":[]}"#.utf8)))
    }

    func testLiveContainerLinkEncodesTheIPAURL() throws {
        let latest = try XCTUnwrap(UpdateChecker.latest(from: source))
        let url = try XCTUnwrap(UpdateChecker.liveContainerInstallURL(for: latest))
        XCTAssertTrue(url.absoluteString.hasPrefix("livecontainer://install?url=https"))
        XCTAssertFalse(url.absoluteString.dropFirst("livecontainer://install?url=".count).contains("&"))
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.queryItems?.first?.value, latest.downloadURL.absoluteString)
    }

    func testSideStoreLinkEncodesTheIPAURL() throws {
        let latest = try XCTUnwrap(UpdateChecker.latest(from: source))
        let url = try XCTUnwrap(UpdateChecker.sideStoreInstallURL(for: latest))
        XCTAssertTrue(url.absoluteString.hasPrefix("sidestore://install?url=https"))
        XCTAssertFalse(url.absoluteString.dropFirst("sidestore://install?url=".count).contains("&"))
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.queryItems?.first?.value, latest.downloadURL.absoluteString)
    }

    @MainActor
    func testInstallURLFollowsTheStore() throws {
        let latest = try XCTUnwrap(UpdateChecker.latest(from: source))
        let lc = try XCTUnwrap(UpdateChecker.installURL(for: latest, store: .liveContainer))
        let ss = try XCTUnwrap(UpdateChecker.installURL(for: latest, store: .sideStore))
        XCTAssertTrue(lc.absoluteString.hasPrefix("livecontainer://install?url="))
        XCTAssertTrue(ss.absoluteString.hasPrefix("sidestore://install?url="))
        XCTAssertEqual(UpdateChecker.installURL(for: latest, store: .download), latest.downloadURL)
    }

    @MainActor
    func testSourceURLPerStore() {
        XCTAssertTrue(UpdateChecker.storeSourceURL(for: .liveContainer)?.absoluteString
            .hasPrefix("livecontainer://source?url=") ?? false)
        XCTAssertTrue(UpdateChecker.storeSourceURL(for: .sideStore)?.absoluteString
            .hasPrefix("sidestore://source?url=") ?? false)
        XCTAssertEqual(UpdateChecker.storeSourceURL(for: .download), UpdateChecker.sourceURL)
    }

    @MainActor
    func testCurrentStorePrefersSideStoreThenFallsBackToDownload() {
        XCTAssertFalse(UpdateChecker.isRunningInLiveContainer)
        XCTAssertEqual(UpdateChecker.currentStore(canOpenScheme: { _ in true }), .sideStore)
        XCTAssertEqual(UpdateChecker.currentStore(canOpenScheme: { _ in false }), .download)
    }
}
