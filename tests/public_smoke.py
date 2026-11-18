"""Isolated README/prerequisite smoke; never install tools or use real HOME."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PublicSmoke(unittest.TestCase):
    def test_readme_prerequisite_legacy_migration_and_stack(self):
        with tempfile.TemporaryDirectory(prefix="envmaker-public-smoke.") as scratch:
            base = Path(scratch)
            home = base / "home"
            home.mkdir()
            environment = {
                "HOME": str(home), "TERM": "dumb", "PATH": os.environ["PATH"],
                "XDG_CONFIG_HOME": str(home / ".config"),
                "XDG_STATE_HOME": str(home / ".local/state"),
                "XDG_CACHE_HOME": str(home / ".cache"),
                "XDG_DATA_HOME": str(home / ".local/share"),
                "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
            }

            def run(*args):
                result = subprocess.run(args, cwd=ROOT, env=environment, capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
                return result.stdout

            def envmaker(*args):
                return run("bash", str(ROOT / "envmaker.sh"), *map(str, args))

            run("/opt/stow-2.4.1/bin/stow", "--version")
            self.assertIn(b'"version":"2.4.1"', run("perl", "bin/stow_probe.pl", "/opt/stow-2.4.1/bin/stow", "2.4.1"))
            generic, personal = base / "generic", base / "personal space"
            for source in (generic, personal):
                envmaker("init", source)
                (source / "common/example/.config/example").mkdir(parents=True)
            lower = generic / "common/example/.config/example/config"
            upper = personal / "common/example/.config/example/config"
            lower.write_text("generic\n")
            upper.write_text("personal\n")
            target = home / ".config/example/config"
            legacy = ["--dotfiles-dir", generic, "--yes"]
            envmaker(*legacy, "listdirs")
            envmaker(*legacy, "--dry-run", "execstow", "stow")
            self.assertFalse(target.exists())
            envmaker(*legacy, "execstow", "stow")
            self.assertTrue(target.is_symlink())
            self.assertEqual(target.read_text(), "generic\n")
            envmaker(*legacy, "execstow", "restow")
            stack = ["--source", "generic=" + str(generic), "--source", "personal=" + str(personal)]
            envmaker(*stack, "--dry-run", "migrate", "--from", "generic")
            envmaker(*stack, "--yes", "migrate", "--from", "generic")
            self.assertEqual(target.read_text(), "personal\n")
            envmaker(*stack, "explain", ".config/example/config")
            envmaker(*stack, "ls")
            unchanged = os.readlink(target)
            envmaker(*stack, "execstow", "restow")
            self.assertEqual(os.readlink(target), unchanged)
            upper.rename(upper.with_name("saved-upper"))
            envmaker(*stack, "execstow", "restow")
            self.assertEqual(target.read_text(), "generic\n")
            envmaker(*stack, "--yes", "--dry-run", "execstow", "delete")
            self.assertTrue(target.is_symlink())
            envmaker(*stack, "--yes", "execstow", "delete")
            self.assertFalse(target.is_symlink())
            self.assertEqual(lower.read_text(), "generic\n")
            # Source selection and all generated state stay in this fixture.
            self.assertTrue((home / ".local/state/dotfiletracker").is_dir())


if __name__ == "__main__":
    unittest.main()
