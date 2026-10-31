require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  config.assume_ssl = ENV.fetch("RAILS_ASSUME_SSL", "true") == "true"

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  # Set RAILS_FORCE_SSL=false to run over plain HTTP locally (e.g. docker compose).
  config.force_ssl = ENV.fetch("RAILS_FORCE_SSL", "true") == "true"

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Shared Redis cache so every Puma process/container sees the same forecasts.
  # Falls back to a per-process memory store when REDIS_URL is not set.
  config.cache_store = if ENV["REDIS_URL"].present?
    [ :redis_cache_store, {
      url: ENV["REDIS_URL"],
      connect_timeout: 1, read_timeout: 0.5, write_timeout: 0.5,
      reconnect_attempts: 1,
      # If Redis is down, log it and behave like a cache miss instead of failing the request.
      error_handler: ->(method:, returning:, exception:) {
        Rails.logger.warn("[cache] #{method} failed: #{exception.class}: #{exception.message}")
      }
    } ]
  else
    :memory_store
  end

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Enable DNS rebinding protection and other `Host` header attacks.
  # config.hosts = [
  #   "example.com",     # Allow requests from example.com
  #   /.*\.example\.com/ # Allow requests from subdomains like `www.example.com`
  # ]
  #
  # Skip DNS rebinding protection for the default health check endpoint.
  # config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
