class UpItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :access_token, deterministic: true
    encrypts :raw_payload
    encrypts :raw_institution_payload
  end

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later
  has_many :up_accounts, dependent: :destroy
  has_many :accounts, through: :up_accounts

  validates :name, presence: true
  validates :access_token, presence: true, on: :create

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_up_data
    provider = up_provider
    unless provider
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Cannot import: Up provider is not configured",
        source: self.class.name,
        provider_key: "up",
        family: family,
        metadata: { up_item_id: id }
      )
      raise StandardError.new("Up provider is not configured")
    end

    UpItem::Importer.new(self, up_provider: provider).import
  rescue => e
    DebugLogEntry.capture(
      category: "provider_sync_error",
      level: "error",
      message: "Failed to import data",
      source: self.class.name,
      provider_key: "up",
      family: family,
      metadata: { up_item_id: id, error_class: e.class.name, error_message: e.message }
    )
    raise
  end

  def process_accounts
    return [] if up_accounts.empty?

    up_accounts.joins(:account).merge(Account.visible).map do |up_account|
      result = UpAccount::Processor.new(up_account).process
      if result.is_a?(Hash) && result.with_indifferent_access[:success] == false
        { up_account_id: up_account.id, success: false, error: I18n.t("up_item.errors.account_processing_failed") }
      else
        { up_account_id: up_account.id, success: true, result: result }
      end
    rescue => e
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Failed to process account",
        source: self.class.name,
        provider_key: "up",
        family: family,
        account_provider: up_account.account_provider,
        metadata: { up_item_id: id, up_account_id: up_account.id, error_class: e.class.name, error_message: e.message }
      )
      { up_account_id: up_account.id, success: false, error: I18n.t("up_item.errors.account_processing_failed") }
    end
  end

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
        provider_key: "up",
        family: family,
        account: account,
        metadata: { up_item_id: id, account_id: account.id, error_class: e.class.name, error_message: e.message }
      )
      { account_id: account.id, success: false, error: I18n.t("up_item.errors.account_sync_schedule_failed") }
    end
  end

  def upsert_up_snapshot!(accounts_snapshot)
    assign_attributes(raw_payload: accounts_snapshot)
    save!
  end

  def has_completed_initial_setup?
    accounts.any?
  end

  def sync_status_summary
    total_accounts = total_accounts_count
    linked_count = linked_accounts_count
    unlinked_count = unlinked_accounts_count

    if total_accounts.zero?
      I18n.t("up_item.sync_status.no_accounts")
    elsif unlinked_count.zero?
      I18n.t("up_item.sync_status.all_synced", count: linked_count)
    else
      I18n.t("up_item.sync_status.partial", linked: linked_count, unlinked: unlinked_count)
    end
  end

  def linked_accounts_count
    up_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    up_accounts.needs_setup.count
  end

  def total_accounts_count
    up_accounts.count
  end

  def institution_display_name
    institution_name.presence || institution_domain.presence || name
  end

  def connected_institutions
    up_accounts.includes(:account)
               .where.not(institution_metadata: nil)
               .map(&:institution_metadata)
               .uniq { |inst| inst["name"] || inst["domain"] }
  end

  def institution_summary
    institutions = connected_institutions
    case institutions.count
    when 0
      I18n.t("up_item.institution_summary.none")
    when 1
      institutions.first["name"].presence || I18n.t("up_item.institution_summary.one")
    else
      I18n.t("up_item.institution_summary.count", count: institutions.count)
    end
  end

  def credentials_configured?
    access_token.present?
  end
end
