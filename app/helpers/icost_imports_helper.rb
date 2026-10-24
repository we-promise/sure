module IcostImportsHelper
  def icost_record_visible?(record)
    return false unless record && Current.user && record.family_id == Current.family.id
    return true if record.icost_import.user_id == Current.user.id

    account_ids = [ record.entry&.account_id, record.counterpart_entry&.account_id ].compact.uniq
    account_ids.any? && Current.accessible_accounts.where(id: account_ids).count == account_ids.length
  end

  def icost_account_resolution?(record)
    %w[支出 收入].include?(record.transaction_type) &&
      ((record.issues & %w[account_required account_mapping_required account_valuation_requires_review]).any? ||
        record.resolution["account_id"].present?)
  end

  def icost_transfer_resolution?(record)
    record.transaction_type == "转账" && !record.issues.include?("installment_details_required") &&
      ((record.issues & %w[transfer_direction_required account_valuation_requires_review]).any? ||
        record.resolution.values_at("from_account_id", "to_account_id").any?(&:present?))
  end

  def icost_value(value)
    return t("icost_imports.empty_value") if value.nil? || value == ""
    return number_with_delimiter(value.to_s("F")) if value.is_a?(BigDecimal)
    return JSON.generate(value) if value.is_a?(Array) || value.is_a?(Hash)

    value.to_s
  end

  def icost_status(record)
    t("icost_imports.statuses.#{record.status}", default: record.status)
  end

  def icost_issue(issue)
    t("icost_imports.issues.#{issue}", default: t("icost_imports.issues.unsupported", code: issue))
  end

  def icost_structured_fields(record)
    %w[recorded_at_text transaction_type amount currency category_path account_name
       counterparty_name book_name note tags refund_amount discount_amount fee_amount
       image_references].map do |field|
      [ t("icost_imports.fields.#{field}"), icost_value(record.public_send(field)) ]
    end
  end

  def icost_source_fields(record)
    Array.new([ record.icost_import.headers.length, record.source_values.length ].max).each_index.map do |index|
      header = record.icost_import.headers[index]
      label = header.presence || t("icost_imports.unnamed_column", index: index + 1)
      [ "#{index + 1}. #{label}", icost_value(record.source_values[index]) ]
    end
  end
end
