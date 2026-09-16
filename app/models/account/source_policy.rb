# Source selection is explicit and versioned. It gates automated imports only;
# publication of a reviewed document is an independently authorized operation.
class Account::SourcePolicy < ApplicationRecord
  self.table_name = "account_source_policies"
  RESOURCES = %w[transactions balances holdings activities historical_balances].freeze
  CASH_RESOURCES = %w[transactions activities].freeze

  belongs_to :account, optional: true
  belongs_to :account_identity, class_name: "Account::IngestionIdentity", foreign_key: :account_id, optional: true
  belongs_to :family
  belongs_to :account_provider, optional: true
  before_create :capture_source_binding
  scope :active, -> { where(active: true) }
  validates :resource, inclusion: { in: RESOURCES }
  validates :revision, numericality: { only_integer: true, greater_than: 0 }
  validate :same_account_and_family
  validate :consistent_cash_source
  validate :captured_source_is_valid
  validate :deactivated_revision_is_final
  attr_readonly :account_id, :family_id, :account_provider_id, :resource, :revision, :source_binding

  def self.select!(account:, account_provider:, resource:)
    select_many!(account: account, account_provider: account_provider, resources: [ resource ]).first
  end

  def self.select_many!(account:, account_provider:, resources:)
    raise ArgumentError, "Source belongs to another account" unless account_provider.account_id == account.id
    unless resources.is_a?(Array) && resources.any? && resources.uniq == resources && (resources - RESOURCES).empty?
      raise ArgumentError, "Select known distinct resources"
    end
    # A caller may rescue selection failure inside its own transaction.
    # Deactivations and every new revision must still roll back together.
    account.with_lock(requires_new: true) do
      account_provider.reload
      raise ArgumentError, "Source belongs to another account" unless account_provider.account_id == account.id
      account_provider.update!(family_id: account.family_id) if account_provider.family_id.nil?
      current = active.where(account: account, resource: resources).index_by(&:resource)
      changing = resources.reject do |resource|
        selected = current[resource]
        next false unless selected&.account_provider_id == account_provider.id && selected.source_binding.present?
        Binding.verify_live!(policy: selected)
      end
      active.where(account: account, resource: changing).update_all(active: false, updated_at: Time.current)
      resources.map do |resource|
        next current.fetch(resource) unless changing.include?(resource)
        revision = (where(account: account, resource: resource).maximum(:revision) || 0) + 1
        create!(account: account, family: account.family, account_provider: account_provider, resource: resource, revision: revision)
      end
    end
  end

  private
    def capture_source_binding
      captured = Binding.capture!(account: account, account_provider: account_provider)
      unless source_binding.blank? || source_binding == captured
        raise Binding::Conflict, "Source policy differs from its selected owner"
      end
      self.source_binding = captured
    end

    def captured_source_is_valid
      return if source_binding == {} || (new_record? && source_binding.nil?)
      Binding.validate!(source_binding, policy: self)
    rescue Binding::Conflict
      errors.add(:source_binding, "must preserve the selected source owner")
    end

    def deactivated_revision_is_final
      if persisted? && active? && will_save_change_to_active? && !active_in_database
        errors.add(:active, "requires a new source selection revision")
      end
    end

    def consistent_cash_source
      return unless active? && CASH_RESOURCES.include?(resource)
      if self.class.active.where(account_id: account_id, resource: CASH_RESOURCES)
          .where.not(account_provider_id: account_provider_id).where.not(id: id).exists?
        errors.add(:account_provider, "must also own cash movements delivered by transaction and activity feeds")
      end
    end

    def same_account_and_family
      valid = if !new_record? && !active? && source_binding.present?
        account_identity&.family_id == family_id
      else
        account && account_provider && account.family_id == family_id &&
          account_provider.account_id == account_id && account_provider.family_id == family_id
      end
      unless valid
        errors.add(:account_provider, "must belong to the selected account and family")
      end
    end
end
