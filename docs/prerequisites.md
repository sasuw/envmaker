# How to prepare GNU Stow for envmaker

A human installs GNU Stow 2.4.1 and its matching Perl modules before using
envmaker. The expected executable is `/opt/stow-2.4.1/bin/stow`. The wrapper
checks CLI and module versions together for overlay operations.

## Build a reviewed upstream release

1. A human obtains the `stow-2.4.1.tar.gz` release and its signature from
   [GNU Stow downloads](https://ftp.gnu.org/gnu/stow/), verifies its provenance
   using GNU's release instructions, and extracts it into a new disposable
   build directory. No archive is bundled with envmaker.
2. A human ensures Perl, `make`, a compiler and the upstream build
   prerequisites are available. On a shared machine an operator approves
   any package installation first. No special pinned Perl build is required.
3. From the extracted `stow-2.4.1` source, a human runs:

   ```bash
   ./configure --prefix=/opt/stow-2.4.1
   make
   # Administrator action; writes /opt/stow-2.4.1 only as directed by upstream.
   sudo make install
   ```

   Configure and build are unprivileged. Installation requires privileges
   unless the destination has already been provisioned for that account.
   Review upstream install behavior before granting privileges. No manpage
   links or system package metadata changes are required by envmaker.

4. A human checks both executable and module availability, from the envmaker
   checkout:

   ```bash
   /opt/stow-2.4.1/bin/stow --version
   perl bin/stow_probe.pl /opt/stow-2.4.1/bin/stow 2.4.1
   ```

The JSON probe must report version `2.4.1` and an existing `Stow.pm`.
Copying only the executable, or pointing it at an unrelated module version,
does not satisfy this prerequisite. A human can use another Stow version only
with the matching `/opt/stow-VERSION` installation and `STOW_VERSION=VERSION`
on every wrapper invocation; compatibility requires separate verification.

The smoke test checks the installed 2.4.1 executable/module pair and exercises
the wrapper with isolated HOME and XDG directories. It does not perform a
privileged install, verify upstream signatures or prove a native macOS/FreeBSD
build. The private legacy installer and Perl Makefile are excluded because
their package changes, privilege use and cleanup are unnecessary here.
