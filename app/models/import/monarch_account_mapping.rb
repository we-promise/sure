# One Monarch account in a MonarchImport, and what to do with it: create a
# Sure account of the chosen type, import into an existing manual account
# (mappable), or skip it. value holds the choices as JSON.
class Import::MonarchAccountMapping < Import::Mapping
  DEFAULTS = { "name" => nil, "type" => "Depository", "closed" => false, "include" => true, "transactions" => true, "current_balance" => nil }.freeze

  serialize :value, coder: JSON

  validates :key, presence: true
  validate :choices_are_valid
  validate :target_is_a_manual_family_account

  def self.target_accounts_for(import)
    import.family.accounts.listable_manual.alphabetically
  end

  def choices
    DEFAULTS.merge(value.is_a?(Hash) ? value.slice(*DEFAULTS.keys) : {})
  end

  def choices=(attributes)
    self.value = choices.merge(attributes.to_h.stringify_keys.slice(*DEFAULTS.keys))
  end

  %w[type closed include transactions current_balance].each do |name|
    define_method(name) { choices[name] }
  end

  def target
    mappable if mappable_type == "Account"
  end

  # The name a new account gets in Sure: the one chosen, or Monarch's.
  def account_name
    choices["name"].to_s.strip.presence || key
  end

  def to_converter_choice
    MonarchImport::Converter::Choice.new(
      name: key,
      account_name: account_name,
      type: target&.accountable_type || type,
      closed: boolean(closed),
      include: boolean(include),
      transactions: boolean(transactions),
      current_balance: parsed_current_balance,
      target: target
    )
  end

  def selectable_values
    self.class.target_accounts_for(import).map { |account| [ account.name, account.id ] }
  end

  def values_count
    1
  end

  def mappable_class
    Account
  end

  # Accounts are created by the import itself, not ahead of it.
  def create_mappable!
  end

  private
    def boolean(value)
      ActiveModel::Type::Boolean.new.cast(value) || false
    end

    def parsed_current_balance
      raw = current_balance.to_s.delete(",$").strip
      BigDecimal(raw) if raw.present?
    rescue ArgumentError
      nil
    end

    def choices_are_valid
      errors.add(:value, :inclusion) unless Accountable::TYPES.include?(type)
      raw = current_balance.to_s.delete(",$").strip
      errors.add(:value, :not_a_number) if raw.present? && parsed_current_balance.nil?
    end

    def target_is_a_manual_family_account
      return if mappable.nil?

      unless mappable.is_a?(Account) && self.class.target_accounts_for(import).exists?(id: mappable.id)
        errors.add(:mappable, :invalid)
      end
    end
end
