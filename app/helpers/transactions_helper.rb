module TransactionsHelper
  def transaction_search_filters
    [
      { key: "account_filter", label: t("transactions.search.filters.account"), icon: "layers" },
      { key: "date_filter", label: t("transactions.search.filters.date"), icon: "calendar" },
      { key: "type_filter", label: t("transactions.search.filters.type"), icon: "tag" },
      { key: "status_filter", label: t("transactions.search.filters.status"), icon: "clock" },
      { key: "amount_filter", label: t("transactions.search.filters.amount"), icon: "hash" },
      { key: "category_filter", label: t("transactions.search.filters.category"), icon: "shapes" },
      { key: "tag_filter", label: t("transactions.search.filters.tag"), icon: "tags" },
      { key: "merchant_filter", label: t("transactions.search.filters.merchant"), icon: "store" }
    ]
  end

  def get_transaction_search_filter_partial_path(filter)
    "transactions/searches/filters/#{filter[:key]}"
  end

  def get_default_transaction_search_filter
    transaction_search_filters[0]
  end

  def in_split_group?(entry, params_grouped)
    entry.split_child? && Current.user.show_split_grouped? && params_grouped == "true"
  end

  # ---- Transaction extra details helpers ----
  # Returns a structured hash describing extra details for a transaction.
  # Input can be a Transaction or an Entry (responds_to :transaction).
  # Structure:
  #   {
  #     kind: :simplefin | :raw,
  #     simplefin: { payee:, description:, memo: },
  #     provider_extras: [ { key:, value:, title: } ],
  #     raw: String (pretty JSON or string)
  #   }
  def build_transaction_extra_details(obj)
    tx = obj.respond_to?(:transaction) ? obj.transaction : obj
    return nil unless tx.respond_to?(:extra) && tx.extra.present?

    extra = tx.extra

    if extra.is_a?(Hash) && extra["simplefin"].present?
      sf = extra["simplefin"]
      simple = {
        payee: sf.is_a?(Hash) ? sf["payee"].presence : nil,
        description: sf.is_a?(Hash) ? sf["description"].presence : nil,
        memo: sf.is_a?(Hash) ? sf["memo"].presence : nil
      }.compact

      extras = []
      if sf.is_a?(Hash) && sf["extra"].is_a?(Hash) && sf["extra"].present?
        sf["extra"].each do |k, v|
          display = (v.is_a?(Hash) || v.is_a?(Array)) ? v.to_json : v
          extras << {
            key: k.to_s.humanize,
            value: display,
            title: (v.is_a?(String) ? v : display.to_s)
          }
        end
      end

      {
        kind: :simplefin,
        simplefin: simple,
        provider_extras: extras,
        raw: nil
      }
    else
      filtered = extra.is_a?(Hash) ? extra.dup : extra
      filtered.delete("exchange_rate") if filtered.respond_to?(:delete)
      filtered.delete("exchange_rate_invalid") if filtered.respond_to?(:delete)
      filtered.delete("plaid") if filtered.respond_to?(:delete)
      filtered.delete("lunchflow") if filtered.respond_to?(:delete)

      if filtered.respond_to?(:empty?) ? filtered.empty? : filtered.to_s.blank?
        return nil
      end

      pretty = begin
        JSON.pretty_generate(filtered)
      rescue StandardError
        filtered.to_s
      end
      {
        kind: :raw,
        simplefin: {},
        provider_extras: [],
        raw: pretty
      }
    end
  end
end
