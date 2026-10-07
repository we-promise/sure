# Scopes the category, merchant and tag ids of split rows to records the family may use, so a
# crafted, foreign or since-deleted id is dropped instead of attached to a child entry. Shared by
# manual splits (SplitsController) and rule splits (Rule::ActionExecutor::SplitTransaction).
#
# The merchant scope is the one difference between the two: a manual split may use any merchant
# the user can see (available_merchants_for, which includes provider merchants on accounts they
# can access), while a rule runs without a user and only offers family merchants in its picker.
class Entry::SplitReferences
  def initialize(family, merchants: family.merchants)
    @category_ids = family.categories.pluck(:id).to_set
    @merchant_ids = merchants.pluck(:id).to_set
    @tag_ids = family.tags.pluck(:id).to_set
  end

  def scope(category_id:, merchant_id:, tag_ids:)
    category_id = category_id.presence
    merchant_id = merchant_id.presence

    {
      category_id: (category_id if @category_ids.include?(category_id)),
      merchant_id: (merchant_id if @merchant_ids.include?(merchant_id)),
      tag_ids: Array(tag_ids).reject(&:blank?).select { |id| @tag_ids.include?(id) }.uniq
    }
  end
end
