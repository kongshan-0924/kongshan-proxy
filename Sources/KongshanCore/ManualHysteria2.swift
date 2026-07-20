import Foundation

public enum ManualHysteria2Error: Error, Equatable, LocalizedError {
    case emptyName
    case emptyServer
    case invalidPort
    case emptyPassword
    case invalidUploadBandwidth
    case invalidDownloadBandwidth

    public var errorDescription: String? {
        switch self {
        case .emptyName: "名称不能为空"
        case .emptyServer: "服务器地址不能为空"
        case .invalidPort: "端口必须在 1 到 65535 之间"
        case .emptyPassword: "密码不能为空"
        case .invalidUploadBandwidth: "上行带宽必须大于 0"
        case .invalidDownloadBandwidth: "下行带宽必须大于 0"
        }
    }
}

public struct ManualHysteria2: Equatable, Sendable {
    public var name: String
    public var server: String
    public var port: Int
    public var password: String
    public var sni: String
    public var skipCertificateVerification: Bool
    public var obfsPassword: String?
    public var uploadMbps: Int?
    public var downloadMbps: Int?

    public init(
        name: String,
        server: String,
        port: Int,
        password: String,
        sni: String,
        skipCertificateVerification: Bool,
        obfsPassword: String?,
        uploadMbps: Int?,
        downloadMbps: Int?
    ) {
        self.name = name
        self.server = server
        self.port = port
        self.password = password
        self.sni = sni
        self.skipCertificateVerification = skipCertificateVerification
        self.obfsPassword = obfsPassword
        self.uploadMbps = uploadMbps
        self.downloadMbps = downloadMbps
    }

    public func makeNode(id: UUID = UUID()) throws -> ProxyNode {
        let name = name.trimmed
        guard !name.isEmpty else { throw ManualHysteria2Error.emptyName }

        let server = server.trimmed
        guard !server.isEmpty else { throw ManualHysteria2Error.emptyServer }
        guard (1...65_535).contains(port) else { throw ManualHysteria2Error.invalidPort }

        let password = password.trimmed
        guard !password.isEmpty else { throw ManualHysteria2Error.emptyPassword }
        if let uploadMbps, uploadMbps <= 0 { throw ManualHysteria2Error.invalidUploadBandwidth }
        if let downloadMbps, downloadMbps <= 0 { throw ManualHysteria2Error.invalidDownloadBandwidth }

        return ProxyNode(
            id: id,
            name: name,
            protocolType: .hysteria2,
            server: server,
            port: port,
            password: password,
            tlsEnabled: true,
            sni: sni.nilIfEmpty,
            skipCertificateVerification: skipCertificateVerification,
            obfsPassword: obfsPassword?.nilIfEmpty,
            uploadMbps: uploadMbps,
            downloadMbps: downloadMbps
        )
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? {
        let value = trimmed
        return value.isEmpty ? nil : value
    }
}
