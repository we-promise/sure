class StashawayItem < ApplicationRecord
  include Syncable, Provided, Authentication, Unlinking, Encryptable, DestroyableLater

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :email, deterministic: true
    encrypts :api_token
    encrypts :pending_login_token
    encrypts :password
  end

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later
  has_many :stashaway_accounts, dependent: :destroy

  validates :email, presence: true
  validates :device_id, presence: true
  validates :region, inclusion: { in: Provider::Stashaway::Region.codes }

  scope :active, -> { where(scheduled_for_deletion: false) }
  # A connection that can sync, or one that can sign itself in again: it
  # has a saved password and is not waiting for an SMS code.
  scope :syncable, -> { active.where(status: :good).where.not(api_token: nil).or(active.where.not(password: nil).where(pending_login_token: nil)) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def credentials_configured?
    api_token.present?
  end

  def ready_for_sync?
    good? && credentials_configured?
  end

  def password_saved?
    password.present?
  end

  def import_latest_data
    StashawayItem::Importer.new(self, provider: stashaway_provider).import
  rescue => e
    DebugLogEntry.capture(
      category: "sync",
      level: "error",
      message: "StashawayItem #{id} - Failed to import data: #{e.class} - #{e.message}",
      source: "stashaway",
      family: family,
      provider_key: "stashaway"
    )
    raise
  end

  def process_accounts
    linked_stashaway_accounts.includes(account_provider: :account).each_with_object([]) do |stashaway_account, results|
      account = stashaway_account.current_account
      next unless account
      next if account.pending_deletion? || account.disabled?

      begin
        result = StashawayAccount::Processor.new(stashaway_account).process
        results << { stashaway_account_id: stashaway_account.id, success: true, result: result }
      rescue => e
        DebugLogEntry.capture(
          category: "sync",
          level: "error",
          message: "StashawayItem #{id} - Failed to process account #{stashaway_account.id}: #{e.class} - #{e.message}",
          source: "stashaway",
          family: family,
          provider_key: "stashaway",
          account_provider_id: stashaway_account.account_provider&.id
        )
        results << { stashaway_account_id: stashaway_account.id, success: false, error: e.message }
      end
    end
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    accounts.reject { |account| account.pending_deletion? || account.disabled? }.each_with_object([]) do |account, results|
      begin
        account.sync_later(parent_sync: parent_sync, window_start_date: window_start_date, window_end_date: window_end_date)
        results << { account_id: account.id, success: true }
      rescue => e
        DebugLogEntry.capture(
          category: "sync",
          level: "error",
          message: "StashawayItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}",
          source: "stashaway",
          family: family,
          provider_key: "stashaway",
          account_id: account.id
        )
        results << { account_id: account.id, success: false, error: e.message }
      end
    end
  end

  def accounts
    stashaway_accounts.includes(account_provider: :account).filter_map(&:current_account).uniq
  end

  def linked_stashaway_accounts
    stashaway_accounts.joins(:account_provider)
  end

  def linked_accounts_count
    linked_stashaway_accounts.count
  end

  def unlinked_accounts_count
    stashaway_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    stashaway_accounts.count
  end

  def sync_status_summary
    total = total_accounts_count
    linked = linked_accounts_count
    unlinked = total - linked

    if total.zero?
      I18n.t("stashaway_items.sync_status.no_accounts")
    elsif unlinked.zero?
      I18n.t("stashaway_items.sync_status.all_linked", count: linked)
    else
      I18n.t("stashaway_items.sync_status.partial", linked: linked, unlinked: unlinked)
    end
  end

  # Unknown regions are refused on save, so only a record that failed
  # validation can ask for one.
  def region_info
    Provider::Stashaway::Region.find(region)
  end

  def institution_display_name
    I18n.t("stashaway_items.defaults.display_name", region: region_info.label)
  end
end
