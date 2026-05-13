class IbkrItem::Importer
  attr_reader :ibkr_item, :ibkr_provider

  def initialize(ibkr_item, ibkr_provider:)
    @ibkr_item = ibkr_item
    @ibkr_provider = ibkr_provider
  end

  def import
    xml_body = ibkr_provider.download_statement
    parsed_report = IbkrItem::ReportParser.new(xml_body).parse

    accounts_imported = 0
    ibkr_item.transaction do
      ibkr_item.upsert_ibkr_snapshot!(parsed_report[:metadata].merge("fetched_at" => Time.current.iso8601))

      parsed_report[:accounts].each do |account_data|
        next if account_data[:ibkr_account_id].blank?

        ibkr_account = ibkr_item.ibkr_accounts.find_or_initialize_by(ibkr_account_id: account_data[:ibkr_account_id])
        ibkr_account.upsert_from_ibkr_statement!(account_data)
        accounts_imported += 1
      end

      ibkr_item.update!(status: :good)
    end

    {
      success: true,
      accounts_imported: accounts_imported
    }
  end
end
