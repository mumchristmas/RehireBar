import CryptoKit
import Foundation

// A fresh test-only seed. Production signing keys are never accessed by this test.
guard CommandLine.arguments.count == 2 else { exit(2) }
let key = Curve25519.Signing.PrivateKey()
let url = URL(fileURLWithPath: CommandLine.arguments[1])
try key.rawRepresentation.base64EncodedString().write(to: url, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
print(key.publicKey.rawRepresentation.base64EncodedString())
