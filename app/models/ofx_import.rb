require "digest"
require "ofx"
require "stringio"

class OfxImport < Import
  after_create :set_defaults

  def import!
    raise Import::MappingError, "Account is required for OFX imports." if account.nil?

    adapter = Account::ProviderImportAdapter.new(account)

    rows.each do |row|
      adapter.import_transaction(
        external_id: external_id_for(row),
        amount: row.signed_amount,
        currency: row.currency.presence || account.currency || family.currency,
        date: row.date_iso,
        name: row.name,
        source: "ofx",
        notes: row.notes
      )
    end
  end

  def required_column_keys
    %i[date amount]
  end

  def column_keys
    %i[date amount name currency notes]
  end

  def mapping_steps
    []
  end

  def generate_rows_from_csv
    rows.destroy_all

    statement = ofx_statement
    raise Import::MappingError, "No statements found in OFX file." if statement.nil?

    currency = statement.currency.presence ||
      statement.account&.currency.presence ||
      account&.currency.presence ||
      family.currency

    mapped_rows = Array(statement.transactions).map do |transaction|
      name = transaction_name(transaction)
      {
        date: format_date(transaction),
        amount: transaction.amount.to_s,
        currency: currency.to_s,
        name: name,
        notes: transaction_notes(transaction, name),
        external_id: transaction.fit_id
      }
    end

    rows.insert_all!(mapped_rows)
  end

  def matching_account
    account_id = ofx_statement&.account&.id.to_s
    return if account_id.blank?

    last4 = account_id.gsub(/\D/, "")[-4..]
    return if last4.blank?

    family.accounts.visible.find do |candidate|
      next unless candidate.name.to_s.include?(last4)

      statement_currency = ofx_statement&.currency
      statement_currency.blank? || candidate.currency == statement_currency
    end
  end

  private
    def set_defaults
      update!(
        date_format: "%Y-%m-%d",
        signage_convention: "inflows_positive",
        amount_type_strategy: "signed_amount"
      )
    end

    def ofx_parser
      raise Import::MappingError, "Missing OFX data." if raw_file_str.blank?

      @ofx_parser ||= OFX(StringIO.new(raw_file_str))
    rescue OFX::UnsupportedFileError, Nokogiri::XML::SyntaxError
      raise Import::MappingError, "OFX file could not be parsed."
    end

    def ofx_statement
      @ofx_statement ||= ofx_parser.statements&.first
    end

    def transaction_name(transaction)
      transaction.payee.presence ||
        transaction.name.presence ||
        transaction.memo.presence ||
        "OFX Transaction"
    end

    def transaction_notes(transaction, name)
      memo = transaction.memo.to_s
      return "" if memo.blank? || memo == name

      memo
    end

    def format_date(transaction)
      date = transaction.posted_at || transaction.occurred_at
      return "" if date.nil?

      date.to_date.strftime(date_format)
    end

    def external_id_for(row)
      return row.external_id if row.external_id.present?

      Digest::SHA256.hexdigest([ row.date, row.amount, row.currency, row.name ].join("|"))
    end
end
