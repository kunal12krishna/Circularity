// Prints "<sha256> <signature>" for a DMG: the SHA-256 of the file, signed with the
// update key (scripts/update-key.swift). The app checks both before it installs anything.
//   swift scripts/sign-update.swift dist/Circularity.dmg
import CryptoKit
import Foundation

let key = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/circularity/update-signing-key")
let hex = { (d: Data) in d.map { String(format: "%02x", $0) }.joined() }
func unhex(_ s: String) -> Data { Data(stride(from: 0, to: s.count, by: 2).compactMap { i in
    UInt8(s[s.index(s.startIndex, offsetBy: i)..<s.index(s.startIndex, offsetBy: i + 2)], radix: 16) }) }
guard CommandLine.arguments.count == 2, let text = try? String(contentsOf: key, encoding: .utf8) else {
    FileHandle.standardError.write(Data("usage: sign-update.swift <file> (needs \(key.path); make it with update-key.swift)\n".utf8)); exit(1)
}
let signer = try Curve25519.Signing.PrivateKey(rawRepresentation: unhex(text.trimmingCharacters(in: .whitespacesAndNewlines)))
let digest = Data(SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)))
print(hex(digest), hex(try signer.signature(for: digest)))
