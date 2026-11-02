# Third-Party Notices

## sing-box 1.14.4 (with XHTTP)

kongshan bundles a sing-box binary built from the official
[SagerNet/sing-box v1.14.4](https://github.com/SagerNet/sing-box/releases/tag/v1.14.4) source
(commit `c005f35`) with the XHTTP client transport ported from
[Leadaxe/sing-box-lx](https://github.com/Leadaxe/sing-box-lx) `v1.14.4-lx.25` (commit `d0e2a15`).
Both are licensed under GPL-3.0-or-later. The complete corresponding source of the modification —
the ported files, the patch to upstream files, and the build script — is in this repository under
`Kernel/xhttp/` and `scripts/build_sing_box.sh`.

## Yams 6.2.2

Yams and its bundled libYAML code are licensed under the MIT License. Source and license
are available in the [Yams repository](https://github.com/jpsim/Yams/tree/6.2.2).

## Dependency scope

These are kongshan's only non-Apple runtime dependencies. Dashboard charts,
notifications, login-item management, process monitoring, networking, and the native UI
use macOS system frameworks supplied by Apple.
