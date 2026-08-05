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
| Yarn | `yarn.lock` exists | `yarn upgrade --latest` |
| Importmap | `config/importmap.rb` and `bin/importmap` exist | `bin/importmap update` |

For each ecosystem it resolves the latest versions, then checks the publication
date of every bump. Anything released within the cooldown window is rolled back
and replaced with the newest version that is already older than the cooldown. If
none qualifies, it keeps the currently locked version. At the end it prints a
summary of what was updated and what was held back, with ages.

Release dates come from the public registries: rubygems.org for gems, and
registry.npmjs.org for Yarn and Importmap packages.

## Bundler native cooldown

Bundler 4.0.13 and newer ship a built in `--cooldown` filter. When a capable
bundler is available, `dependency-update` uses it directly, and will bump the
`BUNDLED WITH` pin in `Gemfile.lock` so the run resolves under native cooldown.
On older bundlers it falls back to the rubygems.org API based logic above, and
prints a notice recommending an upgrade.

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
