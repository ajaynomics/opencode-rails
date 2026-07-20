# frozen_string_literal: true

require_relative "lib/opencode/rails_version"

Gem::Specification.new do |spec|
  spec.name          = "opencode-rails"
  spec.version       = Opencode::RAILS_VERSION
  spec.authors       = ["Ajay Krishnan"]
  spec.email         = ["opencode-rails@ajay.to"]

  spec.summary       = "Production-grade Rails integration for OpenCode."
  spec.description   = <<~DESC
    Rails companion to opencode-ruby. ActiveRecord-aware session lifecycle
    (idempotent ensure!/recreate!/abort! with row-level locks), a Turn
    orchestrator that drives the Reply state machine + handles
    session-not-found recovery, an artifact pipeline backed by
    ActiveStorage, sandbox seeding, and tool-display value objects for
    Turbo Stream broadcasts. Drop into any Rails 7.1+ app that wants
    production-grade OpenCode streaming without rolling your own
    boilerplate.
  DESC
  spec.homepage      = "https://github.com/ajaynomics/opencode-rails"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"

  spec.files = Dir.glob("lib/**/*.rb") +
               Dir.glob("examples/**/*.rb") +
               %w[README.md LICENSE CHANGELOG.md opencode-rails.gemspec]
  spec.require_paths = ["lib"]

  # The opencode-ruby gem provides the wire-level Client + Reply primitives
  # this gem builds on. During alpha both gems evolve in lockstep — we pin
  # exactly (= not ~>) so that consumers always pick the version this gem
  # was tested against.
  spec.add_runtime_dependency "opencode-ruby", "= 0.0.1.alpha8"
  spec.add_runtime_dependency "marcel", "~> 1.0"

  # Rails sub-libraries used at runtime. Depending on these individually
  # (instead of the `rails` umbrella) avoids forcing host apps to load
  # ActionMailer, ActionCable, ActionView, etc. just to use this gem.
  spec.add_runtime_dependency "activerecord",  ">= 7.1", "< 9.0"
  spec.add_runtime_dependency "activestorage", ">= 7.1", "< 9.0"
  spec.add_runtime_dependency "activesupport", ">= 7.1", "< 9.0"

  spec.add_development_dependency "minitest", "~> 5.20"
  spec.add_development_dependency "rake", "~> 13.0"
end
