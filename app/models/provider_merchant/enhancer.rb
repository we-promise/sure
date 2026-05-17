class ProviderMerchant::Enhancer
  BATCH_SIZE = 25

  def initialize(family)
    @family = family
  end

  def enhance
    return { enhanced: 0, deduplicated: 0 } unless llm_provider
    return { enhanced: 0, deduplicated: 0 } if unenhanced_merchants.none?

    Rails.logger.info("Enhancing #{unenhanced_merchants.count} provider merchants for family #{@family.id}")

    enhanced_count = 0
    deduplicated_count = 0

    unenhanced_merchants.each_slice(BATCH_SIZE) do |batch|
      result = llm_provider.enhance_provider_merchants(
        merchants: batch.map { |m| { id: m.id, name: m.name } },
        family: @family,
        model: Provider::Openai.effective_background_model
      )

      next unless result.success?

      result.data.each do |enhancement|
        next unless enhancement.business_url.present?

        merchant = batch.find { |m| m.id == enhancement.merchant_id }
        next unless merchant
        next if merchant.website_url.present? # Skip if already enhanced (race condition guard)

        # Step 1: Update the provider merchant with website + logo
        updates = { website_url: enhancement.business_url }
        updates[:logo_url] = build_logo_url(enhancement.business_url) if Setting.brand_fetch_client_id.present?
        merchant.update!(updates)
        enhanced_count += 1

        # Step 2: Deduplicate — find other merchants with the same website_url
        # and merge them INTO this provider merchant (prefer provider over AI)
        deduplicated_count += deduplicate_by_website(merchant, enhancement.business_url)
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.error("Failed to enhance merchant #{merchant.id}: #{e.message}")
      end
    end

    Rails.logger.info("Enhanced #{enhanced_count} merchants, deduplicated #{deduplicated_count} for family #{@family.id}")

    { enhanced: enhanced_count, deduplicated: deduplicated_count }
  end

  private

    def deduplicate_by_website(target_merchant, website_url)
      # Find duplicate provider merchants assigned to this family with the same website_url.
      # Excludes FamilyMerchants — user-curated merchants should never be touched by dedup.
      duplicates = @family.assigned_merchants
                          .where(type: "ProviderMerchant")
                          .where(website_url: website_url)
                          .where.not(id: target_merchant.id)

      return 0 if duplicates.none?

      count = 0
      duplicates.each do |duplicate|
        # Reassign family's transactions from duplicate to target
        @family.transactions.where(merchant_id: duplicate.id)
               .update_all(merchant_id: target_merchant.id)
        count += 1
      end
      count
    end

    def llm_provider
      @llm_provider ||= Provider::Registry.get_provider(:openai)
    end

    def unenhanced_merchants
      @unenhanced_merchants ||= @family.assigned_merchants
                                       .where(type: "ProviderMerchant")
                                       .where(website_url: [ nil, "" ])
                                       .to_a
    end

    def build_logo_url(business_url)
      return nil unless Setting.brand_fetch_client_id.present? && business_url.present?
      domain = extract_domain(business_url)
      return nil unless domain.present?
      size = Setting.brand_fetch_logo_size
      "https://cdn.brandfetch.io/#{domain}/icon/fallback/lettermark/w/#{size}/h/#{size}?c=#{Setting.brand_fetch_client_id}"
    end

    def extract_domain(url)
      normalized_url = url.start_with?("http://", "https://") ? url : "https://#{url}"
      URI.parse(normalized_url).host&.sub(/\Awww\./, "")
    rescue URI::InvalidURIError
      url.sub(/\Awww\./, "")
    end
end
