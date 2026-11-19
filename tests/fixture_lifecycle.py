"""Owned test roots: release passing fixtures, retain diagnostic failures."""

import argparse
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import unittest


def require_cleanup_support():
    """Refuse deletion unless every descriptor-relative operation is available."""
    if sys.version_info < (3, 9):
        raise RuntimeError("test fixtures require Python 3.9 or newer")
    if (not {os.open, os.stat, os.unlink, os.rmdir} <= os.supports_dir_fd
            or os.scandir not in os.supports_fd
            or os.stat not in os.supports_follow_symlinks
            or not all(hasattr(os, flag) for flag in ("O_DIRECTORY", "O_NOFOLLOW"))):
        raise RuntimeError("fixture cleanup requires descriptor-relative filesystem support")


def remove_contents(directory_fd):
    """Walk held directories only; unlink symlinks without visiting their targets."""
    with os.scandir(directory_fd) as entries:
        for entry in entries:
            if not entry.is_dir(follow_symlinks=False):
                os.unlink(entry.name, dir_fd=directory_fd)
                continue
            expected = entry.stat(follow_symlinks=False)
            child_fd = os.open(entry.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                               dir_fd=directory_fd)
            try:
                held = os.fstat(child_fd)
                if (held.st_dev, held.st_ino) != (expected.st_dev, expected.st_ino):
                    raise RuntimeError("fixture child directory was replaced")
                remove_contents(child_fd)
                current = os.stat(entry.name, dir_fd=directory_fd, follow_symlinks=False)
                if (current.st_dev, current.st_ino) != (held.st_dev, held.st_ino):
                    raise RuntimeError("fixture child directory was replaced")
                os.rmdir(entry.name, dir_fd=directory_fd)
            finally:
                os.close(child_fd)


class Fixture:
    """One invocation owns these open directory identities, never a path receipt."""

    def __init__(self, prefix="envmaker-fixture."):
        if not prefix or any(c not in "abcdefghijklmnopqrstuvwxyz0123456789-_." for c in prefix):
            raise ValueError("invalid fixture prefix")
        parent = Path(os.environ.get("TMPDIR") or tempfile.gettempdir()).resolve(strict=True)
        self.parent = parent
        self.name = tempfile.mkdtemp(prefix=prefix, dir=parent)
        self.root = Path(self.name)
        try:
            require_cleanup_support()
        except RuntimeError:
            print("Fixtures retained: " + self.name, file=sys.stderr)
            raise
        self.parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        self.root_fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        self.identity = os.fstat(self.root_fd)
        self.owner = os.getpid()
        self.closed = False

    def validate(self):
        if self.closed or os.getpid() != self.owner:
            raise RuntimeError("fixture cleanup is restricted to its allocating process")
        if self.root.parent != self.parent or self.root == self.parent or not self.root.is_absolute():
            raise RuntimeError("unexpected fixture root")
        # No ancestor may have become a symlink or a replacement directory.
        if self.parent.resolve(strict=True) != self.parent:
            raise RuntimeError("fixture parent was redirected")
        parent_stat = self.parent.stat()
        held_parent = os.fstat(self.parent_fd)
        if (parent_stat.st_dev, parent_stat.st_ino) != (held_parent.st_dev, held_parent.st_ino):
            raise RuntimeError("fixture parent was replaced")
        current = os.stat(self.root.name, dir_fd=self.parent_fd, follow_symlinks=False)
        if (not stat.S_ISDIR(current.st_mode) or current.st_uid != os.getuid()
                or (current.st_dev, current.st_ino) != (self.identity.st_dev, self.identity.st_ino)):
            raise RuntimeError("fixture root was replaced or is not owned")

    def cleanup(self, dry_run=False):
        require_cleanup_support()
        self.validate()
        if dry_run:
            print("Would remove fixture: " + self.name, file=sys.stderr)
            return
        remove_contents(self.root_fd)
        self.validate()
        os.rmdir(self.root.name, dir_fd=self.parent_fd)

    def finish(self, result=0, dry_run=False):
        if self.closed:
            return result
        try:
            if result == 0:
                self.cleanup(dry_run=dry_run)
        except (OSError, RuntimeError) as error:
            print("Fixture cleanup refused/failed: " + str(error), file=sys.stderr)
            result = 1
        finally:
            if result != 0 or dry_run:
                print("Fixtures retained: " + self.name, file=sys.stderr)
            os.close(self.root_fd)
            os.close(self.parent_fd)
            self.closed = True
        return result

    def __enter__(self):
        return self.name

    def __exit__(self, exception_type, exception, traceback):
        result = self.finish(1 if exception_type else 0)
        if result and not exception_type:
            raise RuntimeError("fixture cleanup failed")


