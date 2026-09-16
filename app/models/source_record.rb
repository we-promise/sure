class SourceRecord < ApplicationRecord
  belongs_to :family
  belongs_to :account, optional: true
  belongs_to :account_identity, class_name: "Account::IngestionIdentity", foreign_key: :account_id, optional: true
  belongs_to :external_account, optional: true
  belongs_to :account_statement, optional: true
  belongs_to :ingestion_batch
  has_many :entry_sources, dependent: :destroy
  has_one :entry_source, -> { where(active: true) }
  has_one :entry, through: :entry_source
  has_many :holding_sources, dependent: :destroy
  has_one :holding_source, -> { where(active: true) }

  before_validation :remember_input_identity, on: :create
  before_save :capture_account_identity

  validates :external_id, presence: true
  validates :kind, inclusion: { in: %w[transaction activity holding] }
  validates :input_occurrence, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :consistent_origin
  validate :valid_observation_order
  validate :financial_binding_is_stable
  validate :retired_observation_is_immutable
  attr_readonly :family_id, :external_account_id, :account_statement_id, :kind, :external_id, :input_external_id, :input_occurrence

  private
    def capture_account_identity
      return unless account_id && (new_record? || will_save_change_to_account_id?)
      self.account_identity = Account::IngestionIdentity.capture!(account: account)
    end

    def retired_observation_is_immutable
      return unless account_identity&.retired?
      if new_record? || (changes_to_save.keys - [ "updated_at" ]).any?
        errors.add(:base, "Retired source observations cannot be changed")
      end
    end

    def retained_account_identity?
      account_identity&.retired? && account_identity.id == account_id &&
        account_identity.family_id == family_id && account.nil?
    end

    def valid_observation_order
      unless observation_order.is_a?(Array) && observation_order.all? { |value| value.is_a?(Integer) }
        errors.add(:observation_order, "must contain integer ordering values")
      end
    end

    def remember_input_identity
      self.input_external_id ||= external_id
    end

    def financial_binding_is_stable
      return if new_record? || !will_save_change_to_account_id?
      if account_id_in_database.present?
        errors.add(:account, "cannot change after publication binding")
        return
      end
      # First binding is part of a newly authorized publication, not a side
      # effect of editing an account link or reusing an old retained batch.
      policy = account && Account::SourcePolicy.active.find_by(account: account, resource: ingestion_batch&.stream)
      unless external_account && account && external_account.current_account&.id == account_id &&
          policy && ingestion_batch&.source_policy_version == policy.id
        errors.add(:account, "requires a current link and captured source selection")
      end
    end

    def consistent_origin
      if [ external_account_id, account_statement_id ].compact.size != 1
        errors.add(:base, "Exactly one source is required")
      end
      if (account && account.family_id != family_id) || ingestion_batch&.family_id != family_id
        errors.add(:base, "Source and batch must belong to the account family")
      end
      if external_account
        unless external_account.family_id == family_id && (account_id.nil? || retained_account_identity? || external_account.current_account&.id == account_id) &&
            ingestion_batch&.provider_connection_id == external_account.provider_connection_id &&
            ingestion_batch.external_account_id == external_account_id && supported_external_origin?
          errors.add(:external_account, "must match the batch and linked account")
        end
      elsif account_statement
        unless account_statement.family_id == family_id && (retained_account_identity? || (account && account_statement.account_id == account_id)) &&
            ingestion_batch&.account_statement_id == account_statement_id
          errors.add(:account_statement, "must match the batch and account")
        end
      end
    end

    def supported_external_origin?
      if ingestion_batch.origin_kind == "provider"
        ingestion_batch.stream == { "transaction" => "transactions", "activity" => "activities", "holding" => "holdings" }[kind]
      elsif ingestion_batch.origin_kind == "migration"
        Ingestion::LegacyIdentityEvidence.for_observation!(source_record: self, require_applied: !new_record?)
        true
      else
        false
      end
    rescue Ingestion::LegacyIdentityEvidence::InvalidEvidence
      false
    end
end
