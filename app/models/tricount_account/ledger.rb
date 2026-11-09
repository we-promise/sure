# frozen_string_literal: true

# One member's view of a tricount: their balance and the transactions that
# explain it in Sure.
#
# Tricount signs amounts from the group's side: an expense is negative, money
# the group receives (INCOME) is positive, and each allocation carries the same
# sign as its entry. A member's balance is what the group owes them: their
# allocations less what they paid. Paying 100 for a dinner shared four ways
# leaves +75; a friend paying 40 for a taxi shared four ways takes 10 off.
#
# Each entry becomes up to two transactions in the member's Sure account, whose
# balance is that position:
# - what the member paid, as a transfer leg: the money left one of their own
#   accounts (a card, a bank), and Sure's transfer matching pairs the two;
# - the member's share, as their spending (or income), categorised. A transfer
#   between members (a settle-up, BALANCE in Tricount) is a transfer leg too.
# Paying 100 of which 25 is yours shows 25 of spending, not 100, and the 75
# the others owe you as the account's balance.
#
# What a member paid for an entry can be divided into parts (TricountAccount
# #paid_splits), so a bill paid with two card charges pairs one part with
# each: a leg per part instead of one. Parts that no longer add up to the
# payment (the entry was edited in Tricount) are ignored.
#
# A share split by ratio is stored rounded to the cent, while Tricount works
# out balances from the exact ratios and rounds only the total, so the
# stored shares can drift from Tricount's balance by a few cents. The balance
# follows Tricount, and one rounding leg makes up the difference.
class TricountAccount::Ledger
  Member = Data.define(:uuid, :name, :status)
  Entry = Data.define(:uuid, :date, :description, :category, :type_transaction, :amount, :currency, :payer_uuid, :allocations, :exact_shares, :scale)
  Leg = Data.define(:external_id, :amount, :currency, :date, :name, :kind, :category, :entry)

  ACTIVE = "ACTIVE".freeze
  SETTLE_UP = "BALANCE".freeze
  UNCATEGORIZED = "UNCATEGORIZED".freeze

  # The memberships of a registry payload, wrapped or not.
  def self.members_from(registry)
    Array(registry && registry["memberships"]).filter_map do |wrapper|
      membership = unwrap(wrapper)
      next unless membership.is_a?(Hash) && membership["uuid"].present?

      Member.new(
        uuid: membership["uuid"],
        name: membership.dig("alias", "display_name").presence || membership["display_name"].presence || membership["uuid"],
        status: membership["status"]
      )
    end
  end

  # API objects come wrapped in their type ({"RegistryEntry" => {...}}).
  def self.unwrap(object)
    return object unless object.is_a?(Hash) && object.size == 1

    inner = object.values.first
    inner.is_a?(Hash) ? inner : object
  end

  def initialize(entries_payload)
    @entries = Array(entries_payload).filter_map { |raw| parse_entry(self.class.unwrap(raw)) }
  end

  def entries
    @entries
  end

  def active_entries
    entries.select { |entry| entry_active?(entry) }
  end

  # What the group owes the member, as Tricount shows it: from the exact
  # ratio shares, rounded once.
  def balance_for(member_uuid)
    return BigDecimal("0") if member_uuid.blank?

    exact = active_entries.sum(Rational(0)) do |entry|
      entry.exact_shares.fetch(member_uuid, Rational(0)) - (entry.payer_uuid == member_uuid ? entry.amount.to_r : Rational(0))
    end
    BigDecimal(exact, 20).round(scale)
  end

  # The same from the shares as stored, each rounded to the cent.
  def stored_balance_for(member_uuid)
    return BigDecimal("0") if member_uuid.blank?

    active_entries.sum(BigDecimal("0")) do |entry|
      entry.allocations.fetch(member_uuid, BigDecimal("0")) - (entry.payer_uuid == member_uuid ? entry.amount : BigDecimal("0"))
    end
  end

  # The member's transactions, in Sure's sign (positive is money out of the
  # account). Entries the member neither paid nor shares in give none.
  def legs_for(member_uuid, paid_splits: {})
    return [] if member_uuid.blank?

    active_entries.flat_map do |entry|
      legs = []

      if entry.payer_uuid == member_uuid && entry.amount.nonzero?
        parts = paid_split_parts(entry, paid_splits[entry.uuid])
        if parts
          parts.each_with_index do |part, index|
            legs << Leg.new(
              external_id: "#{entry.uuid}:paid:#{index + 1}", amount: entry.amount.negative? ? -part : part, currency: entry.currency,
              date: entry.date, name: entry.description, kind: "funds_movement", category: nil, entry: entry
            )
          end
        else
          legs << Leg.new(
            external_id: "#{entry.uuid}:paid", amount: entry.amount, currency: entry.currency, date: entry.date,
            name: entry.description, kind: "funds_movement", category: nil, entry: entry
          )
        end
      end

      share = entry.allocations.fetch(member_uuid, BigDecimal("0"))
      if share.nonzero?
        settle_up = entry.type_transaction == SETTLE_UP
        legs << Leg.new(
          external_id: "#{entry.uuid}:share", amount: -share, currency: entry.currency, date: entry.date,
          name: entry.description, kind: settle_up ? "funds_movement" : "standard",
          category: settle_up ? nil : entry.category, entry: entry
        )
      end

      legs
    end.tap { |legs| append_rounding_leg(legs, member_uuid) }
  end

  # The stored splits that still apply: the member paid the entry and the
  # parts add up to what they paid.
  def applicable_paid_splits(member_uuid, paid_splits)
    return {} if member_uuid.blank? || paid_splits.blank?

    paid_entries = active_entries.select { |entry| entry.payer_uuid == member_uuid && entry.amount.nonzero? }.index_by(&:uuid)
    paid_splits.select { |uuid, parts| paid_entries[uuid] && paid_split_parts(paid_entries[uuid], parts) }
  end

  # The parts a payment is divided into, positive amounts adding up to what
  # was paid, at the entry's precision; nil unless there are at least two.
  def paid_split_parts(entry, parts)
    return nil unless parts.is_a?(Array) && parts.size >= 2

    values = parts.map { |part| decimal(part) }
    return nil if values.any? { |value| value.nil? || !value.positive? || value.round(entry.scale) != value }
    return nil unless values.sum == entry.amount.abs

    values
  end

  private

    # The cents between the stored shares and Tricount's balance, dated with
    # the latest entry, so the legs add up to the balance.
    def append_rounding_leg(legs, member_uuid)
      difference = stored_balance_for(member_uuid) - balance_for(member_uuid)
      # Even with no other legs: a member whose stored shares all round to 0.00
      # can still owe a cent once the exact shares are added up.
      return if difference.zero?

      latest = active_entries.max_by(&:date)
      return unless latest

      legs << Leg.new(
        external_id: "rounding", amount: difference, currency: latest.currency, date: latest.date,
        name: nil, kind: "funds_movement", category: nil, entry: latest
      )
    end

    def scale
      active_entries.map(&:scale).max || 2
    end

    def entry_active?(entry)
      entry.uuid.present? && entry.date.present? && (entry.allocations.any? || entry.payer_uuid.present?)
    end

    def parse_entry(raw)
      return nil unless raw.is_a?(Hash)
      return nil if raw["status"].present? && raw["status"] != ACTIVE

      amount = decimal(raw.dig("amount", "value"))
      return nil if amount.nil?

      allocations = Array(raw["allocations"]).each_with_object({}) do |allocation, by_member|
        member_uuid = membership_uuid(allocation["membership"]) || allocation["membership_uuid"]
        value = decimal(allocation.dig("amount", "value"))
        next if member_uuid.blank? || value.nil?

        by_member[member_uuid] = by_member.fetch(member_uuid, BigDecimal("0")) + value
      end

      Entry.new(
        exact_shares: exact_shares(raw, amount, allocations),
        scale: raw.dig("amount", "value").to_s.split(".")[1].to_s.size,
        uuid: raw["uuid"].presence || raw["id"]&.to_s,
        date: parse_date(raw["date"]),
        description: raw["description"].to_s.strip,
        category: entry_category(raw),
        type_transaction: raw["type_transaction"].presence,
        amount: amount,
        currency: raw.dig("amount", "currency"),
        payer_uuid: membership_uuid(raw["membership_owned"]) || raw["membership_uuid_owner"],
        allocations: allocations
      )
    end

    # A custom label the member typed wins over Tricount's own category
    # (GROCERIES, TRANSPORT, FOOD_AND_DRINK, ...); UNCATEGORIZED is none.
    def entry_category(raw)
      category = raw["category_custom"].presence || raw["category"].presence
      category == UNCATEGORIZED ? nil : category
    end

    # Each member's share before rounding: a RATIO allocation's exact part of
    # what the fixed (AMOUNT) allocations leave of the entry.
    def exact_shares(raw, amount, allocations)
      ratio_allocations = Array(raw["allocations"]).select { |allocation| allocation["type"] == "RATIO" && allocation["share_ratio"].to_i.positive? }
      total_ratio = ratio_allocations.sum { |allocation| allocation["share_ratio"].to_i }
      exact = allocations.transform_values(&:to_r)
      return exact if total_ratio.zero?

      fixed = Array(raw["allocations"]).reject { |allocation| ratio_allocations.include?(allocation) }.sum(Rational(0)) { |allocation| decimal(allocation.dig("amount", "value")).to_r }
      ratio_allocations.each do |allocation|
        member_uuid = membership_uuid(allocation["membership"]) || allocation["membership_uuid"]
        exact[member_uuid] = (amount.to_r - fixed) * allocation["share_ratio"].to_i / total_ratio if member_uuid
      end
      exact
    end

    def membership_uuid(membership)
      return nil unless membership.is_a?(Hash)

      self.class.unwrap(membership)["uuid"].presence
    end

    def decimal(value)
      return nil if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end

    def parse_date(value)
      Date.iso8601(value.to_s[0, 10])
    rescue ArgumentError
      nil
    end
end
