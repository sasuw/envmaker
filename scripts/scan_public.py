"""Fail-closed public filename/content and secret gates; never print matched text."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile

# Gitleaks 8.16.0's default global path allowlist (case-insensitively
# over-rejected here), plus its filesystem walker's nested Git exclusion.
# Unsupported paths fail the gate rather than silently bypass secret checks.
SECRET_SKIPPED_PATHS = re.compile(
    r"gitleaks.toml|(.*?)(jpg|gif|doc|docx|zip|xls|pdf|bin|svg|socket)$|"
    r"(go.mod|go.sum)$|node_modules|package-lock.json|vendor", re.IGNORECASE
)
SECRET_CONFIG = b'title = "Public tree secret gate"\n\n[extend]\nuseDefault = true\n'
# This retained, extensionless rule ends in a default-allowlisted suffix.
# Its bytes get a separate stdin scan, with findings mapped back to its path.
PIPE_SCANNED_FILES = ()

GITLEAKS_VERSION = "8.16.0"
GITLEAKS_MODULE = "github.com/zricethezav/gitleaks/v8"
# Ubuntu's package omits the version string. Accept only the reviewed binary.
GITLEAKS_PACKAGE_SHA256 = "805ff18613b1bfbd8067f1f578d9ce60fd6e3e76eac6927c4184a39e797fb2d6"


def fail(message):
    raise ValueError(message)


def walk_error(error):
    raise error


def secret_path_is_skipped(relative, directory=False):
    if any(part.casefold() == ".git" for part in Path(relative).parts):
        return True
    if directory:
        return re.search(r"gitleaks.toml|node_modules|package-lock.json|vendor", relative, re.IGNORECASE) is not None
    return SECRET_SKIPPED_PATHS.search(relative) is not None


def scan_tree(root):
    for parent, dirs, files in os.walk(root, followlinks=False, onerror=walk_error):
        if Path(parent) == root and ".git" in dirs:
            dirs.remove(".git")
        for name in sorted(dirs + files):
            target = Path(parent) / name
            relative = target.relative_to(root).as_posix()
            if relative == ".git":
                continue
            if name == ".env" or name.endswith(".pem") or name == ".ssh":
                fail("prohibited credential path")
            if target.name in (".gitleaksignore", ".gitleaks.toml"):
                fail("alternative secret ignore/config file: " + relative)
            mode = target.lstat().st_mode
            if relative not in ("policy/gitleaks.toml", *PIPE_SCANNED_FILES) and secret_path_is_skipped(relative, stat.S_ISDIR(mode)):
                fail("unsupported secret-scan path: " + relative)
            if stat.S_ISLNK(mode):
                resolved = target.resolve(strict=True)
                if root != resolved and root not in resolved.parents:
                    fail("external symlink: " + relative)
                text = os.readlink(target)
            elif stat.S_ISDIR(mode):
                continue
            elif stat.S_ISREG(mode):
                text = target.read_bytes().decode("utf-8")
            else:
                fail("special file: " + relative)
            if relative == "policy/gitleaks.toml":
                # The default scanner skips its config. Permit only these
                # exact, reviewed bytes; even an added comment must fail.
                if text.encode("utf-8") != SECRET_CONFIG:
                    fail("secret policy differs from reviewed bytes")
            if any((ord(c) < 32 and c not in "\t\r\n") or ord(c) == 127 for c in text):
                fail("binary file: " + relative)
    if (root / "AGENTS.md").read_bytes() != (root / ".public-agent-template.md").read_bytes():
        fail("AGENTS.md differs from public template")


def verify_gitleaks(scanner, environment, root):
    version = subprocess.run([scanner, "version"], env=environment, cwd=root,
                             capture_output=True, timeout=10)
    if version.returncode:
        fail("gitleaks version command failed")
    if version.stdout.strip() in (GITLEAKS_VERSION.encode(), ("gitleaks version " + GITLEAKS_VERSION).encode()):
        return
    if hashlib.sha256(Path(scanner).read_bytes()).hexdigest() == GITLEAKS_PACKAGE_SHA256:
        return
    # go install does not set the release version string. Inspect the actual
    # executable's main package/module metadata instead; dependency versions,
    # replacements and development builds do not establish its identity.
    metadata = subprocess.run(["go", "version", "-m", scanner], env=environment, cwd=root,
                              capture_output=True, timeout=10)
    rows = [line.strip().split("\t") for line in metadata.stdout.decode("utf-8").splitlines()]
    paths = [row[1:] for row in rows if row[0] == "path"]
    modules = [row[1:] for row in rows if row[0] == "mod"]
    if (metadata.returncode or paths != [[GITLEAKS_MODULE]] or len(modules) != 1 or
            modules[0][:2] != [GITLEAKS_MODULE, "v" + GITLEAKS_VERSION] or
            any(row[0] == "=>" for row in rows)):
        fail("unsupported gitleaks build")


def scan_secrets(root, executable):
    root = root.resolve(strict=True)
    scanner = shutil.which(executable)
    if not scanner:
        fail("missing gitleaks executable")
    scanner = str(Path(scanner).resolve())
    with tempfile.TemporaryDirectory(prefix="public_scan.") as scratch:
        # Do not inherit private scanner configuration, ignores or credentials.
        environment = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": scratch}
        verify_gitleaks(scanner, environment, root)

        def scan(arguments, source_name=None, data=None):
            report = Path(scratch) / ("stdin.json" if source_name else "tree.json")
            with (Path(scratch) / "diagnostics").open("ab") as diagnostics:
                result = subprocess.run(
                    [scanner, "detect", "--source", ".", *arguments,
                     "--config", str(root / "policy/gitleaks.toml"),
                     "--redact", "--no-banner", "--report-format", "json",
                     "--report-path", str(report), "--exit-code", "23"],
                    cwd=root, env=environment,
                    **({"input": data} if data is not None else {"stdin": subprocess.DEVNULL}),
                    stdout=diagnostics, stderr=diagnostics, timeout=120,
                )
            if result.returncode not in (0, 23) or not report.is_file():
                fail("gitleaks tool/report error (diagnostics withheld)")
            # Some scanner versions retain context even with --redact. Read
            # only the safe fields; do not print/preserve the raw report.
            entries = json.loads(report.read_text(encoding="utf-8"))
            if not isinstance(entries, list):
                fail("invalid gitleaks report")
            for entry in entries:
                print("secret: {} {}:{}".format(entry["RuleID"], source_name or entry["File"], entry["StartLine"]), file=sys.stderr)
            if result.returncode != 0 or entries:
                fail("unexplained secret findings")

        scan(["--no-git"])
        # Gitleaks does not follow links by default. Scan their literal text.
        paths = []
        for parent, dirs, names in os.walk(root, followlinks=False, onerror=walk_error):
            if Path(parent) == root and ".git" in dirs:
                dirs.remove(".git")
            for name in dirs + names:
                target = Path(parent) / name
                paths.append(target.relative_to(root).as_posix())
                if target.is_symlink():
                    scan(["--pipe"], source_name=target.relative_to(root).as_posix(),
                         data=os.fsencode(os.readlink(target)))
        # Filesystem scanning does not treat a pathname as content. Check
        # the relative namespace too, without disclosing a matched filename.
        scan(["--pipe"], source_name="<filenames>", data=json.dumps(paths, ensure_ascii=False).encode("utf-8"))
        for relative in PIPE_SCANNED_FILES:
            target = root / relative
            if target.exists():
                data = os.readlink(target).encode("utf-8") if target.is_symlink() else target.read_bytes()
                scan(["--pipe"], source_name=relative, data=data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("."))
    parser.add_argument("--gitleaks", default="gitleaks")
    args = parser.parse_args()
    try:
        root = args.root.resolve(strict=True)
        scan_tree(root)
        scan_secrets(root, args.gitleaks)
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError):
        # Parse errors can include input text: deliberately keep this generic.
        print("Public scan failed; inspect policy, safe finding locations and tool availability.", file=sys.stderr)
        return 1
    print("Public tree gates passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
