//
// TranslationScriptRecognizer.swift
// TelegramCore · TelegramEngine/Messages
//
// 出站翻译用：粗略判断草稿是否为中文。
// 不引 NLLanguageRecognizer（那是 TelegramUI 侧能力，且有系统版本依赖），
// 这里只做"是否以汉字为主"的判定，误判代价是"该翻的没翻"，可接受。
//

import Foundation

public enum TranslationScriptRecognizer {
    /// CJK 表意文字占字母类字符比例 > 30% 视为中文
    public static func isPredominantlyChinese(_ text: String) -> Bool {
        var cjk = 0
        var letters = 0
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if (0x4E00 ... 0x9FFF).contains(value) || (0x3400 ... 0x4DBF).contains(value) {
                cjk += 1
                letters += 1
            } else if CharacterSet.letters.contains(scalar) {
                letters += 1
            }
        }
        guard letters > 0 else {
            return false
        }
        return Double(cjk) / Double(letters) > 0.3
    }
}
