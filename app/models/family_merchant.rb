class FamilyMerchant < Merchant
  COLORS = %w[#e99537 #4da568 #6471eb #db5a54 #df4e92 #c44fe9 #eb5429 #61c9ea #805dee #6ad28a]

  belongs_to :family

  attr_accessor :remove_logo_image

  before_validation :set_default_color
  before_save :generate_logo_url_from_website, if: :should_generate_logo?
  normalizes :website_url, with: ->(url) { url.to_s.strip.presence }

  validates :color, presence: true, format: { with: /\A#[0-9A-Fa-f]{6}\z/ }
  validates :name, uniqueness: { scope: %i[family_id website_url] }
  validate :logo_image_type_and_size

  private
    def set_default_color
      self.color = COLORS.sample unless valid_hex_color?
    end

    def logo_image_type_and_size
      return unless logo_image.attached?

      unless logo_image.content_type.in?(%w[image/png image/jpeg image/webp])
        errors.add(:logo_image, "must be a PNG, JPEG, or WebP image")
      end

      if logo_image.byte_size > 5.megabytes
        errors.add(:logo_image, "must be 5 MB or smaller")
      end
    end

    def valid_hex_color?
      color.present? && color.match?(/\A#[0-9A-Fa-f]{6}\z/)
    end

    def should_generate_logo?
      (website_url_changed? && (!new_record? || logo_url.blank?)) || (website_url.present? && logo_url.blank?)
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
