//
// TranslationOutbound.swift
// TelegramCore · PendingMessages
//
// 出站自动翻译（T2）：打字是中文 → 发送前自动翻成目标语言 → 发出的就是译文。
//
// 为什么挂在 enqueueMessages 而不是发送按钮：
//   `enqueueMessages(account:peerId:messages:)`（PendingMessages/EnqueueMessage.swift:761）是
//   所有出站消息的唯一公共汇合点，拦截这里不需要读改输入框状态（那套 API 在面板侧且易随版本漂移），
//   也不会漏掉「回车发送 / 菜单发送 / 快捷回复」等旁路。
//
// 边界（刻意保守，避免误伤）：
//   - 只处理纯文本消息（mediaReference == nil），媒体 caption 不动
//   - 跳过以 "/" 开头的命令、空串
//   - 只翻「以中文为主」的文本（TranslationScriptRecognizer，CJK 占比 > 0.3）
//   - 目标语言就是中文时不翻
//   - 译文会剔除 TextEntitiesMessageAttribute：译文长度与原文不同，原实体区间必然错位
//   - 关闭开关或无需翻译时直接透传原数组，行为与未打补丁完全一致
//

import Foundation
import Postbox
import SwiftSignalKit

func translationOutboundTransform(
    account: Account,
    peerId: PeerId,
    messages: [EnqueueMessage]
) -> Signal<[EnqueueMessage], NoError> {
    let settings = TranslationProviderSettingsStore.shared.load()
    guard settings.translateOutgoing, !messages.isEmpty else {
        return .single(messages)
    }

    let toLang = settings.targetLanguage
    guard TranslationLanguage.canonical(toLang) != "zh" else {
        // 目标语言是中文，而输入本来就是中文，没有翻译的必要
        return .single(messages)
    }

    var pending: [(index: Int, text: String)] = []
    for (index, message) in messages.enumerated() {
        guard case let .message(text, _, _, mediaReference, _, _, _, _, _, _) = message else {
            continue
        }
        guard mediaReference == nil else {
            continue
        }
        guard !text.isEmpty, !text.hasPrefix("/") else {
            continue
        }
        guard TranslationScriptRecognizer.isPredominantlyChinese(text) else {
            continue
        }
        pending.append((index, text))
    }

    guard !pending.isEmpty else {
        return .single(messages)
    }

    let signals: [Signal<String?, NoError>] = pending.map { item in
        // 出站不能卡住发送：2 秒拿不到译文就按原文发出去
        return translationWithDeadline(
            MultiProviderTranslationService.shared.translateSingle(
                text: item.text,
                fromLang: "zh",
                toLang: toLang
            ),
            seconds: 2.0
        )
    }

    return combineLatest(signals)
    |> map { results -> [EnqueueMessage] in
        var translated: [Int: String] = [:]
        var failed: Set<Int> = []
        for (offset, item) in pending.enumerated() {
            let value = offset < results.count ? results[offset] : nil
            if let value, !value.isEmpty {
                translated[item.index] = value
            } else {
                failed.insert(item.index)
            }
        }

        // 失败一律按原文发送（绝不因为翻译失败而丢掉用户的消息）
        let dropFailures = false
        if !failed.isEmpty {
            TranslationLog.log("outbound", "翻译失败 \(failed.count)/\(pending.count) 条，按原文发送")
        }
        _ = settings.sendOriginalOnOutgoingFailure

        var output: [EnqueueMessage] = []
        output.reserveCapacity(messages.count)
        for (index, message) in messages.enumerated() {
            if let newText = translated[index] {
                if let replaced = translationReplaceText(of: message, with: newText) {
                    output.append(replaced)
                } else {
                    output.append(message)
                }
                continue
            }
            if failed.contains(index) && dropFailures {
                TranslationLog.log("outbound", "翻译失败且设置为中止，丢弃该条出站消息")
                continue
            }
            output.append(message)
        }
        return output
    }
}

/// 给翻译信号加一个硬上限：超时按「无译文」处理，避免阻塞发送。
private final class TranslationDeadlineFlag {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done {
            return false
        }
        done = true
        return true
    }
}

private func translationWithDeadline(_ signal: Signal<String?, NoError>, seconds: Double) -> Signal<String?, NoError> {
    return Signal { subscriber in
        let flag = TranslationDeadlineFlag()
        // 入参是 Signal<String?, NoError>：error 回调永远不会触发，写了就是 dead code（-warnings-as-errors 会直接报错）
        let inner = signal.start(next: { value in
            if flag.claim() {
                subscriber.putNext(value)
                subscriber.putCompletion()
            }
        }, completed: {
            if flag.claim() {
                subscriber.putNext(nil)
                subscriber.putCompletion()
            }
        })
        let work = DispatchWorkItem {
            if flag.claim() {
                subscriber.putNext(nil)
                subscriber.putCompletion()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: work)
        return ActionDisposable {
            work.cancel()
            inner.dispose()
        }
    }
}

/// 用译文重建 `EnqueueMessage.message`，并剔除会错位的文本实体属性。
private func translationReplaceText(of message: EnqueueMessage, with text: String) -> EnqueueMessage? {
    guard case let .message(
        _,
        attributes,
        inlineStickers,
        mediaReference,
        threadId,
        replyToMessageId,
        replyToStoryId,
        localGroupingKey,
        correlationId,
        bubbleUpEmojiOrStickersets
    ) = message else {
        return nil
    }

    // 译文与原文长度/结构不同，旧实体区间（粗体、链接、提及）必然错位，整段剔除最安全
    let cleanedAttributes = attributes.filter { !($0 is TextEntitiesMessageAttribute) }

    return .message(
        text: text,
        attributes: cleanedAttributes,
        inlineStickers: inlineStickers,
        mediaReference: mediaReference,
        threadId: threadId,
        replyToMessageId: replyToMessageId,
        replyToStoryId: replyToStoryId,
        localGroupingKey: localGroupingKey,
        correlationId: correlationId,
        bubbleUpEmojiOrStickersets: bubbleUpEmojiOrStickersets
    )
}
