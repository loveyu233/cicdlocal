#!/usr/bin/env python3
"""只使用 cicddemo 的隔离副本和本地裸仓库验证推送，不访问真实远端。"""
import os
from pathlib import Path
import subprocess
import tempfile

from test_source import test_source

ROOT = Path(__file__).resolve().parent.parent
SOURCE = test_source()
ENV = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
ENV.update(GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0")
# 只用来制造一个新提交；PushWatch 不解析配置，替换目标也不会被执行。
CONFIG = """\
build:
  image: 127.0.0.1:5000/cicddemo:${TIME}
  dockerfile: Dockerfile
deploy:
  - branch: main
    k8s: 测试环境
    namespace: default
    deployment: cicddemo
    container: cicddemo
"""


def git(directory, *arguments):
    return subprocess.check_output(
        ["/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-C", str(directory), *arguments],
        env=ENV, stderr=subprocess.PIPE,
    )


def state():
    return tuple(git(SOURCE, *args) for args in [
        ("rev-parse", "HEAD"), ("show-ref",), ("status", "--porcelain=v1", "-z"),
    ])


before = state()
(ROOT / ".test-repos").mkdir(exist_ok=True)
work = Path(tempfile.mkdtemp(prefix="cicddemo-push-", dir=ROOT / ".test-repos"))
repository = work / "工作 副本'"
remote = work / "remote.git"
try:
    for arguments in [
        ("clone", "--no-hardlinks", "--bare", str(SOURCE), str(remote)),
        ("clone", "--no-hardlinks", str(remote), str(repository)),
    ]:
        subprocess.run(["/usr/bin/git", *arguments], env=ENV, check=True, capture_output=True)
    git(repository, "config", "user.name", "本地推送测试")
    git(repository, "config", "user.email", "test@example.invalid")
    git(repository, "config", "commit.gpgsign", "false")
    (repository / ".local.cicd.yml").write_text(CONFIG)
    git(repository, "add", "--", ".local.cicd.yml")
    git(repository, "commit", "-m", "添加本地 CI 配置")
    (work / "source").write_text(str(SOURCE))
    package = ROOT / "Packages/PushWatch"
    subprocess.run(["swift", "build", "--package-path", str(package), "--product", "localcicd-hook"],
                   env=ENV, check=True)
    binary = subprocess.check_output(["swift", "build", "--package-path", str(package), "--show-bin-path"],
                                     env=ENV, text=True).strip()
    print(f"推送验证目录：{work}", flush=True)
    subprocess.run(
        [str(ROOT / "scripts/test-packages.sh"), "Storage", "PushWatch"], cwd=ROOT, check=True,
        env=dict(ENV, LOCALCICD_PUSH_TEST_ROOT=str(work), LOCALCICD_HOOK_HELPER=str(Path(binary) / "localcicd-hook")),
    )
finally:
    if state() != before:
        raise RuntimeError("cicddemo 原仓库状态发生变化，需要检查")
    print("cicddemo 原仓库 HEAD、引用和工作区状态保持不变。", flush=True)
