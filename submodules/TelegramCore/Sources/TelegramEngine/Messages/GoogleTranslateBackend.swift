//
// GoogleTranslateBackend.swift
// TelegramCore · TelegramEngine/Messages
//
// Google 免费 gtx 端点：
//   GET https://translate.googleapis.com/translate_a/single
//       ?client=gtx&dt=t&sl=<from>&tl=<to>&q=<text>
// 返回：[ [ ["译文","原文",…], … ], null, "en", … ] → 取 [0][*][0] 依次拼接
//
// 无 key、无计费；非公开文档化端点，无 SLA。
// 中国大陆直连不通（实测超时），必须走设置里的代理。
//

import Foundation

public final class GoogleTranslationBackend: TranslationBackend {
    public let kind: TranslationProviderKind = .google

    private let settingsProvider: () -> TranslationProviderSettings

    public init(settingsProvider: @escaping () -> TranslationProviderSettings) {
        self.settingsProvider = settingsProvider
    }

    public var isConfigured: Bool {
        return true
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
        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(value: max(1, settings.googleMaxConcurrency))
        let queue = DispatchQueue(label: "tgtranslate.google", attributes: .concurrent)

        for item in items {
            group.enter()
            queue.async {
                semaphore.wait()
                if task.isCancelled {
                    semaphore.signal()
                    group.leave()
                    return
                }
                self.translateOne(
                    text: item.text,
                    fromLang: fromLang,
                    toLang: toLang,
                    proxy: settings.googleProxy,
                    chunkChars: max(500, settings.googleFallbackChunkChars),
                    attempt: 0
                ) { result in
                    switch result {
                    case let .success(text):
                        TranslationCache.shared.write(
                            TranslationCache.shared.key(
                                provider: self.kind.rawValue,
                                text: item.text,
                                toLang: toLang
                            ),
                            text: text
                        )
                        collector.succeed(item.id, text)
                    case .failure:
                        collector.fail(item.id)
                    }
                    semaphore.signal()
                    group.leave()
                }
            }
        }

        group.notify(queue: DispatchQueue.global(qos: .utility)) {
            completion(collector.outcome())
        }
        return task
    }

    // MARK: - 单条（含分块与退避）

    private func translateOne(
        text: String,
        fromLang: String,
        toLang: String,
        proxy: String,
        chunkChars: Int,
        attempt: Int,
        completion: @escaping (Result<String, TranslationBackendError>) -> Void
    ) {
        let cachedKey = TranslationCache.shared.key(provider: kind.rawValue, text: text, toLang: toLang)
        if let hit = TranslationCache.shared.read(cachedKey) {
            completion(.success(hit))
            return
        }
        let pieces = TranslationChunker.chunks(text, maxChars: chunkChars)
        self.translateChunks(
            pieces: pieces,
            index: 0,
            collected: [],
            fromLang: fromLang,
            toLang: toLang,
            proxy: proxy,
            chunkChars: chunkChars,
            attempt: attempt,
            completion: completion
        )
    }

    private func translateChunks(
        pieces: [String],
        index: Int,
        collected: [String],
        fromLang: String,
        toLang: String,
        proxy: String,
        chunkChars: Int,
        attempt: Int,
        completion: @escaping (Result<String, TranslationBackendError>) -> Void
    ) {
        guard index < pieces.count else {
            completion(.success(collected.joined(separator: "\n")))
            return
        }
        requestChunk(pieces[index], fromLang: fromLang, toLang: toLang, proxy: proxy) { result in
            switch result {
            case let .success(text):
                var next = collected
                next.append(text)
                self.translateChunks(
                    pieces: pieces,
                    index: index + 1,
                    collected: next,
                    fromLang: fromLang,
                    toLang: toLang,
                    proxy: proxy,
                    chunkChars: chunkChars,
                    attempt: attempt,
                    completion: completion
                )
            case let .failure(error):
                let isLastChunkFailureRetryable = error.isRetryableElsewhere
                if attempt < 2, isLastChunkFailureRetryable {
                    let delay = 0.5 * pow(2.0, Double(attempt))
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
                        self.translateChunks(
                            pieces: pieces,
                            index: 0,
                            collected: [],
                            fromLang: fromLang,
                            toLang: toLang,
                            proxy: proxy,
                            chunkChars: chunkChars,
                            attempt: attempt + 1,
                            completion: completion
                        )
                    }
                } else {
                    completion(.failure(error))
                }
            }
        }
    }

    private func requestChunk(
        _ chunk: String,
        fromLang: String,
        toLang: String,
        proxy: String,
        completion: @escaping (Result<String, TranslationBackendError>) -> Void
    ) {
        guard var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single") else {
            completion(.failure(.badURL))
            return
        }
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "sl", value: TranslationLanguage.canonical(fromLang)),
            URLQueryItem(name: "tl", value: TranslationLanguage.canonical(toLang)),
            URLQueryItem(name: "q", value: chunk),
        ]
        guard let url = components.url else {
            completion(.failure(.badURL))
            return
        }
        _ = TranslationHttp.shared.get(url: url, proxy: proxy) { result in
            switch result {
            case let .failure(error):
                if error.isRateLimited {
                    completion(.failure(.rateLimited))
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

    static func parse(_ data: Data) -> Result<String, TranslationBackendError> {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let array = root as? [Any],
              let segments = array.first as? [Any] else {
            return .failure(.invalidResponse)
        }
        var text = ""
        for segment in segments {
            guard let parts = segment as? [Any], let piece = parts.first as? String else {
                continue
            }
            text += piece
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .failure(.invalidResponse)
        }
        return .success(text)
    }
}
