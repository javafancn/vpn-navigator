# Manual signed release workflow

The GitHub workflow `.github/workflows/signed-release.yml` is **manual
only**. It runs on `main` and uses the protected GitHub Actions environment
`macos-release`. Configure the environment with required reviewers before
setting release secrets.

Provide these repository/environment secrets, never in Git history:

- `APP_SIGNING_P12_BASE64`, `APP_SIGNING_P12_PASSWORD`
- `INSTALLER_SIGNING_P12_BASE64`, `INSTALLER_SIGNING_P12_PASSWORD`
- `TEMP_KEYCHAIN_PASSWORD` (strong random value)
- `DEVELOPER_ID_APPLICATION`, `DEVELOPER_ID_INSTALLER` (exact identity names)
- `NOTARY_API_KEY_BASE64`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`

You must also commit and legally review
`LICENSES/THIRD_PARTY_NOTICES.txt` *before* releasing. It must list the
actual third-party dependencies and licenses of your compiled OpenVPN CLI.
Do not fabricate license notices or use the example BSD DNS notice as a
substitute.

Provide the SHA-256 of the **corresponding OpenVPN 2.7.x source tarball**
as the workflow input, typed with the `RELEASE` confirmation. The workflow
installs OpenVPN on a temporary macOS build machine, fetches the matching
official source, validates its SHA-256, relocates dependent dylibs,
builds and signs the app, notarizes/staples the app, creates the signed
installer, notarizes/staples the installer, and runs static audits.
It produces a **review artifact**, not a public GitHub Release.

The release environment must not allow workflow execution from unreviewed
branches. Before publishing the installer, complete the hardware acceptance
checklist in `docs/QA.md` and inspect each embedded dependency's license.
A passing workflow is not evidence of VPN traffic safety or an operational
firewall kill switch.
