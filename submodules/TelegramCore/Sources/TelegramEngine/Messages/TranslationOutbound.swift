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
    guard !messages.isEmpty else {
        return .single(messages)
    }
    guard settings.translateOutgoing else {
        // TGTranslate: 以前这里静默 return，日志里什么都没有，被误判成「翻译链路坏了」。
        // 现在每道闸都留一行，30 行日志就能定位卡在哪。
        TranslationLog.log("outbound", "跳过：发送前自动翻译=关")
        return .single(messages)
    }

    // 出站目标语言与入站目标语言是两件事：入站要 zh、出站要 en，共用一个字段只能活一个方向
    let outgoingRaw = settings.outgoingTargetLanguage
    guard !TranslationLanguage.isChinese(outgoingRaw) else {
        TranslationLog.log("outbound", "跳过：发送目标语言是中文 (\(outgoingRaw))")
        return .single(messages)
    }
    let officialToLang = TranslationLanguage.officialCode(outgoingRaw)
    let localToLang = TranslationLanguage.canonical(outgoingRaw)

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
        TranslationLog.log("outbound", "跳过：没有中文纯文本 (共 \(messages.count) 条)")
        return .single(messages)
    }
    TranslationLog.log("outbound", "官方优先发起 \(pending.count) 条 (to=\(officialToLang))")

    let signals: [Signal<String?, NoError>] = pending.map { item in
        // TGTranslate: 出站改「官方优先，本地兜底」。
        // 为什么翻过来：本地通道是 Google，国内直连是**挂住**不是快速失败（URLSession 15s/30s），
        // 而上一版给整条链只留 5 秒硬截止 → 到点就按原文发送，官方回退一次都没机会发起
        // （真机日志只有「翻译失败 0/1 条，按原文发送」）。官方 messages.translateText 这个账号可用
        // （入站三条路就靠它），所以出站也先打官方。
        let official = _internal_translateOfficial(
            network: account.network,
            text: item.text,
            toLang: officialToLang
        )
        |> map { result -> String? in
            if let translated = result?.0, !translated.isEmpty {
                return translated
            }
            return nil
        }
        |> `catch` { error -> Signal<String?, NoError> in
            TranslationLog.log("outbound", "官方失败 \(error)")
            return .single(nil)
        }

        let chain = translationWithDeadline(official, seconds: 4.0)
        |> mapToSignal { officialValue -> Signal<String?, NoError> in
            if let officialValue, !officialValue.isEmpty {
                TranslationLog.log("outbound", "官方成功")
                return .single(officialValue)
            }
            TranslationLog.log("outbound", "官方无结果，本地兜底 (to=\(localToLang))")
            return MultiProviderTranslationService.shared.translateSingle(
                text: item.text,
                fromLang: "zh",
                toLang: localToLang
            )
            |> map { localValue -> String? in
                if let localValue, !localValue.isEmpty {
                    TranslationLog.log("outbound", "本地兜底成功")
                    return localValue
                }
                return nil
            }
        }
        // 出站不能卡住发送：官方 4 秒 + 本地兜底，整体最多 10 秒，再不行按原文发送（绝不丢消息）
        return translationWithDeadline(chain, seconds: 10.0)
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
