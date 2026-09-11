# frozen_string_literal: true

# One Fio banka API token, and therefore exactly one Fio account.
#
# Fio issues a token per account with no way to enumerate accounts, so a family tracking
# three Fio accounts holds three items. The single `fio_accounts` row is still a
# collection because the surrounding sync machinery (Family::Syncer, the setup flow,
# Family::FinancialDataReset) is written against provider items with many accounts.
class FioItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :token, deterministic: true
    encrypts :raw_payload
    encrypts :raw_institution_payload
  end

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later
  has_many :fio_accounts, dependent: :destroy
  has_many :accounts, through: :fio_accounts

  validates :name, presence: true
  validates :token, presence: true, on: :create

  # Fio is a single institution, so its metadata is known up front rather than discovered
  # per connection. On the model so both the settings panel and Family#create_fio_item!
  # get it.
  before_validation :apply_institution_defaults, on: :create

  scope :active, -> { where(scheduled_for_deletion: false) }
  # Family::Syncer discovers provider items reflectively and calls `syncable` on every
  # `*_items` association whose model includes Syncable.
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  # Mark the item for deletion and enqueue the background destroy job.
  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  # Run the importer to fetch the latest statement from Fio.
  def import_latest_fio_data
    provider = fio_provider
    unless provider
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Cannot import: Fio provider is not configured",
        source: self.class.name,
        provider_key: "fio",
        family: family,
        metadata: { fio_item_id: id }
      )
      raise StandardError.new("Fio provider is not configured")
    end

    FioItem::Importer.new(self, fio_provider: provider).import
  rescue => e
    DebugLogEntry.capture(
      category: "provider_sync_error",
      level: "error",
      message: "Failed to import data",
      source: self.class.name,
      provider_key: "fio",
      family: family,
      metadata: { fio_item_id: id, error_class: e.class.name, error_message: e.message }
    )
    raise
  end

  # Process each linked, visible Fio account, returning a per-account result array.
  def process_accounts
    return [] if fio_accounts.empty?

    fio_accounts.joins(:account).merge(Account.visible).map do |fio_account|
      result = FioAccount::Processor.new(fio_account).process
      if result.is_a?(Hash) && result.with_indifferent_access[:success] == false
        { fio_account_id: fio_account.id, success: false, error: I18n.t("fio_item.errors.account_processing_failed") }
      else
        { fio_account_id: fio_account.id, success: true, result: result }
      end
    rescue => e
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Failed to process account",
        source: self.class.name,
        provider_key: "fio",
        family: family,
        account_provider: fio_account.account_provider,
        metadata: { fio_item_id: id, fio_account_id: fio_account.id, error_class: e.class.name, error_message: e.message }
      )
      { fio_account_id: fio_account.id, success: false, error: I18n.t("fio_item.errors.account_processing_failed") }
    end
  end

  # Enqueue a balance sync for each visible linked account, returning per-account results.
  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    return [] if accounts.empty?

    accounts.visible.map do |account|
      account.sync_later(
        parent_sync: parent_sync,
        window_start_date: window_start_date,
        window_end_date: window_end_date
      )
      { account_id: account.id, success: true }
    rescue => e
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Failed to schedule sync for account",
        source: self.class.name,
        provider_key: "fio",
        family: family,
        account: account,
        metadata: { fio_item_id: id, account_id: account.id, error_class: e.class.name, error_message: e.message }
      )
      { account_id: account.id, success: false, error: I18n.t("fio_item.errors.account_sync_schedule_failed") }
    end
  end

  # Persist the latest statement header for this item.
  #
  # The header is the only account description Fio offers, so it is kept for support. The
  # account number is not an institution id, but it is what identifies the connection, and
  # `raw_payload` is only encrypted at rest when the deployment has ActiveRecord
  # encryption configured — hence IBAN and balances are dropped here and live on the
  # account row instead.
  def upsert_fio_snapshot!(statement_info)
    snapshot = statement_info.to_h.with_indifferent_access

    assign_attributes(
      institution_id: snapshot[:bankId].presence || institution_id,
      raw_payload: snapshot.slice(:accountId, :bankId, :currency, :dateStart, :dateEnd)
    )
    save!
  end

  # The single Fio account reached by this item's token, once discovered.
  def fio_account
    fio_accounts.first
  end

  # True once the Fio account has been linked to a Sure account.
  def has_completed_initial_setup?
    accounts.any?
  end

  # Human-readable summary of linked vs. unlinked account counts.
  def sync_status_summary
    if total_accounts_count.zero?
      I18n.t("fio_item.sync_status.no_accounts")
    elsif unlinked_accounts_count.zero?
      I18n.t("fio_item.sync_status.all_synced", count: linked_accounts_count)
    else
      I18n.t("fio_item.sync_status.partial", linked: linked_accounts_count, unlinked: unlinked_accounts_count)
    end
  end

  # Number of Fio accounts linked to a Sure account.
  def linked_accounts_count
    account_counts[:linked]
  end

  # Number of unlinked Fio accounts still awaiting setup.
  def unlinked_accounts_count
    account_counts[:unlinked]
  end

  # Total number of Fio accounts under this item.
  def total_accounts_count
    account_counts[:total]
  end

  # Best available display name for the connected institution.
  def institution_display_name
    institution_name.presence || institution_domain.presence || name
  end

  # True when a token is present and the item can call the Fio API.
  def credentials_configured?
    token.present?
  end

  private

    def apply_institution_defaults
      self.institution_name ||= FioAccount::INSTITUTION_NAME
      self.institution_domain ||= FioAccount::INSTITUTION_DOMAIN
      self.institution_url ||= "https://#{FioAccount::INSTITUTION_DOMAIN}"
    end

    # Single query for all three account counts, reused across sync_status_summary and
    # the settings partial.
    def account_counts
      @account_counts ||= begin
        rows = fio_accounts
                 .left_joins(:account_provider)
                 .pluck(Arel.sql("account_providers.id IS NOT NULL"), :ignored)

        linked = rows.count { |has_provider, _ignored| has_provider }
        unlinked = rows.count { |has_provider, ignored| !has_provider && !ignored }

        { linked: linked, unlinked: unlinked, total: rows.size }
      end
    end
end