class FixtureTestCase(unittest.TestCase):
    """Retain roots on assertions, setup/teardown errors and unexpected success."""

    def run(self, result=None):
        result = result if result is not None else self.defaultTestResult()
        before = len(result.failures) + len(result.errors) + len(result.unexpectedSuccesses)
        self.scratch = Fixture(prefix="envmaker-python.")
        try:
            super().run(result)
        except BaseException:
            self.scratch.finish(1)
            raise
        failed = len(result.failures) + len(result.errors) + len(result.unexpectedSuccesses) != before
        if self.scratch.finish(int(failed)) and not failed:
            try:
                raise RuntimeError("fixture cleanup failed")
            except RuntimeError:
                result.addError(self, sys.exc_info())
        return result


def suite_root(prefix, command=None):
    """Re-execute a suite under its owner; nested suites get separate owners."""
    if os.environ.get("DFT_FIXTURE_OWNER") == str(os.getppid()):
        return os.environ["DFT_FIXTURE_ROOT"]
    # Use the same flag reconstruction as multiprocessing's Python children.
    # Both the owner and the suite must retain isolation (-I/-E/-s), not just -B.
    interpreter = [sys.executable, *subprocess._args_from_interpreter_flags(), "-B"]
    if command is None:
        command = [*interpreter, str(Path(sys.argv[0]).resolve()), *sys.argv[1:]]
    os.execv(sys.executable, [*interpreter, __file__, "--prefix", prefix, "--", *command])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", default="envmaker-fixture.")
    parser.add_argument("-n", "--dry-run", action="store_true", help="validate and name the owned root without deleting it")
    parser.add_argument("command", nargs=argparse.REMAINDER, help="suite command after --")
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a suite command is required")
    fixture = Fixture(prefix=args.prefix)
    child = None
    received = 0

    def interrupted(number, _frame):
        nonlocal received
        received = number
        if child is not None:
            try:
                os.killpg(child.pid, number)
            except ProcessLookupError:
                pass

    previous = {s: signal.signal(s, interrupted) for s in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)}
    result = 1
    try:
        temporary = fixture.root / "tmp"
        temporary.mkdir()
        environment = dict(os.environ, TMPDIR=str(temporary), DFT_FIXTURE_ROOT=fixture.name,
                           DFT_FIXTURE_OWNER=str(os.getpid()), PYTHONDONTWRITEBYTECODE="1")
        environment.pop("BASH_ENV", None)
        environment.pop("ENV", None)
        # Deterministic negative controls for every suite entry point.
        fault = environment.pop("DFT_FIXTURE_FAULT", "")
        if fault == "early":
            result = 23
        else:
            child = subprocess.Popen(command, env=environment, start_new_session=True)
            if received:
                interrupted(received, None)
            result = child.wait()
            result = 128 - result if result < 0 else result
            if fault == "assertion" and result == 0:
                print("ASSERTION FAILED: forced fixture lifecycle failure", file=sys.stderr)
                result = 1
        if received:
            result = 128 + received
    except BaseException:
        fixture.finish(1)
        raise
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)
    return fixture.finish(result, dry_run=args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
