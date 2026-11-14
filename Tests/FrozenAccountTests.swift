import XCTest
@testable import QuantSwarmAlphaZero

/// "Trading sospeso" si riconosce dal messaggio di Alpaca, non dal codice
/// 40310000: quel codice arriva anche per il saldo insufficiente (messaggio
/// vero letto sul conto paper il 14/11/2026).
final class FrozenAccountTests: XCTestCase {
    func testUserSuspensionMessageIsAFrozenAccount() {
        let error = QuantSwarmError.httpStatus(
            403, "{\"code\":40310000,\"message\":\"new orders are rejected by user request\"}")
        XCTAssertTrue(QuantSwarmError.isAccountFrozen(error))
    }

    func testInsufficientBalanceWithTheSameCodeIsNotAFrozenAccount() {
        let error = QuantSwarmError.httpStatus(
            403, "{\"available\":\"0\",\"balance\":\"0.00017944\",\"code\":40310000,\"message\":\"insufficient balance for BTC (requested: 0.00017944, available: 0)\",\"symbol\":\"USD\"}")
        XCTAssertFalse(QuantSwarmError.isAccountFrozen(error))
        XCTAssertFalse(QuantSwarmError.isAccountFrozen(URLError(.timedOut)))
    }
}
