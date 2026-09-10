// Non-production interoperability fixtures generated with Apple Security/CryptoKit.
// All exported private keys are PUBLIC TEST MATERIAL, never enrollment secrets.
import Foundation
import CryptoKit
import Security

func b64(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
func json(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
}
func publicJWK(_ key: P256.Signing.PrivateKey) -> [String: String] {
    let bytes = key.publicKey.x963Representation
    return ["kty": "EC", "crv": "P-256", "x": b64(bytes.subdata(in: 1..<33)), "y": b64(bytes.subdata(in: 33..<65))]
}
func sign(_ claims: [String: Any], key: P256.Signing.PrivateKey, type: String) throws -> String {
    let input = b64(try json(["alg": "ES256", "typ": type])) + "." + b64(try json(claims))
    return input + "." + b64(try key.signature(for: Data(input.utf8)).rawRepresentation)
}
var keyError: Unmanaged<CFError>?
// Generate a public-test RSA key with OpenSSL, then import its PKCS#1 DER
// without Keychain access. Pass its path as the second command-line argument.
let rsaDER = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
guard let server = SecKeyCreateWithData(rsaDER as CFData, [
    kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate,
    kSecAttrKeySizeInBits: 3072
] as CFDictionary, &keyError) else { throw keyError!.takeRetainedValue() }
let device = P256.Signing.PrivateKey()
let receipt = P256.Signing.PrivateKey()
let sourceID = "11111111-1111-4111-8111-111111111111"
let payload: [String: Any] = [
    "captured_at": "2026-09-10T12:00:00Z",
    "history": ["kind": "snapshot", "snapshot_id": "33333333-3333-4333-8333-333333333333",
        "start_at": "2026-01-01T00:00:00Z", "end_at": "2026-09-10T12:00:00Z", "complete": true],
    "accounts": [["source_id": sourceID, "mapping_version": 1, "observed_at": "2026-09-10T12:00:00Z",
        "booked_balance": ["amount": "112.6600", "currency": "USD", "credit_debit": "credit"]]],
    "transactions": [["source_id": "22222222-2222-4222-8222-222222222222", "account_id": sourceID,
        "mapping_version": 1, "amount": "12.3400", "currency": "USD", "credit_debit": "debit",
        "transacted_at": "2026-09-01T06:00:00Z", "posted_at": "2026-09-01T07:00:00Z",
        "status": "booked", "type": "purchase", "merchant": "Synthetic shop"]], "tombstones": []
]
let plaintext = try json(payload)
let header = b64(Data(#"{"alg":"RSA-OAEP","enc":"A256GCM"}"#.utf8))
let cek = SymmetricKey(size: .bits256)
let cekData = cek.withUnsafeBytes { Data($0) }
let encryptedKey = SecKeyCreateEncryptedData(SecKeyCopyPublicKey(server)!, .rsaEncryptionOAEPSHA1, cekData as CFData, &keyError)! as Data
let box = try AES.GCM.seal(plaintext, using: cek, authenticating: Data(header.utf8))
let jwe = [header, b64(encryptedKey), b64(box.nonce.withUnsafeBytes { Data($0) }), b64(box.ciphertext), b64(box.tag)].joined(separator: ".")
let digest = SHA256.hash(data: Data(jwe.utf8)).map { String(format: "%02x", $0) }.joined()
let connectionID = "44444444-4444-4444-8444-444444444444"
let batchID = "55555555-5555-4555-8555-555555555555"
let claims: [String: Any] = ["aud": "sure-test-server", "protocol": 1, "connection_id": connectionID,
    "generation": 1, "batch_id": batchID, "sequence": 1, "previous_digest": NSNull(), "digest": digest, "ciphertext": jwe]
let receiptClaims: [String: Any] = ["aud": connectionID, "iss": "sure-test-server", "protocol": 1,
    "batch_id": batchID, "generation": 1, "sequence": 1, "digest": digest, "status": "accepted",
    "counts": [:], "error_code": NSNull(), "accepted_at": "2026-09-10T12:00:00.000000Z",
    "applied_at": NSNull(), "issued_at": "2026-09-10T12:00:00.000000Z"]
let privateDER = SecKeyCopyExternalRepresentation(server, &keyError)! as Data
let base64DER = privateDER.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
let vectors: [String: Any] = [
    "notice": "PUBLIC TEST MATERIAL. Never use these private keys in an installation.",
    "producer": "Apple CryptoKit and Security; ES256, RSA-OAEP (SHA-1), A256GCM; compact JOSE",
    "server_private_pem": "-----BEGIN RSA PRIVATE KEY-----\n" + base64DER + "\n-----END RSA PRIVATE KEY-----\n",
    "device_public_jwk": publicJWK(device), "receipt_public_jwk": publicJWK(receipt),
    "connection_id": connectionID, "payload": payload, "claims": claims,
    "upload_jws": try sign(claims, key: device, type: "sure-financekit+jwt"),
    "receipt_jws": try sign(receiptClaims, key: receipt, type: "sure-financekit-receipt+jwt")
]
let output = try JSONSerialization.data(withJSONObject: vectors, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
try output.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
// Independently check the round trip using the same standard Apple algorithms.
let recoveredCEK = SecKeyCreateDecryptedData(server, .rsaEncryptionOAEPSHA1, encryptedKey as CFData, &keyError)! as Data
let recovered = try AES.GCM.open(box, using: SymmetricKey(data: recoveredCEK), authenticating: Data(header.utf8))
precondition(recovered == plaintext)
print("Generated and verified Apple JOSE test vectors")
