# frozen_string_literal: true

module Opencode
  # Pluggable error-reporter adapter. opencode-rails ships with zero
  # dependency on Honeybadger, Sentry, Bugsnag, Rollbar, or any specific
  # error-tracking library. Host apps plug their own adapter in:
  #
  #   # config/initializers/opencode.rb
  #   Opencode::ErrorReporter.adapter = ->(error, **opts) {
  #     Rails.error.report(error, **opts)
  #   }
  #
  # When no adapter is set (default), `.report` is a silent no-op. This
  # lets the gem be used outside Rails-style apps without forcing a
  # dependency on any specific error reporter, while keeping the option
  # to route errors anywhere the host wants when the gem ships in a
  # Rails context.
  #
  # Semantics mirror Rails.error.report (handled:, severity:, context:)
  # but the gem doesn't enforce any specific kwarg vocabulary — whatever
  # the gem code passes is forwarded verbatim to the adapter.
  module ErrorReporter
    class << self
      attr_accessor :adapter
    end

    # Report an error to the configured adapter, or no-op if none set.
    # Returns the adapter's return value (typically the error itself for
    # `Rails.error.report`).
    def self.report(error, **opts)
      adapter&.call(error, **opts)
    end
  end
end
