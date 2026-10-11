# Be sure to restart your server when you modify this file.
#
# See the Securing Rails Applications Guide for more information:
# https://guides.rubyonrails.org/security.html#content-security-policy-header
#
# Deliberately excluded directives:
# - form-action: the OAuth authorization consent form
#   (app/views/doorkeeper/authorizations/new.html.erb) and the redirect pages
#   in app/views/doorkeeper/authorizations/form_post.html.erb /
#   app/views/sessions/mobile_sso_start.html.erb submit to a caller-registered
#   redirect_uri or custom URL scheme (e.g. "sureapp://") that isn't known
#   ahead of time, so a static allowlist can't cover it without breaking
#   every third-party OAuth client and the mobile app's SSO flow.
# - report-uri: no violation-collection endpoint exists yet; add one before
#   relying on this for detection rather than just enforcement.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.font_src    :self, :https, :data
    # blob: is required for the profile-picture upload preview
    # (app/javascript/controllers/profile_image_preview_controller.js uses
    # URL.createObjectURL(file) to show the selected file before it's saved).
    policy.img_src     :self, :https, :data, :blob

    # Plaid Link (app/javascript/controllers/plaid_controller.js) loads its
    # widget script from cdn.plaid.com at runtime via a dynamically inserted
    # <script> tag — that bypasses the nonce entirely (nonces only apply to
    # markup the server itself rendered), so the origin must be allowlisted
    # directly. The widget then opens an iframe from the same cdn.plaid.com
    # host and talks to the Plaid API host of the active environment. That
    # environment is not known at boot: Settings > Providers can override
    # PLAID_ENV (config_value(:environment) in
    # app/models/provider/plaid_adapter.rb wins over the env var), and Plaid
    # EU reads PLAID_EU_ENV instead, so a US and an EU family on the same
    # install can use different environments. Allowlist every Plaid API host
    # rather than tracking one env var, or bank-linking breaks silently
    # whenever the effective environment differs from it. Always included
    # (not gated on Plaid being actively configured) since Plaid is a core,
    # always-available connection method, not an opt-in add-on like PostHog
    # below.
    plaid_api_hosts = %w[sandbox development production].map { |env| "https://#{env}.plaid.com" }
    plaid_cdn_host = "https://cdn.plaid.com"
    policy.frame_src :self, plaid_cdn_host

    # PostHog dynamically inserts a plain <script src> for its recorder
    # bundle (_posthog_bootstrap.html.erb loads <host>-assets/static/array.js)
    # and long-polls its ingestion endpoint — neither goes through importmap,
    # so both need explicit script-src/connect-src entries. Two independent
    # integrations load it, each with its own host:
    # - analytics (layouts/shared/_head.html.erb) on POSTHOG_HOST, only when
    #   POSTHOG_KEY is set;
    # - the self-hosted feedback survey (FeedbackHelper#feedback_config) on
    #   the shared public project, without POSTHOG_KEY, unless
    #   POSTHOG_FEEDBACK_ENABLED=false.
    # Hosts are added only when the matching integration renders, using the
    # same gates as the views, so the default policy stays as tight as
    # possible. Resolved per request (Rails instance_execs the proc in the
    # controller) so the gates are read the same way the views read them.
    # config/initializers/00_posthog.rb sets Rails.configuration.x.posthog —
    # the "00_" prefix forces it to load before this file (plain alphabetical
    # order would put "content_security_policy.rb" first and crash boot with
    # NoMethodError on nil).
    posthog_hosts = lambda do
      config = Rails.configuration.x.posthog
      # Same gate as FeedbackHelper#posthog_enabled?, which the head partial
      # and the feedback survey both check before rendering.
      next [] unless Rails.env.production? || (Rails.env.development? && config.development_enabled)

      hosts = []
      hosts << config.host if config.enabled
      if config.feedback_enabled && Rails.application.config.app_mode.self_hosted?
        hosts << config.self_hosted_feedback_project[:host]
      end
      hosts.uniq.flat_map { |host| [ host, host.sub(".i.posthog.com", "-assets.i.posthog.com") ] }.uniq
    end
    policy.script_src  :self, plaid_cdn_host, posthog_hosts
    policy.connect_src :self, *plaid_api_hosts, posthog_hosts
    # unsafe-inline is scoped to styles only, never scripts. Category/tag
    # colors are the only user-influenced values rendered into style="..."
    # attributes, and Category#color / Tag#color are validated server-side
    # against /\A#[0-9A-Fa-f]{6}\z/ (see app/models/category.rb,
    # app/models/tag.rb), so this can't be used to inject arbitrary CSS —
    # nonces don't cover inline style *attributes* (only <style> elements),
    # and this app relies on inline styles too heavily (D3 charts, dynamic
    # widget sizing) to refactor them all away in this change.
    policy.style_src :self, :unsafe_inline
    policy.object_src :none
    # Blocks a classic CSP bypass: an attacker-injected <base href="...">
    # tag would otherwise silently redirect every relative script/asset URL
    # (including importmap-resolved module specifiers) to an attacker origin.
    policy.base_uri :self
    # CSP's modern replacement for X-Frame-Options; kept even though Rails
    # already sends X-Frame-Options: SAMEORIGIN by default, since
    # frame-ancestors is what's actually enforced by current browsers and
    # supports non-SAMEORIGIN cases X-Frame-Options can't express.
    policy.frame_ancestors :self
  end

  # Every <script> element must carry this nonce to execute — an attacker
  # who injects a script tag via an XSS payload has no way to predict or
  # read it (Rails ties it to the session id; browsers also hide nonce
  # attributes from generic DOM access), so injected markup without the
  # nonce is simply not executed. Deliberately NOT applied to style-src:
  # nonces only cover <style> elements, not inline style="..." attributes,
  # so it would give no benefit there and just make it look like inline
  # styles need per-element upkeep they don't.
  config.content_security_policy_nonce_generator = ->(request) { request.session.id.to_s }
  config.content_security_policy_nonce_directives = %w[script-src]
end
