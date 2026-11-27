#!/usr/bin/env swift
// Signs a release's zip so that installed copies of Tint will accept it as an
// update, and checks such signatures. Tint only replaces itself with an archive
// signed by the private half of the key whose public half is built into it
// (UpdateInstaller.publicKey), so a release someone else managed to publish
// can't be installed.
//
//   swift scripts/update-signature.swift generate <key file>          make a key; prints its public half
//   swift scripts/update-signature.swift public <key file>            print the public half
//   swift scripts/update-signature.swift sign <key file> <file>       print the file's signature
//   swift scripts/update-signature.swift verify <public> <file> <sig> exit 0 when the signature fits
//
// The key file holds the private key and belongs outside the repository
// (scripts/release.sh looks in ~/.config/tint/update-key). Lose it and
// installed copies can't be updated from inside the app again.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func privateKey(at path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("\(path) isn't an update key") }
    return key
}

func contents(of path: String) -> Data {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { fail("can't read \(path)") }
    return data
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch (arguments.first, arguments.count) {
case ("generate", 2):
    let path = arguments[1]
    guard !FileManager.default.fileExists(atPath: path) else { fail("\(path) already exists; a new key would orphan every installed copy") }
    let key = Curve25519.Signing.PrivateKey()
    try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
    // Readable by its owner only, from the moment it exists.
    guard FileManager.default.createFile(atPath: path, contents: Data((key.rawRepresentation.base64EncodedString() + "\n").utf8),
                                         attributes: [.posixPermissions: 0o600])
    else { fail("can't write \(path)") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case ("public", 2):
    print(privateKey(at: arguments[1]).publicKey.rawRepresentation.base64EncodedString())
case ("sign", 3):
    guard let signature = try? privateKey(at: arguments[1]).signature(for: contents(of: arguments[2])) else { fail("signing failed") }
    print(signature.base64EncodedString())
case ("verify", 4):
    guard let raw = Data(base64Encoded: arguments[1]), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { fail("not a public key") }
    guard let signature = Data(base64Encoded: arguments[3].trimmingCharacters(in: .whitespacesAndNewlines)) else { fail("not a signature") }
    guard key.isValidSignature(signature, for: contents(of: arguments[2])) else { fail("the signature doesn't fit") }
default:
    fail("usage: update-signature.swift generate <key file> | public <key file> | sign <key file> <file> | verify <public> <file> <signature>")
}
