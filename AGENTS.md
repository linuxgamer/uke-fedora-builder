# Uke Fedora builder — contributor and AI-agent rules

These rules extend the [umbrella contributor rules](https://github.com/linuxgamer/uke-fedora/blob/main/AGENTS.md) and the
[developer guide](https://github.com/linuxgamer/uke-fedora/blob/main/docs/DEVELOPING.md); they do not replace them. If this
file and a fresh command disagree, the command wins and the file is fixed.

## What this repository is

Fedora root filesystems, image recipes, manifests and release packaging for
Xiaomi Pad 7 and POCO Pad X1 (`uke`, SM7675). This is one of the three component
forks of the Uke Fedora umbrella. Kernel and device-tree changes belong in the
kernel repository, not here.

## Read order

1. The umbrella [AGENTS.md](https://github.com/linuxgamer/uke-fedora/blob/main/AGENTS.md) and
   [docs/DEVELOPING.md](https://github.com/linuxgamer/uke-fedora/blob/main/docs/DEVELOPING.md).
2. The umbrella [docs/STATE.md](https://github.com/linuxgamer/uke-fedora/blob/main/docs/STATE.md) for current heads and
   blockers, and [docs/BACKLOG.md](https://github.com/linuxgamer/uke-fedora/blob/main/docs/BACKLOG.md) for the work queue.
3. This file.
4. This repository's `README.md` and the build document linked from it.

## Start of a session

```sh
git status
git branch --show-current
bash -n build-images.sh build-rootfs.sh src/image/*.sh
```

Read the top of the umbrella backlog, pick one item and say which files you
expect to write. Keep one item per session unless it is a small follow-up.

## Task loop

1. Pick the top unblocked item from the umbrella `docs/BACKLOG.md`, or record a
   new item there before starting.
2. Branch here, make the smallest change, and keep each commit focused.
3. Run the checks below; a build is not a boot test.
4. Push and open the pull request in this repository; describe the tests and
   what remains unverified.
5. Update the umbrella `docs/STATE.md` and `docs/BACKLOG.md` in the umbrella
   repository, then the umbrella gitlink if the change is accepted.

## Working with the umbrella

The umbrella repository owns the pin, the image builder, the submodule pointers
and the cross-component documentation. Work and commit here, and open the pull
request in this repository; the umbrella updates its gitlink only after the
change is accepted. Do not edit umbrella files from here and do not move the
gitlink in an unrelated pull request. Cross-repository links must be absolute
URLs.

## Checks

- `bash -n build-images.sh build-rootfs.sh src/image/*.sh` — fast syntax gate.
- CI runs `shellcheck` and the contract tests in
  `.github/workflows/source-contracts.yml`; there is no local one-shot runner yet
  (umbrella backlog B12). For script changes, install `shellcheck` and reproduce
  the workflow commands, then say what you did not run.
- Device and release checks are listed in the umbrella
  [RELEASE.md](https://github.com/linuxgamer/uke-fedora/blob/main/docs/RELEASE.md).

CI runs the component source contracts; see the workflow files in
`.github/workflows/`. A passing check is not a device test and a successful
build is not a boot test.

## Build

Image build from the umbrella checkout:

```sh
./uke-fedora-builder/build-images.sh --cross-kernel --profiles kde,gnome \
    --output build/images
```

Needs Docker or Podman, `avbtool`, `jq`, `g++`, `zstd` and free disk; see
[BUILDING.md](docs/BUILDING.md) and [BUILD-CACHE.md](docs/BUILD-CACHE.md). The
builder creates files only: it never flashes a device, changes a slot or touches
`userdata`.

## Documentation rules

- Write English engineering records: date, environment, exact command or
  observation, result, remaining work. Name the device directly.
- Keep source, build, package, VM and on-device results separate. Never infer a
  hardware result from a build or a boot.
- Keep proofs, logs and long trial histories in the private records, not in this
  public repository. Do not commit credentials, serial numbers, calibration,
  OEM blobs or home-directory paths.
- Do not recreate the `referances/` or `reports/` trees.
- Documents created before November 2026 were removed in the 2026-11-11
  documentation cleanup; recover them from git history when needed.
- Link only to files that exist in this repository or to absolute URLs of other
  repositories. Do not link to the umbrella `private/`, `build/` or
  `artifacts/` paths, and do not recreate the removed `referances/README.md` or
  `uke-linux-docs/` trees.

Keep the release contract in mind: a matched boot/root pair, a manifest, and a
recovery path for the user. Do not publish an image as tested because it built.

## Rules for AI agents

- Verify first. Cite the file and line or the command output for every factual
  claim. Never invent paths, flags, test results or hardware behaviour.
- If a rule points at a path that does not exist, treat it as a documentation
  bug: use the substitutes in the umbrella
  [DEVELOPING.md](https://github.com/linuxgamer/uke-fedora/blob/main/docs/DEVELOPING.md#missing-evidence-paths), say so in
  your change, and fix the rule here. Do not fabricate donor evidence.
- Declare the files you own. Do not edit files another agent is editing; re-read
  before every edit and rebase instead of overwriting on a conflict.
- Subagents are for independent read-only research or a disjoint file set, at
  most two at a time. Give absolute paths, the expected output and an explicit
  "do not edit". The main agent reviews the diff, runs the checks and commits.
- Do not let a subagent push branches, move gitlinks or touch the tablet.
- Never flash, repartition, switch slots or re-lock the bootloader without an
  explicit user request. Keep a working boot image and a recovery route.
- Never commit or paste credentials, tokens, private logs, serial numbers or
  personal paths. If a secret was exposed, say so privately and rotate it.

## End of a session

- [ ] The relevant checks were run, or the document says which were not.
- [ ] The umbrella `docs/STATE.md` and `docs/BACKLOG.md` were updated in the
      umbrella repository, not here.
- [ ] Commit pushed; no credential, private log or OEM blob is included.
- [ ] The next action is one line and does not depend on this conversation.

## Safety

- Preserve the stock bootloader contract and matching boot/root artifacts.
- Do not silently flash, repartition, switch slots or overwrite Android/OEM
  data; the builder itself must never do these things.
- Never commit credentials, private device records, calibration data or OEM
  firmware blobs. Keep device-specific data out of public repositories.
