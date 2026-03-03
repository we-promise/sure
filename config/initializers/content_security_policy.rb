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

    managed_mode = Rails.application.config.app_mode.managed?

    # Scripts: self + (optional) PostHog + Plaid + Stripe + importmap inline (nonce-controlled)
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
      script_src += [
        "https://us.i.posthog.com",
        "https://us-assets.i.posthog.com"
      ]

      connect_src += [
        "https://us.i.posthog.com",
        "https://us-assets.i.posthog.com",
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

  # Nonces for inline scripts/styles managed by importmap and Hotwire
  # Use SecureRandom for nonce — do NOT use session.id (leaks session identifier)
  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]

  # REPORT-ONLY: violations are logged, nothing is blocked.
  # Remove this line to enforce the policy.
  config.content_security_policy_report_only = true
end
