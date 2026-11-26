# What family members bought and when, from forwarded order emails and scanned receipts.
class Assistant::Function::GetPurchases < Assistant::Function
  DEFAULT_LIMIT = 20
  MAX_LIMIT = 50

  class << self
    def name
      "get_purchases"
    end

    def description
      <<~INSTRUCTIONS
        Returns purchases the user recorded from forwarded order emails and scanned receipts:
        the shop, order date and number, total, status, the transaction that paid for it when
        known, and each item bought with its quantity, amount and category.

        Use this for questions about what was bought and when, e.g. "when did I buy the vacuum
        filter?", "what did I order from Amazon last month?" or "how much did I spend on mugs?".
        `query` matches shop names, order numbers and item names. Newest purchases first.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [],
      properties: {
        query: { type: "string", description: "Text to find in shop names, order numbers or item names" },
        start_date: { type: "string", description: "Earliest order date, YYYY-MM-DD" },
        end_date: { type: "string", description: "Latest order date, YYYY-MM-DD" },
        category: { type: "string", description: "Only purchases with an item in this category (exact name)" },
        status: { type: "string", enum: Purchase.statuses.keys, description: "Only purchases in this state" },
        limit: { type: "integer", minimum: 1, maximum: MAX_LIMIT, description: "Defaults to #{DEFAULT_LIMIT}" }
      }
    )
  end

  def call(params = {})
    # Read once per call: the function serves several calls, and access can change in between.
    @accessible_account_ids = nil
    scope = filtered(Purchase.visible_to(user).where(family:), params)
    purchases = scope
      .includes(items: :category, linked_transaction: { entry: :account })
      .order(Arel.sql("purchases.ordered_on DESC NULLS LAST"), created_at: :desc)
      .limit(limit(params))

    { purchases: purchases.map { serialize(_1) }, total_results: scope.count }
  end

  private
    def filtered(scope, params)
      if params["query"].present?
        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(params["query"])}%"
        scope = scope.where(
          "purchases.merchant ILIKE :q OR purchases.order_number ILIKE :q OR EXISTS (" \
          "SELECT 1 FROM purchase_items WHERE purchase_items.purchase_id = purchases.id AND purchase_items.name ILIKE :q)",
          q: pattern
        )
      end
      scope = scope.where(ordered_on: date(params["start_date"])..) if date(params["start_date"])
      scope = scope.where(ordered_on: ..date(params["end_date"])) if date(params["end_date"])
      scope = scope.where(status: params["status"]) if params["status"].in?(Purchase.statuses.keys)
      if params["category"].present?
        category_ids = family.categories.where("lower(name) = ?", params["category"].downcase).select(:id)
        scope = scope.where(id: PurchaseItem.where(category_id: category_ids).select(:purchase_id))
      end
      scope
    end

    def limit(params)
      (params["limit"].presence || DEFAULT_LIMIT).to_i.clamp(1, MAX_LIMIT)
    end

    def date(value)
      Date.iso8601(value.to_s) if value.present?
    rescue Date::Error
      nil
    end

    def serialize(purchase)
      entry = purchase.linked_transaction&.entry
      entry = nil unless entry && accessible_account_ids.include?(entry.account_id)

      {
        id: purchase.id,
        source: purchase.source,
        merchant: purchase.merchant,
        order_number: purchase.order_number,
        ordered_on: purchase.ordered_on&.iso8601,
        total: purchase.total&.to_s("F"),
        currency: purchase.currency,
        status: purchase.status,
        account_name: entry&.account&.name,
        transaction_id: entry ? purchase.transaction_id : nil,
        items: purchase.items.map do |item|
          { name: item.name, quantity: item.quantity&.to_s("F"), amount: item.amount&.to_s("F"), category: item.category&.name }
        end
      }
    end

    def accessible_account_ids
      @accessible_account_ids ||= Account.accessible_by(user).pluck(:id).to_set
    end
end
