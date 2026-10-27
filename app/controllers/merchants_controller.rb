class MerchantsController < ApplicationController
  def show
    @merchant = find_merchant

    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.merchants"), family_merchants_path ],
      [ @merchant.name, nil ]
    ]

    @accessible_account_ids = Current.user.accessible_accounts.pluck(:id)
    @search = Transaction::Search.new(
      Current.family,
      filters: { merchants: [ @merchant.name ] },
      accessible_account_ids: @accessible_account_ids
    )
    @first_date, @last_date = @search.transactions_scope.pick(Arel.sql("MIN(entries.date)"), Arel.sql("MAX(entries.date)"))

    @pagy, @transactions = pagy(
      @search.transactions_scope.reverse_chronological.includes({ entry: :account }, :category, :merchant, :tags),
      limit: safe_per_page(50)
    )
    Transaction::ActivitySecurityPreloader.new(@transactions).preload

    @split_parents = {}
    @projected_recurring = []
    @q = {}
  end

  private
    def find_merchant
      Current.family.available_merchants.find(params[:id])
    end
end
