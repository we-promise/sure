# Fills in the merchant of a family's transactions from their descriptions: a merchant the family
# already has, a shared provider merchant with the same website, or a new family merchant. The
# requester of :detect_merchants: Ai::GenerationJob runs it one batch at a time.
class Family::AutoMerchantDetector
  include Ai::Requester
  include RuleRun::AiProgress
  ai_feature :detect_merchants

  def self.from_ai_job(ids:, family_id:, rule_run_id: nil)
    new(Family.find(family_id), transaction_ids: ids, rule_run: (RuleRun.find_by(id: rule_run_id) if rule_run_id))
  end

  def initialize(family, transaction_ids: [], rule_run: nil)
    @family = family
    @transaction_ids = transaction_ids
    @rule_run = rule_run
  end

  def ai_generation
    if scope.none?
      Rails.logger.info("No transactions to auto-detect merchants for family #{family.id}")
      return
    end

    Rails.logger.info("Auto-detecting merchants for #{scope.count} transactions for family #{family.id}")
    Ai::Generations::DetectMerchants.new(transactions: transactions_input, merchants: user_merchants_input, family:)
  end

  def apply_ai(result)
    detections = result.value[:merchants].index_by { _1[:transaction_id] }
    modified_count = 0

    scope.each do |transaction|
      auto_detection = detections[transaction.id]
      next unless auto_detection&.dig(:business_name).present? && auto_detection&.dig(:business_url).present?

      existing_merchant = transaction.merchant

      if existing_merchant.nil?
        # Case 1: No merchant - create/find AI merchant and assign
        merchant_id = find_matching_user_merchant(auto_detection)
        merchant_id ||= find_or_create_ai_merchant(auto_detection)&.id

        if merchant_id.present?
          was_modified = transaction.enrich_attribute(:merchant_id, merchant_id, source: "ai")
          transaction.lock_attr!(:merchant_id)
          modified_count += 1 if was_modified
        end

      elsif existing_merchant.is_a?(ProviderMerchant) && existing_merchant.source != "ai"
        # Case 2: Has provider merchant (non-AI) - enhance it with AI data
        if enhance_provider_merchant(existing_merchant, auto_detection)
          transaction.lock_attr!(:merchant_id)
          modified_count += 1
        end
      end
      # Case 3: AI merchant or FamilyMerchant - skip (already good or user-set)
    end

    report_batch(result, modified: modified_count)
    modified_count
  end

  # The modified counts reached the run per batch (apply_ai); this releases the rest.
  def ai_finished(_count)
    release_unhandled
    @rule_run&.complete_job!
  end

  def ai_failed(error)
    release_unhandled
    @rule_run&.fail_job!(error:, source: self.class.name, transaction_ids:)
    DebugLogEntry.capture(
      category: "merchant_detection", level: "error", message: "AI merchant detection failed",
      source: self.class.name, family:,
      metadata: { error_class: error.class.name, error_message: error.message.truncate(500), requested_transaction_ids: transaction_ids }
    )
  end

  private
    attr_reader :family, :transaction_ids

    def user_merchants_input
      @user_merchants_input ||= family.merchants.map do |merchant|
        {
          id: merchant.id,
          name: merchant.name
        }
      end
    end

    def transactions_input
      scope.map do |transaction|
        {
          id: transaction.id,
          amount: transaction.entry.amount.abs,
          classification: transaction.entry.classification,
          description: [ transaction.entry.name, transaction.entry.notes ].compact.reject(&:empty?).join(" "),
          merchant: transaction.merchant&.name
        }
      end
    end

    def scope
      family.transactions.where(id: transaction_ids)
                         .enrichable(:merchant_id)
                         .includes(:merchant, :entry)
    end

    def find_matching_user_merchant(auto_detection)
      user_merchants_input.find { |m| m[:name] == auto_detection[:business_name] }&.dig(:id)
    end

    def find_or_create_ai_merchant(auto_detection)
      # Strategy 1: Find an existing merchant by website_url (most reliable for
      # deduplication). Provider-sourced merchants (Plaid etc.) are vetted
      # shared data and stay reusable across families. AI-sourced ones were
      # created from some family's own transaction text (before #3842), so
      # they're only reused when already assigned to this family — otherwise
      # another family's crafted name/logo would surface here.
      if auto_detection[:business_url].present?
        existing = reusable_provider_merchants.find_by(website_url: auto_detection[:business_url])
        return existing if existing
      end

      # Strategy 2: Find an AI-sourced merchant by exact name match, limited
      # to the ones this family already uses (see Strategy 1).
      existing = family_ai_provider_merchants.find_by(name: auto_detection[:business_name])
      return existing if existing

      # Strategy 3: no shared merchant to reuse. Create a merchant scoped to
      # this family rather than a globally-shared ProviderMerchant, so a
      # family can't use LLM-extracted data derived from its own transaction
      # description/notes to create a record visible to every other family
      # (issue #3842).
      merchant, _created = FamilyMerchant.find_or_create_with_name(
        family,
        auto_detection[:business_name],
        website_url: auto_detection[:business_url]
      )
      merchant
    rescue ActiveRecord::RecordInvalid => e
      # A name the model rejects (e.g. the reserved Merchant::NO_MERCHANT_FILTER_VALUE)
      # leaves this transaction without a merchant, as before, instead of
      # failing the whole detection batch. The name itself isn't logged since
      # it's derived from the family's transaction text.
      Rails.logger.warn("Skipping invalid AI-detected merchant for family #{family.id}: #{e.record.errors.attribute_names.join(', ')}")
      nil
    end

    def family_ai_provider_merchants
      ProviderMerchant.where(source: "ai", id: family.transactions.select(:merchant_id))
    end

    def reusable_provider_merchants
      ProviderMerchant.where.not(source: "ai").or(family_ai_provider_merchants)
    end

    def enhance_provider_merchant(merchant, auto_detection)
      updates = {}

      # Add website_url if missing. ProviderMerchant fills a blank logo from it
      # and keeps a provider-supplied one (issue #2925).
      if merchant.website_url.blank? && auto_detection[:business_url].present?
        updates[:website_url] = auto_detection[:business_url]
      end

      return false if updates.empty?

      merchant.update!(updates)
      true
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("Failed to enhance merchant #{merchant.id}: #{e.message}")
      false
    end
end
