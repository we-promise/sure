# Be sure to restart your server when you modify this file.
#
# Content Security Policy — report-only mode.
# Violations are logged to /csp-violation-report but nothing is blocked yet.
# Once violations are reviewed and the policy is tuned, switch to enforcement
# by removing config.content_security_policy_report_only = true.
#
# Known external services that need allowlisting:
#   - PostHog:  https://us.i.posthog.com, https://us-assets.i.posthog.com
#   - Plaid:    https://cdn.plaid.com
#   - Stripe:   https://js.stripe.com, https://hooks.stripe.com
#   - Pusher:   wss://*.pusher.com (ActionCable / Hotwire)
#   - OpenAI:   (server-side only, no browser resources needed)

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.font_src    :self, :data
    policy.img_src     :self, :https, :data, :blob
    policy.object_src  :none

    # Baseline hardening directives — all browsers respect these and they cost
    # nothing: no arbitrary <base>, forms only to self, no framing.
    policy.base_uri        :self
    policy.form_action     :self
    policy.frame_ancestors :none

    managed_mode = Rails.application.config.app_mode.managed?

    # Scripts: self + Plaid + Stripe (+ PostHog in managed mode) + importmap inline (nonce-controlled)
    script_src = [
      :self,
      "https://cdn.plaid.com",
      "https://js.stripe.com"
    ]

    # Connections: self + external APIs used client-side
    connect_src = [
      :self,
      "https://hooks.stripe.com"
    ]

    if managed_mode
      # Derive PostHog hosts from the same env var config/initializers/posthog.rb
      # uses, so a managed deploy pointed at a different PostHog region doesn't
      # have CSP silently blocking the very traffic that initializer enables.
      #
      # Region handling: the assets host mirrors the API host with the first
      # subdomain labelled "-assets" (us.i.posthog.com → us-assets.i.posthog.com,
      # eu.i.posthog.com → eu-assets.i.posthog.com). Operators on self-hosted
      # PostHog with a different layout can override via POSTHOG_ASSETS_HOST.
      posthog_host = ENV.fetch("POSTHOG_HOST", "https://us.i.posthog.com")
      posthog_assets_host = ENV.fetch("POSTHOG_ASSETS_HOST") do
        uri = URI.parse(posthog_host)
        assets_host = uri.host.to_s.sub(/\A([^.]+)/, '\1-assets')
        "#{uri.scheme}://#{assets_host}"
      end

      script_src += [ posthog_host, posthog_assets_host ]

      connect_src += [
        posthog_host,
        posthog_assets_host,
        "wss://*.pusher.com"
      ]
    end

    policy.script_src(*script_src)

    # Styles: self + unsafe_inline needed for Tailwind/inline styles
    policy.style_src :self, :unsafe_inline

    policy.connect_src(*connect_src)

    # Frames: Plaid and Stripe use iframes
    policy.frame_src "https://cdn.plaid.com",
                     "https://js.stripe.com"

    policy.report_uri "/csp-violation-report"
  end

  # Nonces for inline scripts/styles managed by importmap and Hotwire.
  # Per-response random nonce — a session-id nonce is constant for the lifetime of
  # the session and provides no CSP guarantee once an attacker observes one script tag.
  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]

  # REPORT-ONLY: violations are logged, nothing is blocked.
  # Remove this line to enforce the policy.
  config.content_security_policy_report_only = true
end
