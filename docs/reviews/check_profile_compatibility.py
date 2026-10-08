#!/usr/bin/env python3
"""Exercise actual profile codecs at two Git revisions using synthetic data only.

No app is launched. No UserDefaults, Keychain, CLI auth files, or live APIs are
accessed. Unrelated usage-cache and service types are stubbed; Profile,
MenuBarIconConfiguration, provider/configuration types and notification settings
come from the specified revisions. Requires macOS, Python 3, Git and swiftc.
"""

import argparse
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
MODELS = "Claude Usage/Shared/Models/"


def source(ref, path):
    return subprocess.check_output(
        ["git", "show", f"{ref}:{path}"], cwd=ROOT, text=True
    )


STUBS = """
import Foundation
struct ClaudeUsage: Codable, Equatable {}
struct APIUsage: Codable, Equatable {}
final class ClaudeCodeSyncService {
    static let shared = ClaudeCodeSyncService()
    func isTokenExpired(_ json: String) -> Bool { false }
}
final class CodexAuthService {
    static let shared = CodexAuthService()
    func authFileExists() -> Bool { false }
}
struct ProviderDescriptor {}
enum ProviderRegistry {
    static func descriptor(for provider: Provider) -> ProviderDescriptor {
        ProviderDescriptor()
    }
}
"""

LOCAL_MAIN = """
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let profiles = [
    Profile(name: "Synthetic Claude", provider: .claude),
    Profile(name: "Synthetic Codex", provider: .codex,
        codexConfiguration: CodexProfileConfiguration(connectionType: .ssh,
            executablePath: "/opt/example/codex", codexHome: "/example/account-a",
            sshHost: "synthetic-host", selectedRateLimitID: "named-limit"),
        iconConfig: .codexProfileDefault),
    Profile(name: "Synthetic Zai", provider: .zai,
        zaiConfiguration: ZAIProfileConfiguration(selectedLimitID: "CREDIT_LIMIT-6"),
        iconConfig: .zaiProfileDefault)
]
let data = try JSONEncoder().encode(profiles)
let roundTrip = try JSONDecoder().decode([Profile].self, from: data)
precondition(roundTrip.count == 3)
try data.write(to: folder.appendingPathComponent("fork-profiles.json"))
let metricNames = profiles[0].iconConfig.metrics.map { $0.metricType.rawValue }
print("Fork default Claude metrics: \\(metricNames.joined(separator: ", "))")
print("Fork synthetic round-trip: 3 profiles preserved")
"""

UPSTREAM_MAIN = """
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let data = try Data(contentsOf: folder.appendingPathComponent("fork-profiles.json"))
do {
    _ = try JSONDecoder().decode([Profile].self, from: data)
    fatalError("Unexpected: upstream accepted fork metrics; review findings changed")
} catch {
    print("Upstream decoding unchanged fork array: FAILED (expected)")
    print("  \\(error)")
}
let original = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
for item in original {
    do {
        _ = try JSONDecoder().decode(Profile.self,
            from: JSONSerialization.data(withJSONObject: item))
        fatalError("Unexpected: upstream accepted fork metrics")
    } catch {
        print("Upstream individual fork profile \\(item["provider"]!): FAILED (expected)")
    }
}
// Remove only the unsupported metrics to expose the next compatibility layer.
let normalized = original.map { item -> [String: Any] in
    var item = item
    var icon = item["iconConfig"] as! [String: Any]
    icon["metrics"] = (icon["metrics"] as! [[String: Any]]).filter {
        ["session", "week", "api"].contains($0["metricType"] as! String)
    }
    item["iconConfig"] = icon
    return item
}
let decoded = try JSONDecoder().decode([Profile].self,
    from: JSONSerialization.data(withJSONObject: normalized))
precondition(decoded.map { $0.provider.rawValue } == ["anthropic", "codex", "anthropic"])
print("After removing unsupported metrics: claude -> anthropic, codex -> codex, zai -> anthropic")
let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as! [[String: Any]]
precondition(saved[1]["codexConfiguration"] == nil)
precondition(saved[2]["zaiConfiguration"] == nil)
precondition(decoded[1].codexCredentialsJSON == nil)
print("Upstream re-encode: Codex SSH/home/bucket configuration and Zai configuration dropped")
print("Upstream migrated Codex profile: no per-profile credentials imported")
try JSONEncoder().encode(Profile(name: "Synthetic upstream", provider: .anthropic))
    .write(to: folder.appendingPathComponent("upstream-profile.json"))
"""

