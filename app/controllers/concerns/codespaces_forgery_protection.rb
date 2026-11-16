module CodespacesForgeryProtection
  private
    def valid_request_origin?
      super || codespaces_local_preview_origin?
    end

    def codespaces_local_preview_origin?
      return false unless Rails.env.development? && ENV["CODESPACES"] == "true"

      forwarding_domain = ENV["GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN"].to_s.downcase
      codespace_name = ENV["CODESPACE_NAME"].to_s.downcase
      port = ENV.fetch("PORT", 3000).to_i
      forwarded_host = "#{codespace_name}-#{port}.#{forwarding_domain}"
      return false if forwarding_domain.blank? || codespace_name.blank?
      return false unless request.ssl? && request.host.downcase == forwarded_host

      origin = URI.parse(request.origin.to_s)
      origin.scheme == "https" && origin.host == "localhost" && origin.port == port
    rescue URI::InvalidURIError
      false
    end
end
