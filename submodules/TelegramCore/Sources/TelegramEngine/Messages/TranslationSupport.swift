//
// TranslationSupport.swift
// TelegramCore · TelegramEngine/Messages
//
// 翻译通道公共支撑：设置项、Keychain、HTTP（含代理）、缓存、限速。
// 依赖：Foundation / Security / SwiftSignalKit（均为 TelegramCore 现有依赖）
//

import Foundation
import Security
import SwiftSignalKit

// MARK: - 通道类型

public enum TranslationProviderKind: String, CaseIterable {
    case google
    case baidu

    public var displayName: String {
        switch self {
        case .google: return "Google"
        case .baidu:  return "百度"
        }
    }
}

// MARK: - 设置

public struct TranslationProviderSettings {
    public static let defaults = TranslationProviderSettings(
        kind: .google,
        googleProxy: "",
        baiduAppId: "",
        baiduKey: "",
        targetLanguage: "zh",
        translateIncoming: true,
        translateOutgoing: false,
        sendOriginalOnOutgoingFailure: true,
        preferOriginalInClipboard: true,
        googleFallbackChunkChars: 4000,
        baiduChunkBytes: 5000,
        baiduMinInterval: 1.05,
        googleMaxConcurrency: 2
    )

    public var kind: TranslationProviderKind
    /// HTTP/SOCKS 代理，形如 http://127.0.0.1:7890 或 socks5://127.0.0.1:1080；空串=直连
    public var googleProxy: String
    public var baiduAppId: String
    public var baiduKey: String
    public var targetLanguage: String
    /// 收到外语消息自动翻译
    public var translateIncoming: Bool
    /// 发送前把中文自动翻成目标语言
    public var translateOutgoing: Bool
    /// 出站翻译失败时：原样发送(true) / 中止发送(false)
    public var sendOriginalOnOutgoingFailure: Bool
    /// 出站翻译后把原文写入剪贴板，便于后悔
    public var preferOriginalInClipboard: Bool
    public var googleFallbackChunkChars: Int
    public var baiduChunkBytes: Int
    public var baiduMinInterval: TimeInterval
    public var googleMaxConcurrency: Int
}

public final class TranslationProviderSettingsStore {
    public static let shared = TranslationProviderSettingsStore()

    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "tgtranslate.settings")
    private let prefix = "tgtranslate."

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> TranslationProviderSettings {
        var s = TranslationProviderSettings.defaults
        queue.sync {
            if let raw = defaults.string(forKey: prefix + "kind"),
               let kind = TranslationProviderKind(rawValue: raw) {
                s.kind = kind
            }
            s.googleProxy = defaults.string(forKey: prefix + "googleProxy") ?? s.googleProxy
            s.baiduAppId = defaults.string(forKey: prefix + "baiduAppId") ?? s.baiduAppId
            s.targetLanguage = defaults.string(forKey: prefix + "targetLanguage") ?? s.targetLanguage
            s.translateIncoming = defaults.object(forKey: prefix + "translateIncoming") as? Bool ?? s.translateIncoming
            s.translateOutgoing = defaults.object(forKey: prefix + "translateOutgoing") as? Bool ?? s.translateOutgoing
            s.sendOriginalOnOutgoingFailure = defaults.object(forKey: prefix + "sendOriginalOnFailure") as? Bool ?? s.sendOriginalOnOutgoingFailure
            if let n = defaults.object(forKey: prefix + "googleChunk") as? Int, n > 0 { s.googleFallbackChunkChars = n }
            if let n = defaults.object(forKey: prefix + "baiduChunkBytes") as? Int, n > 0 { s.baiduChunkBytes = n }
            if let d = defaults.object(forKey: prefix + "baiduInterval") as? Double, d > 0 { s.baiduMinInterval = d }
            if let n = defaults.object(forKey: prefix + "googleConcurrency") as? Int, n > 0 { s.googleMaxConcurrency = n }
            // 密钥只从 Keychain 读，绝不落 UserDefaults
            s.baiduKey = TranslationKeychain.get(account: "baiduKey") ?? s.baiduKey
        }
        // 优先级：界面里改过的值 > 配置文件 > 内置默认
        // 之前是配置文件覆盖一切，导致「面板里点了切换却毫无变化」。
        if !self.userOverride {
            // 配置文件只在「面板没被改过」时生效（apply(to:) 返回 Void，不能当条件用）
            TranslationConfigFile.apply(to: &s)
        }
        return s
    }

    /// 用户是否在 App 内改过设置。改过之后配置文件不再覆盖界面。
    public var userOverride: Bool {
        return self.defaults.object(forKey: self.prefix + "userOverride") as? Bool ?? false
    }

    /// 恢复「以配置文件为准」
    public func clearUserOverride() {
        self.queue.sync {
            self.defaults.removeObject(forKey: self.prefix + "userOverride")
        }
    }

    public func update(_ mutate: (inout TranslationProviderSettings) -> Void) {
        var s = load()
        mutate(&s)
        queue.sync {
            // 一旦在界面里改过，就不再让 tgtranslate.json 覆盖界面值
            defaults.set(true, forKey: prefix + "userOverride")
            defaults.set(s.kind.rawValue, forKey: prefix + "kind")
            defaults.set(s.googleProxy, forKey: prefix + "googleProxy")
            defaults.set(s.baiduAppId, forKey: prefix + "baiduAppId")
            defaults.set(s.targetLanguage, forKey: prefix + "targetLanguage")
            defaults.set(s.translateIncoming, forKey: prefix + "translateIncoming")
            defaults.set(s.translateOutgoing, forKey: prefix + "translateOutgoing")
            defaults.set(s.sendOriginalOnOutgoingFailure, forKey: prefix + "sendOriginalOnFailure")
            defaults.set(s.googleFallbackChunkChars, forKey: prefix + "googleChunk")
            defaults.set(s.baiduChunkBytes, forKey: prefix + "baiduChunkBytes")
            defaults.set(s.baiduMinInterval, forKey: prefix + "baiduInterval")
            defaults.set(s.googleMaxConcurrency, forKey: prefix + "googleConcurrency")
        }
        TranslationKeychain.set(s.baiduKey, account: "baiduKey")
    }
}

