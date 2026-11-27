# Fills in the website of a family's provider merchants that have none, so ProviderMerchant can
# generate their logos, and merges duplicates that turn out to share a website. The requester of
# :enhance_merchants: Ai::GenerationJob runs it one batch at a time.
class ProviderMerchant::Enhancer
  include Ai::Requester
  ai_feature :enhance_merchants

  # Held from the click until the run finishes or gives up, so a second click doesn't queue the
  # same merchants again. Each batch renews it, so a long run keeps it; one that dies without
  # giving up frees it after this long.
  LOCK_TTL = 10.minutes

  def self.lock_key(family) = "enhance_provider_merchants:#{family.id}"

  # The family's provider merchants without a website: the ones a run asks the AI about.
  def self.unenhanced(family) = family.assigned_merchants.where(type: "ProviderMerchant").where(website_url: [ nil, "" ])

  # Queues a run over the merchants that lack a website now, unless one is already going. Returns
  # false when one is.
  def self.enhance_later(family)
    return false unless Rails.cache.write(lock_key(family), true, expires_in: LOCK_TTL, unless_exist: true)

    # A run that never starts must not hold the lock until it expires.
    queued = false
    begin
      queued = Ai::GenerationRun.enqueue(:enhance_merchants, family:, ids: unenhanced(family).pluck(:id))
    rescue StandardError
      # A queue adapter raises its own errors (Redis down); the caller handles one kind.
      raise ActiveJob::EnqueueError, "the merchant enhancement couldn't be queued"
    ensure
      Rails.cache.delete(lock_key(family)) unless queued
    end
    raise ActiveJob::EnqueueError, "the merchant enhancement couldn't be queued" unless queued

    true
  end

  def self.from_ai_job(window:, family_id:) = new(Family.find(family_id), window:)

  # window: this job's share of the run; without one, every merchant the family has without a website.
  def initialize(family, window: nil)
    @family = family
    @window = window
  end

  def ai_generation
    hold_lock
    # The run's first job backfills logos before any AI: generating a logo from a known website
    # needs no model, and merchants that already have a website are never sent (issue #2925).
    @family.backfill_provider_merchant_logos if @window.nil? || @window.first?
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
      next if url.blank? || merchant.nil?

      # Provider merchants are shared, so another family's run may save a website at the same time:
      # the row lock (with_lock reloads under it) lets one write it, and the other keeps that website
      # and still merges its own family's duplicates with it. Together, so a merge that fails leaves
      # the website unset and the merchant in the retry's batch. ProviderMerchant generates the
      # Brandfetch logo itself, keeping a provider-supplied one.
      saved = nil
      merchant.with_lock do
        saved = merchant.website_url.presence
        merchant.update!(website_url: url) unless saved
        deduplicated += deduplicate_by_website(merchant, saved || url)
      end
      enhanced += 1 unless saved
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("Failed to enhance merchant #{merchant&.id}: #{e.message}")
    end

    Rails.logger.info("Enhanced #{enhanced} merchants, deduplicated #{deduplicated} for family #{@family.id}")
    hold_lock   # the next batch may wait in the queue
    enhanced
  end

  # Called inside the job's transaction that ends the run: the lock goes once that commits.
  def ai_finished(_count) = release_lock_after_commit

  def ai_failed(error)
    release_lock_after_commit
    DebugLogEntry.capture(
      category: "merchant_enhancement", level: "error", message: "AI merchant enhancement failed",
      source: self.class.name, family: @family,
      metadata: { error_class: error.class.name, error_message: error.message.truncate(500), merchant_ids: @window&.examined_ids,
                  outstanding_count: @window&.outstanding }.compact
    )
  end

  def ai_correlation_id = "family:#{@family.id}:enhance_merchants"

  private
    # The window's merchants that another family's run gave a website since this run queued them:
    # they're no longer sent to the AI, so this family's duplicates are merged with that website here.
    def merge_websites_saved_since(ids)
      @family.assigned_merchants.where(type: "ProviderMerchant", id: ids).where.not(website_url: [ nil, "" ]).each do |merchant|
        merchant.with_lock { deduplicate_by_website(merchant, merchant.website_url) }
      end
    end

    def hold_lock = Rails.cache.write(self.class.lock_key(@family), true, expires_in: LOCK_TTL)

    def release_lock_after_commit
      key = self.class.lock_key(@family)
      ActiveRecord.after_all_transactions_commit { Rails.cache.delete(key) }
    end

    def deduplicate_by_website(target_merchant, website_url)
      # Read under the lock, and another writer may have cleared it: a blank website would match
      # every merchant that has none.
      return 0 if website_url.blank?

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
      @unenhanced_merchants ||=
        if @window
          ids = @window.take_matching { |chunk| self.class.unenhanced(@family).where(id: chunk).pluck(:id) }
          merge_websites_saved_since(@window.examined_ids - ids)
          self.class.unenhanced(@family).where(id: ids).in_order_of(:id, ids).to_a
        else
          self.class.unenhanced(@family).to_a
        end
    end
end
