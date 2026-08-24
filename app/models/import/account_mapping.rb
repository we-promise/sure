class Import::AccountMapping < Import::Mapping
  validates :mappable, presence: true, if: :requires_mapping?

  class << self
    def mappables_by_key(import)
      unique_values = import.rows.map(&:account).uniq
      accounts = importable_accounts(import).where(name: unique_values).index_by(&:name)

      unique_values.index_with { |value| accounts[value] }
    end

    # Linked (provider-managed) accounts are valid CSV targets so users can
    # backfill history after connecting. When Current.user is set, restrict to
    # accounts they can write; otherwise fall back to the family (e.g. jobs).
    def importable_accounts(import)
      scope = import.family.accounts
      return scope unless Current.user

      scope.writable_by(Current.user)
    end
  end

  def selectable_values
    family_accounts = self.class.importable_accounts(import).visible.alphabetically.map { |account| [ account.name, account.id ] }

    unless key.blank?
      family_accounts.unshift [ "Add as new account", CREATE_NEW_KEY ]
    end

    family_accounts
  end

  def requires_selection?
    true
  end

  def values_count
    import.rows.where(account: key).count
  end

  def mappable_class
    Account
  end

  def create_mappable!
    return unless creatable?

    account = import.family.accounts.create_or_find_by!(name: key) do |new_account|
      new_account.balance = 0
      new_account.import = import
      new_account.currency = import.family.currency
      new_account.accountable = Depository.new
    end

    self.mappable = account
    save!
  end

  private
    def requires_mapping?
      (key.blank? || !create_when_empty) && import.account.nil?
    end
end
