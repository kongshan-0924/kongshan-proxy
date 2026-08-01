import Foundation
import XCTest
@testable import KongshanCore

/// 内网 DNS 分流的回归测试。
///
/// 真机事故（2026-07-30，企业网 AD 域，域控兼 DNS 在 172.16.16.7）：TUN 模式下
/// Windows App 连内网设备"一直在加载"。查出来路由是对的（`route_exclude_address` 把
/// 172.16.0.0/12 精确留给了物理网卡，TCP 3389/389/135/445 实测全通），坏的是 DNS——
/// 内网 AD 域是个 `.com`，既不命中 geosite-cn 也就必然掉进 fakeip，
/// 拿到 240.0.0.21 这个假 IP，而假 IP 整段被路由进代理出口。
final class LANResolverTests: XCTestCase {
    func testParsesPhysicalDHCPPacketAndExcludesTUNAddress() {
        let output = """
        domain_name_server (ip_mult): {172.19.0.1, 172.16.16.7}
        domain_name (string): corp.example.com
        """
        XCTAssertEqual(
            LANResolver.parseDHCPPacket(output, excluding: ["172.19.0.1"]),
            LANResolverSnapshot(servers: ["172.16.16.7"], searchDomains: ["corp.example.com"])
        )
    }

    func testPhysicalProbeUsesPrimaryInterfaceAndInfersDomain() async {
        let snapshot = await LANResolver.probePhysicalService(
            interfaceProvider: { "en7" },
            outputProvider: { interface in
                XCTAssertEqual(interface, "en7")
                return "domain_name_server (ip_mult): {10.0.0.53}"
            },
            query: { argument, kind, server in
                XCTAssertEqual(server, "10.0.0.53")
                switch kind {
                case .reverse:
                    XCTAssertEqual(argument, "10.0.0.53")
                    return ["dc1.office.example.com."]
                case .ipv4:
                    XCTAssertEqual(argument, "office.example.com")
                    return ["10.0.0.10"]
                }
            }
        )
        XCTAssertEqual(
            snapshot,
            LANResolverSnapshot(servers: ["10.0.0.53"], searchDomains: ["office.example.com"])
        )
    }

    /// 按真机 `scutil --dns` 的形状构造（含作用域解析器与反解区噪音）。
    private let sample = """
    DNS configuration

    resolver #1
      search domain[0] : corp.example.com
      nameserver[0] : 172.16.16.7
      nameserver[1] : 172.16.16.8
      if_index : 11 (en0)
      flags    : Request A records, Request AAAA records
      reach    : 0x00020002 (Reachable,Directly Reachable Address)

    resolver #2
      domain   : local
      options  : mdns
      timeout  : 5
      flags    : Request A records, Request AAAA records

    resolver #3
      domain   : 254.169.in-addr.arpa
      options  : mdns
      timeout  : 5

    resolver #4
      domain   : 8.e.f.ip6.arpa
      options  : mdns

    DNS configuration (for scoped queries)

    resolver #1
      search domain[0] : corp.example.com
      nameserver[0] : 172.16.16.7
      if_index : 11 (en0)
    """

    func testParsesPrivateNameserversAndSearchDomains() {
        let snapshot = LANResolver.parse(scutilOutput: sample)

        XCTAssertEqual(snapshot.servers, ["172.16.16.7", "172.16.16.8"], "去重且保序")
        XCTAssertEqual(snapshot.searchDomains, ["corp.example.com"])
        XCTAssertTrue(snapshot.isUsable)
    }

    func testDropsReverseZonesAndMDNSDomains() {
        let snapshot = LANResolver.parse(scutilOutput: sample)

        // `*.arpa` 由系统自己处理；`local` 是 mDNS 的地盘，走单播 DNS 问不到东西。
        for noise in ["254.169.in-addr.arpa", "8.e.f.ip6.arpa", "local", "arpa"] {
            XCTAssertFalse(snapshot.searchDomains.contains(noise), "不该收下 \(noise)")
        }
    }

