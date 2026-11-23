// One-time: makes the Ed25519 key that signs updates, or prints the public half of the one you have.
// The private key stays in ~/.config/circularity/update-signing-key (never in the repo);
// the public key goes in Config/Base.xcconfig as UPDATE_PUBLIC_KEY.
//   swift scripts/update-key.swift
import CryptoKit
import Foundation

let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/circularity", isDirectory: true)
let file = dir.appendingPathComponent("update-signing-key")
let hex = { (d: Data) in d.map { String(format: "%02x", $0) }.joined() }
func unhex(_ s: String) -> Data { Data(stride(from: 0, to: s.count, by: 2).compactMap { i in
    UInt8(s[s.index(s.startIndex, offsetBy: i)..<s.index(s.startIndex, offsetBy: i + 2)], radix: 16) }) }

let key: Curve25519.Signing.PrivateKey
if let text = try? String(contentsOf: file, encoding: .utf8) {
    key = try Curve25519.Signing.PrivateKey(rawRepresentation: unhex(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    FileHandle.standardError.write(Data("Using the key in \(file.path)\n".utf8))
} else {
    key = Curve25519.Signing.PrivateKey()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try hex(key.rawRepresentation).write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    FileHandle.standardError.write(Data("Made a new key: \(file.path) (keep it safe and private)\n".utf8))
}
print(hex(key.publicKey.rawRepresentation))
