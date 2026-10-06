class FamilyMerchant::Enhancer
  BATCH_SIZE = 25

  def initialize(family)
    @family = family
  end

  def enhance
    return { enhanced: 0, deduplicated: 0 } unless llm_provider
    return { enhanced: 0, deduplicated: 0 } if unenhanced_merchants.none?

    Rails.logger.info("Enhancing #{unenhanced_merchants.count} family merchants for #{@family.name}")

    enhanced_count = 0
    deduplicated_count = 0

    unenhanced_merchants.each_slice(BATCH_SIZE) do |batch|
      result = llm_provider.enhance_merchants(
        merchants: batch.map { |merchant| { id: merchant.id, name: merchant.name } },
        family: @family
      )

      next unless result.success?

      result.data.each do |enhancement|
        next unless enhancement.business_url.present?

        merchant = batch.find { |candidate| candidate.id == enhancement.merchant_id }
        next unless merchant
        next if merchant.website_url.present?

        existing = @family.merchants.find_by(name: merchant.name, website_url: enhancement.business_url)
        if existing
          deduplicated_count += reassign_and_destroy(merchant, existing)
        else
          updates = { website_url: enhancement.business_url }
          updates[:logo_url] = build_logo_url(enhancement.business_url) if Setting.brand_fetch_client_id.present?
          merchant.update!(updates)
          enhanced_count += 1
        end
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.error("Failed to enhance merchant #{merchant&.id}: #{e.message}")
      end
    end

    Rails.logger.info("Enhanced #{enhanced_count} merchants, deduplicated #{deduplicated_count} for family #{@family.id}")
    { enhanced: enhanced_count, deduplicated: deduplicated_count }
  end

  private

    def reassign_and_destroy(source, target)
      transaction_scope = @family.transactions.where(merchant_id: source.id)
      Entry.mark_user_modified_for_transactions!(transaction_scope)
      transaction_scope.update_all(merchant_id: target.id)
      @family.recurring_transactions.where(merchant_id: source.id).update_all(merchant_id: target.id)
      source.destroy!
      1
    end

    def llm_provider
      @llm_provider ||= Provider::Registry.preferred_llm_provider
    end

    def unenhanced_merchants
      @unenhanced_merchants ||= @family.merchants.where(website_url: [ nil, "" ]).to_a
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