    /// TUN 自身地址（如 172.19.0.1）本身就落在 172.16.0.0/12 里。不排掉就会把内核
    /// 自己当成"内网 DNS"，形成自指：内网域名交给内核，内核再交给自己。
    func testExcludesTunOwnAddressWhichIsAlsoPrivate() {
        let takenOver = """
        resolver #1
          search domain[0] : corp.example.com
          nameserver[0] : 172.19.0.1
        """
        XCTAssertTrue(LANResolver.isPrivateIPv4("172.19.0.1"), "前提：TUN 地址确实是私有地址")

        let snapshot = LANResolver.parse(scutilOutput: takenOver, excluding: ["172.19.0.1"])
        XCTAssertTrue(snapshot.servers.isEmpty)
        XCTAssertFalse(snapshot.isUsable, "只有域名没有服务器时不可用，避免生成一条无处可问的规则")
    }

    func testIgnoresPublicNameservers() {
        let publicOnly = """
        resolver #1
          search domain[0] : corp.example.com
          nameserver[0] : 8.8.8.8
          nameserver[1] : 223.5.5.5
        """
        // 公共 DNS 不是内网 DNS：把内网域名送去公网既问不到，还会泄漏内网域名。
        XCTAssertTrue(LANResolver.parse(scutilOutput: publicOnly).servers.isEmpty)
    }

    func testPrivateIPv4Classification() {
        for host in ["10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.1.1", "169.254.1.1"] {
            XCTAssertTrue(LANResolver.isPrivateIPv4(host), "\(host) 应判为私有")
        }
        for host in ["8.8.8.8", "172.15.0.1", "172.32.0.1", "192.169.0.1", "1.1.1.1", "", "not-an-ip"] {
            XCTAssertFalse(LANResolver.isPrivateIPv4(host), "\(host) 不应判为私有")
        }
    }

    /// 单标签后缀不能整段劫持到内网 DNS，否则半个互联网的解析都被送进去；
    /// 但只在内网出现的 `lan`/`corp` 之类可以。
    func testSingleLabelDomainsOnlyAllowedForPrivateOnlyTopLevels() {
        func domains(_ value: String) -> [String] {
            LANResolver.parse(scutilOutput: """
            resolver #1
              search domain[0] : \(value)
              nameserver[0] : 10.1.1.1
            """).searchDomains
        }
        XCTAssertEqual(domains("lan"), ["lan"])
        XCTAssertEqual(domains("intranet"), ["intranet"])
        XCTAssertEqual(domains("com"), [], "公共顶级后缀绝不能整段接管")
        XCTAssertEqual(domains("cn"), [])
    }

    func testNormalizesTrailingDotAndCase() {
        let snapshot = LANResolver.parse(scutilOutput: """
        resolver #1
          search domain[0] : CORP.Example.COM.
          nameserver[0] : 10.1.1.1
        """)
        XCTAssertEqual(snapshot.searchDomains, ["corp.example.com"])
    }

    // MARK: - 手动设置与自动探测的合成

    private let detected = LANResolverSnapshot(
        servers: ["172.16.16.7"],
        searchDomains: ["corp.example.com"]
    )

    func testDisabledSettingYieldsEmpty() {
        var settings = TunSettings.defaults
        settings.lanDNSEnabled = false
        XCTAssertFalse(LANResolver.effective(settings: settings, detected: detected).isUsable)
    }

    func testManualServerWins() {
        var settings = TunSettings.defaults
        settings.lanDNSServer = "10.9.9.9"
        XCTAssertEqual(LANResolver.effective(settings: settings, detected: detected).servers, ["10.9.9.9"])
    }

    /// 手填了公网地址时退回自动探测：宁可少一个功能，也别把内网域名送去公网 DNS。
    func testManualPublicServerFallsBackToDetected() {
        var settings = TunSettings.defaults
        settings.lanDNSServer = "8.8.8.8"
        XCTAssertEqual(LANResolver.effective(settings: settings, detected: detected).servers, ["172.16.16.7"])
    }

    /// 后缀取并集而非覆盖：很多网络只下发一个搜索域，内网还有别的域要手工补。
    func testManualSuffixesMergeWithDetectedAndAcceptWildcardForm() {
        var settings = TunSettings.defaults
        settings.lanDomainSuffixes = ["*.build.internal", ".ops.example.com", "corp.example.com"]

        let effective = LANResolver.effective(settings: settings, detected: detected)
        XCTAssertEqual(
            effective.searchDomains,
            ["corp.example.com", "build.internal", "ops.example.com"],
            "自动探测在前、手填在后；`*.`/`.` 前缀剥掉；重复项去掉"
        )
    }

