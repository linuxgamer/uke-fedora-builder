# Contributor and agent instructions

- Keep this repository focused on Fedora root filesystems, image recipes, manifests and validation. Kernel changes belong in the kernel repository.
- Write documentation in English. Keep it casual and human-readable. Separate host validation, VM results, package tests and verified on-device behavior.
- Do not imply an image is tested merely because it builds. Identify the exact device, image and test environment when reporting results.
- Preserve the stock bootloader contract, matching boot/root artifacts and a recovery path. Do not silently flash, repartition, switch slots or overwrite Android/OEM data.
- Use upstream Fedora/KDE packages rather than forking KDE applications. Prefer Bash for host scripts and native tools for device integration.
- Do not import donor/reference scripts as executable shortcuts; track provenance, licenses and compatibility for borrowed sources.
- Never publish credentials, private device records, calibration data, identifying hardware details or personal paths.
- Run the relevant build checks and tests before committing. State explicitly which checks were not run.
