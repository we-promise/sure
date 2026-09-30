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

      end
      # Existing family merchants are user-editable and are left as-is.
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
      # Strategy 1: Find existing merchant by website_url (most reliable for deduplication)
      if auto_detection.business_url.present?
        existing = family.merchants.find_by(
          name: auto_detection.business_name,
          website_url: auto_detection.business_url
        )
        return existing if existing
      end

      # Strategy 2: Find by exact name when no website is available.
      existing = family.merchants.find_by(name: auto_detection.business_name, website_url: nil)
      return existing if existing

      # Provider and AI enrichment both land on the family's single merchant type.
      family.merchants.create!(
        name: auto_detection.business_name,
        website_url: auto_detection.business_url,
        logo_url: build_logo_url(auto_detection.business_url)
      )
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      # Race condition: another process created the same family merchant.
      family.merchants.find_by!(name: auto_detection.business_name, website_url: auto_detection.business_url)
    end

    def build_logo_url(business_url)
      return nil unless Setting.brand_fetch_client_id.present? && business_url.present?
      size = Setting.brand_fetch_logo_size
      "#{default_logo_provider_url}/#{business_url}/icon/fallback/lettermark/w/#{size}/h/#{size}?c=#{Setting.brand_fetch_client_id}"
    end

end
