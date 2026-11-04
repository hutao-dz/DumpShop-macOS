import Foundation

/// Supported App Store storefronts. Search always uses the public, unauthenticated
/// iTunes API, but downloads must use an account whose storefront matches the
/// selected region. The `profileKey` is what isolates keychain sessions.
enum StoreRegion: String, CaseIterable, Identifiable {
    case cn = "CN"
    case us = "US"
    case jp = "JP"
    case hk = "HK"
    case tw = "TW"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cn: return "国区"
        case .us: return "美区"
        case .jp: return "日区"
        case .hk: return "港区"
        case .tw: return "台区"
        }
    }

    var shortTitle: String { rawValue }

    var profileKey: String { rawValue.lowercased() }

    static func code(_ value: String) -> String {
        StoreRegion(rawValue: value.uppercased())?.rawValue ?? "CN"
    }

    static func title(_ value: String) -> String {
        StoreRegion(rawValue: value.uppercased())?.title ?? value
    }
}

/// One App Store search hit, as the public iTunes lookup returns it.
///
/// Searching uses Apple's unauthenticated storefront API on purpose. Browsing
/// never needs the persistent download session; only package retrieval does.
struct StoreItem: Identifiable, Hashable {
    let id: Int
    let name: String
    let bundleId: String
    let version: String
    let seller: String
    let price: String
    let artwork: URL?
    let bytes: Int64?
    let genres: [String]
    var numericPrice: Double? = nil
    var currency: String? = nil

    var sizeText: String {
        guard let b = bytes, b > 0 else { return "" }
        let mb = Double(b) / 1048576.0
        return mb >= 1024 ? String(format: "%.2f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }

    var isFree: Bool {
        if let numericPrice { return numericPrice == 0 }
        let low = price.lowercased()
        let tokens = ["免费", "免費", "無料", "无料", "free", "gratuit", "gratis"]
        if price == "0" || price == "$0" || price == "¥0" {
            return true
        }
        return tokens.contains { low.contains($0) }
    }

    /// Larger artwork for the same asset; iTunes only publishes the 100px variant.
    var artworkURL200: URL? {
        guard let u = artwork?.absoluteString.replacingOccurrences(of: "100x100bb",
                                                                  with: "200x200bb") else {
            return nil
        }
        return URL(string: u)
    }

    /// The product page as the device's App Store understands it. Opening this on
    /// the phone is the route that needs no download session on the Mac.
    var itmsURL: String { "itms-apps://itunes.apple.com/app/id\(id)" }

    func asInstalledApp() -> InstalledApp {
        InstalledApp(bundleId: bundleId, name: name, executable: "",
                     shortVersion: version, kind: .appStore)
    }
}

enum StoreSearch {
    struct FlexibleInt64: Decodable {
        let value: Int64?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int64.self) {
                value = number
            } else if let number = try? container.decode(Double.self) {
                value = Int64(number)
            } else if let text = try? container.decode(String.self) {
                value = Int64(text)
            } else {
                value = nil
            }
        }
    }

    struct Response: Decodable {
        struct Item: Decodable {
            let trackId: Int?
            let trackName: String?
            let bundleId: String?
            let version: String?
            let sellerName: String?
            let formattedPrice: String?
            let price: Double?
            let currency: String?
            let artworkUrl100: String?
            let fileSizeEsrp: FlexibleInt64?
            let fileSizeBytes: FlexibleInt64?
            let genres: [String]?
            let kind: String?
            let trackViewUrl: String?
        }
        let resultCount: Int
        let results: [Item]
    }

    static func endpoint(_ term: String, region: String, limit: Int) -> URL? {
        var comps = URLComponents(string: "https://itunes.apple.com/search")
        comps?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "country", value: region),
            URLQueryItem(name: "media", value: "software"),
            URLQueryItem(name: "entity", value: "software"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        return comps?.url
    }

    static func search(_ term: String, region: String = "CN", limit: Int = 30) async throws
        -> [StoreItem] {
        guard let url = endpoint(term, region: region, limit: limit) else { throw Err.badURL }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw Err.http(http.statusCode)
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.results.compactMap(Self.make)
    }

    /// Resolve a bundle id to its real product entry. The device route needs the
    /// numeric trackId, which no caller should have to remember.
    static func lookup(bundleId: String, region: String = "CN") async throws -> StoreItem? {
        var comps = URLComponents(string: "https://itunes.apple.com/lookup")
        comps?.queryItems = [URLQueryItem(name: "bundleId", value: bundleId),
                             URLQueryItem(name: "country", value: region)]
        guard let url = comps?.url else { throw Err.badURL }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw Err.http(http.statusCode)
        }
        let items = try JSONDecoder().decode(Response.self, from: data)
            .results.compactMap(Self.make)
        return items.first { $0.bundleId == bundleId } ?? items.first
    }

    static func make(_ item: Response.Item) -> StoreItem? {
            // Games and apps both come back; bundleId is what we can download.
            guard let bid = item.bundleId, !bid.isEmpty, let tid = item.trackId else { return nil }
            return StoreItem(
                id: tid,
                name: item.trackName ?? bid,
                bundleId: bid,
                version: item.version ?? "?",
                seller: item.sellerName ?? "",
                price: item.formattedPrice ?? "",
                artwork: item.artworkUrl100.flatMap { URL(string: $0) },
                bytes: item.fileSizeEsrp?.value ?? item.fileSizeBytes?.value,
                genres: item.genres ?? [],
                numericPrice: item.price, currency: item.currency)
    }

    enum Err: LocalizedError {
        case badURL, http(Int)
        var errorDescription: String? {
            switch self {
            case .badURL: return "搜索地址无效"
            case .http(let c): return "App Store 搜索接口返回 \(c)"
            }
        }
    }
}

/// What store.py reports about ipatool and the persistent download session.
struct StoreAuth: Equatable {
    var binary = false
    var binarySource = ""
    var loggedIn = false
    var account = ""
    var accountID = ""
    var region = ""
    var error = ""
}

extension StoreAuth {
    init(_ ev: EngineEvent) {
        binary = ev.binary ?? false
        binarySource = ev.source ?? ""
        loggedIn = ev.loggedIn ?? false
        account = (ev.name?.trimmed.isEmpty == false ? ev.name : ev.email) ?? ""
        accountID = ev.accountID ?? ""
        region = ev.region ?? ""
        error = ev.error ?? ""
    }
}
