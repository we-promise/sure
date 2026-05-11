class FamilyMerchant < Merchant
  COLORS = %w[#e99537 #4da568 #6471eb #db5a54 #df4e92 #c44fe9 #eb5429 #61c9ea #805dee #6ad28a]

  belongs_to :family

  before_validation :set_default_color
  before_save :generate_logo_url_from_website, if: :should_generate_logo?

  validates :color, presence: true
  validates :name, uniqueness: { scope: :family }

  def self.default_color
    COLORS.first
  end

  private
    def set_default_color
      self.color = self.class.default_color if color.blank?
    end

    def should_generate_logo?
      website_url_changed? || (website_url.present? && logo_url.blank?)
    end

    def generate_logo_url_from_website
      if website_url.present?
        self.logo_url = Merchant.brandfetch_logo_url_for(website_url)
      else
        self.logo_url = nil
      end
    end
end
