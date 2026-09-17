#!/usr/bin/env python3
"""Compatibility entry point for the managed installer.

The installer now ships inside the wheel as
:mod:`speechrail.service.managed_install`, so a downloaded release can install
its own runtime through ``speechrail install`` without a source checkout.  This
module re-exports the reviewed surface for the release SOP, the zero-setup
script and the installer tests, which import it by path.
"""

from __future__ import annotations

from speechrail.service.installer_errors import InstallerError
from speechrail.service.managed_install import (
    DiarizationInstallPaths,
    InstallResult,
    PreflightOutcome,
    install_managed,
    run_preflight,
)

__all__ = [
    "DiarizationInstallPaths",
    "InstallResult",
    "InstallerError",
    "PreflightOutcome",
    "install_managed",
    "run_preflight",
]


if __name__ == "__main__":
    raise SystemExit(
        "tools/install_macos.py is import-only; run 'speechrail install' from a release wheel"
    )
