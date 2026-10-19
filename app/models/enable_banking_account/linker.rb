class EnableBankingAccount::Linker
  def initialize(provider_account, user:)
    @provider_account = provider_account
    @user = user
  end

  def link!(account_type:, subtype: nil)
    family.with_lock do
      invalid!(:cannot_manage) unless user&.family_id == family.id
      provider_account.reload
      account = provider_account.account || remembered_account
      if account
        validate_account!(account, account_type, subtype)
      else
        account = Account.create_from_enable_banking_account(provider_account, account_type, subtype, owner: user)
      end

      link = AccountProvider.find_or_initialize_by(account: account, provider_type: "EnableBankingAccount")
      link.provider = provider_account
      link.save!
      provider_account.reload
      account
    end
  end

  def link_existing!(account)
    family.with_lock do
      provider_account.reload
      validate_account!(account, account.accountable_type, account.accountable&.subtype)
      previous = provider_account.account
      if previous && previous.id != account.id
        invalid!(:already_linked)
      end

      identity_owner = remembered_account
      if identity_owner && identity_owner.id != account.id
        invalid!(:already_remembered)
      end

      link = provider_account.account_provider || AccountProvider.new(provider: provider_account)
      link.update!(account: account)
      provider_account.reload
      account
    end
  end

  private
    attr_reader :provider_account, :user

    def family
      provider_account.enable_banking_item.family
    end

    def remembered_account
      fingerprint = provider_account.reconnection_fingerprint
      return if fingerprint.blank?

      remembered = family.accounts.find_by(enable_banking_fingerprint: fingerprint)
      return remembered if remembered

      # existing links from before the identity column was added have no fingerprint yet
      candidates = EnableBankingAccount.joins(:enable_banking_item, :account_provider)
        .where(enable_banking_items: { family_id: family.id })
        .includes(:enable_banking_item, account_provider: :account)
        .filter_map do |candidate|
          candidate.account_provider.account if candidate.reconnection_fingerprint == fingerprint
        end.uniq(&:id)
      invalid!(:ambiguous_identity) if candidates.many?
      candidates.first
    end

    def validate_account!(account, account_type, subtype)
      unless user&.family_id == family.id && account.family_id == family.id &&
             account.permission_for(user).in?([ :owner, :full_control ])
        invalid!(:cannot_reconnect)
      end
      invalid!(:pending_deletion) if account.pending_deletion?
      if account.enable_banking_fingerprint.present? && provider_account.reconnection_fingerprint.present? &&
         account.enable_banking_fingerprint != provider_account.reconnection_fingerprint
        invalid!(:identity_mismatch)
      end
      if account.currency != provider_account.currency || account.accountable_type != account_type ||
         (subtype.present? && account.accountable&.subtype != subtype)
        invalid!(:incompatible_account)
      end
      if account.account_providers.where.not(provider_type: "EnableBankingAccount").exists? ||
         account.plaid_account_id.present? || account.simplefin_account_id.present?
        invalid!(:other_provider)
      end
    end

    def invalid!(key)
      provider_account.errors.add(:base, I18n.t("enable_banking_accounts.linking.errors.#{key}"))
      raise ActiveRecord::RecordInvalid, provider_account
    end
end
