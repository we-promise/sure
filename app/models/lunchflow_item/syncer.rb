class LunchflowItem::Syncer < ProviderItem::Syncer
  private

    def credentials_error?(error)
      error.is_a?(Provider::Lunchflow::LunchflowError) && error.error_type.in?([ :unauthorized, :access_forbidden ])
    end

    # Collects a data quality warning if any linked accounts are investment or crypto accounts.
    # Lunchflow cannot provide activity labels (Buy, Sell, Dividend, etc.) for investment transactions,
    # which may affect budget accuracy.
    def collect_processing_warnings(sync, linked_lunchflow_accounts)
      investment_accounts = linked_lunchflow_accounts.select do |la|
        account = la.current_account
        account&.accountable_type.in?(%w[Investment Crypto])
      end

      return if investment_accounts.empty?

      collect_data_quality_stats(sync,
        warnings: investment_accounts.size,
        details: [ {
          message: I18n.t("provider_warnings.limited_investment_data"),
          severity: "warning"
        } ]
      )
    end
end
