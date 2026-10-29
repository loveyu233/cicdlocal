#!/usr/bin/env python3
"""用人工样例验证公开源码检查与测试源边界，不访问业务仓库。"""
import os
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch
from test_source import test_source

check = runpy.run_path(str(Path(__file__).with_name("check-public-source.py")))["violations"]


class SourceGuardTests(unittest.TestCase):
    def test_rejects_private_files_and_paths(self):
        for name in [".env.production", "dump.sqlite-wal", "secret.key", "build/report.txt", ".test-repos/data.txt"]:
            self.assertTrue(check(name, b"test"), name)
        private_path = os.path.join("/", "Users", "example", "project")
        self.assertTrue(check("README.md", private_path.encode()))

    def test_accepts_public_urls_and_rejects_unknown_hosts(self):
        self.assertFalse(check("README.md", b"https://github.com/loveyu233/cicdlocal https://cluster.example.invalid"))
        self.assertTrue(check("README.md", b"https://" + b"internal.company.test"))
        self.assertFalse(check("test.py", b'url = f"http://{registry}/v2/"'))
        self.assertFalse(check("test.swift", b'"https://["'))

    def test_rejects_unreviewed_binary(self):
        self.assertTrue(check("snapshot.bin", b"\0data"))
        icon = b"\x89PNG\r\n\x1a\n" + b"\0\0\0\0eXIf\0\0\0\0"
        self.assertTrue(check("App/Resources/Assets.xcassets/icon.png", icon))

    def test_source_requires_explicit_authorization(self):
        with patch.dict(os.environ, {}, clear=True), self.assertRaises(SystemExit):
            test_source()
        with tempfile.TemporaryDirectory() as directory:
            other = Path(directory) / "other"
            other.mkdir()
            (other / ".git").mkdir()
            with patch.dict(os.environ, {"LOCALCICD_TEST_SOURCE": str(other)}), self.assertRaises(SystemExit):
                test_source()

    def test_source_is_normalized_and_forwarded(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "cicddemo"
            source.mkdir()
            (source / ".git").mkdir()
            with patch.dict(os.environ, {"LOCALCICD_TEST_SOURCE": str(source)}):
                self.assertEqual(test_source(), source.resolve())
                self.assertEqual(os.environ["LOCALCICD_TEST_SOURCE"], str(source.resolve()))


if __name__ == "__main__":
    unittest.main()
