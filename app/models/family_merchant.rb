class FamilyMerchant < Merchant
  COLORS = %w[#e99537 #4da568 #6471eb #db5a54 #df4e92 #c44fe9 #eb5429 #61c9ea #805dee #6ad28a]
  LOGO_CONTENT_TYPES = %w[image/jpeg image/png image/webp].freeze
  LOGO_MAX_SIZE = 5.megabytes

  belongs_to :family

  attribute :remove_logo, :boolean, default: false

  before_validation :set_default_color
  before_save :generate_logo_url_from_website, if: :should_generate_logo?
  after_save :purge_logo, if: -> { remove_logo && !attachment_changes.key?("logo") }

  validates :color, presence: true, format: { with: /\A#[0-9A-Fa-f]{6}\z/ }
  validates :name, uniqueness: { scope: :family }
  validate :logo_is_small_image, if: -> { logo.attached? }

  # Reuses a family's existing merchant of this name instead of raising on the
  # uniqueness validation, and survives a concurrent create for the same name
  # (e.g. two imports, or an import racing a manual edit) landing on the
  # database's unique index first. Returns [merchant, created?].
  def self.find_or_create_with_name(family, name, **attributes)
    existing = family.merchants.find_by(name: name)
    return [ existing, false ] if existing

    begin
      # requires_new: true opens a savepoint, so a RecordNotUnique here rolls
      # back only the failed insert. Without it, Postgres aborts the whole
      # enclosing transaction and the rescue's find_by! below would also fail.
      merchant = transaction(requires_new: true) { family.merchants.create!(attributes.merge(name: name)) }
      [ merchant, true ]
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      raise if e.is_a?(ActiveRecord::RecordInvalid) && !e.record.errors.of_kind?(:name, :taken)
      [ family.merchants.find_by!(name: name), false ]
    end
  end

  def logo_url
    return super unless logo.attached?

    Rails.application.routes.url_helpers.rails_representation_path(logo.variant(:small), only_path: true)
  end

  private
    def purge_logo
      logo.purge_later
      self.remove_logo = false
    end

    def logo_is_small_image
      unless logo.content_type.in?(LOGO_CONTENT_TYPES)
        errors.add(:logo, :invalid_content_type)
      end

      if logo.byte_size > LOGO_MAX_SIZE
        errors.add(:logo, :invalid_file_size, max_megabytes: LOGO_MAX_SIZE / 1.megabyte)
      end
    end

    def set_default_color
      self.color = COLORS.sample unless valid_hex_color?
    end

    def valid_hex_color?
      color.present? && color.match?(/\A#[0-9A-Fa-f]{6}\z/)
    end

    def should_generate_logo?
      website_url_changed? || (website_url.present? && self[:logo_url].blank?)
    end

    def generate_logo_url_from_website
      if website_url.present? && Setting.brand_fetch_client_id.present?
        self.logo_url = Setting.brand_fetch_icon_url(extract_domain(website_url))
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
