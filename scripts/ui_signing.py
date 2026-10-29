"""为界面测试及本地交付包复用签名，避免重编译改变隐私授权身份。"""
import contextlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def resolve_ui_signing(root: Path) -> str:
    cache = root / "build/ui-signing-identity.json"
    explicit = os.environ.get("LOCALCICD_UI_SIGNING_IDENTITY")
    # 临时签名只允许显式选择，不能在已登记证书失效后悄悄退回临时身份。
    if explicit == "-":
        print("本轮显式使用临时签名；重新编译可能再次触发系统权限提示。", flush=True)
        return explicit
    output = subprocess.check_output(
        ["security", "find-identity", "-v", "-p", "codesigning"], text=True)
    identities = re.findall(r'\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"', output)
    identities = [(fingerprint.upper(), name) for fingerprint, name in identities]
    requested = explicit
    if not requested and cache.exists():
        requested = json.loads(cache.read_text())["fingerprint"]
    if requested:
        candidates = [(fingerprint, name) for fingerprint, name in identities
                      if requested.upper() == fingerprint or requested == name]
    else:
        candidates = [(fingerprint, name) for fingerprint, name in identities
                      if name.startswith("Apple Development:")]
    if len(candidates) != 1:
        raise RuntimeError("无法确定唯一且有效的本地开发签名证书。请设置 LOCALCICD_UI_SIGNING_IDENTITY；"
                           "已有授权不会被重置，也不会自动改用临时签名。")
    fingerprint, _ = candidates[0]
    cache.parent.mkdir(parents=True, exist_ok=True)
    # 只存公开证书指纹，不读取或导出私钥；build 目录不会进入版本控制。
    cache.write_text(json.dumps({"fingerprint": fingerprint}) + "\n")
    print(f"复用本地开发签名：{fingerprint}", flush=True)
    return fingerprint


if __name__ == "__main__":
    try:
        # 标准输出只返回指纹，供打包脚本作为单个签名参数传入。
        with contextlib.redirect_stdout(sys.stderr):
            identity = resolve_ui_signing(Path(__file__).resolve().parent.parent)
        print(identity)
    except RuntimeError as error:
        sys.exit(str(error))
