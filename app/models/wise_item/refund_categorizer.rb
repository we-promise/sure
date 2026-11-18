# frozen_string_literal: true

# Gives each Wise card refund the category of the purchase it refunds.
#
# WiseActivity::Processor books a card refund (a CARD_PAYMENT activity that
# Wise describes as "Refunded", with money coming in) as its own inflow and
# keeps the purchase. Once a balance has statements, WiseStatement::Processor
# books it instead, as a CREDIT row sharing the purchase's "CARD-<id>"
# reference. Reports net refunds within a category
# (IncomeStatement::CategoryNetting, Budget), so once the refund has the
# purchase's category the pair stops counting as spending and income.
#
# Only certain pairs: the refund is uncategorized and not locked; the purchase
# is in the same account and currency, for exactly the refunded amount, on or
# up to WINDOW before the refund, and is the same card transaction (same
# "CARD-<id>") or, for an activity refund, has the same merchant name (one
# may contain the other, as "Vinted" / "Mgp*Vinted Vilnius"); exactly one
# purchase matches, and it has a category. A partial refund, or one that
# could be any of several purchases, is left as it is.
class WiseItem::RefundCategorizer
  WINDOW = 120.days
  # A shorter name inside a longer one is not taken as the same merchant.
  MIN_CONTAINED_LENGTH = 4
  CARD_REFERENCE_PREFIX = "CARD-"

  attr_reader :wise_item

  def initialize(wise_item)
    @wise_item = wise_item
  end

  # Returns how many refunds got a category.
  def categorize!
    refunds.find_each.count do |refund|
      purchase = purchase_for(refund)
      purchase && categorize(refund, purchase)
    end
  end

  private
    def refunds
      Transaction.joins(:entry)
                 .where(entries: { account_id: wise_item.accounts.select(:id), source: "wise" })
                 .where("entries.amount < 0")
                 .where(category_id: nil)
                 .where(<<~SQL.squish, card_reference: "#{CARD_REFERENCE_PREFIX}%")
                   (transactions.extra -> 'wise' ->> 'activity_type' = 'CARD_PAYMENT'
                     AND transactions.extra -> 'wise' ->> 'description' = 'Refunded')
                   OR (transactions.extra -> 'wise' ->> 'statement_type' = 'CREDIT'
                     AND transactions.extra -> 'wise' ->> 'reference' LIKE :card_reference)
                 SQL
                 .enrichable(:category_id)
                 .includes(:entry)
    end

    # The single purchase the refund can be of, when it has a category. Every
    # matching purchase counts towards that, categorized or not.
    def purchase_for(refund)
      entry = refund.entry
      matching = Transaction.joins(:entry)
                            .where(entries: { account_id: entry.account_id, currency: entry.currency, amount: entry.amount.abs,
                                              date: (entry.date - WINDOW)..entry.date })
                            .where.not(id: refund.id)
                            .includes(:entry)
                            .select { |purchase| same_purchase?(purchase, refund) }
      return unless matching.one?

      purchase = matching.first
      purchase if purchase.category_id.present?
    end

    # Under a row lock, on the refund as it is now: a category a person set
    # or locked meanwhile stays.
    def categorize(refund, purchase)
      refund.with_lock do
        refund.category_id.nil? &&
          refund.enrich_attribute(:category_id, purchase.category_id, source: "wise",
                                  metadata: { refund_of_entry_id: purchase.entry.id })
      end
    end

    # A statement row's name is Wise's description of the movement, not the
    # merchant, so a statement refund only matches its card transaction.
    def same_purchase?(purchase, refund)
      reference = card_reference(refund)
      return true if reference && card_reference(purchase) == reference
      return false if statement_row?(refund)

      same_merchant?(purchase.entry.name, refund.entry.name)
    end

    # "CARD-<id>": a statement row's reference, or an activity's card
    # transaction (WiseItem::StatementMigration matches them the same way).
    def card_reference(transaction)
      wise = wise_extra(transaction)
      reference = wise["reference"].to_s
      return reference if reference.start_with?(CARD_REFERENCE_PREFIX)

      "#{CARD_REFERENCE_PREFIX}#{wise['resource_id']}" if wise["activity_type"] == "CARD_PAYMENT" && wise["resource_id"].present?
    end

    def statement_row?(transaction)
      wise_extra(transaction)["statement_type"].present?
    end

    def wise_extra(transaction)
      wise = transaction.extra.is_a?(Hash) ? transaction.extra["wise"] : nil
      wise.is_a?(Hash) ? wise : {}
    end

    def same_merchant?(a, b)
      a = normalize(a)
      b = normalize(b)
      return false if a.empty? || b.empty?
      return true if a == b

      shorter, longer = [ a, b ].sort_by(&:length)
      shorter.length >= MIN_CONTAINED_LENGTH && longer.include?(shorter)
    end

    # Letters and digits of any script, accents dropped ("Café" is "cafe").
    def normalize(name)
      name.to_s.unicode_normalize(:nfkd).gsub(/\p{M}/, "").downcase.gsub(/[^\p{L}\p{N} ]/, " ").squeeze(" ").strip
    end
end
