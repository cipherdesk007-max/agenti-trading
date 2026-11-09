import Foundation

struct KimiBalance: Decodable, Sendable {
    let availableBalance: Double?
    let voucherBalance: Double?
    let cashBalance: Double?

    enum CodingKeys: String, CodingKey {
        case availableBalance = "available_balance"
        case voucherBalance = "voucher_balance"
        case cashBalance = "cash_balance"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availableBalance = Self.flexibleDouble(container, key: .availableBalance)
        voucherBalance = Self.flexibleDouble(container, key: .voucherBalance)
        cashBalance = Self.flexibleDouble(container, key: .cashBalance)
    }

    private static func flexibleDouble(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let string = try? container.decodeIfPresent(String.self, forKey: key),
           let value = Double(string) {
            return value
        }
        return nil
    }
}

private struct BalanceResponse: Decodable {
    let data: KimiBalance?
}
