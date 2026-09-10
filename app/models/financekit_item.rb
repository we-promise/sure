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
    status == "active" && device_public_key.present?
  end

  def pending_account_setup?
    financekit_accounts.empty?
  end

  def selected_accounts
    financekit_accounts.where(source_id: consent.fetch("source_ids"))
  end

  def require_writer!
    Financekit.require!(status == "active", "connection_revoked", 403)
    Financekit.require!(Financekit.enabled?(family), "unavailable", 503)
    user.reload
    Financekit.require!(user.active? && user.family_id == family_id && user.admin? && user.preview_features_enabled?, "publisher_forbidden", 403)
    permitted_ids = family.accounts.writable_by(user).pluck(:id)
    Financekit.require!(selected_accounts.all? { |source| source.account && permitted_ids.include?(source.account.id) }, "account_forbidden", 403)
  end

  def disconnect!
    with_lock do
      update!(status: "revoked")
      financekit_batches.where(status: %w[accepted processing failed]).update_all(status: "revoked", error_code: "connection_revoked", envelope: nil)
    end
  end

  def replace_device!(input)
    with_lock do
      Financekit::Payload.shape!(input, %w[expected_generation device_public_key consent continuity])
      Financekit.require!(input["expected_generation"] == generation, "generation_conflict", 409)
      Financekit::Crypto.public_device_key(input["device_public_key"])
      Financekit::Enrollment.validate_consent!(input["consent"])
      # Reinstall with changed transaction UUIDs cannot safely merge historical
      # records. Stop here for explicit reconciliation instead of guessing.
      Financekit.require!(input["continuity"] == "same_source_and_transaction_ids", "identity_reconciliation_required", 409)
      financekit_batches.where(status: %w[accepted processing failed]).update_all(status: "revoked", error_code: "generation_replaced", envelope: nil)
      update!(device_public_key: input["device_public_key"], consent: input["consent"].merge("recorded_at" => Time.current.iso8601),
        generation: generation + 1, next_sequence: 1, previous_digest: nil, status: "active")
    end
  end
end
