# Dev-only adjustments for GitHub Codespaces
if Rails.env.development? && ENV["CODESPACES"] == "true"
  # Example: forwarded URLs like https://<repo>-<user>-<port>.app.github.dev
  forwarding_domain = ENV["GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN"] # typically "app.github.dev"

  # Append allowed hosts ONLY if Host Authorization is enabled (config.hosts is an Array).
  # If it's nil, Host Authorization is disabled and we leave it alone.
  if Rails.application.config.hosts.is_a?(Array)
    if forwarding_domain.present?
      Rails.application.config.hosts << /\A.*\.#{Regexp.escape(forwarding_domain)}\z/
    end
    # Older/alternative preview domain
    Rails.application.config.hosts << /\A.*\.githubpreview\.dev\z/
  end

  # If you use the VS Code "Preview" (iframe), you need SameSite=None; Secure
  # Codespaces serves over HTTPS, so secure: true is OK here.
  Rails.application.config.session_store :cookie_store,
    key: "_app_session",
    same_site: :none,
    secure: true

  # The Codespaces proxy can preserve an https://localhost:<port> browser Origin
  # while forwarding the request under its public app.github.dev host. The
  # controller accepts only that exact development-only pairing; normal CSRF
  # token and origin validation remain enabled for every other request.
end
