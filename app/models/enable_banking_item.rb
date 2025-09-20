class EnableBankingItem < ApplicationRecord
  include Syncable, Provided

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if Rails.application.credentials.active_record_encryption.present?
    encrypts :session_id, deterministic: true
  end

  validates :aspsp_name, :aspsp_country, :session_id, :valid_until, presence: true

  belongs_to :family
  has_one_attached :logo

  has_many :enable_banking_accounts, dependent: :destroy
  has_many :accounts, through: :enable_banking_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def is_session_valid?
    valid_until > Time.current && !requires_update?
  end

  def import_latest_data
    EnableBankingItem::Importer.new(self, enable_banking_provider: enable_banking_provider).import
  end

  # Reads the fetched data and updates internal domain objects
  # Generally, this should only be called within a "sync", but can be called
  # manually to "re-sync" the already fetched data
  def process_accounts
    enable_banking_accounts.each do |enable_banking_account|
      EnableBankingAccount::Processor.new(enable_banking_account).process
    end
  end

  # Once all the data is fetched, we can schedule account syncs to calculate historical balances
  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    accounts.each do |account|
      account.sync_later(
        parent_sync: parent_sync,
        window_start_date: window_start_date,
        window_end_date: window_end_date
      )
    end
  end
end
