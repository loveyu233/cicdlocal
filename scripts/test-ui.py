#!/usr/bin/env python3
"""在 cicddemo 隔离副本上跑原生界面测试：本地裸仓库当远端，假 kubectl 代替集群，不连接任何真实服务。

流程：准备副本、两个假 kubeconfig 和假 kubectl → 启动 UI 测试 → 检测到 App 开启推送监听后执行一次 git push
→ UI 测试走完测试、构建、自动替换测试环境、确认替换正式环境 → 核对数据库、kubectl 参数和凭据处理。
截图导出到验证目录的 ui-attachments，便于人工检查深浅色。
"""
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import tempfile
import time

from ui_signing import resolve_ui_signing

from test_source import test_source

ROOT = Path(__file__).resolve().parent.parent
SOURCE = test_source()
ENV = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
ENV.update(GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0",
           DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
MARKER = "长行结束标记-UI"
TOKENS = {"测试环境": "ui-test-staging-token", "正式环境": "ui-test-production-token"}
# 测试阶段的长行用来检查日志自动换行；构建只回显镜像地址，不调用 docker。
CONFIG = f"""\
test:
  - go version
  - echo "{'自动换行检查 ' * 40}{MARKER}"
build:
  parallel: 2
  images:
    - name: app
      image: 127.0.0.1:5999/cicddemo:${{TIME}}
      command: while [ ! -f .git/localcicd-ui-release-app ]; do sleep 0.1; done; echo "构建推送 $CICD_IMAGE"
    - name: worker
      image: 127.0.0.1:5999/cicddemo-worker:${{TIME}}
      command: echo "构建推送 $CICD_IMAGE"
deploy:
  - name: 测试主服务
    branches: [main]
    k8s: 测试环境
    targets:
      - {{build: app, namespace: demo, deployment: cicddemo, container: cicddemo}}
  - name: 测试工作服务
    branches: [main]
    k8s: 测试环境
    targets:
      - {{build: worker, namespace: demo, deployment: cicddemo-worker, container: cicddemo}}
  - name: 正式主服务
    branches: [main]
    k8s: 正式环境
    confirm: true
    targets:
      - {{build: app, namespace: demo, deployment: cicddemo, container: cicddemo}}
  - name: 正式工作服务
    branches: [main]
    k8s: 正式环境
    confirm: true
    targets:
      - {{build: worker, namespace: demo, deployment: cicddemo-worker, container: cicddemo}}

"""


def git(directory, *args):
    return subprocess.check_output(["git", "-c", "core.hooksPath=/dev/null", "-C", str(directory), *args],
                                   env=ENV, stderr=subprocess.PIPE)


def state():
    return tuple(git(SOURCE, *args) for args in [
        ("rev-parse", "HEAD"), ("show-ref",), ("status", "--porcelain=v1", "-z"),
    ])


def kubeconfig(name, token):
    return f"""\
apiVersion: v1
kind: Config
current-context: {name}
contexts: [{{name: {name}, context: {{cluster: {name}, user: {name}, namespace: demo}}}}]
clusters: [{{name: {name}, cluster: {{server: 'https://127.0.0.1:6443'}}}}]
users: [{{name: {name}, user: {{token: {token}}}}}]
"""


def hook_enabled(database):
    if not database.exists():
        return False
    try:
        with sqlite3.connect(f"file:{database}?mode=ro", uri=True, timeout=1) as connection:
            return connection.execute("SELECT COUNT(*) FROM project WHERE hook_mode != 'none'").fetchone()[0] > 0
    except sqlite3.Error:
        return False


def keychain_has(service):
    # 只查条目是否存在，不读取内容。
    return subprocess.run(["security", "find-generic-password", "-s", service], capture_output=True).returncode == 0


def remove_keychain_items(service):
    """测试中途失败时清理这次测试服务名下的条目；正式数据的服务名不同，不受影响。"""
    for _ in range(10):
        if not keychain_has(service):
            return
        subprocess.run(["security", "delete-generic-password", "-s", service], capture_output=True)


signing_identity = resolve_ui_signing(ROOT)
before = state()
(ROOT / ".test-repos").mkdir(exist_ok=True)
work = Path(tempfile.mkdtemp(prefix="cicddemo-ui-", dir=ROOT / ".test-repos")).resolve()
repo, remote, bin_dir, kube = work / "repository", work / "remote.git", work / "bin", work / "kube"
keychain_service = "io.github.loveyu233.cicdlocal.ui-test." + hashlib.sha256(str(work).encode()).hexdigest()[:24]
try:
    subprocess.run(["git", "clone", "--quiet", "--bare", "--no-hardlinks", str(SOURCE), str(remote)],
                   env=ENV, check=True, capture_output=True)
    subprocess.run(["git", "clone", "--quiet", "--no-hardlinks", str(remote), str(repo)],
                   env=ENV, check=True, capture_output=True)
    git(repo, "config", "user.name", "本地界面测试")
    git(repo, "config", "user.email", "test@example.invalid")
    git(repo, "config", "commit.gpgsign", "false")
    (repo / ".git/localcicd-test-source").write_text(str(SOURCE))
    (repo / ".local.cicd.yml").write_text(CONFIG)
    git(repo, "add", "--", ".local.cicd.yml")
    git(repo, "commit", "-q", "-m", "添加本地 CI 配置")
    sha = git(repo, "rev-parse", "HEAD").decode().strip()

    kube.mkdir()
    files = []
    for context, token in zip(["staging", "production"], TOKENS.values()):
        path = kube / f"{context}.yaml"
        path.write_text(kubeconfig(context, token))
        files.append(str(path))
    bin_dir.mkdir()
    # 界面测试只模拟仓库清单，实际双镜像推送另由 test-cicddemo.py 验证。
    fake_docker = bin_dir / "docker"
    fake_docker.write_text("#!/bin/sh\n[ \"$1 $2 $3\" = 'buildx imagetools inspect' ] || exit 1\necho '{\"digest\":\"sha256:" + "a" * 64 + "\"}'\n")
    fake_docker.chmod(0o755)
    kubectl_log = work / "kubectl.log"
    fake = bin_dir / "kubectl"
    # 假 kubectl：记录参数、KUBECONFIG 的权限和其中的令牌名，不访问网络。
    fake.write_text(f"""#!/bin/sh
printf 'argv: %s\\nkubeconfig: %s %s %s\\n' "$*" "$KUBECONFIG" "$(stat -f %Lp "$KUBECONFIG")" "$(grep -o 'ui-test-[a-z]*-token' "$KUBECONFIG")" >> '{kubectl_log}'
{(ROOT / "scripts/fixtures/healthy-kubectl.sh").read_text()}
""")
    fake.chmod(0o755)

    (ROOT / "build").mkdir(exist_ok=True)
    (ROOT / "build/ui-test-fixture.json").write_text(json.dumps(
        {"source": str(SOURCE), "root": str(work), "kubeconfigs": files, "marker": MARKER}, ensure_ascii=False))
    print(f"界面验证目录：{work}", flush=True)
    subprocess.run(["xcodegen", "generate", "--quiet"], cwd=ROOT, env=ENV, check=True)
    result = ROOT / "build" / f"{work.name}.xcresult"
    log = ROOT / "build/ui-test.log"
    database = work / "ui-support/localcicd.sqlite"
    pushed = False
    with log.open("w") as output:
        process = subprocess.Popen(
            ["xcodebuild", "-project", "LocalCICD.xcodeproj", "-scheme", "LocalCICD",
             "-configuration", "Debug", "-destination", "platform=macOS,arch=arm64",
             "-derivedDataPath", "build/DerivedData", "-resultBundlePath", str(result),
             "CODE_SIGN_STYLE=Manual", f"CODE_SIGN_IDENTITY={signing_identity}", "DEVELOPMENT_TEAM=",
             "-only-testing:LocalCICDUITests/AppUITests/testPushToConfirmedDeploy", "test"],
            cwd=ROOT, env=ENV, stdout=output, stderr=subprocess.STDOUT)
        while process.poll() is None:
            if not pushed and hook_enabled(database):
                time.sleep(1)
                # 用仓库里登记的钩子推送到本地裸仓库，和用户在终端执行 git push 一样。
                push = subprocess.run(["git", "-C", str(repo), "push", "origin", "HEAD:main"],
                                      env=ENV, capture_output=True, text=True)
                print(f"git push 退出码 {push.returncode}", flush=True)
                assert push.returncode == 0, push.stderr
                pushed = True
            release = repo / ".git/localcicd-ui-release-app"
            if pushed and not release.exists() and f"LOCALCICD_UI_RELEASE_APP {work.name}" in log.read_text(errors="replace"):
                # UI 已确认后批成功且前构建仍在运行；宿主负责写入隔离副本的同步文件。
                release.touch()
            time.sleep(0.5)
    attachments = work / "ui-attachments"
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
                    "--output-path", str(attachments)], env=ENV, capture_output=True)
    print(f"截图：{attachments}", flush=True)
    if process.returncode != 0:
        raise SystemExit(f"界面测试失败，详见 {log} 和 {result}")
    assert pushed, "App 没有开启推送监听"

    # 结构化结果：七个阶段成功，后一个服务确实在前一个构建完成之前部署完成。
    with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as connection:
        runs = connection.execute("SELECT id, branch, sha, image, status FROM run").fetchall()
        assert len(runs) == 1, runs
        run_id, branch, run_sha, image, status = runs[0]
        assert (branch, run_sha, status) == ("main", sha, "succeeded"), runs
        plan = json.loads(connection.execute("SELECT plan_json FROM run WHERE id = ?", (run_id,)).fetchone()[0])
        assert len(plan["images"]) == 2, plan
        for item in plan["images"]:
            assert re.fullmatch(r"127\.0\.0\.1:5999/cicddemo(?:-worker)?:\d{8}\.\d{6}", item["image"]), item
            assert item["digest"] == "sha256:" + "a" * 64
        stages = connection.execute(
            "SELECT ordinal, kind, status FROM run_stage WHERE run_id = ? ORDER BY ordinal", (run_id,)).fetchall()
        assert stages == [(0, "test", "succeeded"), (1, "build", "succeeded"), (2, "build", "succeeded"),
                          (3, "deploy", "succeeded"), (4, "deploy", "succeeded"),
                          (5, "deploy", "succeeded"), (6, "deploy", "succeeded")], stages
        times = dict(connection.execute("SELECT ordinal, finished_at FROM run_stage WHERE run_id = ?", (run_id,)).fetchall())
        assert times[6] < times[1], "正式工作服务必须在主服务构建放行前完成"
        connections = connection.execute("SELECT name, metadata_json FROM k8s_connection ORDER BY name").fetchall()
        assert connections == [], f"UI 测试最后应已删除连接：{connections}"
    assert not keychain_has(keychain_service), "删除连接后钥匙串里不应还有 kubeconfig"

    # kubectl：各批次独立执行；kubeconfig 只经 0600 临时文件传入，用完删除。
    lines = kubectl_log.read_text().splitlines()
    argv = [line for line in lines if line.startswith("argv:")]
    configs = [line.split(" ") for line in lines if line.startswith("kubeconfig:")]
    expected = []
    for deployment in ["cicddemo", "cicddemo-worker"]:
        reference = "127.0.0.1:5999/" + deployment + "@sha256:" + "a" * 64
        expected.extend([f"argv: set image deployment/{deployment} cicddemo={reference} -n demo",
                         f"argv: rollout status deployment/{deployment} -n demo --timeout=10m"] * 2)
    assert sorted(line for line in argv if line.startswith(("argv: set image", "argv: rollout status"))) == sorted(expected), argv
    assert len(configs) == len(argv) and configs, configs
    for command, (_, _, mode, token) in zip(argv, configs):
        assert mode == "600" and token in TOKENS.values(), (command, mode, token)
    assert not any(Path(path).exists() for _, path, _, _ in configs), "临时 kubeconfig 应已删除"
    assert not any(token in line for line in argv for token in TOKENS.values())
    for path in (work / "ui-support").rglob("*"):
        if path.is_file():
            data = path.read_bytes()
            assert not any(token.encode() in data for token in TOKENS.values()), f"凭据出现在 {path}"
    print(f"界面测试通过：{result}", flush=True)
finally:
    remove_keychain_items(keychain_service)
    if state() != before:
        raise RuntimeError("cicddemo 原仓库状态发生变化，需要检查")
    print("cicddemo 原仓库 HEAD、引用和工作区状态保持不变。", flush=True)
