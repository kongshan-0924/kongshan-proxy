import Foundation

public struct NodeNameMetadata: Equatable, Sendable {
    public let flag: String?
    public let regionCode: String?
    public let multiplier: Double?

    public init(flag: String?, regionCode: String?, multiplier: Double?) {
        self.flag = flag
        self.regionCode = regionCode
        self.multiplier = multiplier
    }

    public var multiplierText: String? {
        guard let multiplier else { return nil }
        if multiplier.rounded() == multiplier { return "\(Int(multiplier))×" }
        let value = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), multiplier)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
        return "\(value)×"
    }

    public static func parse(_ name: String) -> NodeNameMetadata {
        let explicit = explicitFlag(in: name)
        let inferredCode = explicit?.code ?? inferredRegionCode(in: name)
        return NodeNameMetadata(
            flag: explicit?.flag ?? inferredCode.flatMap(flagEmoji),
            regionCode: inferredCode,
            multiplier: parsedMultiplier(in: name)
        )
    }

    private static func explicitFlag(in text: String) -> (flag: String, code: String)? {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count >= 2 else { return nil }
        for index in 0..<(scalars.count - 1) {
            let first = scalars[index].value
            let second = scalars[index + 1].value
            guard (0x1F1E6...0x1F1FF).contains(first),
                  (0x1F1E6...0x1F1FF).contains(second) else { continue }
            let code = String(UnicodeScalar(first - 0x1F1E6 + 65)!)
                + String(UnicodeScalar(second - 0x1F1E6 + 65)!)
            return (String(String.UnicodeScalarView([scalars[index], scalars[index + 1]])), code)
        }
        return nil
    }

    private static func inferredRegionCode(in text: String) -> String? {
        let lower = text.lowercased()
        let tokens = Set(lower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        for region in regions {
            if region.keywords.contains(where: { keyword in
                keyword.count <= 3 && keyword.unicodeScalars.allSatisfy { $0.isASCII && $0.properties.isAlphabetic }
                    ? tokens.contains(keyword)
                    : lower.contains(keyword)
            }) {
                return region.code
            }
        }
        return nil
    }

    private static func parsedMultiplier(in text: String) -> Double? {
        let patterns = [
            #"(?i)(\d+(?:\.\d+)?)\s*(?:x|×|倍)"#,
            #"倍率\s*[:：]?\s*(\d+(?:\.\d+)?)"#
        ]
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: range),
                  let valueRange = Range(match.range(at: 1), in: text),
                  let value = Double(text[valueRange]), value > 0 else { continue }
            return value
        }
        return nil
    }

    private static func flagEmoji(for code: String) -> String? {
        let scalars = code.uppercased().unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }
        guard scalars.count == 2 else { return nil }
        return String(String.UnicodeScalarView(scalars))
    }

    private static let regions: [(code: String, keywords: [String])] = [
        ("US", ["united states", "los angeles", "san jose", "new york", "seattle", "洛杉矶", "洛杉磯", "美国", "美國", "usa", "us"]),
        ("HK", ["hong kong", "香港", "hk"]),
        ("TW", ["taiwan", "taipei", "台湾", "台灣", "台北", "tw"]),
        ("JP", ["japan", "tokyo", "osaka", "日本", "东京", "東京", "大阪", "jp"]),
        ("SG", ["singapore", "新加坡", "狮城", "獅城", "sg"]),
        ("KR", ["south korea", "korea", "seoul", "韩国", "韓國", "首尔", "首爾", "kr"]),
        ("GB", ["united kingdom", "london", "英国", "英國", "uk", "gb"]),
        ("DE", ["germany", "frankfurt", "德国", "德國", "de"]),
        ("FR", ["france", "paris", "法国", "法國", "fr"]),
        ("CA", ["canada", "加拿大", "toronto", "vancouver", "ca"]),
        ("AU", ["australia", "sydney", "melbourne", "澳大利亚", "澳洲", "au"]),
        ("NL", ["netherlands", "amsterdam", "荷兰", "荷蘭", "nl"]),
        ("FI", ["finland", "helsinki", "芬兰", "芬蘭", "fi"]),
        ("RU", ["russia", "moscow", "俄罗斯", "俄羅斯", "ru"]),
        ("IN", ["india", "mumbai", "印度", "in"]),
        ("TR", ["turkey", "türkiye", "土耳其", "tr"]),
        ("TH", ["thailand", "bangkok", "泰国", "泰國", "th"]),
        ("MY", ["malaysia", "马来西亚", "馬來西亞", "my"]),
        ("PH", ["philippines", "菲律宾", "菲律賓", "ph"]),
        ("VN", ["vietnam", "越南", "vn"]),
        ("ID", ["indonesia", "印尼", "印度尼西亚", "id"]),
        ("FJ", ["fiji", "斐济", "斐濟", "fj"])
    ]
}
