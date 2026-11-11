import XCTest
@testable import QuantSwarmAlphaZero

final class AccountsTests: XCTestCase {
    func testOldCredentialsBecomeOneProfile() throws {
        let json = #"{"moonshotAPIKey":"k","alpacaKeyID":"PKAAAA1111","alpacaSecretKey":"s","paperTrading":true}"#
        let stored = try JSONDecoder().decode(StoredCredentials.self, from: Data(json.utf8))
        XCTAssertEqual(stored.allProfiles.count, 1)
        XCTAssertEqual(stored.activeID, stored.allProfiles.first?.id)
    }

    func testActivatingKeepsKimiKeyAndList() {
        let a = AlpacaProfile(id: "a", name: "Paper 1000", keyID: "PK1", secretKey: "s1", paperTrading: true)
        let b = AlpacaProfile(id: "b", name: "Paper grande", keyID: "PK2", secretKey: "s2", paperTrading: true)
        let stored = StoredCredentials(moonshotAPIKey: "kimi", alpacaKeyID: "PK1", alpacaSecretKey: "s1",
                                       paperTrading: true, profiles: [a, b], activeProfileID: "a")
        let switched = stored.activating(b, in: stored.allProfiles)
        XCTAssertEqual(switched.moonshotAPIKey, "kimi")
        XCTAssertEqual(switched.alpacaKeyID, "PK2")
        XCTAssertEqual(switched.activeID, "b")
        XCTAssertEqual(switched.allProfiles.count, 2)
    }

    func testDailyBookIsPerAccountAndMigratesLegacy() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "test.books.\(UUID().uuidString)"))
        var legacy = DailyBook()
        legacy.entries["SPY"] = "2026-11-01"
        DailyBookStore.save(legacy, account: nil, defaults: defaults)
        // Il primo conto che apre il registro eredita quello vecchio.
        XCTAssertEqual(DailyBookStore.load(account: "PA1", defaults: defaults).entries["SPY"], "2026-11-01")
        DailyBookStore.save(legacy, account: "PA1", defaults: defaults)
        // Un altro conto parte vuoto.
        XCTAssertTrue(DailyBookStore.load(account: "PA2", defaults: defaults).entries.isEmpty)
        XCTAssertEqual(DailyBookStore.load(account: "PA1", defaults: defaults).entries["SPY"], "2026-11-01")
    }
}
