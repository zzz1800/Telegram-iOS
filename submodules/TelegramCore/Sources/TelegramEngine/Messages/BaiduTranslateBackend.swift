//
// BaiduTranslateBackend.swift
// TelegramCore · TelegramEngine/Messages
//
// 百度通用文本翻译：
//   GET https://fanyi-api.baidu.com/api/trans/vip/translate
//       ?q=<text>&from=<src>&to=<dst>&appid=<id>&salt=<8位随机>&sign=<md5>
//   sign = MD5(appid + q + salt + 密钥)，32 位小写
//   ★ 拼 sign 时 q 绝不做 URL encode；encode 只发生在拼 URL 阶段（官方 FAQ 明示，否则 54001）
//
// 额度：未认证 5 万字符/月（个人认证 100 万，企业 200 万），超出 49 元/百万字符
// QPS ：标准版 1 → 必须串行 + ≥1s 间隔（否则 54003）
// 单次：建议 ≤2000 字符，硬顶 6000 字节 → 默认按 5000 字节分块
// 密钥：只从 Keychain 读（官方要求不得放进第三方软件）
//

import Foundation
import CryptoKit

public final class BaiduTranslationBackend: TranslationBackend {
    public let kind: TranslationProviderKind = .baidu

    private let settingsProvider: () -> TranslationProviderSettings
    private lazy var limiter = TranslationRateLimiter(
        label: "tgtranslate.baidu",
        minInterval: max(1.0, settingsProvider().baiduMinInterval)
    )

    public init(settingsProvider: @escaping () -> TranslationProviderSettings) {
        self.settingsProvider = settingsProvider
    }

    public var isConfigured: Bool {
        let settings = settingsProvider()
        return !settings.baiduAppId.isEmpty && !settings.baiduKey.isEmpty
    }

    public func translate(
        items: [(id: String, text: String)],
        fromLang: String,
        toLang: String,
        completion: @escaping (TranslationBackendOutcome) -> Void
    ) -> TranslationBackendTask {
        let task = TranslationBackendTask()
        let settings = settingsProvider()
        let collector = TranslationOutcomeCollector()

        guard !settings.baiduAppId.isEmpty, !settings.baiduKey.isEmpty else {
            for item in items { collector.fail(item.id) }
            completion(collector.outcome())
            return task
        }
        guard let toCode = TranslationLanguage.baiduCode(toLang) else {
            // 百度不支持该语种 → 全部失败，交给上层换 Google
            TranslationLog.log("baidu", "unsupported target \(toLang)")
            for item in items { collector.fail(item.id) }
            completion(collector.outcome())
            return task
        }
        let fromCode = TranslationLanguage.baiduCode(fromLang) ?? "auto"

        let session = BaiduSession(
            backend: self,
            items: items,
            fromCode: fromCode,
            toCode: toCode,
            appId: settings.baiduAppId,
            key: settings.baiduKey,
            chunkBytes: max(1000, settings.baiduChunkBytes),
            proxy: settings.googleProxy,
            collector: collector,
            task: task
        )
        limiter.run {
            session.start(completion: completion)
        }
        task.add { [weak session] in
            session?.cancelled = true
        }
        return task
    }

    // MARK: - 请求

    fileprivate func request(
        chunk: String,
        fromCode: String,
        toCode: String,
        appId: String,
        key: String,
        proxy: String,
        attempt: Int,
        completion: @escaping (Result<String, TranslationBackendError>) -> Void
    ) {
        let salt = String(Int.random(in: 10000000 ... 99999999))
        let sign = Self.md5Hex(appId + chunk + salt + key)

        guard var components = URLComponents(string: "https://fanyi-api.baidu.com/api/trans/vip/translate") else {
            completion(.failure(.badURL))
            return
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: chunk),
            URLQueryItem(name: "from", value: fromCode),
            URLQueryItem(name: "to", value: toCode),
            URLQueryItem(name: "appid", value: appId),
            URLQueryItem(name: "salt", value: salt),
            URLQueryItem(name: "sign", value: sign),
        ]
        guard let url = components.url else {
            completion(.failure(.badURL))
            return
        }
        _ = TranslationHttp.shared.get(url: url, proxy: proxy) { result in
            switch result {
            case let .failure(error):
                if error.isRateLimited {
                    if attempt < 2 {
                        let delay = 1.0 * pow(2.0, Double(attempt))
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
                            self.request(
                                chunk: chunk, fromCode: fromCode, toCode: toCode,
                                appId: appId, key: key, proxy: proxy,
                                attempt: attempt + 1, completion: completion
                            )
                        }
                    } else {
                        completion(.failure(.rateLimited))
                    }
                } else if case let .httpStatus(code) = error {
                    completion(.failure(.other(code: code)))
                } else {
                    completion(.failure(.transport))
                }
            case let .success(data):
                switch Self.parse(data) {
                case let .success(text):
                    completion(.success(text))
                case let .failure(error):
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - 解析

    static func parse(_ data: Data) -> Result<String, TranslationBackendError> {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any] else {
            return .failure(.invalidResponse)
        }
        if let code = object["error_code"] as? String {
            let message = (object["error_msg"] as? String) ?? ""
            return .failure(Self.mapError(code: code, message: message))
        }
        guard let results = object["trans_result"] as? [[String: Any]] else {
            return .failure(.invalidResponse)
        }
        var lines: [String] = []
        for entry in results {
            if let dst = entry["dst"] as? String {
                lines.append(dst)
            }
        }
        let text = lines.joined(separator: "\n")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure(.invalidResponse)
        }
        return .success(text)
    }

