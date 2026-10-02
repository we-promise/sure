class Import::MerchantMapping < Import::Mapping
  class << self
    def mappables_by_key(import)
      names = import.rows.where.not(merchant: [ nil, "" ]).distinct.pluck(:merchant)
      merchants = import.family.merchants.where(name: names).index_by(&:name)

      names.index_with { |name| merchants[name] }
    end
  end

  def selectable_values
    family_merchants = import.family.merchants.alphabetically.map { |merchant| [ merchant.name, merchant.id ] }
    family_merchants.unshift [ "Add as new merchant", CREATE_NEW_KEY ] if key.present?
    family_merchants
  end

  def values_count
    import.rows.where(merchant: key).count
  end

  def mappable_class
    FamilyMerchant
  end

  def create_mappable!
    return unless creatable?

    self.mappable = import.family.merchants.find_or_create_by!(name: key)
    save!
  end
end
