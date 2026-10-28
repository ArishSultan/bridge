import BridgeCore
import Foundation
import Security

/// Claude's plan limits (the 5-hour and weekly windows), as Claude Code's `/usage` shows them:
/// asked from Anthropic with Claude Code's own login, which it keeps in the Keychain. Reading
/// that item makes macOS ask the user first, so this only runs when they ask for it.
public enum ClaudePlan {
    public enum Failure: Error, LocalizedError {
        case notSignedIn
        case refused(String)

        public var errorDescription: String? {
            switch self {
            case .notSignedIn: "Claude Code isn't signed in with a Claude plan on this Mac (or access to its login was refused)."
            case .refused(let message): message
            }
        }
    }

    /// The limits now. Blocks while macOS asks for access to the login, so call it off the main
    /// thread.
    public static func limits() async throws -> [Stats.Limit] {
        guard let token = accessToken() else { throw Failure.notSignedIn }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let configuration = URLSessionConfiguration.ephemeral
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.refused(status == 401
                ? "Claude Code's login has expired; run claude once to sign in again."
                : "Anthropic didn't send the plan's usage (\(status)).")
        }
        return Stats.claudeLimits(object)
    }

    /// Claude Code's OAuth access token, from its Keychain item.
    static func accessToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        return token
    }
}
