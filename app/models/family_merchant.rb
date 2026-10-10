class FamilyMerchant < Merchant
  COLORS = %w[#e99537 #4da568 #6471eb #db5a54 #df4e92 #c44fe9 #eb5429 #61c9ea #805dee #6ad28a]

  belongs_to :family

  before_validation :set_default_color
  before_save :generate_logo_url_from_website, if: :should_generate_logo?

  validates :color, presence: true, format: { with: /\A#[0-9A-Fa-f]{6}\z/ }
  validates :name, uniqueness: { scope: :family }
  # Mirrors the DB-level partial unique index (family_id, iban). Without
  # this, Account::ProviderImportAdapter#find_or_create_merchant's
  # family-merchant lookup by IBAN could match an unspecified one of two
  # duplicates, silently assigning a transaction to the wrong merchant.
  validates :iban, uniqueness: { scope: :family }, allow_nil: true

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

  private
    def set_default_color
      self.color = COLORS.sample unless valid_hex_color?
    end

    def valid_hex_color?
      color.present? && color.match?(/\A#[0-9A-Fa-f]{6}\z/)
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
