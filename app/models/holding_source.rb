class HoldingSource < ApplicationRecord
  belongs_to :source_record
  belongs_to :holding, optional: true
  belongs_to :account, optional: true
  belongs_to :account_identity, class_name: "Account::IngestionIdentity", foreign_key: :account_id
  belongs_to :family

  before_validation :remember_holding_identity, on: :create
  validates :holding_identity, presence: true
  validates :holding, presence: true, if: :active?
  validates :source_record_id, uniqueness: { conditions: -> { where(active: true) } }, if: :active?
  validates :role, inclusion: { in: %w[posting evidence] }
  validate :same_account_and_family
  attr_readonly :source_record_id, :holding_id, :holding_identity, :account_id, :family_id, :role

  private
    def remember_holding_identity
      self.holding_identity ||= holding_id
    end

    def same_account_and_family
      unless source_record&.kind == "holding" && source_record.account_id == account_id &&
          source_record.family_id == family_id && valid_account_identity? &&
          (!holding || (holding.account_id == account_id && holding.id == holding_identity))
        errors.add(:base, "Evidence and holding must belong to the same account and family")
      end
    end

    def valid_account_identity?
      identity = account_identity
      return false unless identity && identity.family_id == family_id
      if identity.retired?
        !new_record? && account.nil? && !active? && holding_id.nil?
      else
        identity.live_account_id == account_id && account&.family_id == family_id
      end
    end
end