// MARK: - Keychain（密钥只存这里）

public enum TranslationKeychain {
    private static let service = "org.telegram.TGTranslateProvider"

    public static func set(_ value: String, account: String) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    public static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public static func remove(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - HTTP

public enum TranslationHttpError: Error {
    case badURL
    case transport(String)
    case httpStatus(Int)
    case invalidResponse

    public var isRateLimited: Bool {
        if case let .httpStatus(code) = self {
            return code == 429 || code == 403 || code == 503
        }
        return false
    }
}

public final class TranslationHttp {
    public static let shared = TranslationHttp()

    private var sessions: [String: URLSession] = [:]
    private let lock = NSLock()

    private func session(proxy: String) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let cached = sessions[proxy] {
            return cached
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 4
        config.connectionProxyDictionary = Self.proxyDictionary(from: proxy)
        let session = URLSession(configuration: config)
        sessions[proxy] = session
        return session
    }

    /// "http://127.0.0.1:7890" / "socks5://127.0.0.1:1080" / "127.0.0.1:7890" -> 代理字典
    public static func proxyDictionary(from raw: String) -> [AnyHashable: Any]? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var scheme = "http"
        if let range = text.range(of: "://") {
            scheme = String(text[text.startIndex..<range.lowerBound]).lowercased()
            text = String(text[range.upperBound...])
        }
        let parts = text.split(separator: ":")
        guard parts.count >= 2, let port = Int(parts[parts.count - 1]) else { return nil }
        let host = parts.dropLast().joined(separator: ":")
        if scheme.hasPrefix("socks") {
            return [
                "SOCKSEnable": 1,
                "SOCKSProxy": host,
                "SOCKSPort": port,
                "SOCKSVersion": scheme == "socks4" ? 4 : 5,
            ]
        }
        // http / https 代理：HTTPS 与 HTTP 同时设置，避免明文重定向漏出直连
        return [
            "HTTPSEnable": 1,
            "HTTPSProxy": host,
            "HTTPSPort": port,
            "HTTPEnable": 1,
            "HTTPProxy": host,
            "HTTPPort": port,
        ]
    }

    public func get(
        url: URL,
        proxy: String,
        completion: @escaping (Result<Data, TranslationHttpError>) -> Void
    ) -> URLSessionDataTask {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 15_4 like Mac OS X) TGTranslate/1.0",
                         forHTTPHeaderField: "User-Agent")
        let task = session(proxy: proxy).dataTask(with: request) { data, response, error in
            if let error = error {
                // 取消不算失败
                let ns = error as NSError
                if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled {
                    return
                }
                completion(.failure(.transport(error.localizedDescription)))
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                completion(.failure(.httpStatus(http.statusCode)))
                return
            }
            guard let data = data, !data.isEmpty else {
                completion(.failure(.invalidResponse))
                return
            }
            completion(.success(data))
        }
        task.resume()
        return task
    }
}

