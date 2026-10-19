class ScalableAccount < ApplicationRecord
  include Encryptable

  BROKER_KIND = "broker".freeze
  BROKER_CURRENCY = "EUR".freeze
  BROKER_NAME = "Scalable Broker".freeze

  encrypts :raw_metadata

  belongs_to :scalable_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_many :holdings, through: :account_provider

  validates :uid, :name, :currency, :kind, presence: true
  validates :uid, uniqueness: { scope: :scalable_item_id }
  validates :kind, inclusion: { in: %w[broker overnight] }
  validates :currency, format: { with: /\A[A-Z]{3}\z/ }
  validates :currency, inclusion: { in: [ BROKER_CURRENCY ] }, if: :broker?
  validates :current_balance, :cash_balance, numericality: true, allow_nil: true
  validate :snapshot_balance_contains_cash
  validate :raw_metadata_requires_encryption

  def broker?
    kind == BROKER_KIND
  end

  def current_account
    account
  end

  def usable_account
    linked_account = current_account
    provider_link = account_provider
    owner = scalable_item.owner

    return unless linked_account.present? && provider_link.present?
    return unless provider_link.provider_type == "ScalableAccount" && provider_link.provider_id == id
    return unless owner&.active? && owner.family_id == scalable_item.family_id
    return unless linked_account.family_id == scalable_item.family_id && linked_account.owner_id == owner.id
    return unless linked_account.investment? && linked_account.currency == currency
    return unless linked_account.active? && !linked_account.disabled? && !linked_account.pending_deletion?
    return unless linked_account.account_providers.where.not(id: provider_link.id).none?
    return unless content_compatible_for_import?(linked_account)

    linked_account
  end

  def content_compatible_for_import?(linked_account = current_account)
    ScalableAccount::ContentValidator.new(self).compatible?(linked_account)
  end

  def clear_generated_snapshot_rows!(linked_account = current_account)
    validator = ScalableAccount::ContentValidator.new(self)
    raise Provider::Scalable::Error.new(:account_conflict) unless linked_account &&
      linked_account.id == current_account&.id && account_provider.present?

    foreign_provider_rows = linked_account.holdings.where.not(account_provider_id: nil)
      .where.not(account_provider_id: account_provider.id).lock.to_a
    foreign_unowned_rows = linked_account.holdings.where(account_provider_id: nil)
      .where.not(external_id: nil).lock.to_a
    if foreign_provider_rows.any? || foreign_unowned_rows.any?
      raise Provider::Scalable::Error.new(:account_conflict)
    end

    candidates = linked_account.holdings.where(account_provider_id: nil, external_id: nil).lock.to_a
    unless candidates.all? { |holding| validator.generated_snapshot_holding?(holding, linked_account) }
      raise Provider::Scalable::Error.new(:account_conflict)
    end

    candidate_ids = candidates.map(&:id)
    deleted_count = if candidate_ids.empty?
      0
    else
      linked_account.holdings.where(id: candidate_ids, account_provider_id: nil, external_id: nil).delete_all
    end
    linked_account.holdings.reset
    deleted_count
  end

  def linkable_to?(candidate)
    broker? && candidate.investment? && candidate.currency == BROKER_CURRENCY
  end

  def ensure_account_provider!(allow_bootstrap: false)
    existing = account_provider
    return existing if existing.present? && usable_account.present?

    if existing.present? || !allow_bootstrap
      raise Provider::Scalable::Error.new(:account_conflict)
    end

    ScalableAccount.transaction do
      scalable_item.with_lock do
        reload
        existing = account_provider
        if existing.present?
          raise Provider::Scalable::Error.new(:account_conflict) unless usable_account
          next existing
        end

        unless scalable_item.ready_for_sync? && broker? && currency == BROKER_CURRENCY && snapshot_values_present?
          raise Provider::Scalable::Error.new(:account_conflict)
        end

        linked_account = scalable_item.family.accounts.create!(
          accountable: Investment.new(subtype: "brokerage"),
          name: name,
          balance: 0,
          cash_balance: 0,
          currency: currency,
          institution_name: "Scalable Capital",
          institution_domain: "scalable.capital",
          owner: scalable_item.owner
        )
        AccountProvider.create!(account: linked_account, provider: self)
      end
    end

    reload.account_provider
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    raise Provider::Scalable::Error.new(:account_conflict), cause: nil
  end

  private

    def snapshot_balance_contains_cash
      return if current_balance.nil? || cash_balance.nil?
      return if current_balance >= cash_balance

      errors.add(:current_balance, "cannot be below brokerage cash")
    end

    def snapshot_values_present?
      !current_balance.nil? && !cash_balance.nil? && current_balance >= cash_balance
    end

    def raw_metadata_requires_encryption
      return if ActiveRecordEncryptionConfig.explicitly_configured? || raw_metadata.blank?

      errors.add(:base, :encryption_unavailable)
    end
end
