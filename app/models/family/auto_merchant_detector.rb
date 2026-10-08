class Family::AutoMerchantDetector
  Error = Class.new(StandardError)

  def initialize(family, transaction_ids: [])
    @family = family
    @transaction_ids = transaction_ids
  end

  def auto_detect
    raise "No LLM provider for auto-detecting merchants" unless llm_provider

    if scope.none?
      Rails.logger.info("No transactions to auto-detect merchants for family #{family.id}")
      return 0
    else
      Rails.logger.info("Auto-detecting merchants for #{scope.count} transactions for family #{family.id}")
    end

    result = llm_provider.auto_detect_merchants(
      transactions: transactions_input,
      user_merchants: user_merchants_input,
      family: family
    )

    unless result.success?
      Rails.logger.error("Failed to auto-detect merchants for family #{family.id}: #{result.error.message}")
      return 0
    end

    modified_count = 0
    scope.each do |transaction|
      auto_detection = result.data.find { |c| c.transaction_id == transaction.id }
      next unless auto_detection&.business_name.present? && auto_detection&.business_url.present?

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

    modified_count
  end

  private
    attr_reader :family, :transaction_ids

    # Honors Setting.llm_provider (issue #2113) — Provider::Anthropic implements
    # auto_detect_merchants (PR #1984), so batch merchant detection routes to the
    # configured provider, with fallback handled by
    # Provider::Registry.preferred_llm_provider.
    def llm_provider
      Provider::Registry.preferred_llm_provider
    end

    def default_logo_provider_url
      "https://cdn.brandfetch.io"
    end

    def user_merchants_input
      family.merchants.map do |merchant|
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
      user_merchants_input.find { |m| m[:name] == auto_detection.business_name }&.dig(:id)
    end

    def find_or_create_ai_merchant(auto_detection)
      # Strategy 1: Find an existing merchant by website_url (most reliable for
      # deduplication). Reusing an already-vetted shared merchant is safe —
      # unlike creating one, it doesn't let this family's transaction text
      # write anything into a record other families see.
      if auto_detection.business_url.present?
        existing = ProviderMerchant.find_by(website_url: auto_detection.business_url)
        return existing if existing
      end

      # Strategy 2: Find an existing AI-sourced merchant by exact name match.
      existing = ProviderMerchant.find_by(source: "ai", name: auto_detection.business_name)
      return existing if existing

      # Strategy 3: no shared merchant to reuse. Create a merchant scoped to
      # this family rather than a globally-shared ProviderMerchant, so a
      # family can't use LLM-extracted data derived from its own transaction
      # description/notes to create a record visible to every other family
      # (issue #3842).
      merchant, _created = FamilyMerchant.find_or_create_with_name(
        family,
        auto_detection.business_name,
        website_url: auto_detection.business_url
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

    def enhance_provider_merchant(merchant, auto_detection)
      updates = {}

      # Add website_url if missing
      if merchant.website_url.blank? && auto_detection.business_url.present?
        updates[:website_url] = auto_detection.business_url

        # Add logo if BrandFetch is configured
        if Setting.brand_fetch_client_id.present?
          size = Setting.brand_fetch_logo_size
          updates[:logo_url] = "#{default_logo_provider_url}/#{auto_detection.business_url}/icon/fallback/lettermark/w/#{size}/h/#{size}?c=#{Setting.brand_fetch_client_id}"
        end
      end

      return false if updates.empty?

      merchant.update!(updates)
      true
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("Failed to enhance merchant #{merchant.id}: #{e.message}")
      false
    end
end