ROLLBACK_MAIN = """
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let data = try Data(contentsOf: folder.appendingPathComponent("upstream-profile.json"))
do {
    _ = try JSONDecoder().decode(Profile.self, from: data)
    fatalError("Unexpected: fork accepted upstream anthropic provider")
} catch {
    print("Fork decoding upstream anthropic profile on rollback: FAILED (expected)")
}
"""


INTEGRATION_MAIN = """
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let originalData = try Data(contentsOf: folder.appendingPathComponent("fork-profiles.json"))
let original = try JSONSerialization.jsonObject(with: originalData) as! [[String: Any]]
let profiles = try JSONDecoder().decode([Profile].self, from: originalData)
precondition(profiles.map { $0.provider.rawValue } == ["anthropic", "codex", "zai"])
precondition(profiles.map { $0.id.uuidString } == original.map { $0["id"] as! String })
precondition(profiles[1].codexConfiguration?.sshHost == "synthetic-host")
precondition(profiles[1].codexConfiguration?.codexHome == "/example/account-a")
precondition(profiles[1].codexConfiguration?.selectedRateLimitID == "named-limit")
precondition(profiles[2].zaiConfiguration.selectedLimitID == "CREDIT_LIMIT-6")
precondition(profiles[1].iconConfig.config(for: .session)?.isEnabled == true)
precondition(profiles[2].iconConfig.config(for: .session)?.isEnabled == true)
let saved = try JSONEncoder().encode(profiles)
let decoded = try JSONDecoder().decode([Profile].self, from: saved)
precondition(profiles == decoded)
print("Integration: actual fork codecs accepted, UUIDs/SSH/home/buckets retained, shared metrics enabled")
print("Integration: re-encoded profile array round-trips without loss")
"""

RESTORED_MAIN = """
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let backup = try Data(contentsOf: folder.appendingPathComponent("fork-profiles.json"))
let restored = try JSONDecoder().decode([Profile].self, from: backup)
precondition(restored.count == 3)
precondition(restored.map { $0.provider.rawValue } == ["claude", "codex", "zai"])
precondition(restored[1].codexConfiguration.sshHost == "synthetic-host")
print("Rollback: restoring original bytes loads all three accounts with the actual fork codec")
"""


def model_source(ref, fork, integration=False):
    # Preserve the actual enum used by MetricIconConfig, excluding DataStore.
    icon_style = source(ref, "Claude Usage/Shared/Storage/DataStore.swift")
    icon_style = icon_style[icon_style.index("enum MenuBarIconStyle:"):]
    icon_style = icon_style[:icon_style.index("/// Manages shared data storage")]
    parts = [STUBS, icon_style]
    if fork:
        # The descriptor stub is unused by the fork; its signature still needs
        # an alias because the fork calls its provider enum ProfileProvider.
        parts.append("typealias Provider = ProfileProvider")
        for name in ("CodexSettings", "CodexUsage", "ZAISettings", "ZAIUsage"):
            parts.append(source(ref, MODELS + name + ".swift"))
    else:
        parts.append(source(ref, MODELS + "Provider.swift"))
        if integration:
            for name in ("CodexSettings", "CodexUsage", "ZAISettings", "ZAIUsage"):
                parts.append(source(ref, MODELS + name + ".swift"))
    for name in ("MenuBarIconConfig", "NotificationSettings", "Profile"):
        parts.append(source(ref, MODELS + name + ".swift"))
    return "\n".join(parts)


def run(directory, label, code):
    swift = directory / (label + ".swift")
    binary = directory / label
    swift.write_text(code)
    subprocess.run(["swiftc", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(directory)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fork-ref", default="97712e7")
    parser.add_argument("--upstream-ref", default="588775e")
    parser.add_argument("--integration-ref", help="Also check the adapted integration codecs")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="claude-profile-codec-review-") as tmp:
        directory = Path(tmp)
        fork = model_source(args.fork_ref, True)
        upstream = model_source(args.upstream_ref, False)
        run(directory, "fork", fork + LOCAL_MAIN)
        run(directory, "upstream", upstream + UPSTREAM_MAIN)
        run(directory, "rollback", fork + ROLLBACK_MAIN)
        if args.integration_ref:
            integration = model_source(args.integration_ref, False, integration=True)
            run(directory, "integration", integration + INTEGRATION_MAIN)
            run(directory, "restored", fork + RESTORED_MAIN)


if __name__ == "__main__":
    main()
