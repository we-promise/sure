# Module for providers that provide institution/bank metadata
# Include this module in your adapter if the provider returns institution information
module Provider::InstitutionMetadata
  extend ActiveSupport::Concern

  # Returns the institution's domain (e.g., "chase.com")
  # @return [String, nil] The institution domain or nil if not available
  def institution_domain
    nil
  end

  # Returns the institution's display name (e.g., "Chase Bank")
  # @return [String, nil] The institution name or nil if not available
  def institution_name
    nil
  end

  # Returns the institution's website URL
  # @return [String, nil] The institution URL or nil if not available
  def institution_url
    nil
  end

  # Returns the institution's brand color (for UI purposes)
  # @return [String, nil] The hex color code or nil if not available
  def institution_color
    nil
  end

  # Returns the institution/account logo URL (direct image URL)
  # @return [String, nil] The logo URL or nil if not available
  def logo_url
    nil
  end

  # Returns a hash of all institution metadata
  # @return [Hash] Hash containing institution metadata
  def institution_metadata
    {
      domain: institution_domain,
      name: institution_name,
      url: institution_url,
      color: institution_color,
      logo_url: logo_url
    }.compact
  end
end
