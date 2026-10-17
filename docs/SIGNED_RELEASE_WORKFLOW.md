# Manual signed release workflow

The workflow runs only on main when the operator enters RELEASE. It builds separate arm64 and x86_64 packages in the macos-release environment.

## Inputs

- Exact reviewed OpenVPN 2.7.x version.
- Reviewed matching OpenVPN and OpenSSL source SHA256 values.
- Optional creation/update of a **draft** release; default off.

`Resources/Engine/sources.lock.json` pins official upstream archive URLs, versions and SHA256 values (OpenVPN 2.7.8 and OpenSSL 3.5.9); release inputs independently confirm the reviewed versions/hashes. Source compilation occurs before loading signing credentials. The engine targets macOS 13 and statically links source-built OpenSSL; actual source licenses and archives are bundled before signing.

## Environment secrets

Configure these using GitHub's protected environment UI, never chat or Git:

- APP_SIGNING_P12_BASE64 / APP_SIGNING_P12_PASSWORD
- INSTALLER_SIGNING_P12_BASE64 / INSTALLER_SIGNING_P12_PASSWORD
- TEMP_KEYCHAIN_PASSWORD
- DEVELOPER_ID_APPLICATION / DEVELOPER_ID_INSTALLER
- NOTARY_API_KEY_BASE64 / NOTARY_KEY_ID / NOTARY_ISSUER_ID

The workflow creates a temporary signing keychain, signs nested binaries and the app, notarizes/staples the app, builds the architecture-specific PKG, notarizes/staples it, audits architecture and minimum OS, and emits hashes/manifests. Temporary signing material is removed.

Draft creation requires both architecture jobs to pass. It targets the workflow commit, refuses to replace a published release, and attaches review artifacts. The workflow never publishes the draft automatically.

## Publication gate

Before publication, review the generated dependency/license materials and record actual signed-machine QA for XPC approval, VPN traffic, DNS restoration, IPv6 safety, PF failures, sleep/wake and installation lifecycle. CI tests of one loopback port do not establish leak-free VPN operation. Configure any required macos-release environment reviewers through GitHub; do not bypass them in code.
