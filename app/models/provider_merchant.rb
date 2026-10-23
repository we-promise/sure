class ProviderMerchant < Merchant
  enum :source, { plaid: "plaid", simplefin: "simplefin", lunchflow: "lunchflow", akahu: "akahu", up: "up", monobank: "monobank", synth: "synth", ai: "ai", enable_banking: "enable_banking", coinstats: "coinstats", mercury: "mercury", brex: "brex", indexa_capital: "indexa_capital", sophtron: "sophtron", questrade: "questrade", redbark: "redbark", fio: "fio" }

  # Unlike FamilyMerchant, only fill a blank logo: providers such as Plaid or
  # CoinStats supply their own logo_url, which must not be replaced (issue #2925).
  before_save :generate_logo_url_from_website, if: :should_generate_logo?

  validates :name, uniqueness: { scope: [ :source ] }
  validates :source, presence: true

  def self.find_by_import_data(data, source)
    provider_merchant_id = data["provider_merchant_id"].presence
    by_provider_id = find_by(provider_merchant_id: provider_merchant_id, source: source) if provider_merchant_id
    by_provider_id || find_by(name: data["name"], source: source)
  end

  # color is not compared: ProviderMerchant does not support color.
  def import_diff(data)
    %w[website_url name provider_merchant_id].filter_map do |field|
      imported_value = data[field].presence
      next if imported_value.blank? || imported_value == self[field]

      { field: field, imported_value: imported_value, kept_value: self[field] }
    end
  end

  # ProviderMerchant does not support color. merchants.color is a legacy column from
  # when every merchant was family-owned, and FamilyMerchant is the only type that
  # uses it. It is switched off in three overlapping places, so no path can store or
  # show one for this type:
  #
  # ProviderMerchant does not support color: reads are always nil, so a stale value
  # on an old row never reaches a view, and writes are discarded.
  def color = nil

  def color=(_value)
    super(nil)
  end

  # ProviderMerchant does not support color: this clears a stale stored value so the
  # next save writes NULL (see NullProviderMerchantColors for the one-off cleanup).
  before_validation { self.color = nil }

  # ProviderMerchant does not support color: states the contract. It can't fail today,
  # because the accessors and the hook above have already discarded any value.
  validates :color, absence: true

  # Merchants that have a website but no logo, e.g. because the website arrived
  # from a provider or the LLM before Brandfetch was configured.
  scope :missing_logo, -> { where.not(website_url: [ nil, "" ]).where(logo_url: [ nil, "" ]) }

  # Generates Brandfetch logos for merchants in the current scope that have a
  # website but no logo. Needs no LLM. Returns the number of logos generated.
  def self.backfill_logos
    return 0 if Setting.brand_fetch_client_id.blank?

    missing_logo.find_each.count do |merchant|
      generated = false

      merchant.with_lock do
        if merchant.logo_url.blank?
          merchant.save!
          generated = merchant.logo_url.present?
        end
      end

      generated
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn("Failed to backfill logo for merchant #{merchant.id}: #{e.message}")
      false
    end
  end

  # Convert this ProviderMerchant to a FamilyMerchant for a specific family.
  # Only affects transactions belonging to that family.
  # Returns the newly created FamilyMerchant.
  def convert_to_family_merchant_for(family, attributes = {})
    transaction do
      # If the family already has a FamilyMerchant with this name, reuse it
      # instead of failing on the uniqueness validation.
      family_merchant, created = FamilyMerchant.find_or_create_with_name(
        family,
        attributes[:name].presence || name,
        color: attributes[:color].presence || FamilyMerchant::COLORS.sample,
        # A submitted blank website clears it; only an omitted one is inherited.
        website_url: attributes.key?(:website_url) ? attributes[:website_url].presence : website_url
      )

      # find_or_create_with_name doesn't touch a merchant it reused, so
      # explicitly submitted attributes still need applying here; omitted
      # ones leave the reused merchant untouched. A submitted website
      # (present or blank-to-clear) is honored; color can't be cleared
      # (FamilyMerchant requires it), so only a non-blank submission applies.
      if !created
        reuse_updates = {}
        reuse_updates[:website_url] = attributes[:website_url].presence if attributes.key?(:website_url)
        reuse_updates[:color] = attributes[:color] if attributes[:color].present?
        family_merchant.update!(reuse_updates) if reuse_updates.any?
      end

      scope = family.transactions.where(merchant_id: id)

      # Protect the manual reassignment from being reverted on the next
      # provider sync (issue #1977). Must run before the merchant_id update.
      Entry.mark_user_modified_for_transactions!(scope)

      # Update only this family's transactions to point to new merchant
      scope.update_all(merchant_id: family_merchant.id)

      family_merchant
    end
  end

  # Generate logo URL from website_url using BrandFetch, if configured.
  # Only refreshes or clears a logo generated here: a provider-supplied logo
  # (Plaid, CoinStats) must not be replaced (issue #2925), while a Brandfetch
  # logo must follow the website it was derived from.
  def generate_logo_url_from_website!
    return unless logo_url.blank? || brandfetch_logo?

    if website_url.present? && Setting.brand_fetch_client_id.present?
      update!(logo_url: brandfetch_logo_url)
    elsif website_url.blank?
      update!(logo_url: nil)
    end
  end

  # Unlink from family's transactions (set merchant_id to null).
  # Does NOT delete the ProviderMerchant since it may be used by other families.
  # Tracks the unlink in FamilyMerchantAssociation so it shows as "recently unlinked".
  def unlink_from_family(family)
    scope = family.transactions.where(merchant_id: id)

    # Protect the manual unlink from being reverted on the next provider sync
    # (issue #1977). Must run before the merchant_id is nulled.
    Entry.mark_user_modified_for_transactions!(scope)

    scope.update_all(merchant_id: nil)

    # Track that this merchant was unlinked from this family
    association = FamilyMerchantAssociation.find_or_initialize_by(family: family, merchant: self)
    association.update!(unlinked_at: Time.current)
  end

  private

    def should_generate_logo?
      website_url.present? && logo_url.blank?
    end

    def generate_logo_url_from_website
      self.logo_url = brandfetch_logo_url
    end

    # Ties ownership to our own Brandfetch account id, not just the CDN host,
    # so a provider-supplied logo that merely happens to be hosted on
    # cdn.brandfetch.io (e.g. under the provider's own account) is never
    # mistaken for one this app generated.
    def brandfetch_logo?
      client_id = Setting.brand_fetch_client_id
      return false if client_id.blank?

      logo_url.to_s.start_with?("https://cdn.brandfetch.io/") && logo_url.include?("?c=#{client_id}")
    end

    def brandfetch_logo_url
      return nil if website_url.blank?

      Setting.brand_fetch_icon_url(extract_domain(website_url))
    end

    def extract_domain(url)
      normalized_url = url.start_with?("http://", "https://") ? url : "https://#{url}"
      URI.parse(normalized_url).host&.sub(/\Awww\./, "")
    rescue URI::InvalidURIError
      url.sub(/\Awww\./, "")
    end
end
