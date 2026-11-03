import Foundation

// Build-time tool. Deliberately whitelist only Desktop client fields so the
// downloaded project's metadata or any unrelated data cannot enter a release.
do {
    guard CommandLine.arguments.count == 3 else { throw NSError(domain: "Arguments", code: 1) }
    let source = URL(fileURLWithPath: CommandLine.arguments[1])
    let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
          let size = attributes[.size] as? NSNumber, size.intValue < 65536 else {
        throw NSError(domain: "Input", code: 1)
    }
    let data = try Data(contentsOf: source)
    guard data.count < 65536,
          let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          root["web"] == nil, root["type"] == nil,
          let installed = root["installed"] as? [String: Any],
          let id = installed["client_id"] as? String,
          id.hasSuffix(".apps.googleusercontent.com"),
          id.count > ".apps.googleusercontent.com".count,
          !id.contains(where: { $0.isWhitespace }) else { throw NSError(domain: "DesktopClient", code: 1) }
    var client = ["client_id": id]
    if let secret = installed["client_secret"] {
        guard let value = secret as? String else { throw NSError(domain: "DesktopClient", code: 2) }
        client["client_secret"] = value
    }
    let output = try JSONSerialization.data(withJSONObject: ["installed": client], options: [.sortedKeys])
    try output.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
    print("Bundled Desktop OAuth app identity; no user credentials or project settings included.")
} catch {
    // Do not print input contents, client identifiers or secrets into build logs.
    FileHandle.standardError.write(Data("Could not prepare OAuth configuration. Supply a readable Google Desktop app JSON file smaller than 64 KB.\n".utf8))
    exit(1)
}
