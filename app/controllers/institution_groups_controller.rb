# The page of an institution bundle: the accounts the sidebar shows as one
# entry, with their combined balance chart and their activity merged, and the
# settings (InstitutionGroup) of its name, domain, icon and currency.
class InstitutionGroupsController < ApplicationController
  include Periodable, AccountLogoOptions

  before_action :require_non_guest!, only: %i[edit update logo_options]
  before_action :set_bundle

  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.accounts"), accounts_path ],
      [ @bundle.name, nil ]
    ]
    @chart_period = chart_period
    @series = @bundle.balance_series(period: @chart_period)
    # A range dragged on the chart (a custom period) narrows the activity too;
    # a preset period only changes the chart.
    @activity_range = @period if @period.key.blank?
    @reconciliation_indicators = Current.family.manual_reconciliation? ? Account::ReconciliationIndicator.for_accounts(@bundle.accounts) : {}

    account_ids = @bundle.accounts.map(&:id)
    entries = Entry.where(account_id: account_ids)
      .excluding_split_parents
      .where.not(entryable_type: "Transaction", entryable_id: inflows_of_internal_transfers(account_ids))
      .reverse_chronological
      .includes(:account, :entryable)
    entries = entries.where(date: @activity_range.date_range) if @activity_range

    @pagy, @entries = pagy(entries, limit: safe_per_page)
    preload_entry_rows
  end

  # The bundle's sidebar sparkline, like an account's (AccountsController#sparkline):
  # a URL carrying the current version can't go stale, so the browser may reuse it.
  def sparkline
    version = @bundle.sparkline_version
    expires_in 1.day if params[:v] == version
    if stale?(etag: [ "institution_group_sparkline", version, Date.current ])
      @sparkline_series = @bundle.sparkline_series
      render layout: false
    end
  end

  def edit
    @institution_group = settings
  end

  # Loads the icons found for the domain typed in the settings into their
  # icon picker, the account form's, which shows the group's own icon.
  def logo_options
    return redirect_to institution_group_path(@bundle) unless turbo_frame_request?

    render_logo_options(settings.logo_preview(@bundle.lead_account, name: @bundle.name))
  end

  def update
    @institution_group = settings
    @institution_group.assign_attributes(institution_group_params)
    @institution_group.logo_choice = logo_choice
    @institution_group.inherited_name = @bundle.inherited_name
    @institution_group.inherited_domain = @bundle.inherited_domain

    writable = writable_member_accounts
    if (saved = @institution_group.save_to_accounts(writable))
      flash[:notice] = t(".success")
      skipped = institution_accounts.size - writable.size
      alerts = []
      alerts << t(".skipped_accounts", count: skipped) if skipped.positive?
      alerts << t(".logo_not_applied") if @institution_group.logo_choice.not_applied?
      flash[:alert] = alerts.join(" ") if alerts.any?
      path = path_after_update(saved.key)
      respond_to do |format|
        format.html { redirect_to path }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, path) }
      end
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private
    # Only a bundle among the accounts the user can see: the balance sheet is
    # built from them.
    def set_bundle
      @bundle = Current.family.balance_sheet.institution_bundle(params[:slug].to_s)
      raise ActiveRecord::RecordNotFound unless @bundle
    end

    def settings
      Current.family.institution_groups.find_or_initialize_by(key: @bundle.key)
    end

    # Every account the user can see at this institution: the bundle's, then
    # its accounts of other types (its cards, say, in a bundle or alone),
    # which share the settings row and must take a new name with them, and
    # those already at the institution a rename merges into, which take the
    # icon chosen with it.
    def institution_accounts
      @institution_accounts ||= begin
        keys = [ @bundle.key, @institution_group&.destination_key(@bundle.lead_account) ].compact.uniq
        others = Current.family.balance_sheet.account_groups.flat_map(&:accounts)
          .select { |account| keys.include?(InstitutionGroup.key_for(account)) }
        (@bundle.accounts + others).uniq(&:id)
      end
    end

    # The institution's accounts the user may edit (owned, or shared with
    # full control, as for editing an account), the bundle's first, loaded
    # afresh so a failed save leaves the bundle's own copies as they were.
    # The destination's accounts join only when one of the institution's own
    # is writable: with none, nothing is renamed and the settings stay where
    # they are (InstitutionGroup#save_to_accounts with no accounts).
    def writable_member_accounts
      member_ids = institution_accounts.map(&:id)
      writable = Current.family.accounts.writable_by(Current.user).where(id: member_ids)
        .with_attached_logo.includes(:accountable, account_providers: :provider)
        .sort_by { |account| member_ids.index(account.id) }
      return [] unless writable.any? { |account| InstitutionGroup.key_for(account) == @bundle.key }

      writable
    end

    # A rename moves the bundle to another key and so another slug. Its page
    # is the bundle now at the saved key in the same group, else the one left
    # at the old key, else (no two accounts share either) the accounts.
    def path_after_update(key)
      bundles = Family.find(Current.family.id).balance_sheet(user: Current.user).institution_bundles
                      .select { |bundle| bundle.group_key == @bundle.group_key }
      bundle = bundles.find { |candidate| candidate.key == key } || bundles.find { |candidate| candidate.key == @bundle.key }
      bundle ? institution_group_path(bundle) : accounts_path
    end

    def institution_group_params
      params.require(:institution_group).permit(:name, :institution_domain, :currency)
    end

    # What the icon picker submitted, as the account form submits it: an
    # uploaded file, or the icon picked (accounts/_logo_picker). "stored"
    # shares the group's stored logo, which the picker showed.
    def logo_choice
      submitted = params.require(:institution_group).permit(:logo, :logo_choice)
      upload = submitted[:logo] if submitted[:logo].is_a?(ActionDispatch::Http::UploadedFile)
      Account::LogoChoice.new(upload: upload, choice: submitted[:logo_choice], source: @institution_group)
    end

    # "All" starts where the oldest of the accounts' histories does, as on an
    # account's chart.
    def chart_period
      start_date = @bundle.history_start_date if @period.key == "all_time"
      return @period unless start_date && start_date > @period.start_date

      Period.new(key: "all_time", start_date: start_date, end_date: @period.end_date)
    end

    # A transfer between two of the bundle's accounts shows once, as its
    # outflow (as entries_by_date shows it on a page): its inflow leg is left
    # out before paging, so pages are counted and filled by what they show.
    def inflows_of_internal_transfers(account_ids)
      outflow_entries = Entry.where(entryable_type: "Transaction", account_id: account_ids)
      outflow_entries = outflow_entries.where(date: @activity_range.date_range) if @activity_range
      Transfer.where(outflow_transaction_id: outflow_entries.select(:entryable_id)).select(:inflow_transaction_id)
    end

    # What the entry rows read, loaded for the page at once (as on an account's activity).
    def preload_entry_rows
      @accessible_account_ids = Current.user.accessible_accounts.pluck(:id).to_set

      transactions = @entries.filter_map { |entry| entry.entryable if entry.transaction? }
      if transactions.any?
        ActiveRecord::Associations::Preloader.new(
          records: transactions,
          associations: [
            :category, :tags, { merchant: { logo_attachment: :blob } },
            { transfer_as_outflow: { inflow_transaction: { entry: :account } } },
            { transfer_as_inflow: { inflow_transaction: { entry: :account }, outflow_transaction: [ :category, { entry: :account } ] } }
          ]
        ).call
      end

      trades = @entries.filter_map { |entry| entry.entryable if entry.entryable_type == "Trade" }
      ActiveRecord::Associations::Preloader.new(records: trades, associations: [ :security ]).call if trades.any?

      Transaction::ActivitySecurityPreloader.new(@entries).preload
      @transfer_hint_transaction_ids = Current.family.transaction_ids_with_transfer_candidates(transactions, user: Current.user)
      @split_parent_entry_ids = Entry.split_parent_ids_among(@entries.map(&:id))

      split_parent_ids = Current.user.show_split_grouped? ? @entries.filter_map(&:parent_entry_id).uniq : []
      @split_parents = if split_parent_ids.any?
        Entry.where(id: split_parent_ids)
             .includes(:account, entryable: [ :category, { merchant: { logo_attachment: :blob } } ])
             .index_by(&:id)
      else
        {}
      end
    end
end