    func testProbeReturnsEmptyWhenCommandFails() async {
        struct Boom: Error {}
        let snapshot = await LANResolver.probe(outputProvider: { throw Boom() })
        XCTAssertFalse(snapshot.isUsable, "探测失败要降级，不能阻塞启动")
    }
}

// MARK: - 没有搜索域时靠 PTR 推断内网域名

/// 真机前提：企业网常常只下发 DNS 服务器、**不下发搜索域**。
/// 光看搜索域会一个域名都找不到，内网分流等于没开。
extension LANResolverTests {
    /// AD 的固有结构：域控反解 = `<主机>.<AD 域>`，且 **AD 域名本身解析到域控私有地址**。
    func testInfersADDomainFromServerPTR() async {
        let inferred = await LANResolver.inferDomains(fromServers: ["172.16.16.7"]) { argument, kind, server in
            XCTAssertEqual(server, "172.16.16.7")
            switch kind {
            case .reverse:
                XCTAssertEqual(argument, "172.16.16.7")
                return ["AD1.corp.example.com."]
            case .ipv4:
                XCTAssertEqual(argument, "corp.example.com")
                return ["172.16.16.6"]   // 另一台域控，私有
            }
        }
        XCTAssertEqual(inferred, ["corp.example.com"])
    }

    /// 防误判的关键一步：父域解析到公网 IP 就不是内网域，必须拒。
    /// 公共 DNS 的反解也有父域（`114.114.114.114` → `public1.114dns.com`），
    /// 但 `114dns.com` 解析出来是公网地址。
    func testRejectsCandidateWhoseDomainResolvesToPublicIP() async {
        let inferred = await LANResolver.inferDomains(fromServers: ["10.0.0.53"]) { _, kind, _ in
            switch kind {
            case .reverse: return ["public1.114dns.com."]
            case .ipv4: return ["114.114.114.114"]
            }
        }
        XCTAssertTrue(inferred.isEmpty, "父域解析到公网 IP 时必须拒绝")
    }

    func testSkipsNonPrivateServersEntirely() async {
        let asked = QueryFlag()
        let inferred = await LANResolver.inferDomains(fromServers: ["8.8.8.8"]) { _, _, _ in
            asked.mark()
            return []
        }
        XCTAssertTrue(inferred.isEmpty)
        XCTAssertFalse(asked.value, "公网 DNS 连查都不该查")
    }

    func testIgnoresSingleLabelPTR() async {
        let inferred = await LANResolver.inferDomains(fromServers: ["192.168.1.1"]) { _, kind, _ in
            kind == .reverse ? ["router."] : ["192.168.1.1"]
        }
        XCTAssertTrue(inferred.isEmpty, "只有一级标签推不出父域")
    }

    /// 有搜索域时不该白跑两次 DNS 往返。
    func testProbeSkipsInferenceWhenSearchDomainPresent() async {
        let queried = QueryFlag()
        let snapshot = await LANResolver.probe(
            outputProvider: {
                """
                resolver #1
                  search domain[0] : corp.example.com
                  nameserver[0] : 172.16.16.7
                """
            },
            query: { _, _, _ in queried.mark(); return [] }
        )
        XCTAssertEqual(snapshot.searchDomains, ["corp.example.com"])
        XCTAssertFalse(queried.value, "已有搜索域时不该再发推断查询")
    }

    /// 没有搜索域时，probe 必须自动补上推断结果——否则功能在真机上不激活。
    func testProbeFallsBackToInferenceWhenNoSearchDomain() async {
        let snapshot = await LANResolver.probe(
            outputProvider: {
                """
                resolver #1
                  nameserver[0] : 172.16.16.7
                  nameserver[1] : 114.114.114.114
                """
            },
            query: { _, kind, _ in
                kind == .reverse ? ["AD1.corp.example.com."] : ["172.16.16.6"]
            }
        )
        XCTAssertEqual(snapshot.servers, ["172.16.16.7"], "公网 DNS 不进快照")
        XCTAssertEqual(snapshot.searchDomains, ["corp.example.com"])
        XCTAssertTrue(snapshot.isUsable)
    }
}

/// 查询是否被调用过。查询闭包是 @Sendable，故自带锁。
private final class QueryFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func mark() { lock.withLock { flag = true } }
}
