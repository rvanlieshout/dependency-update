# dependency-update

Update a project's Ruby, Yarn, and Importmap dependencies in one pass, while
holding back releases that are newer than a cooldown period.

Most supply chain attacks and broken releases are caught within days of
publication. By refusing to install anything younger than the cooldown (default
**7 days**), you stay current without being the first to run a just published,
and possibly compromised, version.

## What it does

Run it from a project root. It auto detects each ecosystem and updates what is
present:

| Ecosystem | Trigger | Command used |
| --------- | ------- | ------------ |
| Ruby gems | always | `bundle update --all` |
| Yarn (berry) | `yarn.lock` exists, yarn 4.10+ | `yarn up '*'` |
| Yarn (classic) | `yarn.lock` exists, yarn 1.x | `yarn upgrade --latest` |
| Importmap | `config/importmap.rb` and `bin/importmap` exist | `bin/importmap update` |

Where the package manager enforces the cooldown itself, `dependency-update` just
hands it the window and lets it resolve. Where it does not, the tool resolves the
latest versions, then checks the publication date of every bump. Anything
released within the cooldown window is rolled back and replaced with the newest
version that is already older than the cooldown. If none qualifies, it keeps the
currently locked version. At the end it prints a summary of what was updated and
what was held back, with ages.

Release dates for the fallback path come from the public registries:
rubygems.org for gems, and registry.npmjs.org for Yarn and Importmap packages.

## Native cooldown support

| Ecosystem | Native filter | Available since | Used when |
| --------- | ------------- | --------------- | --------- |
| Bundler | `--cooldown <days>` | 4.0.13 | bundler 4.0.13+ is installed |
| Yarn | `npmMinimalAgeGate` | 4.10.0 | the project's yarn is 4.10+ |
| Importmap | none | — | never; always the API fallback |

See [cooldowns.dev](https://cooldowns.dev) for the state of native cooldown
support across package managers.

**Bundler.** A project's `Gemfile.lock` pins a bundler via `BUNDLED WITH`, and
bundler auto switches to it. When that pin predates native cooldown but a capable
bundler is installed, `dependency-update` bumps the pin so the run resolves under
native cooldown. On older bundlers it falls back to the rubygems.org API based
logic and prints a notice recommending an upgrade.

**Yarn.** Yarn 4.10 and newer gate resolution on publication age. The gate is set
per run via `YARN_NPM_MINIMAL_AGE_GATE`, so no `.yarnrc.yml` changes are needed.
The value is always passed **in minutes**: yarn 4.15+ also accepts duration
strings like `7d`, but 4.10–4.14 parse those numerically, turning `7d` into a
seven *minute* gate that silently lets everything through. Yarn 1 (classic) has
no equivalent and keeps the registry API fallback, with a notice recommending
`yarn set version stable`.

The yarn classic fallback covers transitive dependencies too. After the upgrade
every version in `yarn.lock` that was not locked before is checked against
registry.npmjs.org. A version inside the cooldown window is replaced, in place in
`yarn.lock`, by the newest version that is older than the cooldown and still
satisfies every range of that lockfile entry, followed by `yarn install`. This
repeats for dependencies the replacement pulls in. When no older version fits
the ranges, the young version stays and the summary says so.

`resolutions` in `package.json` are deliberate overrides, so they are never
changed. The summary lists a resolution as stale when a newer version older than
the cooldown exists, or, with yarn classic, when no package in `yarn.lock`
depends on it anymore and the override has no effect.

Note that yarn 4.15+ applies a one day gate by default, so a yarn project has
some protection even without this tool.

## Installation

Distributed as a git gem. Add it to the development group and skip auto require:

```ruby
group :development do
  gem "dependency-update",
      git: "https://github.com/rvanlieshout/dependency-update.git",
      require: false
end
```

Then `bundle install`.

## Usage

```sh
bundle exec dependency_update
```

Review the resulting diff (`Gemfile.lock`, `yarn.lock`, `package.json`,
`config/importmap.rb`), run your test suite, and commit. The tool changes files
only. It does not commit or push.

### Configuration

| Environment variable | Default | Meaning |
| -------------------- | ------- | ------- |
| `DEPENDENCY_COOLDOWN_DAYS` | `7` | Minimum age, in days, a release must have before it may be installed. |

```sh
DEPENDENCY_COOLDOWN_DAYS=14 bundle exec dependency_update
```

## Requirements

- Ruby 3.0 or newer
- Network access to rubygems.org and, for JS packages, registry.npmjs.org
- `yarn` and/or `bin/importmap` on `PATH` for those ecosystems

## License

MIT
