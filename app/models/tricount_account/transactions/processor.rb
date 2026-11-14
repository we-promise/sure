# frozen_string_literal: true

# Writes the account owner's transactions from the stored tricount (see
# TricountAccount::Ledger): what they paid as transfer legs, their share as
# spending. A transaction whose entry was deleted or edited away in Tricount
# is removed, so the account always adds up to the owner's balance there.
class TricountAccount::Transactions::Processor
  SOURCE = "tricount".freeze
  # What the member paid for an entry, whole or one part of it.
  PAID_LEG = /:paid(?::(?<part>\d+))?\z/

  attr_reader :tricount_account

  def initialize(tricount_account)
    @tricount_account = tricount_account
  end

  def process
    return { success: true, total: 0, imported: 0, failed: 0, removed: 0, errors: [] } unless account

    # No legs when no member is followed (the one followed left the
    # tricount), so the transactions imported for them are removed below,
    # matching the balance, which drops to zero.
    legs = tricount_account.ledger.legs_for(tricount_account.member_uuid, paid_splits: tricount_account.paid_splits)
    imported = 0
    errors = []

    legs.each do |leg|
      import_leg(leg)
      imported += 1
    rescue ActiveRecord::ActiveRecordError, ArgumentError => e
      Rails.logger.error "TricountAccount::Transactions::Processor - Failed to import #{leg.external_id}: #{e.class}"
      errors << { external_id: leg.external_id, error: e.class.name }
    end

    removed = errors.empty? ? remove_stale_entries(legs.map(&:external_id)) : 0

    { success: errors.empty?, total: legs.size, imported: imported, failed: errors.size, removed: removed, errors: errors }
  end

  private

    def account
      @account ||= tricount_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def category_matcher
      @category_matcher ||= TricountAccount::Transactions::CategoryMatcher.new(account.family.categories.to_a)
    end

    def import_leg(leg)
      name =
        if leg.external_id == "rounding"
          I18n.t("tricount_items.transactions.rounding_name")
        elsif (match = leg.external_id.match(PAID_LEG))
          # A positive amount is money out of the tricount: received for the group.
          key = leg.amount.positive? ? "received" : "paid"
          description = leg.name.presence || tricount_account.name
          if match[:part]
            parts = tricount_account.paid_splits.fetch(leg.entry.uuid, []).size
            I18n.t("tricount_items.transactions.#{key}_part_name", description: description, part: match[:part], parts: parts)
          else
            I18n.t("tricount_items.transactions.#{key}_name", description: description)
          end
        else
          leg.name.presence || tricount_account.name
        end

      import_adapter.import_transaction(
        external_id: leg.external_id,
        amount: leg.amount,
        currency: leg.currency.presence || tricount_account.currency,
        date: leg.date,
        name: name.truncate(255),
        source: SOURCE,
        kind: leg.kind,
        category_id: leg.category && category_matcher.match(leg.category)&.id,
        allow_heuristic_matching: false,
        extra: extra_for(leg),
        # The "tricount" branch is a snapshot of the entry: a field Tricount
        # stops sending (a category removed) goes, and a transaction the user
        # edited still gets the current one.
        replace_extra_namespaces: [ "tricount" ]
      )
    end

    def extra_for(leg)
      payer = tricount_account.members.find { |member| member.uuid == leg.entry.payer_uuid }

      {
        "tricount" => {
          "entry_uuid" => leg.entry.uuid,
          "leg" => leg_kind(leg),
          "part" => leg.external_id.match(PAID_LEG)&.[](:part)&.to_i,
          "category" => leg.entry.category,
          "type_transaction" => leg.entry.type_transaction,
          "paid_by" => payer&.name,
          "total" => leg.entry.amount.abs.to_s("F")
        }.compact
      }
    end

    def leg_kind(leg)
      parts = leg.external_id.split(":")
      parts.size > 1 ? parts[1] : parts.first
    end

    # Removes this provider's transactions that no longer have a leg: the entry
    # was deleted in Tricount, or the account follows another member now. One
    # the user edited, excluded or locked is theirs now and stays.
    def remove_stale_entries(external_ids)
      stale = account.entries.where(source: SOURCE, entryable_type: "Transaction").where.not(external_id: external_ids)
      count = 0
      stale.find_each do |entry|
        next if entry.protected_from_sync?

        entry.destroy!
        count += 1
      end
      count
    end
end
