class Merchant < ApplicationRecord
  TYPES = %w[FamilyMerchant ProviderMerchant].freeze

  has_many :transactions, dependent: :nullify
  has_many :recurring_transactions, dependent: :destroy

  validates :name, presence: true
  validates :type, inclusion: { in: TYPES }

  scope :alphabetically, -> { order(:name) }

  class << self
    def extract_domain(url)
      return nil if url.blank?

      normalized_url = url.to_s.strip
      normalized_url = "https://#{normalized_url}" unless normalized_url.match?(/\Ahttps?:\/\//i)
      normalize_domain(URI.parse(normalized_url).host)
    rescue URI::InvalidURIError
      sanitized_domain_from(url)
    end

    def brandfetch_logo_url_for(url, logo_size: Setting.brand_fetch_logo_size, client_id: Setting.brand_fetch_client_id)
      domain = extract_domain(url)
      return nil unless domain.present? && client_id.present?

      size = logo_size.presence || Setting::BRAND_FETCH_LOGO_SIZE_STANDARD
      encoded_domain = URI.encode_www_form_component(domain)
      "https://cdn.brandfetch.io/#{encoded_domain}/icon/fallback/lettermark/" \
        "w/#{size}/h/#{size}?c=#{client_id}"
    end

    private
      def normalize_domain(domain)
        domain = domain.to_s.strip.sub(/\Awww\./i, "").downcase
        return nil unless valid_domain?(domain)

        domain
      end

      def valid_domain?(domain)
        labels = domain.split(".")

        domain.present? &&
          domain != "localhost" &&
          labels.length >= 2 &&
          labels.last.match?(/[a-z]/i) &&
          labels.all? { |label| label.match?(/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/i) }
      end

      def sanitized_domain_from(url)
        domain = url.to_s.strip
          .sub(/\Ahttps?:\/\//i, "")
          .split(/[\/:?#]/, 2)
          .first
          .to_s

        normalize_domain(domain)
      end
  end
end
