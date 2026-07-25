module Silas
  # One deprecator for the whole gem, so hosts can control the noise the way
  # they control Rails' own:
  #
  #   Silas.deprecator.behavior = :raise    # or :warn (default), :silence
  #
  # Rails registers it in application.deprecators (see Silas::Engine), which
  # means `config.active_support.report_deprecations = false` silences Silas
  # along with everything else, and a host can opt into raising in CI.
  #
  # Every deprecation message names BOTH the replacement and the version it
  # disappears in — a warning you can't act on is just noise.
  def self.deprecator
    @deprecator ||= ActiveSupport::Deprecation.new("2.0", "Silas")
  end
end
