import CryptoKit
import Foundation

// Only the public key is printed. The private seed stays in the supplied file.
guard CommandLine.arguments.count == 2 else { exit(2) }
do {
    let file = URL(fileURLWithPath: CommandLine.arguments[1])
    let encoded = try String(contentsOf: file, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let seed = Data(base64Encoded: encoded), seed.count == 32 else { exit(2) }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    print(key.publicKey.rawRepresentation.base64EncodedString())
} catch {
    fputs("Could not read the Sparkle signing seed.\n", stderr)
    exit(1)
}
