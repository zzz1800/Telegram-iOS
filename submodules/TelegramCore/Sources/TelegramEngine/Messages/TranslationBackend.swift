//
// TranslationBackend.swift
// TelegramCore · TelegramEngine/Messages
//
// 通道后端契约 + 可取消句柄 + 结果收集器。
// 后端只负责"把一批文本翻掉"，缓存/限速/分块都在各自后端内部，
// MultiProviderTranslationService 只做「选谁、失败了换谁」。
//

import Foundation

public struct TranslationBackendOutcome {
    public var translated: [String: String]
    public var failed: Set<String>

    public init(translated: [String: String] = [:], failed: Set<String> = []) {
        self.translated = translated
        self.failed = failed
    }
}

public final class TranslationBackendTask {
    private let lock = NSLock()
    private var cancellations: [() -> Void] = []
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func add(_ cancel: @escaping () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            cancel()
            return
        }
        cancellations.append(cancel)
        lock.unlock()
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let list = cancellations
        cancellations = []
        lock.unlock()
        for item in list {
            item()
        }
    }
}

public protocol TranslationBackend: AnyObject {
    var kind: TranslationProviderKind { get }
    /// 密钥/代理等前置条件是否齐备
    var isConfigured: Bool { get }

    func translate(
        items: [(id: String, text: String)],
        fromLang: String,
        toLang: String,
        completion: @escaping (TranslationBackendOutcome) -> Void
    ) -> TranslationBackendTask
}

/// 并发安全的累加器，避免在并发闭包里直接 mutate 捕获变量（Swift 6 会报错）
final class TranslationOutcomeCollector {
    private let lock = NSLock()
    private var translated: [String: String] = [:]
    private var failed: Set<String> = []

    func succeed(_ id: String, _ text: String) {
        lock.lock()
        translated[id] = text
        lock.unlock()
    }

    func fail(_ id: String) {
        lock.lock()
        failed.insert(id)
        lock.unlock()
    }

    var unfinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !failed.isEmpty
    }

    func outcome() -> TranslationBackendOutcome {
        lock.lock()
        defer { lock.unlock() }
        return TranslationBackendOutcome(translated: translated, failed: failed)
    }
}

public enum TranslationBackendError: Error {
    case notConfigured
    case badURL
    case transport
    case invalidResponse
    case rateLimited
    case quotaExceeded
    case unsupportedLanguage
    case service(string: String)
    case other(code: Int)

    /// 这些错误值得换一个通道再试
    public var isRetryableElsewhere: Bool {
        switch self {
        case .notConfigured, .unsupportedLanguage:
            return true
        case .rateLimited, .quotaExceeded, .transport, .invalidResponse, .service, .other:
            return true
        case .badURL:
            return false
        }
    }
}
