class LunchflowItem < ApplicationRecord
  include Syncable, Provided

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  validates :name, presence: true

  belongs_to :family
  has_one_attached :logo

  has_many :lunchflow_accounts, dependent: :destroy
  has_many :accounts, through: :lunchflow_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_lunchflow_data
    provider = lunchflow_provider
    unless provider
      Rails.logger.error "LunchflowItem #{id} - Cannot import: Lunchflow provider is not configured (missing API key)"
      raise StandardError.new("Lunchflow provider is not configured")
    end

    LunchflowItem::Importer.new(self, lunchflow_provider: provider).import
  rescue => e
    Rails.logger.error "LunchflowItem #{id} - Failed to import data: #{e.message}"
    raise
  end

  def process_accounts
    return [] if lunchflow_accounts.empty?

    results = []
    lunchflow_accounts.joins(:account).each do |lunchflow_account|
      begin
        result = LunchflowAccount::Processor.new(lunchflow_account).process
        results << { lunchflow_account_id: lunchflow_account.id, success: true, result: result }
      rescue => e
        Rails.logger.error "LunchflowItem #{id} - Failed to process account #{lunchflow_account.id}: #{e.message}"
        results << { lunchflow_account_id: lunchflow_account.id, success: false, error: e.message }
        # Continue processing other accounts even if one fails
      end
    end

    results
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    return [] if accounts.empty?

    results = []
    accounts.each do |account|
      begin
        account.sync_later(
          parent_sync: parent_sync,
          window_start_date: window_start_date,
          window_end_date: window_end_date
        )
        results << { account_id: account.id, success: true }
      rescue => e
        Rails.logger.error "LunchflowItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
        results << { account_id: account.id, success: false, error: e.message }
        # Continue scheduling other accounts even if one fails
      end
    end

    results
  end

  def upsert_lunchflow_snapshot!(accounts_snapshot)
    assign_attributes(
      raw_payload: accounts_snapshot
    )

    save!
  end

  def has_completed_initial_setup?
    # Setup is complete if we have any linked accounts
    accounts.any?
  end

  def sync_status_summary
    latest = latest_sync
    return nil unless latest

    # If sync has statistics, use them
    if latest.sync_stats.present?
      stats = latest.sync_stats
      total = stats["total_accounts"] || 0
      linked = stats["linked_accounts"] || 0
      unlinked = stats["unlinked_accounts"] || 0

      if total == 0
        "No accounts found"
      elsif unlinked == 0
        "#{linked} #{'account'.pluralize(linked)} synced"
      else
        "#{linked} synced, #{unlinked} need setup"
      end
    else
      # Fallback to current account counts
      total_accounts = lunchflow_accounts.count
      linked_count = accounts.count
      unlinked_count = total_accounts - linked_count

      if total_accounts == 0
        "No accounts found"
      elsif unlinked_count == 0
        "#{linked_count} #{'account'.pluralize(linked_count)} synced"
      else
        "#{linked_count} synced, #{unlinked_count} need setup"
      end
    end
  end

  def institution_display_name
    # Try to get institution name from stored metadata
    institution_name.presence || institution_domain.presence || name
  end

  def connected_institutions
    # Get unique institutions from all accounts
    lunchflow_accounts.includes(:account)
                      .where.not(institution_metadata: nil)
                      .map { |acc| acc.institution_metadata }
                      .uniq { |inst| inst["name"] || inst["institution_name"] }
  end

  def institution_summary
    institutions = connected_institutions
    case institutions.count
    when 0
      "No institutions connected"
    when 1
      institutions.first["name"] || institutions.first["institution_name"] || "1 institution"
    else
      "#{institutions.count} institutions"
    end
  end
end
