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

    /// `Encrypt_MD5(data)` — lassoguide.com `operations/encryption.html`:
    /// "Hashes a string using the one-way MD5 hash algorithm... Returns a
    /// fixed-size hash value in hexadecimal as a string" — always hex, no
    /// output-format flags (unlike `Encrypt_HMAC`'s -Base64/-Hex/-Cram).
    static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `Cipher_Digest(data, -digest, -hex?)` — a general one-shot digest,
    /// distinct from `Encrypt_HMAC` (keyed) above. Only the algorithms
    /// swift-crypto actually provides are supported: MD5/SHA1/SHA256/
    /// SHA384/SHA512 — real Lasso's own list (`Cipher_List(-digest)`,
    /// same page) is much larger (MD2/MD4/SHA/DSA-SHA/DSA/RIPEMD160),
    /// backed by a full OpenSSL binding this codebase doesn't have and
    /// isn't adding as a new dependency for this stage; `cipherDigestNames`
    /// below discloses exactly this supported subset for `Cipher_List`.
    static func digest(_ data: Data, algorithm: String) -> Data? {
        switch algorithm.lowercased() {
        case "md5": Data(Insecure.MD5.hash(data: data))
        case "sha1": Data(Insecure.SHA1.hash(data: data))
        case "sha256": Data(SHA256.hash(data: data))
        case "sha384": Data(SHA384.hash(data: data))
        case "sha512": Data(SHA512.hash(data: data))
        default: nil
        }
    }

    static let cipherDigestNames = ["MD5", "SHA1", "SHA256", "SHA384", "SHA512"]

    /// `Cipher_Encrypt`/`Cipher_Decrypt(data, -cipher, -key, -seed?)` —
    /// real Lasso supports a wide OpenSSL-backed cipher list (AES/DES/
    /// 3DES/RC4/RC2/CAST5/RC5, `Cipher_List`'s own worked example);
    /// swift-crypto's only general-purpose symmetric cipher is AES-GCM
    /// (authenticated, nonce-based) — `-cipher` values containing "AES"
    /// (case-insensitively) map to it, anything else is unsupported
    /// (returns `nil`, surfaced as a recoverable error by the call
    /// site — see `Runtime.swift`'s registrations). This is a loose
    /// substring match on the algorithm family only: a real OpenSSL-
    /// style name like `-cipher='AES-256-CBC'` or `'AES-128-ECB'` also
    /// matches and silently gets AES-GCM regardless — the mode/key-size
    /// portion of the name is ignored entirely, not just unsupported
    /// modes/sizes specifically. `-key` is arbitrary-
    /// length string/byte material in Lasso's own docs, but
    /// `SymmetricKey` needs a fixed size — SHA-256-hashing it into a
    /// 32-byte AES-256 key is a reasonable, disclosed design decision
    /// (not something Lasso's own docs specify, since real Lasso's
    /// OpenSSL binding presumably has its own key-derivation convention
    /// this codebase has no way to replicate exactly without that same
    /// binding). Ciphertext is `nonce + sealed.ciphertext + sealed.tag`
    /// concatenated, so `decrypt` can recover the nonce/tag without
    /// needing them passed separately — real Lasso's own wire format
    /// for this isn't documented either.
    static func cipherKey(_ keyMaterial: Data) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: keyMaterial))
    }

    static func cipherEncrypt(_ data: Data, cipher: String, keyMaterial: Data) -> Data? {
        guard cipher.lowercased().contains("aes") else { return nil }
        guard let sealed = try? AES.GCM.seal(data, using: cipherKey(keyMaterial)) else { return nil }
        return sealed.nonce.withUnsafeBytes { Data($0) } + sealed.ciphertext + sealed.tag
    }

    static func cipherDecrypt(_ data: Data, cipher: String, keyMaterial: Data) -> Data? {
        guard cipher.lowercased().contains("aes") else { return nil }
        let nonceSize = 12
        let tagSize = 16
        // `>=`, not `>` — AES-GCM ciphertext length equals plaintext
        // length exactly (no padding), so encrypting an EMPTY string
        // produces exactly `nonceSize + 0 + tagSize` bytes; a strict `>`
        // here incorrectly rejected that valid empty-plaintext round
        // trip (caught by architect review).
        guard data.count >= nonceSize + tagSize else { return nil }
        guard let nonce = try? AES.GCM.Nonce(data: data.prefix(nonceSize)) else { return nil }
        let ciphertext = data.dropFirst(nonceSize).dropLast(tagSize)
        let tag = data.suffix(tagSize)
        guard let sealed = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag) else { return nil }
        return try? AES.GCM.open(sealed, using: cipherKey(keyMaterial))
    }
}
