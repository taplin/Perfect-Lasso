import Crypto
import Foundation

/// `Encrypt_HMAC` — LassoGuide 9.3 `operations/encryption.html`:
/// `encrypt_hmac(-password, -token, -digest='MD5', -base64, -hex, -cram)`.
/// `-password` is the key, `-token` is the message. See
/// `Documentation/outstanding-compatibility-project-plans.md`.
enum LassoHashing {
    /// `-digest` name -> algorithm, matching this codebase's established
    /// "unrecognized/missing keyword falls through to a benign default,
    /// not a thrown error" convention (`LassoEncoding.keyword(in:)`) —
    /// defaulting specifically to MD5 here (not passing the value through
    /// unchanged) since that's Encrypt_HMAC's own documented default.
    static func hmac(password: String, token: String, digest: String) -> Data {
        let key = SymmetricKey(data: Data(password.utf8))
        let message = Data(token.utf8)
        switch digest.lowercased() {
        case "sha1":
            return Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case "sha256":
            return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case "sha384":
            return Data(HMAC<SHA384>.authenticationCode(for: message, using: key))
        case "sha512":
            return Data(HMAC<SHA512>.authenticationCode(for: message, using: key))
        default:
            return Data(HMAC<Insecure.MD5>.authenticationCode(for: message, using: key))
        }
    }
}
