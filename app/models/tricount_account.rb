# frozen_string_literal: true

class TricountAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable
  include TricountAccount::DataHelpers

  # The snapshots hold the members' names and every expense, as the other
  # providers' raw payloads do.
  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :tricount_item

  # Association through account_providers
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  # A sharing token grants write access to its tricount, so it stays in the
  # encrypted TricountItem#sharing_tokens and out of the stored snapshots.
  CREDENTIAL_KEYS = %w[public_identifier_token].freeze

  # Parts that are fewer than two, not positive, or don't add up to the payment.
  class InvalidPaymentSplit < StandardError; end

  validates :name, :currency, presence: true

  # Scopes
  scope :with_linked, -> { joins(:account_provider) }
  scope :without_linked, -> { left_joins(:account_provider).where(account_providers: { id: nil }) }
  scope :ordered, -> { order(created_at: :desc) }

  # Callbacks
  after_destroy :enqueue_connection_cleanup

  # Helper to get account using account_providers system
  def current_account
    account
  end

  # Idempotently create or update AccountProvider link
  # CRITICAL: After creation, reload association to avoid stale nil
  def ensure_account_provider!(linked_account)
    return nil unless linked_account

    provider = account_provider || build_account_provider
    provider.account = linked_account
    provider.save!

    # Reload to clear cached nil value
    reload_account_provider
    account_provider
  end

  # Stores a tricount (a registry payload, memberships and entries included).
  # The entries are kept whole, so an expense deleted in Tricount leaves the
  # snapshot and its transactions with it.
  def upsert_from_tricount!(registry)
    entries = Array(registry["all_registry_entry"]).map { |entry| TricountAccount::Ledger.unwrap(entry) }

    assign_attributes(
      tricount_account_id: registry["uuid"].to_s,
      name: registry["title"].presence || registry["uuid"].to_s,
      currency: parse_currency(registry["currency"]),
      account_status: registry["status"],
      account_type: "tricount",
      provider: "tricount",
      institution_metadata: TricountItem::INSTITUTION.transform_keys(&:to_s),
      raw_payload: without_credentials(registry.except("all_registry_entry")),
      raw_transactions_payload: without_credentials(entries)
    )
    self.member_uuid = nil if member_uuid.present? && members.none? { |member| member.uuid == member_uuid }
    self.current_balance = member_uuid.present? ? ledger.balance_for(member_uuid) : nil
    # A split whose entry was edited, deleted or paid by someone else goes.
    self.paid_splits = ledger.applicable_paid_splits(member_uuid, paid_splits)
    save!
  end

  # The tricount's members, for choosing which one is the account's owner.
  def members
    TricountAccount::Ledger.members_from(raw_payload)
  end

  def member
    members.find { |candidate| candidate.uuid == member_uuid }
  end

  def ledger
    TricountAccount::Ledger.new(raw_transactions_payload)
  end

  # Expenses, incomes and transfers still in the tricount (deleted ones left out).
  def active_entry_count
    ledger.active_entries.size
  end

  # Chooses the member whose position this account follows.
  def assign_member!(uuid)
    raise ArgumentError, "Unknown Tricount member" unless members.any? { |candidate| candidate.uuid == uuid }

    update!(member_uuid: uuid, current_balance: ledger.balance_for(uuid), paid_splits: ledger.applicable_paid_splits(uuid, paid_splits))
  end

  # Divides what the member paid for an entry into parts (amount strings), so
  # each pairs with its own card or bank charge, and rewrites the account's
  # transactions. The entry's payment row, and any match it had, is replaced
  # by one row per part.
  def split_payment!(entry_uuid, parts)
    values = Array(parts).map { |part| part.to_s.strip }.compact_blank
    raise InvalidPaymentSplit unless ledger.applicable_paid_splits(member_uuid, { entry_uuid => values }).any?

    replace_payment_rows!(entry_uuid) { update!(paid_splits: paid_splits.merge(entry_uuid => values)) }
  end

  # Puts an entry's payment back into one row.
  def remove_payment_split!(entry_uuid)
    return unless paid_splits.key?(entry_uuid)

    replace_payment_rows!(entry_uuid) { update!(paid_splits: paid_splits.except(entry_uuid)) }
  end

  private

    # Removes the entry's payment rows (whole or in parts) and writes the
    # account's transactions again, so the new rows appear at once. Rows the
    # user edited would otherwise stay beside the new ones.
    def replace_payment_rows!(entry_uuid)
      account = current_account
      transaction do
        yield
        if account
          pattern = "#{self.class.sanitize_sql_like(entry_uuid)}:paid:%"
          account.entries.where(source: TricountAccount::Transactions::Processor::SOURCE, entryable_type: "Transaction")
            .where("external_id = ? OR external_id LIKE ?", "#{entry_uuid}:paid", pattern)
            .find_each(&:destroy!)
        end
      end
      return unless account

      TricountAccount::Processor.new(self).process
      account.sync_later
    end

    def without_credentials(value)
      case value
      when Hash then value.except(*CREDENTIAL_KEYS).transform_values { |nested| without_credentials(nested) }
      when Array then value.map { |nested| without_credentials(nested) }
      else value
      end
    end

    def enqueue_connection_cleanup
      return unless tricount_item

      TricountConnectionCleanupJob.perform_later(
        tricount_item_id: tricount_item.id,
        account_id: id
      )
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Tricount account #{id}, keeping #{currency || "EUR"}")
    end
end
