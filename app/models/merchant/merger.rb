class Merchant::Merger
  class UnauthorizedMerchantError < StandardError; end

  attr_reader :family, :target_merchant, :source_merchants, :merged_count

  def initialize(family:, target_merchant:, source_merchants:)
    @family = family
    @target_merchant = target_merchant
    @merged_count = 0

    validate_merchant_belongs_to_family!(target_merchant, "Target merchant")

    sources = Array(source_merchants)
    sources.each { |m| validate_merchant_belongs_to_family!(m, "Source merchant '#{m.name}'") }

    @source_merchants = sources.reject { |m| m.id == target_merchant.id }
  end

  private

    def validate_merchant_belongs_to_family!(merchant, label)
      return if family_merchant_ids.include?(merchant.id)

      raise UnauthorizedMerchantError, "#{label} does not belong to this family"
    end

    def family_merchant_ids
      @family_merchant_ids ||= begin
        family_ids = family.merchants.pluck(:id)
        assigned_ids = family.assigned_merchants.pluck(:id)
        (family_ids + assigned_ids).uniq
      end
    end

  public

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
