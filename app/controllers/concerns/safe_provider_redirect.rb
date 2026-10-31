# Redirects the browser to a page a provider hands back (a consent dialog, a
# bank picker) only when that URL is HTTPS on a host the controller trusts, so
# a tampered or mistaken provider response can't send the user elsewhere.
# Each provider controller passes its own host list.
module SafeProviderRedirect
  extend ActiveSupport::Concern

  private
    def safe_redirect_to_provider(url, trusted_hosts:, fallback_path:, fallback_alert:, status: :found)
      if trusted_provider_url?(url, trusted_hosts)
        redirect_to url, allow_other_host: true, status: status
      else
        Rails.logger.warn("#{self.class.name} - redirect blocked, untrusted URL: #{url.to_s.inspect}")
        redirect_to fallback_path, alert: fallback_alert, status: status
      end
    end

    # True for an https URL whose host is one of the trusted hosts or a
    # subdomain of one. A look-alike such as "example.com.evil.test" is not.
    def trusted_provider_url?(url, trusted_hosts)
      uri = URI.parse(url.to_s)
      return false unless uri.scheme == "https" && uri.host.present?

      trusted_hosts.any? { |host| uri.host == host || uri.host.end_with?(".#{host}") }
    rescue URI::InvalidURIError
      false
    end
end
