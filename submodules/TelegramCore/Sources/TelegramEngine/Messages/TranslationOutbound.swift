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
        return MultiProviderTranslationService.shared.translateSingle(
            text: item.text,
            fromLang: "zh",
            toLang: toLang
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

        // 失败且用户选择「中止发送」：把这些消息从出站队列里摘掉
        let dropFailures = !settings.sendOriginalOnOutgoingFailure

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
