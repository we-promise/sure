class YaxiItem < ApplicationRecord
  include Encryptable

  enum :status, { connecting: "connecting", good: "good", requires_update: "requires_update" }, default: :connecting

  if encryption_ready?
    encrypts :credential_secret
  end

  belongs_to :family
  has_many :yaxi_accounts, dependent: :destroy
  has_many :accounts, through: :yaxi_accounts

  validates :name, :credential_storage_id, :credential_secret, presence: true
  validates :credential_storage_id, uniqueness: { scope: :family_id }

  scope :ordered, -> { order(created_at: :desc) }

  before_validation :set_browser_credential_keys, on: :create

  def complete_connection!(accounts_result:, connection_info:)
    snapshots = Array(accounts_result)
    raise Provider::Yaxi::InvalidResultError, "YAXI returned no accounts" if snapshots.empty?

    transaction do
      update!(
        connection_id: connection_info["id"],
        institution_name: connection_info["displayName"].presence || name,
        logo_id: connection_info["logoId"],
        name: connection_info["displayName"].presence || name,
        status: :good
      )

      snapshots.each do |snapshot|
        yaxi_account = yaxi_accounts.find_or_initialize_by(external_id: YaxiAccount.external_id_for(snapshot))
        yaxi_account.apply_snapshot!(snapshot)
        yaxi_account.ensure_linked_account!
      end
    end
  end

  def credential_secret_bytes
    Base64.strict_decode64(credential_secret)
  end

  private

    def set_browser_credential_keys
      self.credential_storage_id ||= SecureRandom.uuid
      self.credential_secret ||= Base64.strict_encode64(SecureRandom.random_bytes(32))
    end
end
