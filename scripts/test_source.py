"""集中校验人工指定的 cicddemo 测试源，禁止回退到其他项目。"""
import os
from pathlib import Path


def test_source() -> Path:
    value = os.environ.get("LOCALCICD_TEST_SOURCE", "")
    if not value or not Path(value).is_absolute():
        raise SystemExit("请用 LOCALCICD_TEST_SOURCE 指定已获授权的 cicddemo 仓库绝对路径。")
    source = Path(value).resolve()
    if source.name != "cicddemo" or not (source / ".git").exists():
        raise SystemExit("流程测试源必须是已获授权的 cicddemo Git 仓库，不能使用其他项目。")
    # 子进程用同一规范路径校验副本来源；脚本只在 .test-repos 中写入和推送。
    os.environ["LOCALCICD_TEST_SOURCE"] = str(source)
    return source
