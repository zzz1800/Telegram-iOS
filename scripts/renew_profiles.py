#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把仓库自带的假描述文件（.mobileprovision）过期时间续到未来，并重新 CMS 签名。

背景：Telegram-iOS 仓库里 build-system/fake-codesigning/profiles/ 的那批描述文件
签于 2025-11，ExpirationDate 为 2026-10-30；过期后 Bazel 的 ProcessEntitlementsFiles
会直接失败：

    ERROR: On target "@@//Telegram:BroadcastUploadExtension",
    provisioning profile ExpirationDate ("2026-10-30T17:06:30") is in the past.

本脚本只做三件事：
  1. 解出 profile 内嵌的 plist，把 ExpirationDate 推到 +N 天（默认 365）
  2. 去掉 DER-Encoded-Profile（原签名块）
  3. 用 build-system/fake-codesigning/certs/SelfSigned.p12 重新 CMS 签名整份 plist

签名身份不再靠解析 openssl 的 subject 字符串（新版 OpenSSL 输出格式会变，解析会拿到 None），
改为导入临时钥匙串后用 `security find-identity -v -p codesigning` 直接取。

用法（在仓库根目录执行）：
    python3 scripts/renew_profiles.py                # 续签 profiles/
    python3 scripts/renew_profiles.py --days 730
"""

import argparse
import datetime
import os
import plistlib
import re
import subprocess
import sys
import tempfile

CANDIDATE_DIRS = [
    "build-system/fake-codesigning/profiles",
    "build-system/fake-codesigning/provisioning",
    "build-system/example-configuration/provisioning",
]


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def setup_keychain(p12_path, password=""):
    name = "renew-profiles-temp.keychain"
    keychain_password = "temp123"
    run(["security", "delete-keychain", name])
    subprocess.check_call(["security", "create-keychain", "-p", keychain_password, name])
    existing = run(["security", "list-keychains", "-d", "user"]).stdout
    names = [line.strip().strip('"') for line in existing.splitlines() if line.strip()]
    subprocess.check_call(["security", "list-keychains", "-d", "user", "-s", name] + names)
    run(["security", "set-keychain-settings", name])
    subprocess.check_call(["security", "unlock-keychain", "-p", keychain_password, name])
    subprocess.check_call([
        "security", "import", p12_path, "-k", name, "-P", password,
        "-T", "/usr/bin/codesign", "-T", "/usr/bin/security",
    ])
    run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:", "-k", keychain_password, name])
    return name


def find_identity(keychain):
    """从钥匙串里取签名身份（security cms -N 需要的字符串）。

    自签证书通常不带 codesigning 策略，`-p codesigning` 过滤会得到 0 条，
    所以逐级放宽：带策略 -> 只看有效 -> 全量列出。
    """
    attempts = [
        ["security", "find-identity", "-v", "-p", "codesigning", keychain],
        ["security", "find-identity", "-v", keychain],
        ["security", "find-identity", keychain],
    ]
    for cmd in attempts:
        result = run(cmd)
        out = (result.stdout or "") + (result.stderr or "")
        ids = re.findall(r'"([^"]+)"', out)
        if ids:
            print("identity via:", " ".join(cmd[:3]), "->", ids[0])
            return ids[0]
        print("no identity via:", " ".join(cmd[:3]), "|", out.strip().splitlines()[-1] if out.strip() else "empty")
    return None


def find_identity_from_p12(p12_path, password=""):
    """兜底：直接解析 openssl 输出的 subject，兼容 'CN = x' 与 'CN=x' 两种格式。"""
    pem = ""
    for extra in (["-legacy"], []):
        result = subprocess.run(
            ["openssl", "pkcs12", "-in", p12_path, "-passin", "pass:" + password, "-nokeys"] + extra,
            capture_output=True)
        if result.stdout:
            pem = result.stdout.decode("utf-8", "replace")
            break
        print("openssl pkcs12 失败" + (" (-legacy)" if extra else ""), ":",
              result.stderr.decode("utf-8", "replace").strip()[:200])
    if not pem:
        return None
    proc = subprocess.run(["openssl", "x509", "-noout", "-subject", "-nameopt", "RFC2253"],
                          input=pem.encode(), capture_output=True)
    subject = proc.stdout.decode("utf-8", "replace").strip()
    if not subject:
        proc = subprocess.run(["openssl", "x509", "-noout", "-subject"],
                              input=pem.encode(), capture_output=True)
        subject = proc.stdout.decode("utf-8", "replace").strip()
    print("subject:", subject)
    match = re.search(r"CN=([^,]+)", subject) or re.search(r"CN\s*=\s*([^,]+)", subject)
    if match:
        return match.group(1).strip()
    return None


def renew_one(path, identity, keychain, new_expiry):
    with open(path, "rb") as fh:
        raw = fh.read()
    start = raw.find(b"<?xml")
    end = raw.find(b"</plist>") + len(b"</plist>")
    if start < 0 or end <= start:
        print("  skip (no embedded plist):", os.path.basename(path))
        return False
    pl = plistlib.loads(raw[start:end])
    old = pl.get("ExpirationDate")
    pl["ExpirationDate"] = new_expiry
    pl.pop("DER-Encoded-Profile", None)
    tmp = tempfile.mktemp(suffix=".plist")
    with open(tmp, "wb") as fh:
        plistlib.dump(pl, fh)
    try:
        subprocess.check_call([
            "security", "cms", "-S", "-k", keychain, "-N", identity, "-i", tmp, "-o", path,
        ])
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    print("  renewed:", os.path.basename(path), old, "->", new_expiry)
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=365)
    ap.add_argument("--certs", default="build-system/fake-codesigning/certs")
    ap.add_argument("--dir", default=None, help="指定 profiles 目录（默认自动探测）")
    args = ap.parse_args()

    prof_dir = args.dir
    if prof_dir is None:
        for candidate in CANDIDATE_DIRS:
            if os.path.isdir(candidate):
                prof_dir = candidate
                break
    if not prof_dir or not os.path.isdir(prof_dir):
        print("找不到 profiles 目录，已探测:", CANDIDATE_DIRS)
        return 1
    print("profiles dir:", os.path.abspath(prof_dir))

    p12 = os.path.join(args.certs, "SelfSigned.p12")
    if not os.path.exists(p12):
        print("缺少证书:", p12)
        return 1

    keychain = setup_keychain(p12, "")
    try:
        identity = find_identity(keychain)
        if not identity:
            print("钥匙串里没有签名身份，尝试从 p12 解析")
            identity = find_identity_from_p12(p12, "")
        if not identity:
            print("拿不到签名身份，放弃（不要用 None 去签名）")
            return 1
        print("signing identity:", identity)

        new_expiry = datetime.datetime.now() + datetime.timedelta(days=args.days)
        count = 0
        for name in sorted(os.listdir(prof_dir)):
            if not name.endswith(".mobileprovision"):
                continue
            if renew_one(os.path.join(prof_dir, name), identity, keychain, new_expiry):
                count += 1
        print("renewed total:", count)
        return 0 if count > 0 else 1
    finally:
        run(["security", "delete-keychain", keychain])


if __name__ == "__main__":
    sys.exit(main())