    /// 官方错误码 → 动作（文档「错误码列表」）
    static func mapError(code: String, message: String) -> TranslationBackendError {
        switch code {
        case "52003":
            // 未授权用户 / 服务未开通 / appid 与密钥不匹配
            return .notConfigured
        case "54001":
            // 签名错误：q 提前 encode、salt 重复、密钥错
            return .service(string: "54001 sign")
        case "54003":
            return .rateLimited
        case "54004":
            return .quotaExceeded
        case "54005":
            return .rateLimited
        case "58000":
            return .service(string: "58000 ip")
        case "58001":
            return .unsupportedLanguage
        case "58002":
            return .service(string: "58002 service off")
        case "58003":
            // 同 IP 当日多 APPID → 当日封禁
            return .service(string: "58003 ip banned")
        case "59003":
            return .service(string: "59003 too long")
        case "59004":
            return .rateLimited
        default:
            return .service(string: "\(code) \(message)")
        }
    }

    fileprivate static func md5Hex(_ value: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(value.utf8))
        var hex = ""
        hex.reserveCapacity(32)
        for byte in digest {
            hex += String(format: "%02x", Int(byte))
        }
        return hex
    }
}

// MARK: - 串行流水线（QPS=1，绝不并发）

private final class BaiduSession {
    private let backend: BaiduTranslationBackend
    private let items: [(id: String, text: String)]
    private let fromCode: String
    private let toCode: String
    private let appId: String
    private let key: String
    private let chunkBytes: Int
    private let proxy: String
    private let collector: TranslationOutcomeCollector
    private let task: TranslationBackendTask

    private var itemIndex = 0
    private var chunks: [String] = []
    private var chunkIndex = 0
    private var collected: [String] = []
    private var attempts = 0

    var cancelled = false

    init(
        backend: BaiduTranslationBackend,
        items: [(id: String, text: String)],
        fromCode: String,
        toCode: String,
        appId: String,
        key: String,
        chunkBytes: Int,
        proxy: String,
        collector: TranslationOutcomeCollector,
        task: TranslationBackendTask
    ) {
        self.backend = backend
        self.items = items
        self.fromCode = fromCode
        self.toCode = toCode
        self.appId = appId
        self.key = key
        self.chunkBytes = chunkBytes
        self.proxy = proxy
        self.collector = collector
        self.task = task
    }

    func start(completion: @escaping (TranslationBackendOutcome) -> Void) {
        self.nextItem(completion: completion)
    }

    private func nextItem(completion: @escaping (TranslationBackendOutcome) -> Void) {
        if cancelled || task.isCancelled {
            completion(collector.outcome())
            return
        }
        guard itemIndex < items.count else {
            completion(collector.outcome())
            return
        }
        let item = items[itemIndex]
        let cachedKey = TranslationCache.shared.key(
            provider: TranslationProviderKind.baidu.rawValue,
            text: item.text,
            toLang: toCode
        )
        if let hit = TranslationCache.shared.read(cachedKey) {
            collector.succeed(item.id, hit)
            itemIndex += 1
            nextItem(completion: completion)
            return
        }
        chunks = TranslationChunker.chunks(item.text, maxBytes: chunkBytes)
        chunkIndex = 0
        collected = []
        attempts = 0
        nextChunk(completion: completion)
    }

    private func nextChunk(completion: @escaping (TranslationBackendOutcome) -> Void) {
        if cancelled || task.isCancelled {
            completion(collector.outcome())
            return
        }
        guard chunkIndex < chunks.count else {
            let text = collected.joined(separator: "\n")
            let item = items[itemIndex]
            TranslationCache.shared.write(
                TranslationCache.shared.key(
                    provider: TranslationProviderKind.baidu.rawValue,
                    text: item.text,
                    toLang: toCode
                ),
                text: text
            )
            collector.succeed(item.id, text)
            itemIndex += 1
            nextItem(completion: completion)
            return
        }
        let chunk = chunks[chunkIndex]
        backend.request(
            chunk: chunk,
            fromCode: fromCode,
            toCode: toCode,
            appId: appId,
            key: key,
            proxy: proxy,
            attempt: 0
        ) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case let .success(text):
                self.collected.append(text)
                self.chunkIndex += 1
                self.attempts = 0
                self.nextChunk(completion: completion)
            case .failure:
                if self.attempts < 1 {
                    self.attempts += 1
                    // 同分块重试一次（QPS 抖动/超时）
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.1) {
                        self.nextChunk(completion: completion)
                    }
                } else {
                    self.collector.fail(self.items[self.itemIndex].id)
                    self.itemIndex += 1
                    self.nextItem(completion: completion)
                }
            }
        }
    }
}
