# Stable local signing for Wakely

This machine uses a dedicated **Wakely Local Development** certificate. It is
self-signed, not Apple Developer ID, and is not notarized. Do not claim normal
Gatekeeper acceptance for downloaded builds.

## One-time setup (explicit user action only)

```sh
python3 Tools/Signing/setup-local-signing.py
```

This imports a dedicated RSA signing key/certificate into the existing login
Keychain. User trust is constrained to **Code Signing**; no system-wide, SSL or
email trust is added. `/usr/bin/codesign` is the explicitly allowed private-key
consumer, not every application. Setup never unlocks a keychain, captures a login
password, or uploads the private key. Transient private PEM files live in a fresh
private temporary directory and are deleted after import. Do not run setup during
normal builds or regenerate the certificate for each release.

Only the public certificate and non-secret configuration are kept under:

```
~/Library/Application Support/Wakely/Signing/
  identity.json
  Wakely-Local-Development.cer
```

No private key belongs in this repository, the app, a DMG, logs, or CI artifacts.
If setup imported the identity but stopped before writing configuration, recover
that existing identity through Keychain Access; do not silently create another.

## Building

```sh
bash build.sh
```

The build reads that user's configuration and signs every nested executable and
the app with the configured exact certificate fingerprint. The app identifier
remains `dev.wakely.app`; helper and watchdog retain their own identifiers.
Explicit designated requirements pin **identifier + certificate**, not cdhash.
Missing/locked/invalid configured identities are errors, never an ad-hoc fallback.
An explicit `WAKELY_SIGN_IDENTITY` remains an intentional override. Without a local
configuration or explicit identity, another machine still defaults to ad-hoc.

`package-dmg.sh` can package these locally signed builds. The build's
`WAKELY_DISTRIBUTION=1` mode is for the separate Developer ID signing/timestamping
path, not a claim that a local certificate can be notarized.

## Migrating this installation

Moving from ad-hoc to this certificate changes the identity once:

1. Install the signed app at `/Applications/Wakely.app`.
2. Reinstall the shared helper once with administrator authorization. Its peer
   policy then pins the exact leaf certificate shared by app, helper and watchdog.
3. If Accessibility still lists the old ad-hoc identity, remove that stale entry,
   add the installed signed app and enable it. The user must do this manually.
   Installing a helper does not grant Accessibility.
4. Verify in a normally launched GUI process, not just a CLI child whose privacy
   attribution may differ. Creating a listen-only tap is not a full input-lock test.

Future builds using this exact certificate/DR are intended to keep the same code
identity. Compare requirements across changed builds and test a GUI upgrade before
claiming TCC persistence. A changed build hash alone must not require re-pinning
helper peers. Helper binary updates may still need administrator authorization.

## Protecting the identity

Use Keychain Access to make an **encrypted** backup of the certificate together
with its private key, storing the backup/password separately and securely. No
backup password is generated or retained by the build. The public certificate
alone cannot sign future builds. Losing the key, deleting the certificate or
replacing/renewing it changes the pinned identity and requires a migration.

Do not ask recipients to install a broadly trusted root or share the signing
private key. A self-signed DMG can be shared, but users may need a Gatekeeper
override and managed Macs may block it. It does not provide notarization.
