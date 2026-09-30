class FinancekitItem < ApplicationRecord
  include Syncable
  include ProviderDisconnectable

  # FinanceKit implements discard: see Financekit::Purge.
  self.supports_discard = true

  before_destroy :release_orphaned_lineage_links

  belongs_to :family
  belongs_to :user
  belongs_to :replaces_financekit_item, class_name: "FinancekitItem", optional: true
  has_many :replacement_financekit_items, class_name: "FinancekitItem",
    foreign_key: :replaces_financekit_item_id, dependent: :nullify, inverse_of: :replaces_financekit_item
  has_many :financekit_accounts, dependent: :destroy
  has_many :financekit_account_lineages, through: :financekit_accounts
  has_many :financekit_batches, dependent: :destroy
  has_many :financekit_conflicts, dependent: :destroy
  has_many :accounts, through: :financekit_account_lineages

  scope :ordered, -> { order(created_at: :desc, id: :desc) }
  scope :syncable, -> { none }

  def name
    "Apple Wallet (FinanceKit)"
  end

  def credentials_configured?
    status == "active" && credential_digest.present? && stream_id.present?
  end

  def pending_account_setup?
    mapped_source_ids = financekit_accounts.pluck(:source_id).map(&:downcase)
    (consented_source_ids.map(&:downcase) - mapped_source_ids).any?
  end

  def selected_accounts
    financekit_accounts.where(source_id: consented_source_ids)
  end

  def authenticate_credential?(credential)
    return false if credential_digest.blank? || credential.blank?

    candidate = Financekit.credential_digest(credential)
    ActiveSupport::SecurityUtils.secure_compare(credential_digest, candidate)
  end

  # Re-checked on every upload rather than trusted from enrollment: a credential
  # outlives the state that issued it, and the enroller can be deactivated, moved
  # to another family or demoted between captures.
  #
  # No feature flag and no preview opt-in. Admin is the one standing requirement,
  # because a publisher writes into accounts the whole family reads; the
  # writable-accounts check below is what confines it to accounts this user may
  # actually touch.
  def require_publisher!
    error = status == "repair_required" ? "repair_required" : "connection_revoked"
    Financekit.require!(status == "active", error, 403)
    user.reload
    Financekit.require!(user.active? && user.family_id == family_id && user.admin?,
      "publisher_forbidden", 403)
    Financekit.require!(!pending_account_setup?, "account_setup_required", 409)
    permitted_ids = family.accounts.writable_by(user).pluck(:id)
    Financekit.require!(selected_accounts.includes(financekit_account_lineage: :account).all? do |mapping|
      mapping.account && permitted_ids.include?(mapping.account.id)
    end, "account_forbidden", 403)
  end

  def activate!
    token = nil
    family.with_lock do
      lock!
      Financekit.require!(%w[pending_mapping repair_required].include?(status), "activation_conflict", 409)
      Financekit.require!(!pending_account_setup?, "account_setup_required", 409)
      mappings = selected_accounts.includes(financekit_account_lineage: :account).to_a
      Financekit.require!(mappings.all?(&:account), "account_setup_required", 409)

      Financekit.require!(!competing_active_writer?(mappings, excluding: [ id, replaces_financekit_item_id ]),
        "lineage_writer_conflict", 409)

      replaces_financekit_item&.revoke!(release_lineages_except: mappings.map(&:financekit_account_lineage_id))
      mappings.each do |mapping|
        lineage = mapping.financekit_account_lineage
        lineage.create_account_provider!(account: lineage.account) unless lineage.account_provider
      end

      token = rotate_credential! # pipelock:ignore Credential in URL
      update!(status: "active", repair_reason: nil, stream_id: SecureRandom.uuid,
        next_sequence: 1, predecessor_digest: nil)
    end
    token
  end

  def repair!
    token = nil
    family.with_lock do
      lock!
      Financekit.require!(%w[active repair_required].include?(status), "connection_revoked", 403)
      Financekit.require!(!pending_account_setup?, "account_setup_required", 409)
      mappings = selected_accounts.includes(financekit_account_lineage: :account).to_a
      Financekit.require!(mappings.all?(&:account), "account_setup_required", 409)
      Financekit.require!(!competing_active_writer?(mappings, excluding: [ id ]),
        "lineage_writer_conflict", 409)
      revoke_pending_batches!("generation_replaced")
      token = rotate_credential! # pipelock:ignore Credential in URL
      update!(generation: generation + 1, stream_id: SecureRandom.uuid, next_sequence: 1,
        predecessor_digest: nil, status: "active", repair_reason: nil)
    end
    token
  end

  def renew_credential!
    with_lock do
      Financekit.require!(status == "active", "connection_revoked", 403)
      rotate_credential!
    end
  end

  def mark_repair!(reason)
    with_lock do
      revoke_pending_batches!(reason)
      update!(status: "repair_required", repair_reason: reason, credential_digest: nil)
    end
  end

  # A retain disconnect is the long-standing behaviour: revoke the credential and
  # the links, leave every account and transaction standing. A discard adds the
  # removal of what this connection imported, which runs in the background
  # because a year of card history is not a request-sized amount of deleting.
  def disconnect!(disposition: ProviderDisconnectable::DEFAULT_DISPOSITION)
    discard = discarding?(disposition)
    family.with_lock do
      revoke!(release_lineages_except: [])
      # Recorded inside the revoke so the intent is durable before any job
      # exists. A deletion the family asked for must not be lost to a queue that
      # happened to be unreachable a moment later.
      update!(purge_requested_at: Time.current) if discard
    end
    request_purge! if discard
  end

  def purge_pending?
    purge_requested_at.present? && purge_completed_at.nil?
  end

  def revoke!(release_lineages_except: [])
    lock!
    revoke_pending_batches!("connection_revoked")
    update!(status: "revoked", credential_digest: nil)
    financekit_account_lineages.distinct.where.not(id: release_lineages_except).find_each do |lineage|
      release_lineage_link!(lineage)
    end
  end

  def rotate_credential!
    credential = Financekit.issue_credential
    self.credential_digest = Financekit.credential_digest(credential)
    save! if persisted? && changed?
    credential
  end

  def consented_source_ids
    consent.fetch("selected_source_account_ids")
  end

  private

    # Enqueued outside the revoke transaction so an enqueue failure is visible
    # here rather than deferred to commit. The marker stays set either way: the
    # sweep in FinancekitInboxJob finishes a purge whose job never ran, and
    # rolling the request back would leave the family believing their data was
    # deleted when it was not.
    def request_purge!
      FinancekitPurgeJob.perform_later(self)
    rescue StandardError => error
      Financekit::Diagnostics.capture(item: self, source: self.class.name, level: "warn",
        message: "FinanceKit purge enqueue failed", event: "purge_enqueue_failed",
        error_class: error.class.name)
    end

    def competing_active_writer?(mappings, excluding:)
      FinancekitAccount.joins(:financekit_item)
        .where(financekit_account_lineage_id: mappings.map(&:financekit_account_lineage_id),
          financekit_items: { status: "active" })
        .where.not(financekit_item_id: excluding.compact).exists?
    end

    def revoke_pending_batches!(code)
      financekit_batches.where(status: %w[accepted processing failed])
        .update_all(status: "revoked", error_code: code, payload: nil, updated_at: Time.current)
    end

    def release_orphaned_lineage_links
      financekit_account_lineages.distinct.find_each { |lineage| release_lineage_link!(lineage) }
    end

    def release_lineage_link!(lineage)
      lineage.account_provider&.destroy! unless lineage.other_active_writer_than?(self)
    end
end
