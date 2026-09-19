import Foundation

public enum AppIdentity {
    public static let name = "kongshan"
    public static let bundleIdentifier = "com.kaysen.kongshan"
    public static let supportDirectory = resolvedSupportDirectory()

    /// `CFFIXED_USER_HOME` is no longer consistently honored by Foundation in
    /// hardened macOS app bundles. The release verifier needs an explicit,
    /// tightly-scoped override or its candidate process can touch real user data.
    public static func resolvedSupportDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = releaseVerificationSupportDirectory(environment: environment) { return override }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: name, directoryHint: .isDirectory)
    }

    public static func releaseVerificationSupportDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let raw = environment["KONGSHAN_TEST_SUPPORT_DIRECTORY"] else {
            return nil
        }
        let support = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
        guard support.lastPathComponent == "support" else { return nil }
        let verificationRoot = support.deletingLastPathComponent()
        guard verificationRoot.lastPathComponent.hasPrefix("kongshan-verify-") else { return nil }
        let temporaryRoot = verificationRoot.deletingLastPathComponent().path
        guard temporaryRoot == "/tmp" || temporaryRoot == "/private/tmp" else { return nil }
        return support
    }
}
