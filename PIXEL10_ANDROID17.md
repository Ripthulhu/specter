# Pixel 10 on Android 17

The setup below was verified on a Pixel 10 Pro XL running Android 17
(`mustang`, SDK 37). Two fresh modern Play Store integrity checks passed Basic,
Device, and Strong after setup. The user then confirmed Google Wallet and
McDonald's worked. These are observations from this configuration, rather than
a promise that Google will continue accepting it.

## Generated fingerprints

Pixel 10, 10 Pro, 10 Pro XL, and 10 Pro Fold launched at API 36. Their launch API
differs from the current Android 17 SDK, which is 37.

Older Play Integrity Fork generators write launch API 32 for every generated
device. For generated Pixel 10 fingerprints, this fork corrects both fields:

```properties
DEVICE_INITIAL_SDK_INT=36
*api_level=36
```

The correction uses the generated Google fingerprint's device identity, including
Fork's default/random and preferred-device generation paths. Imported custom
fingerprints remain unchanged. Other spoofing options are preserved.

This follows [PIF's newer Pixel 10 handling](https://github.com/osm0sis/PlayIntegrityFork/commit/ef2f46dbf9104f8b44cc4574ef71df905313dc41).
Our successful comparison combined API 36 with an RKP provider; the test does not
establish that either change alone is sufficient.

## Attestation backend and key provisioning

TEESimulator-RS 6.0.1-282 has a separate Android 17 bug: its SDK map stops at 36,
so a fresh generated certificate can report Android 16 (`OS_VERSION=160000`) on
Android 17. Use a backend with the [SDK 37 correction](https://github.com/Enginex0/TEESimulator-RS/pull/69),
then verify that a fresh generated certificate reports `OS_VERSION=170000`.
The KeyMint/attestation version, such as 400, is a separate field.

The exact minimal DEX patch used for the pinned 282 build is retained in
[patches/teesimulator-rs-282-android17-fallback.patch](patches/teesimulator-rs-282-android17-fallback.patch).
It applies to a baksmali 2.5.2 disassembly of the official release's `classes.dex`:

```text
Original DEX SHA-256: 137e94b55b56e91edca1d25291e67d7b23b5ca587e79a9183c01b4922dff2d66
```

The patch preserves cached and mapped values, adding a SDK 37 fallback of 170000.
It is specific to that verified artifact. Reassemble with smali 2.5.2 and install
a separately reviewed module package through the root manager. Specter does not
patch third-party DEX files during installation or fingerprint refresh.

Pixel 10 identities also need compatible provisioning. PIF's maintainer warns
that first API 36 and newer may require an RKP keybox, and
[Google documents RKP-only provisioning for devices launching with Android 16](https://developer.android.com/privacy-and-security/security-key-attestation#phase-out-factory-keys-remote-key-provisioning-rkp).
Check the selected provider's chain, dates, signatures, and revocation status.
A locally valid chain alone does not prove acceptance by Play Integrity. Keys
and device-specific backups must remain private; no keybox is included here.

## KernelSU and Zygisk injection

With KernelSU-Next and Zygisk Next denylist enforcement, GMS can inherit an
unmount profile that prevents PIF injection. A loaded-module count does not
establish that DroidGuard received the module.

In the root manager's **non-root GMS profile**, keep superuser access off and
disable module unmounting for `com.google.android.gms` only. Preserve the other
profile fields and use the current device's package UID. The tested profile had
`allow_su=false`, `non_root.use_default=false`, and
`non_root.umount_modules=false`. Restart integrity processes with PIF's existing
`killpi.sh`, then check injection and a fresh Play Store verdict.

Specter does not change root permissions or app profiles as part of its scheduled
fingerprint updates. This setup step is separate from fingerprint generation.

## AICore on supported hardware

Passing Play Integrity does not establish that AICore can provision models.
The tested workaround was the official
[Public Compute Services 1.0.6](https://github.com/KieronQuinn/PublicComputeServices/releases/tag/1.0.6)
APK with Vector 2.2, using its recommended scopes:

```text
com.google.android.as.oss
com.google.android.as
com.google.android.dialer
com.google.android.apps.pixel.psi
com.google.android.tts
com.google.android.apps.pixel.agent
com.google.android.aicore
```

Enable those scopes, allow their injection through their non-root unmount
profiles, and reboot. Grant root to PCS itself through the root manager. Use the
[maintainer's manifest repository](https://github.com/PublicComputeServices/pcs-manifests):

```text
https://raw.githubusercontent.com/PublicComputeServices/pcs-manifests/refs/heads/main
```

Keep Google's detected device configuration. This phone reported Variant 14 / Mid;
choosing High based on the Pro name was unnecessary. Leave experimental options
unchanged and allow model downloads on unmetered Wi-Fi. PCS reported up-to-date
manifests, real model downloads completed, and the user confirmed Gboard Proofread
returned a correction. A fresh Play Store check still passed all three labels.

Before setup, save the Vector configuration, affected root profiles,
`device_config list_local_overrides`, and the `aicore` and
`device_personalization_services` namespaces. Rollback should disable PCS sync
and hooks, restore only its changed overrides and profiles, and revoke its new
root grant even if the APK is kept. Avoid clearing app data or resetting entire
DeviceConfig namespaces.

Screenshots and Magic Cue were still factory stub apps on this phone. Screenshots
had no Play Store update option; the Netherlands is absent from
[Google's supported-country list](https://support.google.com/pixelphone/answer/15312581?hl=en).
Those features were not validated, and this setup does not establish Pixel 7 Pro
model support.
