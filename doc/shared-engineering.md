# Shared engineering

Common rules, technical lessons and reusable engineering tools are maintained in the public MIT-licensed
[vocaro/apple-engineering](https://github.com/vocaro/apple-engineering) repository. Clone it as
`apple-engineering` beside this checkout with
`git clone https://github.com/vocaro/apple-engineering.git`, or set
`VOCARO_ENGINEERING_ROOT` to its location. A worktree of this repository, such as a session's,
uses the clone beside its main checkout. No private repository access is needed for the toolkit.

```sh
python3 scripts/eng doctor
python3 scripts/eng instructions
python3 scripts/eng knowledge background
```

Read the printed shared guidance and this repository's AGENTS.md before work. engineering.json
selects relevant capabilities and records exceptions. Current shared-resource policy comes from
`python3 scripts/eng policy refresh`; read current project main rules before using a shared
resource too. Initialization and guidance commands start no builds, devices or hosted jobs.
Existing commands remain project adapters to the shared source. App fixtures, acceptance
requirements, corpus admission, historical measurements and release decisions remain here.

## Runtime and test support

The public shipping products have no dependency on the engineering toolkit or private runtime
packages. The VoiceOver workflow checks out the public toolkit without an SSH key or custom
secret; ordinary public package builds remain self-contained. Public queue enrollment stays in
engineering.json; account-specific private queues are enrolled through local Git configuration
as described in the toolkit's [public access guide](https://github.com/vocaro/apple-engineering/blob/main/guides/public-access.md).

## Updates and new repositories

The toolkit's [adoption guide](https://github.com/vocaro/apple-engineering/blob/main/guides/adoption.md)
describes local checkout updates, isolated trials and rollback. No pin is required. Runtime
package changes are qualified separately with their own suites and affected consumer checks;
local path adoption is also supported where this project's distribution contract permits it.
A new repository can run the toolkit's `bin/eng --project /path/to/NewRepo init`, select its
capabilities and configure its own lanes without copying maintained implementations.

Reusable findings go in the toolkit's subject guide with the source commit and original evidence
link. This project's observed results stay on the owning issue or existing measurement record.
A source move does not expand a qualification to new operating systems or inputs.
