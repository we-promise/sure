class BankConnection < ApplicationRecord
  include Syncable

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if Rails.application.credentials.active_record_encryption.present?
    encrypts :credentials, deterministic: true
  end

  belongs_to :family
  has_one_attached :logo

  has_many :bank_external_accounts, dependent: :destroy
  has_many :accounts, through: :bank_external_accounts

  validates :name, :provider, presence: true

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_bank_data
    BankConnection::Importer.new(self, bank_provider: bank_provider).import
  end

  def process_accounts
    bank_external_accounts.each do |ext_account|
      BankExternalAccount::Processor.new(ext_account, mapper: bank_mapper).process
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

  def upsert_bank_snapshot!(data)
    assign_attributes(raw_payload: data)
    save!
  end

  def bank_provider
    creds = begin
      case credentials
      when String
        JSON.parse(credentials)
      when Hash
        credentials
      else
        {}
      end
    rescue JSON::ParserError
      {}
    end
    @bank_provider ||= Provider::Banks::Registry.get_instance(provider.to_sym, creds)
  end

  def bank_mapper
    @bank_mapper ||= Provider::Banks::Registry.get_mapper(provider.to_sym)
  end
end
