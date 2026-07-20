import Foundation

public enum AppIdentity {
    public static let name = "kongshan"
    public static let bundleIdentifier = "com.kaysen.kongshan"
    public static let supportDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: name, directoryHint: .isDirectory)
}