// MARK: - 缓存（内存 LRU + 磁盘）

public final class TranslationCache {
    public static let shared = TranslationCache()

    private let memory = NSCache<NSString, NSString>()
    private let queue = DispatchQueue(label: "tgtranslate.cache")
    private var disk: [String: Entry] = [:]
    private var loaded = false
    private let ttl: TimeInterval = 30 * 24 * 60 * 60

    private struct Entry: Codable {
        let text: String
        let at: TimeInterval
    }

    public init() {
        memory.countLimit = 2000
    }

    public func key(provider: String, text: String, toLang: String) -> String {
        let raw = "\(provider)|\(toLang)|\(text)"
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    public func read(_ key: String) -> String? {
        if let hit = memory.object(forKey: key as NSString) {
            return hit as String
        }
        var result: String?
        queue.sync {
            loadIfNeeded()
            if let entry = disk[key], Date().timeIntervalSince1970 - entry.at < ttl {
                result = entry.text
            }
        }
        if let result = result {
            memory.setObject(result as NSString, forKey: key as NSString)
        }
        return result
    }

    public func write(_ key: String, text: String) {
        memory.setObject(text as NSString, forKey: key as NSString)
        queue.async { [weak self] in
            guard let self = self else { return }
            self.loadIfNeeded()
            self.disk[key] = Entry(text: text, at: Date().timeIntervalSince1970)
            if self.disk.count > 5000 {
                let sorted = self.disk.sorted { $0.value.at > $1.value.at }
                self.disk = Dictionary(uniqueKeysWithValues: sorted.prefix(4000).map { ($0.key, $0.value) })
            }
            self.persist()
        }
    }

    private var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return dir.appendingPathComponent("tg-translate-cache.json")
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return
        }
        disk = decoded
    }

    private func persist() {
        guard let url = fileURL, let data = try? JSONEncoder().encode(disk) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - 串行 + 最小间隔（百度 QPS=1 必须）

public final class TranslationRateLimiter {
    private let queue: DispatchQueue
    private var lastFire: TimeInterval = 0
    private let minInterval: TimeInterval

    public init(label: String, minInterval: TimeInterval) {
        self.queue = DispatchQueue(label: label)
        self.minInterval = minInterval
    }

    public func run(_ work: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let now = Date().timeIntervalSince1970
            let wait = self.lastFire + self.minInterval - now
            if wait > 0 {
                Thread.sleep(forTimeInterval: wait)
            }
            self.lastFire = Date().timeIntervalSince1970
            work()
        }
    }
}

// MARK: - 文本分块（按 UTF-8 字节上限，尽量在句末切）

public enum TranslationChunker {
    public static func chunks(_ text: String, maxBytes: Int) -> [String] {
        if text.utf8.count <= maxBytes { return [text] }
        var result: [String] = []
        var current = ""
        var currentBytes = 0
        let soft = Double(maxBytes) * 0.6
        for ch in text {
            let size = String(ch).utf8.count
            if currentBytes + size > maxBytes {
                result.append(current)
                current = ""
                currentBytes = 0
            }
            current.append(ch)
            currentBytes += size
            if "\n。！？!?；;.".contains(ch), Double(currentBytes) >= soft {
                result.append(current)
                current = ""
                currentBytes = 0
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    public static func chunks(_ text: String, maxChars: Int) -> [String] {
        if text.count <= maxChars { return [text] }
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: maxChars, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[start..<end]))
            start = end
        }
        return result
    }
}

// MARK: - 日志（release 下静默，只留计数）

public enum TranslationLog {
    /// release 也记录：写入 Documents/tgtranslate.log，「文件」App 里可直接取
    public static var enabled = true

    private static let logLock = NSLock()
    private static let maxBytes: UInt64 = 512 * 1024

    private static var logURL: URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return documents.appendingPathComponent("tgtranslate.log")
    }

    private static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    public static func log(_ tag: String, _ message: String) {
        let line = logFormatter.string(from: Date()) + " [" + tag + "] " + message + "\n"
        #if DEBUG
        print(line, terminator: "")
        #endif
        guard enabled, let url = logURL else {
            return
        }
        logLock.lock()
        defer { logLock.unlock() }
        let data = Data(line.utf8)
        // 用 FileManager 取大小：FileHandle.seekToEnd() 要 iOS 13.4+，本 target 部署版本更低
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        if size > maxBytes {
            // 超限就轮转：删掉，下一次写入重新建文件
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.write(data)
        } else {
            try? data.write(to: url)
        }
    }
}
