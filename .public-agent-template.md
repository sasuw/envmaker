# Public contributor instructions

envmaker manages separate dotfiles trees using Bash, Perl and GNU Stow.
Contributors keep shared behavior in `bin/` and use the existing package layout
in `templates/dotfiles/`. A contributor preserves ownership checks and tests
every affected CLI entry point, including deletion, migration and recovery.

Before changes, a contributor reads `README.md` and the related references
under `docs/`. A contributor runs `python3 -I scripts/scan_public.py --root .`
and `bash scripts/check_public.sh`. Runtime tests use a temporary HOME and XDG
directories; a contributor never applies test dotfiles to a real home.
Prerequisites are described in `docs/prerequisites.md`; tests never install
packages or use privileges.

`AGENTS.md` and `.public-agent-template.md` are generated from the same public
template. A maintainer changes that template at its source and regenerates
both outputs together. No private development instructions or configuration
belong in this tree. Publishing a release requires explicit maintainer approval
of the destination and exact commit.
