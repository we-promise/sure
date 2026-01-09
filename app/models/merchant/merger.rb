class Merchant::Merger
  attr_reader :family, :target_merchant, :source_merchants, :merged_count

  def initialize(family:, target_merchant:, source_merchants:)
    @family = family
    @target_merchant = target_merchant
    @source_merchants = Array(source_merchants).reject { |m| m.id == target_merchant.id }
    @merged_count = 0
  end

  def merge!
    return false if source_merchants.empty?

    Merchant.transaction do
      source_merchants.each do |source|
        # Reassign family's transactions to target
        family.transactions.where(merchant_id: source.id).update_all(merchant_id: target_merchant.id)

        # Delete FamilyMerchant, keep ProviderMerchant (it may be used by other families)
        source.destroy! if source.is_a?(FamilyMerchant)

        @merged_count += 1
      end
    end

    true
  end
end
