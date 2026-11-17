//
// TranslationLanguage.swift
// TelegramCore · TelegramEngine/Messages
//
// 语言码归一化。三家各用一套码：
//   Telegram 侧：en / zh-hans / zh-hant / ja / ko / fr / es / ...
//   Google：     en / zh-CN  / zh-TW   / ja / ko / fr / es / ...
//   百度：       en / zh / cht / jp / kor / fra / spa / yue / wyw / ara / bul / est / vie ...
// 百度的 31 个语种代码来自官方文档语种对照表（已逐条抓取核对）：
//   auto zh en yue wyw jp kor fra spa th ara ru pt de it el nl pl bul est dan fin cs rom slo swe hu cht vie
//

import Foundation

public enum TranslationLanguage {
    /// 归一化到 Google 风格代码
    public static func canonical(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.isEmpty { return "auto" }
        switch value {
        case "auto": return "auto"
        case "zh", "zh-cn", "zh_cn", "zh-hans", "zh_hans", "chs", "cn": return "zh-CN"
        case "zh-hant", "zh_hant", "zh-tw", "zh_tw", "cht", "tw": return "zh-TW"
        case "yue": return "zh-yue"
        case "jp", "ja": return "ja"
        case "kor", "ko": return "ko"
        case "fra", "fre", "fr": return "fr"
        case "spa", "es": return "es"
        case "rus", "ru": return "ru"
        case "ger", "deu", "de": return "de"
        case "por", "pt": return "pt"
        case "ita", "it": return "it"
        case "gre", "el": return "el"
        case "nld", "nl": return "nl"
        case "pol", "pl": return "pl"
        case "bul", "bg": return "bg"
        case "est", "et": return "et"
        case "dan", "da": return "da"
        case "fin", "fi": return "fi"
        case "cs", "ces", "cze": return "cs"
        case "rom", "rum", "ro": return "ro"
        case "slo", "sk": return "sk"
        case "swe", "sv": return "sv"
        case "hu", "hun": return "hu"
        case "vie", "vi": return "vi"
        case "ara", "ar": return "ar"
        case "tha", "th": return "th"
        case "wyw", "lzh": return "zh-CN"   // 文言文，Google 无对应，退化为简体
        default: return value
        }
    }

    /// 百度代码；返回 nil 表示百度不支持该语种，调用方应回退 Google
    public static func baiduCode(_ raw: String) -> String? {
        switch canonical(raw) {
        case "auto": return "auto"
        case "zh-CN": return "zh"
        case "zh-TW": return "cht"
        case "zh-yue": return "yue"
        case "en": return "en"
        case "ja": return "jp"
        case "ko": return "kor"
        case "fr": return "fra"
        case "es": return "spa"
        case "th": return "th"
        case "ar": return "ara"
        case "ru": return "ru"
        case "pt": return "pt"
        case "de": return "de"
        case "it": return "it"
        case "el": return "el"
        case "nl": return "nl"
        case "pl": return "pl"
        case "bg": return "bul"
        case "et": return "est"
        case "da": return "dan"
        case "fi": return "fin"
        case "cs": return "cs"
        case "ro": return "rom"
        case "sk": return "slo"
        case "sv": return "swe"
        case "hu": return "hu"
        case "vi": return "vie"
        default:
            // 百度对照表里没有的语种（he / hi / id / ms / tr / uk / fa / ur / bn / ta / te …）
            return nil
        }
    }

    /// 设置页展示用
    public static func displayName(_ raw: String) -> String {
        switch canonical(raw) {
        case "zh-CN": return "简体中文"
        case "zh-TW": return "繁体中文"
        case "zh-yue": return "粤语"
        case "en": return "英语"
        case "ja": return "日语"
        case "ko": return "韩语"
        case "fr": return "法语"
        case "es": return "西班牙语"
        case "ru": return "俄语"
        case "de": return "德语"
        case "pt": return "葡萄牙语"
        case "it": return "意大利语"
        case "ar": return "阿拉伯语"
        case "th": return "泰语"
        case "vi": return "越南语"
        case "auto": return "自动"
        default: return raw
        }
    }
}
