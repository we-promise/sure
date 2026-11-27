class Import::AccountTypeMapping < Import::Mapping
  validates :value, presence: true
  validate :preview_type_allowed, if: :will_save_change_to_value?

  class << self
    def mappables_by_key(import)
      import.rows.map(&:entity_type).uniq.index_with { nil }
    end
  end

  def selectable_values
    Accountable.types_for(Current.user).map { |type| [ type.titleize, type ] }
  end

  def requires_selection?
    true
  end

  def values_count
    import.rows.where(entity_type: key).count
  end

  def create_mappable!
    # no-op
  end

  private
    def preview_type_allowed
      return unless value.in?(Accountable::PREVIEW_TYPES) && !value.in?(Accountable.types_for(Current.user))

      errors.add(:value, :inclusion, value: value)
    end
end
