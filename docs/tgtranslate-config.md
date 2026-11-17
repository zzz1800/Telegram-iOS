# TGTranslate 配置说明（tgtranslate.json）

装好 App 后，手机「文件」App 里会出现 **Telegram** 文件夹（因为 Info.plist 已开 `UIFileSharingEnabled`）。
把 `tgtranslate.json` 放进去，**重启 Telegram** 即生效。

路径（App 内部视角，二选一即可）：
- `文件 App → 我的 iPhone → Telegram → tgtranslate.json`
- 或 `Library/Application Support/tgtranslate.json`

---

## 完整模板（把不要的键删掉也行，缺字段用默认值）

```json
{
  "provider": "google",
  "targetLanguage": "zh",
  "translateIncoming": true,
  "translateOutgoing": false,
  "sendOriginalOnFailure": true,
  "proxy": "",
  "baiduAppId": "",
  "baiduKey": "",
  "baiduChunkBytes": 5000,
  "baiduMinInterval": 1.05,
  "googleMaxConcurrency": 2,
  "googleChunkChars": 4000
}
```

---

## 字段说明

| 字段 | 取值 | 作用 |
|---|---|---|
| `provider` | `google` / `baidu` | 翻译引擎（默认 google） |
| `targetLanguage` | `zh` `en` `ja` … | 译文语言；等于原文语言时不翻译 |
| `translateIncoming` | true/false | **收到的外语消息自动翻译**（默认 true） |
| `translateOutgoing` | true/false | **打中文时自动翻成 targetLanguage 再发送**（默认 false） |
| `sendOriginalOnFailure` | true/false | 出站翻译失败时：true=原样发送，false=不发送 |
| `proxy` | `http://127.0.0.1:7890` / `socks5://127.0.0.1:1080` / 空 | **Google 通道必需**（国内直连超时） |
| `baiduAppId` | 百度翻译开放平台 APPID | 用百度通道时必填 |
| `baiduKey` | 百度密钥 | 用百度通道时必填；会自动存进 Keychain |
| `baiduChunkBytes` | 整数，默认 5000 | 百度单次请求字节上限（官方硬顶 6000） |
| `baiduMinInterval` | 秒，默认 1.05 | 百度标准版 QPS=1，必须串行 ≥1s |
| `googleMaxConcurrency` | 整数，默认 2 | Google 并发请求数 |
| `googleChunkChars` | 整数，默认 4000 | Google 单次请求字符上限 |

---

## 三种典型配置

### 1) 只用 Google（有全局代理/VPN 时）
```json
{ "provider": "google", "targetLanguage": "zh", "translateIncoming": true }
```
> 没配代理且直连不通时，会自动回退到 Telegram 官方翻译（仍可用，但不是 Google）。

### 2) Google 走本地代理
```json
{ "provider": "google", "targetLanguage": "zh", "translateIncoming": true, "proxy": "http://127.0.0.1:7890" }
```

### 3) 用百度（国内直连可用，无需代理）
```json
{
  "provider": "baidu",
  "targetLanguage": "en",
  "translateIncoming": true,
  "translateOutgoing": true,
  "baiduAppId": "你的APPID",
  "baiduKey": "你的密钥"
}
```
> 百度标准版免费额度 5 万字符/月，超出 49 元/百万字符；QPS=1，程序已做串行排队。
> 官方要求「勿将 APPID 和密钥填入第三方软件」——自用请自行评估；密钥只存本机。

---

## 排错

| 现象 | 原因 | 处理 |
|---|---|---|
| 完全没翻译 | 消息本来就是目标语言 / 开了「不翻译的语言」 | 换条外语消息试 |
| Google 一直慢/失败 | 无代理，直连超时 | 配 `proxy` 或挂 VPN |
| 百度报 54003 | 频率超限（QPS=1） | 调大 `baiduMinInterval` |
| 百度报 54001 | 签名错 | 检查 APPID/密钥；本程序的签名实现已对过官方样例 |
| 百度报 58003 | 同 IP 用了多个 APPID，当日封禁 | 次日恢复，只用一个 APPID |
| 改了 json 没生效 | 需要重启 App | 完全退出 Telegram 再打开 |
| json 写错 | 解析失败会静默回退默认 | 用 JSON 校验器检查语法 |
