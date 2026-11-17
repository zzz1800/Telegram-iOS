//
// TranslationMD5.swift
// TelegramCore · TelegramEngine/Messages
//
// 用途：百度翻译 sign = MD5(appid + q + salt + 密钥) 的兜底实现。
// 背景：主实现用 CryptoKit.Insecure.MD5（BaiduTranslateBackend.swift）。若 CI 在
//       submodules/TelegramCore 的 swift_library 下链接 CryptoKit 失败，把
//       BaiduTranslateBackend.swift 里的 md5Hex 换成 TranslationMD5.hex 即可，
//       其余代码不动。
//
// 约束：该 target 开了 -warnings-as-errors，本文件不得有未使用变量 / 隐式转换警告。
// 自测向量（百度官方文档样例）：
//   appid=2015063000000001, q=apple, salt=65478, key=1234567890
//   → a1a7461d92e5194c5cae3182b5b24de1
//

import Foundation

enum TranslationMD5 {

    // 每轮左移位数（RFC 1321）
    private static let shifts: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]

    // K[i] = floor(abs(sin(i + 1)) * 2^32)，运行时算出，避免手抄 64 个常量出错
    private static let table: [UInt32] = (0 ..< 64).map { index in
        let value = abs(sin(Double(index) + 1.0)) * 4294967296.0
        return UInt32(truncatingIfNeeded: UInt64(value.rounded(.down)))
    }

    static func digest(_ message: [UInt8]) -> [UInt8] {
        var stateA: UInt32 = 0x67452301
        var stateB: UInt32 = 0xefcdab89
        var stateC: UInt32 = 0x98badcfe
        var stateD: UInt32 = 0x10325476

        let bitLength = UInt64(message.count) * 8
        var bytes = message
        bytes.append(0x80)
        while bytes.count % 64 != 56 {
            bytes.append(0)
        }
        for index in 0 ..< 8 {
            bytes.append(UInt8(truncatingIfNeeded: bitLength >> (8 * UInt64(index))))
        }

        var words = [UInt32](repeating: 0, count: 16)
        var offset = 0
        while offset < bytes.count {
            for index in 0 ..< 16 {
                let base = offset + index * 4
                words[index] = UInt32(bytes[base])
                    | (UInt32(bytes[base + 1]) << 8)
                    | (UInt32(bytes[base + 2]) << 16)
                    | (UInt32(bytes[base + 3]) << 24)
            }

            var a = stateA
            var b = stateB
            var c = stateC
            var d = stateD

            for index in 0 ..< 64 {
                let f: UInt32
                let g: Int
                switch index {
                case 0 ..< 16:
                    f = (b & c) | (~b & d)
                    g = index
                case 16 ..< 32:
                    f = (d & b) | (~d & c)
                    g = (5 * index + 1) % 16
                case 32 ..< 48:
                    f = b ^ c ^ d
                    g = (3 * index + 5) % 16
                default:
                    f = c ^ (b | ~d)
                    g = (7 * index) % 16
                }
                let previousD = d
                d = c
                c = b
                let sum = a &+ f &+ table[index] &+ words[g]
                let rotated = (sum << shifts[index]) | (sum >> (32 - shifts[index]))
                b = b &+ rotated
                a = previousD
            }

            stateA = stateA &+ a
            stateB = stateB &+ b
            stateC = stateC &+ c
            stateD = stateD &+ d

            offset += 64
        }

        var output = [UInt8]()
        output.reserveCapacity(16)
        for value in [stateA, stateB, stateC, stateD] {
            for index in 0 ..< 4 {
                output.append(UInt8(truncatingIfNeeded: value >> (8 * UInt32(index))))
            }
        }
        return output
    }

    static func hex(_ string: String) -> String {
        return digest(Array(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
