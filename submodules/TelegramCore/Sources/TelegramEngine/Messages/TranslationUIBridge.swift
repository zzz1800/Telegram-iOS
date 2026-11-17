//
// TranslationUIBridge.swift
// TelegramCore · TelegramEngine/Messages
//
// SettingsUI 与 TelegramCore 之间的最小桥：
//   - tgTranslatePresentSettings：由 LocalizationListController 在 init 时注入，
//     语言设置页的「翻译通道」一行点击后调用它弹出设置面板。
//   - tgTranslateSummary：给那一行做副标题（当前引擎 · 目标语言）。
//
// 之所以用全局闭包而不是给 ItemList 的构造函数加参数：
// 后者要改 4 处调用点 + 2 个函数签名，改动面大且易漏；这里只动 1 处注入 + 1 处调用。
//

import Foundation

/// 打开 TGTranslate 设置面板（由 SettingsUI 注入）
public var tgTranslatePresentSettings: (() -> Void)?

/// 语言设置页「翻译通道」一行的副标题
public func tgTranslateSummary() -> String {
    let settings = TranslationProviderSettingsStore.shared.load()
    return settings.kind.displayName + " · " + settings.targetLanguage
}
