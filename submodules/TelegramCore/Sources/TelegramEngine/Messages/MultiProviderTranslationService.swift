//
// MultiProviderTranslationService.swift
// TelegramCore · TelegramEngine/Messages
//
// 引擎侧注入点。Translate.swift 里的协议是：
//   public protocol ExperimentalInternalTranslationService: AnyObject {
//       func translate(texts: [AnyHashable: String], fromLang: String, toLang: String)
//           -> Signal<[AnyHashable: String]?, NoError>
//   }
//   public var engineExperimentalInternalTranslationService: ExperimentalInternalTranslationService?
//
// 本类按设置选主通道，失败按「另一个通道 → 官方 MTProto」回退：
//   返回 nil  → 引擎走 .fail(.generic)，由调用方回退官方翻译
//   缺项      → 引擎对该条使用原文（Translate.swift:284-330 的既有逻辑）
//

import Foundation
import SwiftSignalKit

public final class MultiProviderTranslationService: ExperimentalInternalTranslationService {
    public static let shared = MultiProviderTranslationService()

    private let settingsProvider: () -> TranslationProviderSettings
    private let google: GoogleTranslationBackend
    private let baidu: BaiduTranslationBackend

    public init(
        settingsProvider: @escaping () -> TranslationProviderSettings = {
            TranslationProviderSettingsStore.shared.load()
        }
    ) {
        self.settingsProvider = settingsProvider
        self.google = GoogleTranslationBackend(settingsProvider: settingsProvider)
        self.baidu = BaiduTranslationBackend(settingsProvider: settingsProvider)
    }

    private func backend(for kind: TranslationProviderKind) -> TranslationBackend {
        switch kind {
        case .google: return google
        case .baidu: return baidu
        }
    }

    /// 主通道在前，另一个可用的在后
    private func chain(primary: TranslationProviderKind) -> [TranslationBackend] {
        let other: TranslationProviderKind = (primary == .google) ? .baidu : .google
        var result: [TranslationBackend] = []
        if backend(for: primary).isConfigured {
            result.append(backend(for: primary))
        }
        if backend(for: other).isConfigured {
            result.append(backend(for: other))
        }
        // 主通道未配置（如百度没填 appid）时，上面已经只剩另一个
        return result
    }

    // MARK: - 引擎协议

    public func translate(
        texts: [AnyHashable: String],
        fromLang: String,
        toLang: String
    ) -> Signal<[AnyHashable: String]?, NoError> {
        return Signal { subscriber in
            let settings = self.settingsProvider()
            let keys = Array(texts.keys)
            if keys.isEmpty {
                subscriber.putNext(Optional<[AnyHashable: String]>.none)
                subscriber.putCompletion()
                return ActionDisposable { }
            }

            var indexToKey: [String: AnyHashable] = [:]
            var items: [(id: String, text: String)] = []
            for (offset, key) in keys.enumerated() {
                guard let text = texts[key],
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                let id = "m\(offset)"
                indexToKey[id] = key
                items.append((id: id, text: text))
            }
            if items.isEmpty {
                subscriber.putNext(Optional<[AnyHashable: String]>.none)
                subscriber.putCompletion()
                return ActionDisposable { }
            }

            let backends = self.chain(primary: settings.kind)
            if backends.isEmpty {
                TranslationLog.log("multi", "no configured backend")
                subscriber.putNext(Optional<[AnyHashable: String]>.none)
                subscriber.putCompletion()
                return ActionDisposable { }
            }

            let runner = TranslationChainRunner(
                items: items,
                backends: backends,
                fromLang: fromLang,
                toLang: toLang
            ) { translated in
                var result: [AnyHashable: String] = [:]
                for (id, text) in translated {
                    if let key = indexToKey[id] {
                        result[key] = text
                    }
                }
                TranslationLog.log("multi", "translated \(result.count)/\(items.count)")
                if result.isEmpty {
                    subscriber.putNext(Optional<[AnyHashable: String]>.none)
                } else {
                    subscriber.putNext(result)
                }
                subscriber.putCompletion()
            }
            runner.run()
            return ActionDisposable {
                runner.cancel()
            }
        }
    }

    // MARK: - 出站草稿翻译（Phase 3 用）

    public func translateSingle(
        text: String,
        fromLang: String,
        toLang: String
    ) -> Signal<String?, NoError> {
        return self.translate(texts: [AnyHashable("draft"): text], fromLang: fromLang, toLang: toLang)
        |> map { result in
            result?[AnyHashable("draft")]
        }
    }
}

// MARK: - 回退链执行器

private final class TranslationChainRunner {
    private let items: [(id: String, text: String)]
    private let backends: [TranslationBackend]
    private let fromLang: String
    private let toLang: String
    private let completion: ([String: String]) -> Void
    private let task = TranslationBackendTask()

    private let lock = NSLock()
    private var step = 0
    private var pending: [(id: String, text: String)]
    private var acc: [String: String] = [:]
    private var finished = false

    init(
        items: [(id: String, text: String)],
        backends: [TranslationBackend],
        fromLang: String,
        toLang: String,
        completion: @escaping ([String: String]) -> Void
    ) {
        self.items = items
        self.backends = backends
        self.fromLang = fromLang
        self.toLang = toLang
        self.completion = completion
        self.pending = items
    }

    func run() {
        next()
    }

    func cancel() {
        task.cancel()
        finish()
    }

    private func next() {
        lock.lock()
        if finished || task.isCancelled || step >= backends.count || pending.isEmpty {
            lock.unlock()
            finish()
            return
        }
        let backend = backends[step]
        step += 1
        let current = pending
        lock.unlock()

        let child = backend.translate(
            items: current,
            fromLang: fromLang,
            toLang: toLang
        ) { [weak self] outcome in
            guard let self = self else { return }
            self.lock.lock()
            for (id, text) in outcome.translated {
                self.acc[id] = text
            }
            self.pending = current.filter { outcome.failed.contains($0.id) }
            let left = self.pending
            self.lock.unlock()
            if left.isEmpty {
                self.finish()
            } else {
                self.next()
            }
        }
        task.add {
            child.cancel()
        }
    }

    private func finish() {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let result = acc
        lock.unlock()
        completion(result)
    }
}
