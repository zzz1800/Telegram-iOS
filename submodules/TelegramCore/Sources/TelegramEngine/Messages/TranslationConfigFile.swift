//
// TranslationConfigFile.swift
// TelegramCore · TelegramEngine/Messages
//
// 用「配置文件」代替设置界面：把 tgtranslate.json 放进 Telegram 的「文件」App 目录即可
// 切换翻译引擎、填代理、填百度密钥、开关收发自动翻译。
//
// 读取顺序（后者覆盖前者）：
//   内置默认  <  UserDefaults  <  Documents/tgtranslate.json
//                                < Library/Application Support/tgtranslate.json
//
// 设计约束：
//   - 只用 Foundation，不引入新依赖，编译风险最低
//   - 任何解析失败都静默回退默认值，绝不崩溃
//   - 按文件 mtime + size 缓存，避免每次翻译都读盘；改完文件重启 App 即生效
//   - 密钥若写在文件里，会同步写入 Keychain（与设置界面同一存储位置）
//

import Foundation

enum TranslationConfigFile {

    struct Payload {
        var provider: TranslationProviderKind?
        var targetLanguage: String?
        var translateIncoming: Bool?
        var translateOutgoing: Bool?
        var sendOriginalOnFailure: Bool?
        var proxy: String?
        var baiduAppId: String?
        var baiduKey: String?
        var baiduChunkBytes: Int?
        var baiduMinInterval: Double?
        var googleMaxConcurrency: Int?
        var googleChunkChars: Int?
    }

    // MARK: 缓存

    private static let lock = NSLock()
    private static var cachedPath: String?
    private static var cachedStamp: String?
    private static var cachedPayload: Payload?

    // MARK: 对外

    static func apply(to settings: inout TranslationProviderSettings) {
        guard let payload = payload() else {
            return
        }
        if let value = payload.provider {
            settings.kind = value
        }
        if let value = payload.targetLanguage, !value.isEmpty {
            settings.targetLanguage = value
        }
        if let value = payload.translateIncoming {
            settings.translateIncoming = value
        }
        if let value = payload.translateOutgoing {
            settings.translateOutgoing = value
        }
        if let value = payload.sendOriginalOnFailure {
            settings.sendOriginalOnOutgoingFailure = value
        }
        if let value = payload.proxy {
            settings.googleProxy = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let value = payload.baiduAppId, !value.isEmpty {
            settings.baiduAppId = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let value = payload.baiduKey, !value.isEmpty {
            let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.baiduKey = key
            // 与 Keychain 双向一致：文件里给了就同步进去，之后即使删掉文件也还能用
            TranslationKeychain.set(key, account: "baiduKey")
        }
        if let value = payload.baiduChunkBytes, value > 0 {
            settings.baiduChunkBytes = value
        }
        if let value = payload.baiduMinInterval, value > 0 {
            settings.baiduMinInterval = value
        }
        if let value = payload.googleMaxConcurrency, value > 0 {
            settings.googleMaxConcurrency = value
        }
        if let value = payload.googleChunkChars, value > 0 {
            settings.googleFallbackChunkChars = value
        }
    }

    /// 配置文件路径（供日志与文档引用）
    static var searchPaths: [String] {
        var paths: [String] = []
        let manager = FileManager.default
        if let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first {
            paths.append(documents.appendingPathComponent("tgtranslate.json").path)
        }
        if let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            paths.append(support.appendingPathComponent("tgtranslate.json").path)
        }
        return paths
    }

    // MARK: 读取

    private static func payload() -> Payload? {
        let manager = FileManager.default
        for path in searchPaths {
            guard let attributes = try? manager.attributesOfItem(atPath: path) else {
                continue
            }
            let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            let stamp = "\(mtime)-\(size)"

            lock.lock()
            if cachedPath == path, cachedStamp == stamp {
                let cached = cachedPayload
                lock.unlock()
                return cached
            }
            lock.unlock()

            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let json = object as? [String: Any] else {
                TranslationLog.log("config", "配置文件解析失败，忽略: \(path)")
                lock.lock()
                cachedPath = path
                cachedStamp = stamp
                cachedPayload = nil
                lock.unlock()
                return nil
            }

            let parsed = parse(json)
            TranslationLog.log("config", "已加载配置 \(path)")
            lock.lock()
            cachedPath = path
            cachedStamp = stamp
            cachedPayload = parsed
            lock.unlock()
            return parsed
        }
        return nil
    }

    private static func parse(_ json: [String: Any]) -> Payload {
        var payload = Payload()
        if let raw = json["provider"] as? String {
            payload.provider = TranslationProviderKind(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        if let value = json["targetLanguage"] as? String {
            payload.targetLanguage = value
        }
        if let value = json["translateIncoming"] as? Bool {
            payload.translateIncoming = value
        }
        if let value = json["translateOutgoing"] as? Bool {
            payload.translateOutgoing = value
        }
        if let value = json["sendOriginalOnFailure"] as? Bool {
            payload.sendOriginalOnFailure = value
        }
        if let value = json["proxy"] as? String {
            payload.proxy = value
        }
        if let value = json["baiduAppId"] as? String {
            payload.baiduAppId = value
        }
        if let value = json["baiduKey"] as? String {
            payload.baiduKey = value
        }
        if let value = json["baiduChunkBytes"] as? Int {
            payload.baiduChunkBytes = value
        }
        if let value = json["baiduMinInterval"] as? Double {
            payload.baiduMinInterval = value
        }
        if let value = json["googleMaxConcurrency"] as? Int {
            payload.googleMaxConcurrency = value
        }
        if let value = json["googleChunkChars"] as? Int {
            payload.googleChunkChars = value
        }
        return payload
    }
}
