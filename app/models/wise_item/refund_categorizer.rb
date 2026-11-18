# frozen_string_literal: true

# Gives each Wise card refund the category of the purchase it refunds.
#
# WiseActivity::Processor books a card refund (a CARD_PAYMENT activity that
# Wise describes as "Refunded", with money coming in) as its own inflow and
# keeps the purchase. Reports net refunds within a category
# (IncomeStatement::CategoryNetting, Budget), so once the refund has the
# purchase's category the pair stops counting as spending and income.
#
# Only certain pairs: the refund is uncategorized and not locked; the purchase
# is in the same account and currency, for exactly the refunded amount, on or
# up to WINDOW before the refund, has a category, and has the same merchant
# name (one may contain the other, as "Vinted" / "Mgp*Vinted Vilnius"); and
# exactly one purchase matches. A partial refund, or one that could be any of
# several purchases, is left as it is.
class WiseItem::RefundCategorizer
  WINDOW = 120.days
  # A shorter name inside a longer one is not taken as the same merchant.
  MIN_CONTAINED_LENGTH = 4

  attr_reader :wise_item

  def initialize(wise_item)
    @wise_item = wise_item
  end

  # Returns how many refunds got a category.
  def categorize!
    refunds.find_each.count do |refund|
      purchase = purchase_for(refund)
      purchase && refund.enrich_attribute(:category_id, purchase.category_id, source: "wise",
                                          metadata: { refund_of_entry_id: purchase.entry.id })
    end
  end

  private
    def refunds
      Transaction.joins(:entry)
                 .where(entries: { account_id: wise_item.accounts.select(:id), source: "wise" })
                 .where("entries.amount < 0")
                 .where(category_id: nil)
                 .where("transactions.extra -> 'wise' ->> 'activity_type' = 'CARD_PAYMENT'")
                 .where("transactions.extra -> 'wise' ->> 'description' = 'Refunded'")
                 .enrichable(:category_id)
                 .includes(:entry)
    end

    def purchase_for(refund)
      entry = refund.entry
      candidates = Transaction.joins(:entry)
                              .where(entries: { account_id: entry.account_id, currency: entry.currency, amount: entry.amount.abs,
                                                date: (entry.date - WINDOW)..entry.date })
                              .where.not(category_id: nil)
                              .where.not(id: refund.id)
                              .includes(:entry)
                              .select { |purchase| same_merchant?(purchase.entry.name, entry.name) }

      candidates.one? ? candidates.first : nil
    end

    def same_merchant?(a, b)
      a = normalize(a)
      b = normalize(b)
      return false if a.empty? || b.empty?
      return true if a == b

      shorter, longer = [ a, b ].sort_by(&:length)
      shorter.length >= MIN_CONTAINED_LENGTH && longer.include?(shorter)
    end

    def normalize(name)
      name.to_s.unicode_normalize(:nfkd).downcase.gsub(/[^a-z0-9 ]/, " ").squeeze(" ").strip
    end
end
