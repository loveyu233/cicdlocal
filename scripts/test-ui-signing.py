#!/usr/bin/env python3
"""验证测试签名选择稳定，证书变化时不会静默重置应用身份。"""
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from ui_signing import resolve_ui_signing


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.output = '1) ' + 'A' * 40 + ' "Apple Development: 测试身份"\n'
        self.environment = patch.dict(os.environ, {}, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def resolve(self, output=None):
        with patch('ui_signing.subprocess.check_output', return_value=output or self.output), redirect_stdout(io.StringIO()):
            return resolve_ui_signing(self.root)

    def test_remembers_identity_when_another_certificate_appears(self):
        self.assertEqual(self.resolve(), 'A' * 40)
        multiple = self.output + '2) ' + 'B' * 40 + ' "Apple Development: 第二身份"\n'
        self.assertEqual(self.resolve(multiple), 'A' * 40)

    def test_missing_remembered_identity_does_not_fall_back(self):
        self.resolve()
        with self.assertRaises(RuntimeError):
            self.resolve('0 valid identities found')

    def test_ambiguous_identity_requires_explicit_selection(self):
        multiple = self.output + '2) ' + 'B' * 40 + ' "Apple Development: 第二身份"\n'
        with self.assertRaises(RuntimeError):
            self.resolve(multiple)
        os.environ['LOCALCICD_UI_SIGNING_IDENTITY'] = 'Apple Development: 第二身份'
        self.assertEqual(self.resolve(multiple), 'B' * 40)

    def test_temporary_override_preserves_remembered_identity(self):
        self.resolve()
        os.environ['LOCALCICD_UI_SIGNING_IDENTITY'] = '-'
        self.assertEqual(self.resolve(), '-')
        stored = json.loads((self.root / 'build/ui-signing-identity.json').read_text())
        self.assertEqual(stored['fingerprint'], 'A' * 40)


if __name__ == '__main__':
    unittest.main()
