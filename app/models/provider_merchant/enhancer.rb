# Fills in the website of a family's provider merchants that have none, so ProviderMerchant can
# generate their logos, and merges duplicates that turn out to share a website. The requester of
# :enhance_merchants: Ai::GenerationJob runs it one batch at a time.
class ProviderMerchant::Enhancer
  include Ai::Requester
  ai_feature :enhance_merchants

  # Set by FamilyMerchantsController#enhance so a second click doesn't queue the same merchants
  # again; released when the run finishes or gives up.
  LOCK_TTL = 10.minutes

  def self.lock_key(family) = "enhance_provider_merchants:#{family.id}"

  def self.enhance_later(family) = Ai::GenerationJob.perform_later(:enhance_merchants, { family_id: family.id })

  # ids: the merchants left from an earlier batch; nil on the first job, which starts the run.
  def self.from_ai_job(family_id:, ids: nil) = new(Family.find(family_id), merchant_ids: ids)

  def initialize(family, merchant_ids: nil)
    @family = family
    @merchant_ids = merchant_ids
  end

  def ai_generation
    # The run's first job backfills logos before any AI: generating a logo from a known website
    # needs no model, and merchants that already have a website are never sent (issue #2925).
    @family.backfill_provider_merchant_logos if @merchant_ids.nil?
    return if unenhanced_merchants.empty?

    Rails.logger.info("Enhancing #{unenhanced_merchants.size} provider merchants for family #{@family.id}")
    Ai::Generations::EnhanceMerchants.new(merchants: unenhanced_merchants.map { { id: _1.id, name: _1.name } }, family: @family)
  end

  def apply_ai(result)
    merchants = unenhanced_merchants.index_by(&:id)
    enhanced = 0
    deduplicated = 0

    result.value[:merchants].each do |enhancement|
      url = enhancement[:business_url]
      merchant = merchants[enhancement[:merchant_id]]
      next if url.blank? || merchant.nil? || merchant.reload.website_url.present?   # reload: a race with another run

      # ProviderMerchant generates the Brandfetch logo itself, keeping a provider-supplied one.
      merchant.update!(website_url: url)
      enhanced += 1
      deduplicated += deduplicate_by_website(merchant, url)
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("Failed to enhance merchant #{merchant&.id}: #{e.message}")
    end

    Rails.logger.info("Enhanced #{enhanced} merchants, deduplicated #{deduplicated} for family #{@family.id}")
    enhanced
  end

  def ai_finished(_count) = Rails.cache.delete(self.class.lock_key(@family))

  def ai_failed(error)
    Rails.cache.delete(self.class.lock_key(@family))
    DebugLogEntry.capture(
      category: "merchant_enhancement", level: "error", message: "AI merchant enhancement failed",
      source: self.class.name, family: @family,
      metadata: { error_class: error.class.name, error_message: error.message.truncate(500), merchant_ids: @merchant_ids }.compact
    )
  end

  def ai_correlation_id = "family:#{@family.id}:enhance_merchants"

  private
    def deduplicate_by_website(target_merchant, website_url)
      # Duplicate provider merchants assigned to this family with the same website. Family
      # merchants are user-curated and never touched by dedup.
      duplicates = @family.assigned_merchants
                          .where(type: "ProviderMerchant")
                          .where(website_url: website_url)
                          .where.not(id: target_merchant.id)

      duplicates.each do |duplicate|
        @family.transactions.where(merchant_id: duplicate.id).update_all(merchant_id: target_merchant.id)
      end.size
    end

    def unenhanced_merchants
      @unenhanced_merchants ||= begin
        scope = @family.assigned_merchants.where(type: "ProviderMerchant").where(website_url: [ nil, "" ])
        scope = scope.where(id: @merchant_ids) if @merchant_ids
        scope.to_a
      end
    end
end
