class FamilyMerchant < Merchant
  COLORS = %w[#e99537 #4da568 #6471eb #db5a54 #df4e92 #c44fe9 #eb5429 #61c9ea #805dee #6ad28a]

  belongs_to :family

  before_validation :set_default_color
  before_save :generate_logo_url_from_website, if: :should_generate_logo?

  validates :color, presence: true
  validates :name, uniqueness: { scope: :family }

  private
    def set_default_color
      self.color = COLORS.sample
    end

    def should_generate_logo?
      website_url_changed? || (website_url.present? && logo_url.blank?)
    end

    def generate_logo_url_from_website
      if website_url.present? && Setting.brand_fetch_client_id.present?
        domain = extract_domain(website_url)
        size = Setting.brand_fetch_logo_size
        self.logo_url = "https://cdn.brandfetch.io/#{domain}/icon/fallback/lettermark/w/#{size}/h/#{size}?c=#{Setting.brand_fetch_client_id}"
      elsif website_url.blank?
        self.logo_url = nil
      end
    end

    def extract_domain(url)
      original_url = url
      normalized_url = url.start_with?("http://", "https://") ? url : "https://#{url}"
      URI.parse(normalized_url).host&.sub(/\Awww\./, "")
    rescue URI::InvalidURIError
      original_url.sub(/\Awww\./, "")
    end
end
