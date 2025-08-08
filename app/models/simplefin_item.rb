class SimplefinItem < ApplicationRecord
  include Syncable, Provided

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  # Virtual attribute for the setup token form field
  attr_accessor :setup_token

  if Rails.application.credentials.active_record_encryption.present?
    encrypts :access_url, deterministic: true
  end

  validates :name, :access_url, presence: true

  before_destroy :remove_simplefin_item

  belongs_to :family
  has_one_attached :logo

  has_many :simplefin_accounts, dependent: :destroy
  has_many :accounts, through: :simplefin_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_simplefin_data
    SimplefinItem::Importer.new(self, simplefin_provider: simplefin_provider).import
  end

  def process_accounts
    simplefin_accounts.each do |simplefin_account|
      SimplefinAccount::Processor.new(simplefin_account).process
    end
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    accounts.each do |account|
      account.sync_later(
        parent_sync: parent_sync,
        window_start_date: window_start_date,
        window_end_date: window_end_date
      )
    end
  end

  def upsert_simplefin_snapshot!(accounts_snapshot)
    assign_attributes(
      raw_payload: accounts_snapshot,
    )

    save!
  end

  def upsert_simplefin_institution_snapshot!(institution_snapshot)
    assign_attributes(
      institution_id: institution_snapshot[:id],
      institution_name: institution_snapshot[:name],
      institution_url: institution_snapshot[:url],
      raw_institution_payload: institution_snapshot
    )

    save!
  end

  private
    def remove_simplefin_item
      # SimpleFin doesn't require server-side cleanup like Plaid
      # The access URL just becomes inactive
    end
end
