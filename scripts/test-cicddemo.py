#!/usr/bin/env python3
"""cicddemo 真实验收：在隔离副本上用本机登录 shell 真实执行 go vet / go test 和 docker build / push。

镜像推到本脚本临时启动、只监听 127.0.0.1 的 registry:2，替换阶段用假 kubectl 和假 kubeconfig，
不推送真实镜像仓库，不连接任何 k8s 集群。结束后删除本次的容器和镜像标签，并确认 cicddemo 原仓库没有变化。
"""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.request

from test_source import test_source

ROOT = Path(__file__).resolve().parent.parent
SOURCE = test_source()
ENV = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
ENV.update(GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0")
TOKEN = "accept-staging-token"


def config(registry):
    return f"""\
test:
  - go vet ./...
  - go test ./...
  - docker info --format '本机 docker：{{{{.Name}}}}'
build:
  parallel: 2
  images:
    - name: app
      image: {registry}/cicddemo:${{TIME}}
      dockerfile: Dockerfile
    - name: worker
      image: {registry}/cicddemo-worker:${{TIME}}
      dockerfile: Dockerfile
deploy:
  - name: 测试发布
    branches: [main]
    k8s: 测试环境
    parallel: 2
    targets:
      - {{build: app, namespace: demo, deployment: cicddemo, container: cicddemo}}
      - {{build: worker, namespace: demo, deployment: cicddemo-worker, container: cicddemo}}

"""


def git(directory, *args):
    return subprocess.check_output(["git", "-c", "core.hooksPath=/dev/null", "-C", str(directory), *args],
                                   env=ENV, stderr=subprocess.PIPE)


def state():
    return tuple(git(SOURCE, *args) for args in [
        ("rev-parse", "HEAD"), ("show-ref",), ("status", "--porcelain=v1", "-z"),
    ])


def docker(*args, check=True):
    return subprocess.run(["docker", *args], env=ENV, check=check, capture_output=True, text=True).stdout.strip()


before = state()
(ROOT / ".test-repos").mkdir(exist_ok=True)
work = Path(tempfile.mkdtemp(prefix="cicddemo-accept-", dir=ROOT / ".test-repos")).resolve()
repo, remote, bin_dir, kube = work / "repository", work / "remote.git", work / "bin", work / "kube"
container = f"localcicd-{work.name}"
images = []
try:
    docker("run", "-d", "--rm", "--name", container, "-p", "127.0.0.1::5000", "registry:2")
    port = docker("port", container, "5000/tcp").splitlines()[0].rsplit(":", 1)[1]
    registry = f"127.0.0.1:{port}"
    print(f"临时镜像仓库：{registry}（容器 {container}）", flush=True)

    subprocess.run(["git", "clone", "--quiet", "--bare", "--no-hardlinks", str(SOURCE), str(remote)],
                   env=ENV, check=True, capture_output=True)
    subprocess.run(["git", "clone", "--quiet", "--no-hardlinks", str(remote), str(repo)],
                   env=ENV, check=True, capture_output=True)
    git(repo, "config", "user.name", "本地验收")
    git(repo, "config", "user.email", "test@example.invalid")
    git(repo, "config", "commit.gpgsign", "false")
    (repo / ".git/localcicd-test-source").write_text(str(SOURCE))
    (repo / ".local.cicd.yml").write_text(config(registry))
    git(repo, "add", "--", ".local.cicd.yml")
    git(repo, "commit", "-q", "-m", "改用新的本地 CI 配置")
    # 推到本地裸仓库，模拟日常 git push；推送事件由验收测试直接交给编排层。
    git(repo, "push", "-q", "origin", "HEAD:main")
    sha = git(repo, "rev-parse", "HEAD").decode().strip()
    (work / "pushed-sha").write_text(sha)

    kube.mkdir()
    (kube / "staging.yaml").write_text(f"""\
apiVersion: v1
kind: Config
current-context: staging
contexts: [{{name: staging, context: {{cluster: staging, user: staging, namespace: demo}}}}]
clusters: [{{name: staging, cluster: {{server: 'https://127.0.0.1:6443'}}}}]
users: [{{name: staging, user: {{token: {TOKEN}}}}}]
""")
    bin_dir.mkdir()
    kubectl_log = work / "kubectl.log"
    fake = bin_dir / "kubectl"
    fake.write_text(f"""#!/bin/sh
printf 'argv: %s\\nkubeconfig: %s %s %s\\n' "$*" "$KUBECONFIG" "$(stat -f %Lp "$KUBECONFIG")" "$(grep -c '{TOKEN}' "$KUBECONFIG")" >> '{kubectl_log}'
{(ROOT / "scripts/fixtures/healthy-kubectl.sh").read_text()}
""")
    fake.chmod(0o755)

    print(f"验收目录：{work}", flush=True)
    subprocess.run([str(ROOT / "scripts/test-packages.sh"), "ApplicationKit"], cwd=ROOT, check=True,
                   env=dict(ENV, LOCALCICD_CICDDEMO_ROOT=str(work)))

    result = json.loads((work / "result.json").read_text())
    images = [item["image"] for item in result["images"]]
    assert result["status"] == "succeeded" and result["sha"] == sha, result
    assert [(s["ordinal"], s["kind"], s["status"]) for s in result["stages"]] == [
        (0, "test", "succeeded"), (1, "build", "succeeded"), (2, "build", "succeeded"),
        (3, "deploy", "succeeded"), (4, "deploy", "succeeded")], result["stages"]
    test_log = result["logs"][0]
    for text in ["$ go vet ./...", "$ go test ./...", "本机 docker："]:
        assert text in test_log, f"测试阶段日志缺少：{text}"
    for index, item in enumerate(result["images"]):
        image, reference = item["image"], item["reference"]
        repository_name = ["cicddemo", "cicddemo-worker"][index]
        match = re.fullmatch(re.escape(registry + "/" + repository_name) + r":(\d{8}\.\d{6})", image)
        assert match, image
        tag = match.group(1)
        build_log, deploy_log = result["logs"][index + 1], result["logs"][index + 3]
        assert f"docker build -f Dockerfile -t {image} ." in build_log and f"docker push {image}" in build_log, build_log
        assert "测试环境" in deploy_log and TOKEN not in deploy_log
        assert reference in deploy_log and "60 秒内没有重启" in deploy_log, deploy_log
        with urllib.request.urlopen(f"http://{registry}/v2/{repository_name}/tags/list", timeout=10) as response:
            assert json.load(response)["tags"] == [tag]
        request = urllib.request.Request(f"http://{registry}/v2/{repository_name}/manifests/{tag}",
            headers={"Accept": "application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json"})
        with urllib.request.urlopen(request, timeout=10) as response:
            assert response.headers["Docker-Content-Digest"] == item["digest"]

    lines = kubectl_log.read_text().splitlines()
    argv = [line for line in lines if line.startswith("argv:")]
    configs = [line.split(" ") for line in lines if line.startswith("kubeconfig:")]
    for index, item in enumerate(result["images"]):
        deployment = ["cicddemo", "cicddemo-worker"][index]
        assert f"argv: set image deployment/{deployment} cicddemo={item['reference']} -n demo" in argv
        assert f"argv: rollout status deployment/{deployment} -n demo --timeout=10m" in argv
        assert f"argv: get replicasets -n demo -o json -l app={deployment}" in argv
        assert f"argv: get pods -n demo -o json -l app={deployment}" in argv
    assert configs and all((mode, count) == ("600", "1") for _, _, mode, count in configs), configs
    assert not any(Path(path).exists() for _, path, _, _ in configs), "临时 kubeconfig 应已删除"
    for path in (work / "support").rglob("*"):
        if path.is_file():
            assert TOKEN.encode() not in path.read_bytes(), f"凭据出现在 {path}"
    print(f"验收通过：两个镜像已推送并核对仓库 digest，两个模拟目标完成 60 秒健康观察。镜像：{images}", flush=True)
finally:
    # 只清理本次创建的容器和镜像标签。
    docker("rm", "-f", container, check=False)
    for image in images:
        docker("rmi", image, check=False)
    if state() != before:
        raise RuntimeError("cicddemo 原仓库状态发生变化，需要检查")
    print("cicddemo 原仓库 HEAD、引用和工作区状态保持不变。", flush=True)
