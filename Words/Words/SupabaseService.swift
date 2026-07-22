import Foundation
import Supabase

/// The one Supabase client for the whole app.
///
/// Configuration comes from SupabaseConfig.plist, which is gitignored so
/// keys never land in the repo (copy SupabaseConfig.example.plist and fill
/// it in on a fresh checkout). Missing/invalid config fails loudly at first
/// use — same philosophy as the bundled lexicon.
///
/// The SDK stores the session in the iOS Keychain and silently refreshes
/// tokens in the background; both are default behavior in supabase-swift v2.
enum SupabaseService {
    static let client: SupabaseClient = {
        guard let url = Bundle.main.url(forResource: "SupabaseConfig", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let config = try? PropertyListDecoder().decode(Config.self, from: data),
              let projectURL = URL(string: config.projectURL),
              !config.apiKey.isEmpty, !config.apiKey.contains("YOUR-")
        else {
            fatalError("""
                SupabaseConfig.plist is missing or incomplete. Copy \
                SupabaseConfig.example.plist to Words/Words/SupabaseConfig.plist \
                and fill in the project URL and publishable API key.
                """)
        }
        return SupabaseClient(supabaseURL: projectURL, supabaseKey: config.apiKey)
    }()

    private struct Config: Decodable {
        let projectURL: String
        let apiKey: String

        enum CodingKeys: String, CodingKey {
            case projectURL = "ProjectURL"
            case apiKey = "APIKey"
        }
    }
}
