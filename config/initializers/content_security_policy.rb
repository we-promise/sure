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
#   - OpenAI:   (server-side only, no browser resources needed)

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.font_src    :self, :data
    policy.img_src     :self, :https, :data, :blob
    policy.object_src  :none

    # Scripts: self + PostHog + Plaid + Stripe + importmap inline (nonce-controlled)
    policy.script_src  :self,
                       "https://us.i.posthog.com",
                       "https://us-assets.i.posthog.com",
                       "https://cdn.plaid.com",
                       "https://js.stripe.com"

    # Styles: self + unsafe_inline needed for Tailwind/inline styles
    policy.style_src   :self, :unsafe_inline

    # Connections: self + external APIs used client-side
    policy.connect_src :self,
                       "https://us.i.posthog.com",
                       "https://us-assets.i.posthog.com",
                       "https://hooks.stripe.com",
                       "wss://*.pusher.com"   # ActionCable / Hotwire

    # Frames: Plaid and Stripe use iframes
    policy.frame_src   "https://cdn.plaid.com",
                       "https://js.stripe.com"

    policy.report_uri  "/csp-violation-report"
  end

  # Nonces for inline scripts/styles managed by importmap and Hotwire
  config.content_security_policy_nonce_generator = ->(request) { request.session.id.to_s }
  config.content_security_policy_nonce_directives = %w[script-src]

  # REPORT-ONLY: violations are logged, nothing is blocked.
  # Remove this line to enforce the policy.
  config.content_security_policy_report_only = true
end
