# Prepared Fedora userdata payload

18 October 2026 · Xiaomi Pad 7 / POCO Pad X1 (`uke`) · Fedora Rawhide AArch64

This archive contains the prepared F2FS root and matching stock-ABL boot payload.
It is not yet a recovery installer. Do not sideload or flash this data archive.
OrangeFox integration, device-local provisioning and tablet acceptance follow
when the recovery project is ready.

| Item | Prepared state |
|---|---|
| Root | 14 GiB F2FS, `UKE_LINUX`, intended for the existing `userdata` partition |
| Kernel | Common `senemos-uke-linux-kernel-mainline` 7.2.10-31; no separate `-up` family |
| Desktop | Original Fedora Plasma Login Manager and Plasma Setup |
| Accounts | Locked root; no ordinary account; Setup creates the first user |
| Languages | All packaged runtime translations, multilingual fonts and input methods retained |
| Updates | `mcc45tr/uke-linux` enabled; Discover offline-update components installed |
| Kernel activation | Held until the userdata A/B writer and failed-boot fallback are qualified |
| Secure Boot | Off in this build |
| Debug content | No debug RPMs or development shell services; kernel debug instrumentation disabled |

`payload.json` records exact sizes, hashes, source commits, COPR builds and
validation limits. `checks/` contains package identities, recorded origins,
device-input hashes, language results and boot/payload readback results.
`sources/` contains the builder source and detailed preparation guide.

Verify the extracted archive on the host:

```sh
sha256sum -c SHA256SUMS
```

No OEM firmware or private calibration is included. Firmware and touchscreen
inputs must be provisioned from a validated source on the same device before
activation. The two signed RPMs under `deferred-rpms/` retain their actual
firmware dependencies and are installed after that provisioning.

Host/VM checks do not establish tablet boot, account creation, hardware support,
offline-update execution or slot fallback. Retaining F2FS does not preserve
Android encryption metadata: Android restoration also needs its original boot
stack and Android-compatible userdata initialization. No partition-layout change
is defined by this payload, and no public release is approved by its preparation.
