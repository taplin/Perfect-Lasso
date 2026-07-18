import Foundation

/// The `bytes` type — lassoguide.com "Byte Streams": a raw byte-array type,
/// distinct from `string`, with `->decodeBase64`/`->encodeBase64`/
/// `->encodeUrl` member methods. Real corpus (pages/account.page.lasso,
/// order_history.page.lasso, order_reporting.page.lasso,
/// online_return.page.lasso, view_purchased_giftcerts.lasso,
/// account_info_static.lasso) always uses exactly this trio —
/// `bytes(value)->decodeBase64`/`bytes(value)->encodeBase64->encodeUrl` —
/// to round-trip an identifier (e.g. `cust_id`) through a URL query
/// parameter. lassoguide.com documents a much larger member surface
/// (size/get/contains/find/split/encodeHex/encodeMd5/encodeQP/encodeSql/
/// append/replace/trim/padLeading/forEachByte/etc.) — deliberately not
/// implemented here; none of it appears anywhere in this project's real
/// site corpus.
///
/// A `bytes` value is `.object(LassoObjectInstance(typeName: "bytes"))`,
/// matching the existing `date` native type's representation (see
/// `NativeTypes.swift`). The raw byte content is stored losslessly as a
/// base64 string in a private-by-convention `_base64` field — storing the
/// raw bytes directly as a `.string` would either lose data (a lossy UTF-8
/// decode, same known gap `Decode_Base64`/`Encrypt_HMAC`'s no-output-flag
/// path already live with) or be flatly impossible for non-UTF-8-valid
/// binary. Base64 round-trips any byte sequence exactly.
enum LassoBytesValue {
    static let typeName = "bytes"

    static func makeObject(rawBytes: [UInt8]) -> LassoObjectInstance {
        LassoObjectInstance(typeName: typeName, data: ["_base64": .string(Data(rawBytes).base64EncodedString())])
    }

    static func rawBytes(from receiver: LassoObjectInstance) -> [UInt8] {
        guard case let .string(encoded) = receiver.value(for: "_base64"),
              let data = Data(base64Encoded: encoded) else {
            return []
        }
        return Array(data)
    }

    /// Lossy UTF-8 decode of the current raw byte content — used for both
    /// bare output (`[$myBytes]`) and `string(bytesValue)`, matching the
    /// same documented fallback `includeBytes` already uses for the same
    /// underlying reason (no lossless string representation exists for
    /// arbitrary binary).
    static func string(from receiver: LassoObjectInstance) -> String {
        String(decoding: rawBytes(from: receiver), as: UTF8.self)
    }
}
