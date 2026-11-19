"""Negative controls for owned test roots; all probes stay below this suite."""

import contextlib
import io
import itertools
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
# Resolve this trusted sibling explicitly, including under Python isolated mode.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from fixture_lifecycle import Fixture, FixtureTestCase, require_cleanup_support, suite_root

HERE = Path(__file__).resolve().parent


class LifecycleTests(FixtureTestCase):
    def setUp(self):
        self.base = Path(self.scratch.name)
        self.parent = self.base / "temporary parent with spaces"
        self.parent.mkdir()
        self.sentinel = self.base / "outside"
        self.sentinel.mkdir()
        (self.sentinel / "keep").write_text("sentinel")
        self.environment = dict(os.environ, TMPDIR=str(self.parent), SENTINEL=str(self.sentinel))

    def allocate(self):
        with patch.dict(os.environ, self.environment):
            return Fixture()

    def probe(self, source, *, dry_run=False, fault=None):
        script = self.base / "probe.sh"
        script.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + source + "\n")
        environment = dict(self.environment)
        if fault:
            environment["DFT_FIXTURE_FAULT"] = fault
        arguments = [sys.executable, "-B", str(HERE / "fixture_lifecycle.py")]
        if dry_run:
            arguments.append("--dry-run")
        arguments += ["--", "bash", str(script)]
        return subprocess.run(arguments, env=environment, capture_output=True, timeout=15)

    def retained(self, result, expected):
        self.assertEqual(result.returncode, expected, result.stderr.decode())
        lines = [line.removeprefix("Fixtures retained: ") for line in result.stderr.decode().splitlines()
                 if line.startswith("Fixtures retained: ")]
        self.assertTrue(lines)
        for line in lines:
            self.assertTrue(Path(line).is_dir())
        self.assertEqual((self.sentinel / "keep").read_text(), "sentinel")
        return Path(lines[-1])

    def test_success_spaces_symlinks_nested_files_and_expected_failure(self):
        result = self.probe('''
ln -s "$SENTINEL" "$DFT_FIXTURE_ROOT/outside-link"
[[ -f "$DFT_FIXTURE_ROOT/outside-link/keep" ]]
mktemp > "$DFT_FIXTURE_ROOT/temporary-name"
bash <<'INNER'
set -euo pipefail
mktemp > "$DFT_FIXTURE_ROOT/nested-name"
if false; then exit 99; fi
INNER
[[ -d "$DFT_FIXTURE_ROOT" ]]
''')
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(list(self.parent.iterdir()), [])
        self.assertEqual((self.sentinel / "keep").read_text(), "sentinel")

    def test_assertion_early_command_failure_and_all_catchable_signals(self):
        for source, expected in [('echo "ASSERTION FAILED" >&2; exit 7', 7), ('false', 1),
                                 ('exit 23', 23), ('kill -HUP $$', 129),
                                 ('kill -INT $$', 130), ('kill -TERM $$', 143)]:
            with self.subTest(source=source):
                self.retained(self.probe(source), expected)

    def test_runner_catchable_signals_forward_to_owned_child(self):
        for name, number in [('HUP', signal.SIGHUP), ('INT', signal.SIGINT), ('TERM', signal.SIGTERM)]:
            with self.subTest(signal=name):
                self.retained(self.probe('kill -' + name + ' "$PPID"\nsleep 1'), 128 + number)

    def test_dry_run_is_inspection_only(self):
        result = self.probe('printf evidence > "$DFT_FIXTURE_ROOT/evidence"', dry_run=True)
        root = self.retained(result, 0)
        self.assertIn(b"Would remove fixture: ", result.stderr)
        self.assertEqual((root / "evidence").read_text(), "evidence")

    def test_suite_reexecution_preserves_interpreter_flags(self):
        script = self.base / "flags.py"
        script.write_text(
            "import json, os, sys\n"
            "sys.dont_write_bytecode = True\n"
            f"sys.path.insert(0, {str(HERE)!r})\n"
            "from fixture_lifecycle import suite_root\n"
            "suite_root('envmaker-flags.')\n"
            "assert sys.argv[1:] == ['payload']\n"
            "print(json.dumps([sys.flags.isolated, sys.flags.ignore_environment,\n"
            "                  sys.flags.no_user_site, sys.flags.dont_write_bytecode]))\n")
        for isolated, ignore, no_site in itertools.product((False, True), repeat=3):
            flags = (["-I"] if isolated else []) + (["-E"] if ignore else []) + (["-s"] if no_site else [])
            with self.subTest(flags=flags):
                result = subprocess.run([sys.executable, *flags, str(script), "payload"],
                                        env=self.environment, capture_output=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                self.assertEqual(json.loads(result.stdout),
                                 [int(isolated), int(isolated or ignore), int(isolated or no_site), 1])
        # Verify the owner's argv as well as the real suite child's flags above.
        fixture_os = SimpleNamespace(**vars(os))
        with patch.dict(os.environ, {"DFT_FIXTURE_OWNER": "invalid"}), \
                patch("fixture_lifecycle.os", fixture_os), patch.object(fixture_os, "execv") as execute:
            suite_root("envmaker-flags.")
        arguments = execute.call_args.args[1]
        owner_flags = arguments[1:arguments.index(str(HERE / "fixture_lifecycle.py"))]
        child_start = arguments.index("--") + 1
        self.assertEqual(arguments[child_start + 1:child_start + 1 + len(owner_flags)], owner_flags)
        self.assertEqual(list(self.parent.iterdir()), [])

    def test_replaced_root_directory_and_symlink_are_refused(self):
        for symlink in (False, True):
            with self.subTest(symlink=symlink):
                fixture = self.allocate()
                original = fixture.root
                original.rename(original.with_name(original.name + ".saved"))
                if symlink:
                    original.symlink_to(self.sentinel, target_is_directory=True)
                else:
                    original.mkdir()
                    (original / "keep").write_text("replacement")
                with contextlib.redirect_stderr(io.StringIO()) as messages:
                    self.assertEqual(fixture.finish(), 1)
                self.assertIn("replaced", messages.getvalue())
                self.assertTrue(original.exists())
                self.assertEqual((self.sentinel / "keep").read_text(), "sentinel")

    def test_unexpected_empty_and_non_owned_targets_are_refused(self):
        for target in (Path(""), self.sentinel):
            fixture = self.allocate()
            fixture.root = target
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(fixture.finish(), 1)
        fixture = self.allocate()
        fixture.owner = -1
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(fixture.finish(), 1)
        fixture = self.allocate()
        # Simulate a non-owned root without changing host ownership.
        fixture_os = SimpleNamespace(**vars(os))
        fixture_os.getuid = lambda: -1
        with patch("fixture_lifecycle.os", fixture_os), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(fixture.finish(), 1)
        self.assertEqual((self.sentinel / "keep").read_text(), "sentinel")

    def test_parent_redirection_and_replacement_are_refused(self):
        for symlink in (False, True):
            fixture = self.allocate()
            saved = self.parent.with_name(self.parent.name + ".saved-" + str(symlink))
            self.parent.rename(saved)
            if symlink:
                self.parent.symlink_to(saved, target_is_directory=True)
            else:
                self.parent.mkdir()
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(fixture.finish(), 1)
            # A fresh parent for the next probe; all old trees stay owned by this suite.
            self.parent = self.base / "next parent"
            self.parent.mkdir(exist_ok=True)
            self.environment["TMPDIR"] = str(self.parent)

    def test_cleanup_error_is_visible_and_changes_success_status(self):
        fixture = self.allocate()
        with patch("fixture_lifecycle.remove_contents") as remove, \
                contextlib.redirect_stderr(io.StringIO()) as messages:
            remove.side_effect = PermissionError("forced cleanup failure")
            self.assertEqual(fixture.finish(), 1)
        self.assertTrue(fixture.root.is_dir())
        self.assertIn("forced cleanup failure", messages.getvalue())
        self.assertIn("Fixtures retained: ", messages.getvalue())
        # An original error status never goes through cleanup or becomes success.
        fixture = self.allocate()
        with patch("fixture_lifecycle.remove_contents") as remove, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(fixture.finish(23), 23)
            remove.assert_not_called()

    def test_unsupported_cleanup_retains_root_without_deleting(self):
        cases = [("sys", "version_info", (3, 8)),
                 ("os", "supports_dir_fd", set()),
                 ("os", "supports_fd", set()),
                 ("os", "supports_follow_symlinks", set())]
        cases += [("os", "supports_dir_fd", os.supports_dir_fd - {operation})
                  for operation in (os.open, os.stat, os.unlink, os.rmdir)]
        for module, attribute, value in cases:
            with self.subTest(module=module, attribute=attribute):
                fixture = self.allocate()
                evidence = fixture.root / "keep"
                evidence.write_text("retained")
                messages = io.StringIO()
                dependency = SimpleNamespace(**vars(sys if module == "sys" else os))
                setattr(dependency, attribute, value)
                if module == "sys":
                    dependency.stderr = messages
                with patch("fixture_lifecycle." + module, dependency), \
                        patch("fixture_lifecycle.remove_contents") as remove, \
                        contextlib.redirect_stderr(messages):
                    self.assertEqual(fixture.finish(), 1)
                    remove.assert_not_called()
                    # The same guard refuses a new suite before executing it.
                    with self.assertRaises(RuntimeError):
                        self.allocate()
                self.assertEqual(evidence.read_text(), "retained")
                paths = [line.removeprefix("Fixtures retained: ") for line in messages.getvalue().splitlines()
                         if line.startswith("Fixtures retained: ")]
                self.assertEqual(len(paths), 2)
                self.assertEqual(paths[0], fixture.name)
                self.assertTrue(all(Path(name).is_absolute() and Path(name).is_dir() for name in paths))

    def test_python39_deep_tree_and_directory_symlinks(self):
        # Simulate the minimum version while using only APIs present in 3.9.
        with patch("fixture_lifecycle.sys", wraps=sys) as interpreter:
            interpreter.version_info = (3, 9)
            fixture = self.allocate()
            directory = fixture.root
            for _ in range(96):
                directory = directory / "deep"
                directory.mkdir()
                (directory / "payload").write_text("temporary")
            (directory / "external").symlink_to(self.sentinel, target_is_directory=True)
            (directory / "internal").symlink_to(fixture.root, target_is_directory=True)
            (directory / "broken").symlink_to("absent")
            self.assertEqual(fixture.finish(), 0)
        self.assertFalse(fixture.root.exists())
        self.assertEqual((self.sentinel / "keep").read_text(), "sentinel")

    def test_cleanup_capability_combinations(self):
        operations = (os.open, os.stat, os.unlink, os.rmdir)
        for version, mask, scandir, nofollow in itertools.product(((3, 8), (3, 9)), range(16), (False, True), (False, True)):
            supported = version >= (3, 9) and mask == 15 and scandir and nofollow
            platform = SimpleNamespace(**vars(os))
            platform.supports_dir_fd = {op for index, op in enumerate(operations) if mask & (1 << index)}
            platform.supports_fd = {os.scandir} if scandir else set()
            platform.supports_follow_symlinks = {os.stat} if nofollow else set()
            interpreter = SimpleNamespace(**vars(sys))
            interpreter.version_info = version
            with self.subTest(version=version, mask=mask, scandir=scandir, nofollow=nofollow), \
                    patch("fixture_lifecycle.os", platform), patch("fixture_lifecycle.sys", interpreter):
                if supported:
                    require_cleanup_support()
                else:
                    with self.assertRaises(RuntimeError):
                        require_cleanup_support()

    def test_bash_bootstrap_nested_suite_ownership(self):
        nested = self.base / "nested.sh"
        nested.write_text('set -euo pipefail\nsource "$1/fixture_lifecycle.sh"\nfixture_suite nested. "$@"\n'
                          '[[ -d "$TEST_ROOT" ]]\nprintf "%s\\n" "$TEST_ROOT"\n')
        result = self.probe('source "' + str(HERE) + '/fixture_lifecycle.sh"\n'
                            'fixture_suite outer.\n'
                            'parent=$TEST_ROOT\n'
                            'child=$(bash "' + str(nested) + '" "' + str(HERE) + '")\n'
                            '[[ ! -e "$child" && -d "$parent" ]]')
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(list(self.parent.iterdir()), [])

    def test_unittest_assertion_setup_and_teardown_failures_retain(self):
        for phase in ("assertion", "setup", "teardown", "pass"):
            class Probe(FixtureTestCase):
                def setUp(self):
                    if phase == "setup":
                        raise RuntimeError("early failure")
                def test_probe(self):
                    self.assertNotEqual(phase, "assertion")
                def tearDown(self):
                    if phase == "teardown":
                        raise RuntimeError("late failure")
            with patch.dict(os.environ, self.environment), contextlib.redirect_stderr(io.StringIO()) as messages:
                result = unittest.TestResult()
                probe = Probe("test_probe")
                probe.run(result)
            self.assertEqual(result.wasSuccessful(), phase == "pass")
            self.assertEqual(Path(probe.scratch.name).exists(), phase != "pass")
            self.assertEqual("Fixtures retained:" in messages.getvalue(), phase != "pass")


if __name__ == "__main__":
    suite_root("envmaker-lifecycle.")
    unittest.main()
