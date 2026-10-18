class DirectaAccount < ApplicationRecord
  include Encryptable

  encrypts :raw_position_metadata

  belongs_to :directa_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account

  validates :directa_item_id, uniqueness: true
  validates :currency, format: { with: /\A[A-Z]{3}\z/ }, allow_nil: true
  validates :cash_balance, :current_balance, numericality: true, allow_nil: true
  validate :snapshot_balance_contains_cash

  def current_account
    account
  end

  def usable_account
    linked_account = current_account
    provider_link = account_provider
    owner = directa_item.owner

    return unless linked_account.present? && provider_link.present?
    return unless owner&.active? && owner.family_id == directa_item.family_id
    return unless linked_account.family_id == directa_item.family_id && linked_account.owner_id == owner.id
    return unless linked_account.investment? && linked_account.currency == currency
    return unless linked_account.active? && !linked_account.disabled? && !linked_account.pending_deletion?
    return unless linked_account.account_providers.where.not(id: provider_link.id).none?

    linked_account
  end

  def linkable_to?(account)
    account.investment? && currency.present? && account.currency == currency
  end

  def ensure_account_provider!(allow_bootstrap: false)
    existing = account_provider
    return existing if existing.present? && usable_account.present?

    if existing.present? || !allow_bootstrap
      raise DirectaItem::PortfolioNormalizer::Error.new(:holding_conflict)
    end

    DirectaAccount.transaction do
      directa_item.with_lock do
        reload
        existing = account_provider
        if existing.present?
          raise DirectaItem::PortfolioNormalizer::Error.new(:holding_conflict) unless usable_account
          next existing
        end

        unless directa_item.ready_for_sync? && currency.present? && snapshot_values_present?
          raise DirectaItem::PortfolioNormalizer::Error.new(:holding_conflict)
        end

        linked_account = directa_item.family.accounts.create!(
          accountable: Investment.new(subtype: "brokerage"),
          name: "Directa",
          balance: 0,
          cash_balance: 0,
          currency: currency,
          institution_name: "Directa",
          institution_domain: "directa.it",
          owner: directa_item.owner
        )
        AccountProvider.create!(account: linked_account, provider: self)
      end
    end

    reload.account_provider
  end

  def content_compatible_for_import?(linked_account = account)
    DirectaAccount::ContentValidator.new(self).compatible?(linked_account)
  end

  def store_snapshot!(currency:, current_balance:, cash_balance:, raw_position_metadata:)
    update!(
      currency: currency,
      current_balance: current_balance,
      cash_balance: cash_balance,
      raw_position_metadata: raw_position_metadata
    )
  end

  private

    def snapshot_balance_contains_cash
      return if current_balance.nil? || cash_balance.nil?
      return if current_balance >= cash_balance

      errors.add(:current_balance, "cannot be below brokerage cash")
    end

    def snapshot_values_present?
      current_balance.present? && cash_balance.present? && current_balance >= cash_balance
    end
end
