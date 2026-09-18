class FinancekitItem < ApplicationRecord
  include Syncable

  belongs_to :family
  belongs_to :user
  has_many :financekit_accounts, dependent: :destroy
  has_many :financekit_batches, dependent: :destroy
  has_many :accounts, through: :financekit_accounts

  scope :ordered, -> { order(created_at: :desc, id: :desc) }
  # Wallet cannot be pulled by a server. The inbox worker owns import discovery;
  # family/web schedules must never manufacture a successful device fetch.
  scope :syncable, -> { none }

  def name
    "Apple Wallet (FinanceKit)"
  end

  def credentials_configured?
    status == "active"
  end

  def pending_account_setup?
    linked_source_ids = financekit_accounts.joins(:account_provider).pluck(:source_id)
    (consented_source_ids - linked_source_ids).any?
  end

  def selected_accounts
    financekit_accounts.where(source_id: consented_source_ids)
  end

  def require_writer!
    Financekit.require!(status == "active", "connection_revoked", 403)
    Financekit.require!(Financekit.enabled?(family), "unavailable", 503)
    user.reload
    Financekit.require!(user.active? && user.family_id == family_id && user.admin? && user.preview_features_enabled?, "publisher_forbidden", 403)
    Financekit.require!(!pending_account_setup?, "account_setup_required", 409)
    permitted_ids = family.accounts.writable_by(user).pluck(:id)
    Financekit.require!(selected_accounts.all? { |source| source.account && permitted_ids.include?(source.account.id) }, "account_forbidden", 403)
  end

  def disconnect!
    with_lock do
      financekit_accounts.includes(:account_provider).find_each { |source| source.account_provider&.destroy! }
      update!(status: "revoked")
    end
  end

  private

    def consented_source_ids
      consent.fetch("source_ids")
    end
end
