# Contributor and agent instructions

- Keep this repository focused on Fedora root filesystems, image recipes, manifests and validation. Kernel changes belong in the kernel repository.
- Write documentation in English. Keep it casual and human-readable. Separate host validation, VM results, package tests and verified on-device behavior.
- Do not imply an image is tested merely because it builds. Identify the exact device, image and test environment when reporting results.
- Preserve the stock bootloader contract, matching boot/root artifacts and a recovery path. Do not silently flash, repartition, switch slots or overwrite Android/OEM data.
- Use upstream Fedora/KDE packages rather than forking KDE applications. Prefer Bash for host scripts and native tools for device integration.
- Do not import donor/reference scripts as executable shortcuts; track provenance, licenses and compatibility for borrowed sources.
- Never publish credentials, private device records, calibration data, identifying hardware details or personal paths.
- Run the relevant build checks and tests before committing. State explicitly which checks were not run.

## Checks

- `bash -n build-images.sh build-rootfs.sh src/image/*.sh` — fast syntax gate.
- CI runs `shellcheck` and the contract tests in
  `.github/workflows/source-contracts.yml`; there is no local one-shot runner
  yet (umbrella backlog B12). For script changes, install `shellcheck` and
  reproduce the workflow commands, then state what you did not run.
- A completed build is not a boot test. Keep host, VM, package and device
  results separate and name the exact device and image.

## Working with the umbrella

Commit and push here, and open the pull request in this repository. The umbrella
repository updates its gitlink only after this change is accepted; cross-repo
links must use absolute URLs. Contributor rules:
[AGENTS.md](https://github.com/linuxgamer/uke-fedora/blob/main/AGENTS.md) and
[DEVELOPING.md](https://github.com/linuxgamer/uke-fedora/blob/main/docs/DEVELOPING.md).
