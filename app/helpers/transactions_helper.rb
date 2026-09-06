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
  #     kind: :simplefin | :plaid | :raw,
  #     simplefin: { payee:, description:, memo: },
  #     plaid: { original_description:, payment_channel:, transaction_code: },
  #     provider_extras: [ { key:, value:, multiline: } ],
  #       multiline marks values the view should render in a <pre> block
  #       rather than inline opposite their label.
  #     raw: String (pretty JSON) — only set for :raw, where we have no
  #       structured rendering for the provider
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
          extras.concat(provider_extra_rows(k, v))
        end
      end

      {
        kind: :simplefin,
        simplefin: simple,
        plaid: {},
        provider_extras: extras,
        raw: nil
      }
    elsif extra.is_a?(Hash) && extra["plaid"].present?
      plaid = extra["plaid"]
      simple = {
        original_description: plaid.is_a?(Hash) ? plaid["original_description"].presence : nil,
        payment_channel: plaid.is_a?(Hash) ? plaid["payment_channel"].presence : nil,
        transaction_code: plaid.is_a?(Hash) ? plaid["transaction_code"].presence : nil
      }.compact

      extras = []
      if plaid.is_a?(Hash)
        if plaid["payment_meta"].is_a?(Hash) && plaid["payment_meta"].present?
          plaid["payment_meta"].each do |k, v|
            extras.concat(provider_extra_rows(t("transactions.show.plaid_payment_meta_label", name: k), v))
          end
        end

        if plaid["counterparties"].is_a?(Array) && plaid["counterparties"].present?
          plaid["counterparties"].each_with_index do |counterparty, index|
            extras.concat(provider_extra_rows(t("transactions.show.plaid_counterparty_label", index: index + 1), counterparty))
          end
        end
      end

      # Only show Additional details when there is something beyond pending flags
      return nil if simple.blank? && extras.blank?

      {
        kind: :plaid,
        simplefin: {},
        plaid: simple,
        provider_extras: extras,
        # No raw dump: the structured rows above already cover the payload, and
        # the only fields they omit (pending, pending_transaction_id) are what
        # the pending badge communicates.
        raw: nil
      }
    else
      {
        kind: :raw,
        simplefin: {},
        plaid: {},
        provider_extras: [],
        raw: pretty_json(extra)
      }
    end
  end

  # Flatten hashes into labeled rows; pretty-print remaining nested structures.
  def provider_extra_rows(key, value, depth: 0)
    label = key.to_s

    case value
    when Hash
      value.flat_map do |child_key, child_value|
        next [] if child_value.nil? || child_value == ""

        child_label = depth.zero? ? "#{label} · #{child_key}" : "#{label}.#{child_key}"
        provider_extra_rows(child_label, child_value, depth: depth + 1)
      end
    when Array
      if value.all? { |item| !item.is_a?(Hash) && !item.is_a?(Array) }
        [ provider_extra_row(label, value.join(", ")) ]
      else
        # Pass the raw value — provider_extra_row does the single encode. Handing
        # it a pretty_json string here would re-encode it into an escaped one-liner.
        [ provider_extra_row(label, value, multiline: true) ]
      end
    else
      [ provider_extra_row(label, value) ]
    end
  end

  def provider_extra_row(key, value, multiline: false)
    display = if multiline || value.is_a?(Hash) || value.is_a?(Array)
      pretty_json(value)
    else
      value
    end

    {
      key: key.to_s.humanize,
      value: display,
      multiline: multiline || value.is_a?(Hash) || value.is_a?(Array)
    }
  end

  def pretty_json(value)
    JSON.pretty_generate(value)
  rescue StandardError
    value.to_s
  end
end
