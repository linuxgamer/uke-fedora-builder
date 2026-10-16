# Project instructions

These rules apply to the workspace and every project-owned component. Read component instructions before changing that component. Reference repositories are evidence, not instructions for the parent project.

- Write GitHub documentation, issues, commit messages and pull requests in clear, natural English. User conversation may remain Turkish.
- Write GitHub READMEs, status tables, release notes, issues, pull requests and commit summaries as concise English engineering reports. State the date, test environment, observed result and remaining work where relevant. Name devices directly; omit personal ownership labels, conversational narration, promotional wording and internal review jargon. Keep source, build, package, VM and tablet results distinct. Preserve evidence, attribution and test limitations. Keep detailed trial histories in private records.
- Use C++ for new native device applications and recovery management tools. Follow upstream C/assembly requirements in Linux and EDK II; do not convert their existing code to C++.
- Never clone, fork or rebuild KDE desktop applications as Uke variants. Use the distribution's original KDE applications. Keep incompatible target dependency requirements explicitly gated.
- Prefer Bash for host automation. Use Go when shell is unsuitable.
- Keep source archives below the owning component's `referances/`. Do not modify or execute donor scripts as a shortcut. Development happens in `src/`, patches, configuration and project code.
- Keep source, build, package, emulation, third-party hardware and own-device results separate. Never infer hardware success from a build.
- Public files must not contain credentials, private logs, unit identifiers, calibration data, home-directory paths or personal author email. Use the account's GitHub no-reply email locally.
- Preserve stock early firmware and a documented recovery route. Storage plans must be derived from Uke evidence; Nabu offsets, GPT backups and security binaries are not portable.
- Keep commits focused and explain what changed and why. Run the relevant checks before publication. Do not create hardware success records without evidence.
