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
        # Set through enrichment, so notes the user edited stay theirs.
        notes: notes_for(leg, part: match_part(leg)),
        extra: extra_for(leg),
        # The "tricount" branch is a snapshot of the entry: a field Tricount
        # stops sending (a category removed) goes, and a transaction the user
        # edited still gets the current one.
        replace_extra_namespaces: [ "tricount" ]
      )
    end

    def match_part(leg)
      leg.external_id.match(PAID_LEG)&.[](:part)
    end

    # What the entry was in Tricount, for the transaction's notes: its
    # category, and the amount as entered with the rate Tricount converted it
    # at when it was entered in another currency than the tricount's.
    def notes_for(leg, part: nil)
      return nil if leg.external_id == "rounding"

      entry = leg.entry
      currency = (leg.currency.presence || tricount_account.currency).to_s
      amount = leg.amount.abs
      lines = []
      lines << I18n.t("tricount_items.transactions.notes.category", category: category_label(entry.category)) if entry.category.present?

      if converted?(entry, currency)
        entered = entered_amount(leg, part)
        if entered
          key = part ? "entered_whole_payment" : "entered"
          lines << I18n.t("tricount_items.transactions.notes.#{key}", amount: format_money(entered.abs, entry.local_currency), currency: entry.local_currency)
        end
        lines << I18n.t("tricount_items.transactions.notes.exchange_rate", from: entry.local_currency, rate: format_rate(entry.exchange_rate), to: currency)
        lines << I18n.t("tricount_items.transactions.notes.converted", amount: format_money(amount, currency), currency: currency)
      else
        lines << I18n.t("tricount_items.transactions.notes.amount", amount: format_money(amount, currency), currency: currency)
      end

      lines.join("\n")
    end

    # Entered in another currency, with a rate and a code Sure knows.
    def converted?(entry, currency)
      entry.local_currency.present? && entry.local_currency != currency &&
        entry.exchange_rate&.positive? && Money::Currency.new(entry.local_currency).present?
    rescue Money::Currency::UnknownCurrencyError
      false
    end

    # The leg's own amount as entered: the member's share, or the whole
    # payment (a part of a split payment has no entered amount of its own).
    def entered_amount(leg, part)
      entry = leg.entry
      if leg.external_id.end_with?(":share")
        entry.local_allocations[tricount_account.member_uuid]
      elsif part || leg.external_id.match?(PAID_LEG)
        entry.local_amount
      end
    end

    # Tricount's own categories are codes (FOOD_AND_DRINK); a custom label is
    # shown as typed.
    def category_label(category)
      category.to_s.match?(/\A[A-Z][A-Z0-9_]*\z/) ? category.to_s.humanize : category.to_s
    end

    def format_money(amount, currency)
      Money.new(amount, currency).format
    end

    # Six significant digits, without trailing zeros: 1 KRW = 0.00321457 MYR.
    def format_rate(rate)
      rounded = rate.round([ 6 - rate.exponent, 0 ].max)
      rounded.to_s("F").sub(/\.0+\z/, "").sub(/(\.\d*?)0+\z/, "\\1")
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
          "total" => leg.entry.amount.abs.to_s("F"),
          "entered_currency" => leg.entry.local_currency,
          "exchange_rate" => leg.entry.exchange_rate&.to_s("F")
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
