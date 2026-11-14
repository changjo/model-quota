import Foundation

/// Decodes one element of a provider-controlled array, yielding nil instead of failing the
/// whole response when that single element is malformed.
struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
