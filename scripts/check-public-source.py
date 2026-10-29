#!/usr/bin/env python3
"""检查公开源码中的机器路径、敏感文件及内部域名；不会读取未跟踪的本地数据。"""
from pathlib import Path
import re
import struct
import subprocess
import sys
from urllib.parse import urlsplit


ALLOWED_DOMAINS = {
    "github.com", "docs.docker.com", "www.apple.com", "developer.apple.com",
    "opensource.org", "www.apache.org", "apache.org", "swift.org", "www.swift.org",
}


def violations(name: str, data: bytes) -> list[str]:
    problems = []
    path = Path(name)
    forbidden_parts = {".git", ".test-repos", ".build", "build", "DerivedData", ".codex", "xcuserdata"}
    if forbidden_parts.intersection(path.parts):
        problems.append("本地目录不能公开")
    if (path.name.startswith((".env", "__debug_")) and path.name != ".env.example") or path.name in {".DS_Store", "kubeconfig", ".local.cicd.yml"}:
        problems.append("本地配置不能公开")
    if re.search(r"\.(?:key|pem|p12|pfx|mobileprovision|kubeconfig|sqlite(?:-wal|-shm)?|db(?:-wal|-shm)?|log|zip|bundle)$", name):
        problems.append("凭据、数据或构建文件不能公开")
    # 公开资源只允许项目生成的 PNG 图标；其他二进制需先人工审查。
    if b"\0" in data:
        if not name.startswith("App/Resources/Assets.xcassets/") or not name.endswith(".png") or not data.startswith(b"\x89PNG\r\n\x1a\n"):
            problems.append("未审查的二进制文件")
        else:
            offset = 8
            while offset + 12 <= len(data):
                size = struct.unpack(">I", data[offset:offset + 4])[0]
                if data[offset + 4:offset + 8] in {b"tEXt", b"iTXt", b"zTXt", b"eXIf"}:
                    problems.append("图标含附加文本或 EXIF 元数据")
                    break
                offset += size + 12
        return problems
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return problems + ["未审查的非 UTF-8 文件"]
    if re.search(r"/(?:Users|home|Volumes)/[^/\s\"']+", text):
        problems.append("含机器专用绝对路径")
    for match in re.finditer(r"https?://[^\s<>\"'`)]+", text):
        if "{" in match.group() or "\\(" in match.group():
            continue
        try:
            host = urlsplit(match.group()).hostname
        except ValueError:
            # 源码里可能是用于校验的正则或故意损坏的 URL，不把它当成实际端点。
            continue
        if host and host not in ALLOWED_DOMAINS and host not in {"localhost", "::1"} and not host.startswith("127.") and not host.endswith((".invalid", ".example")):
            problems.append("含未批准的网络域名")
            break
    for match in re.finditer(r"\bregistry\.[a-zA-Z0-9.-]+", text):
        if not match.group().endswith((".invalid", ".example")):
            problems.append("含非示例镜像仓库域名")
            break
    return problems


def main() -> int:
    root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
    names = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")[:-1]
    failed = False
    for name in names:
        path = root / name
        if path.is_symlink():
            issues = ["公开快照不接受符号链接"]
        elif path.exists():
            issues = violations(name, path.read_bytes())
        else:
            continue
        if issues:
            failed = True
            # 只输出文件名和问题类型，不把潜在敏感内容再次打印到日志。
            print(f"{name}: {'；'.join(issues)}")
    if not failed:
        print(f"公开源码检查通过：{len(names)} 个跟踪文件。凭据仍需另用 Gitleaks 扫描。")
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
