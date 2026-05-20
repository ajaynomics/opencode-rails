source "https://rubygems.org"

# opencode-ruby is the underlying wire client. During alpha both gems
# evolve in lockstep; the gemspec pins a release version, but for local
# dev we pull from the sibling working copy so changes in opencode-ruby
# are picked up without a release cycle.
if File.exist?(File.expand_path("../opencode-ruby", __dir__))
  gem "opencode-ruby", path: File.expand_path("../opencode-ruby", __dir__)
end

gemspec
