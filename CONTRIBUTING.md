# Contributing to opencode-rails

## Running the test suite

```bash
bundle install
bundle exec rake test
```

The smoke tests live in `test/opencode/`. They prove that:

- Every gem-provided constant resolves
- The opencode-ruby umbrella loads transitively
- Source locations point at the right gem
- The version constant is not under an `Opencode::Rails` module
  (that would shadow `::Rails` in host apps; see comment in
  `lib/opencode/rails_version.rb`)
- Public API contracts on the AR-coupled classes hold (Session, Turn,
  MessageArtifacts) — verified via `Method#parameters`, not behavior
- Value objects (Artifact, SandboxFile, Transform, Impostor) round-trip
  through their public interfaces

Behavioral tests for AR + ActiveStorage paths live in the host app
that produced this code. Same pattern as opencode-ruby — gem-side
smokes prove load correctness; host-side tests prove integration
correctness.

## Working on opencode-rails together with opencode-ruby

opencode-rails depends on opencode-ruby. During development of either
gem you frequently need changes in opencode-ruby to be picked up by
opencode-rails without going through a release cycle.

**Use Bundler's `local` config — not Gemfile conditionals.** Bundler
behavior must never depend on filesystem state inside the Gemfile.

```bash
# Once per dev machine. Replace the path with wherever you have
# opencode-ruby checked out.
bundle config local.opencode-ruby /path/to/opencode-ruby

# Then bundle install/update against the local copy:
bundle install
```

To switch back to the released version:

```bash
bundle config --delete local.opencode-ruby
bundle install
```

See [Bundler's documentation on local git overrides](https://bundler.io/v2.5/git.html#local).

## Releasing

This gem is in alpha. Versions ship as `0.0.x.alphaN` until the public
API stabilizes.

Coordinated releases with opencode-ruby:

1. In opencode-ruby: bump `Opencode::VERSION`, tag, push.
2. In opencode-rails: bump `Opencode::RAILS_VERSION`, update the
   `add_runtime_dependency "opencode-ruby", "= X.Y.Z"` line in the
   gemspec to match the new opencode-ruby version (alpha discipline:
   pin exactly, not pessimistically). Tag, push.
3. In any consumer app: bump both `tag:` lines (or version pins) in
   the Gemfile to the new versions; `bundle update opencode-ruby
   opencode-rails`.

## Reporting issues

File at <https://github.com/ajaynomics/opencode-rails/issues>.
