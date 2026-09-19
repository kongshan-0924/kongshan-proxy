#!/usr/bin/env python3
"""发布前的私有信息闸门：公开仓库里不许出现任何私有信息，必要处只用示例值。

扫描对象是**即将公开的那一份内容**：
  --tree <tree-ish>   一个 git tree（release.sh 导出公开快照后传入）
  --worktree          当前工作区里会被导出的文件（排除 public-export-exclude.txt 列出的路径）
  --message <文本>    公开提交的说明
  --binary <文件>...  可执行文件里编译进去的字符串（strings -a），防止示例数据之类的私有值随安装包发出去

检查项（命中即失败，退出码 1）：
  - 公网 IPv4 / IPv6（文档保留段 192.0.2.0/24、198.51.100.0/24、203.0.113.0/24、2001:db8::/32，
    私网、回环、链路本地、CGNAT、基准测试段除外；公共 DNS 等非私有值放在白名单里）
  - 邮箱（noreply / example 域除外）、本机用户目录 /Users/<名字>、电脑名 *MacBook*.local
  - 私钥、各类 API 令牌、带账号密码的 URL、带令牌的订阅链接、JWT
  - 私有黑名单里的词（个人 / 单位域名、姓名等）——黑名单本身是私有信息，只放在开发仓库，
    不随公开快照发布（见 --deny）

误报处理：非私有的固定值（测试用的边界 IP、公共 DNS）写进 scripts/leak-guard-allow.txt。
"""
import argparse
import ipaddress
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

DOC_NETS_V4 = [ipaddress.IPv4Network(n) for n in ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24",
                                                    "100.64.0.0/10", "198.18.0.0/15")]
DOC_NET_V6 = ipaddress.IPv6Network("2001:db8::/32")

SECRET_PATTERNS = [
    ("私钥", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP |ENCRYPTED )?PRIVATE KEY-----")),
    ("GitHub 令牌", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,})\b")),
    ("API Key", re.compile(r"\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{24,}\b")),
    ("AWS Access Key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("Slack 令牌", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b")),
    ("Telegram Bot Token", re.compile(r"\b\d{8,10}:AA[A-Za-z0-9_-]{33}\b")),
    ("JWT", re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}")),
    ("带账号密码的 URL", re.compile(r"\b[a-z][a-z0-9+.-]*://[^\s/:@\"'<>]+:[^\s@\"'<>/]{3,}@(?!example\.)[^\s\"'<>]+", re.I)),
    ("带令牌的订阅链接", re.compile(r"https?://(?![^/\s\"']*example\.(?:com|org|net)\b)[^\s\"'<>)]*"
                                  r"(?:[?&](?:token|key|auth|secret|sig)=[A-Za-z0-9_-]{8,}|/api/v1/client/subscribe\?)", re.I)),
    ("电脑名", re.compile(r"\b[A-Za-z0-9-]*MacBook[A-Za-z0-9-]*\.local\b")),
]
EMAIL = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
EXAMPLE_HOST = re.compile(r"(?:^|\.)(?:example\.(?:com|org|net)|example|test|invalid|localhost)\.?$", re.I)
EMAIL_OK = re.compile(r"(?:noreply|no-reply|@users\.noreply\.github\.com$|^git@github\.com$|@2x\.|@3x\.)", re.I)
HOME_DIR = re.compile(r"/Users/(?!(?:shared|example\d*|someone(?:-else)?|user|username|runner|me|name|tester|x|a)\b)[A-Za-z0-9._-]+", re.I)
IPV4 = re.compile(r"(?<![\d.])(\d{1,3}(?:\.\d{1,3}){3})(?![\d.])")
IPV6 = re.compile(r"(?<![0-9A-Fa-f:])((?:[0-9A-Fa-f]{1,4}:){2,7}[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{1,4}){0,5})(?![0-9A-Fa-f:])")


