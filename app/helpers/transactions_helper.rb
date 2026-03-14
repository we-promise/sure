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
      pretty = begin
        JSON.pretty_generate(extra)
      rescue StandardError
        extra.to_s
      end
      {
        kind: :raw,
        simplefin: {},
        provider_extras: [],
        raw: pretty
      }
    end
  end

  # Generates hidden field tags for persisting search query parameters
  # across form submissions, skipping the active_accounts_only parameter.
  def hidden_query_params(q_params)
    return "".html_safe if q_params.blank?

    q_hash = q_params.respond_to?(:to_unsafe_h) ? q_params.to_unsafe_h : q_params.to_h

    fields = q_hash.each_with_object([]) do |(key, value), tags|
      key_str = key.to_s
      next if key_str == "active_accounts_only"

      if value.is_a?(Array)
        value.each { |v| tags << hidden_field_tag("q[#{key_str}][]", v) }
      else
        tags << hidden_field_tag("q[#{key_str}]", value)
      end
    end

    safe_join(fields)
  end
end