def mask(value: str) -> str:
    if IPV4.fullmatch(value):
        a, b, *_ = value.split(".")
        return f"{a}.{b}.x.x"
    if len(value) <= 6:
        return value[0] + "*" * (len(value) - 1)
    keep = max(2, len(value) // 6)
    return f"{value[:keep]}…{value[-keep:]}"


def url_host(url: str) -> str:
    rest = url.split("://", 1)[-1].split("@", 1)[-1]
    return re.split(r"[/:?#]", rest, maxsplit=1)[0]


def load_list(path):
    if not path or not Path(path).exists():
        return []
    items = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            items.append(line)
    return items


def deny_patterns(words):
    # 按词边界匹配：黑名单里有「example.net」时，「example.network-path-probe」这类代码标识符不该被误伤。
    return [(w, re.compile(r"(?<![A-Za-z0-9_-])" + re.escape(w) + r"(?![A-Za-z0-9_])", re.I)) for w in words]


def check_text(text, where, allow, deny):
    problems = []
    for lineno, line in enumerate(text.splitlines(), 1):
        loc = f"{where}:{lineno}"
        for label, rx in SECRET_PATTERNS:
            for m in rx.finditer(line):
                value = m.group(0)
                if value in allow or (label == "带账号密码的 URL" and EXAMPLE_HOST.search(url_host(value))):
                    continue
                problems.append((loc, label, mask(value), value))
        for m in EMAIL.finditer(line):
            value = m.group(0)
            if EMAIL_OK.search(value) or EXAMPLE_HOST.search(value.rsplit("@", 1)[1]) or value in allow:
                continue
            problems.append((loc, "邮箱", mask(value), value))
        for m in HOME_DIR.finditer(line):
            if m.group(0) not in allow:
                problems.append((loc, "本机用户目录", mask(m.group(0)), m.group(0)))
        for m in IPV4.finditer(line):
            ip = m.group(1)
            if ip in allow:
                continue
            try:
                addr = ipaddress.IPv4Address(ip)
            except ValueError:
                continue
            if (addr.is_private or addr.is_loopback or addr.is_link_local or addr.is_multicast
                    or addr.is_reserved or addr.is_unspecified or any(addr in n for n in DOC_NETS_V4)
                    or ip.startswith("0.")):
                continue
            problems.append((loc, "公网 IPv4", mask(ip), ip))
        for m in IPV6.finditer(line):
            cand = m.group(1)
            if cand.count(":") < 3 or cand in allow:
                continue
            try:
                addr = ipaddress.IPv6Address(cand)
            except ValueError:
                continue
            if addr.is_global and addr not in DOC_NET_V6:
                problems.append((loc, "公网 IPv6", mask(cand), cand))
        for word, rx in deny:
            if rx.search(line):
                problems.append((loc, "私有黑名单", mask(word), word))
    return problems


def is_binary(data: bytes) -> bool:
    return b"\0" in data[:8192]


def git(*args, binary=False):
    out = subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, check=True)
    return out.stdout if binary else out.stdout.decode("utf-8", "replace")


def tree_files(tree):
    for line in git("ls-tree", "-r", "-z", tree).split("\0"):
        if not line:
            continue
        meta, path = line.split("\t", 1)
        mode, kind, sha = meta.split()
        if kind == "blob" and mode != "120000":
            yield path, git("cat-file", "blob", sha, binary=True)


def worktree_files(exclude):
    for path in git("ls-files", "-z").split("\0"):
        if not path or any(path == e.rstrip("/") or path.startswith(e.rstrip("/") + "/") for e in exclude):
            continue
        full = ROOT / path
        if full.is_file() and not full.is_symlink():
            yield path, full.read_bytes()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tree")
    parser.add_argument("--worktree", action="store_true")
    parser.add_argument("--message")
    parser.add_argument("--binary", nargs="*", default=[])
    parser.add_argument("--summary", action="store_true", help="按类别与值汇总（值仍打码），便于甄别误报")
    parser.add_argument("--allow", default=str(ROOT / "scripts/leak-guard-allow.txt"))
    parser.add_argument("--deny", default=str(ROOT / "docs/private/leak-denylist.txt"))
    parser.add_argument("--exclude", default=str(ROOT / "scripts/public-export-exclude.txt"))
    args = parser.parse_args()

    allow = set(load_list(args.allow))
    deny = deny_patterns(load_list(args.deny))
    problems = []
    scanned = 0
    if args.tree:
        files = tree_files(args.tree)
    elif args.worktree:
        files = worktree_files(load_list(args.exclude))
    else:
        files = []
    for path, data in files:
        if is_binary(data):
            continue
        scanned += 1
        problems += check_text(data.decode("utf-8", "replace"), path, allow, deny)
    if args.message is not None:
        problems += check_text(args.message, "(提交说明)", allow, deny)
    for binary in args.binary:
        text = subprocess.run(["strings", "-a", binary], capture_output=True, check=True).stdout.decode("utf-8", "replace")
        scanned += 1
        problems += check_text(text, f"(二进制 {Path(binary).name})", allow, deny)

    if problems and args.summary:
        groups = {}
        for loc, label, value, _raw in problems:
            entry = groups.setdefault((label, value), [0, loc])
            entry[0] += 1
        print(f"私有信息闸门：{len(problems)} 处，{len(groups)} 个不同值：", file=sys.stderr)
        for (label, value), (count, loc) in sorted(groups.items(), key=lambda kv: -kv[1][0]):
            print(f"  [{label}] {value}  ×{count}  例：{loc}", file=sys.stderr)
        return 1
    if problems:
        print(f"私有信息闸门：发现 {len(problems)} 处，拒绝公开（值已打码）：", file=sys.stderr)
        for loc, label, value, _raw in problems[:200]:
            print(f"  {loc}  [{label}] {value}", file=sys.stderr)
        if len(problems) > 200:
            print(f"  …另有 {len(problems) - 200} 处", file=sys.stderr)
        return 1
    print(f"私有信息闸门：通过（扫描 {scanned} 个文本文件，黑名单 {len(deny)} 项）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
