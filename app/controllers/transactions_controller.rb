class TransactionsController < ApplicationController
  include EntryableResource

  before_action :set_entry_for_unlock, only: :unlock
  before_action :set_entry_for_tags, only: :update_tags
  before_action :store_params!, only: :index

  helper_method :new_transaction_idempotency_key

  def show
    super
    assign_mark_recurring_state
  end

  def new
    prefill_params_from_duplicate!
    super
    apply_duplicate_attributes!
    set_new_transaction_form_options
  end

  def index
    @q = search_params
    @accessible_account_ids = Current.user.accessible_accounts.pluck(:id)
    @search = Transaction::Search.new(Current.family, filters: @q, accessible_account_ids: @accessible_account_ids)

    base_scope = @search.transactions_scope
                       .reverse_chronological
                       .includes(
                         { entry: :account },
                         :category, :merchant, :tags,
                         # Union of #2643 counterpart UI + Skylight category-menu N+1:
                         # - outflow rows need inflow_transaction (to_account) for both
                         #   counterpart display and Transfer#categorizable?/#payment?
                         # - inflow rows need outflow_transaction (from_account) for
                         #   counterpart display, and inflow_transaction (to_account)
                         #   for the category menu on the same row
                         {
                           transfer_as_outflow: {
                             inflow_transaction: { entry: :account }
                           }
                         },
                         {
                           transfer_as_inflow: {
                             inflow_transaction: { entry: :account },
                             outflow_transaction: { entry: :account }
                           }
                         }
                       )

    @pagy, @transactions = pagy(base_scope, limit: safe_per_page(stored_params["per_page"]))
    Transaction::ActivitySecurityPreloader.new(@transactions).preload

    # Preload split parent data
    entry_ids = @transactions.map { |t| t.entry.id }

    # Load split parent entries for grouped display (only when grouping is enabled)
    @split_parents = if Current.user.show_split_grouped?
      split_parent_ids = @transactions.filter_map { |t| t.entry.parent_entry_id }.uniq
      if split_parent_ids.any?
        Entry.where(id: split_parent_ids)
             .includes(:account, entryable: [ :category, :merchant ])
             .index_by(&:id)
      else
        {}
      end
    else
      {}
    end

    # Preload which entries on this page are split parents (have children) to avoid N+1
    @split_parent_entry_ids = if entry_ids.any?
      Entry.where(parent_entry_id: entry_ids).distinct.pluck(:parent_entry_id).to_set
    else
      Set.new
    end

    @uncategorized_count = Rails.cache.fetch(uncategorized_count_cache_key) do
      Current.accessible_entries.uncategorized_transactions.count
    end

    # Load projected recurring transactions for next 10 days
    @projected_recurring = Rails.cache.fetch(projected_recurring_cache_key, expires_in: 1.day) do
      Current.family.recurring_transactions
                    .accessible_by(Current.user)
                    .active
                    .where("next_expected_date <= ? AND next_expected_date >= ?",
                           10.days.from_now.to_date,
                           Date.current)
                    .includes(:merchant)
                    .to_a
    end

    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.transactions"), nil ] ]
  end

  def clear_filter
    updated_params = {
      "q" => search_params,
      "page" => params[:page],
      "per_page" => params[:per_page]
    }

    q_params = updated_params["q"] || {}

    param_key = params[:param_key]
    param_value = params[:param_value]

    if q_params[param_key].is_a?(Array)
      q_params[param_key].delete(param_value)
      q_params.delete(param_key) if q_params[param_key].empty?
    else
      q_params.delete(param_key)
    end

    updated_params["q"] = q_params.presence

    # Add flag to indicate filters were explicitly cleared
    updated_params["filter_cleared"] = "1" if updated_params["q"].blank?

    Current.session.update!(prev_transaction_page_params: updated_params)

    redirect_to transactions_path(updated_params)
  end

  def create
    account = Current.user.accessible_accounts.find_by(id: params.dig(:entry, :account_id))

    if account.nil?
      @entry = Current.family.entries.new(entry_params)
      @entry.valid?
      set_new_transaction_form_options
      render :new, status: :unprocessable_entity
      return
    end

    return unless require_account_permission!(account)

    idempotency_key = submitted_idempotency_key

    # Sequential double-submit guard: the form was already submitted
    # successfully once (double-click, browser retry, user reopening the
    # dialog after a slow response) and the first request already committed
    # by the time this one runs. Treat it as a success instead of creating a
    # second, identical entry.
    if idempotency_key && (existing_entry = find_duplicate_manual_entry(account, idempotency_key))
      respond_with_created_entry(existing_entry)
      return
    end

    @entry = account.entries.new(entry_params_with_idempotency_key(idempotency_key))

    if @entry.save
      @entry.sync_account_later
      @entry.lock_saved_attributes!
      @entry.mark_user_modified!
      @entry.transaction.lock_attr!(:tag_ids) if @entry.transaction.tags.any?

      respond_with_created_entry(@entry)
    else
      set_new_transaction_form_options
      render :new, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotUnique
    # Concurrent-request backstop: two near-simultaneous submissions both
    # passed the pre-check above (neither saw the other's row yet) and both
    # reached #save. The partial unique index on
    # entries(account_id, idempotency_key) lets exactly one INSERT win;
    # this rescues the loser and redirects it to the winning entry instead of
    # creating a duplicate or surfacing a 500 to the user.
    existing_entry = idempotency_key && find_duplicate_manual_entry(account, idempotency_key)
    raise unless existing_entry

    respond_with_created_entry(existing_entry)
  end

  def update
    if @entry.update(permitted_entry_params)
      transaction = @entry.transaction
      transaction.record_category_usage!

      if needs_rule_notification?(transaction)
        flash[:cta] = {
          type: "category_rule",
          category_id: transaction.category_id,
          category_name: transaction.category.name
        }
      end

      @entry.lock_saved_attributes!
      @entry.mark_user_modified!
      @entry.transaction.lock_attr!(:tag_ids) if @entry.transaction.tags.any?
      @entry.sync_account_later

      notes_changed = @entry.saved_change_to_notes?

      # Reload to ensure fresh state for turbo stream rendering
      @entry.reload

      assign_mark_recurring_state

      respond_to do |format|
        format.html { redirect_back_or_to account_path(@entry.account), notice: t(".updated") }
        format.turbo_stream do
          in_split_group = helpers.in_split_group?(@entry, params[:grouped])
          render turbo_stream: [
            turbo_stream.replace(
              dom_id(@entry, :header),
              partial: "transactions/header",
              locals: { entry: @entry }
            ),
            turbo_stream.replace(
              dom_id(@entry, :protection),
              partial: "entries/protection_indicator",
              locals: { entry: @entry, unlock_path: unlock_transaction_path(@entry.transaction) }
            ),
            (turbo_stream.replace(
              dom_id(@entry, :notes),
              partial: "transactions/notes",
              locals: { entry: @entry, can_annotate: can_annotate_entry? }
            ) if params[:entry]&.key?(:notes) && notes_changed),
            (turbo_stream.replace(
              dom_id(@entry, :mark_recurring),
              partial: "transactions/mark_recurring",
              locals: { entry: @entry }
            ) if can_edit_entry? && !@entry.split_child?),
            turbo_stream.replace(
              dom_id(@entry),
              partial: "entries/entry",
              locals: { entry: @entry, in_split_group: in_split_group }
            ),
            *flash_notification_stream_items
          ].compact
        end
      end
    else
      assign_mark_recurring_state
      render :show, status: :unprocessable_entity
    end
  end

  def update_tags
    return unless require_account_permission!(@entry.account, :annotate, redirect_path: transaction_path(@entry))

    tag_ids = Current.family.tags.where(id: tag_ids_param).pluck(:id)

    @entry.transaction.tag_ids = tag_ids
    @entry.lock_saved_attributes!
    @entry.mark_user_modified!
    @entry.transaction.lock_attr!(:tag_ids)
    @entry.sync_account_later

    render json: { tag_ids: @entry.transaction.tag_ids }
  end

  def merge_duplicate
    transaction = accessible_transactions.includes(entry: :account).find(params[:id])

    return unless require_account_permission!(transaction.entry.account)

    if transaction.merge_with_duplicate!
      flash[:notice] = t("transactions.merge_duplicate.success")
    else
      flash[:alert] = t("transactions.merge_duplicate.failure")
    end

    redirect_to transactions_path
  rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid,
         ActiveRecord::RecordNotDestroyed, ActiveRecord::Deadlocked,
         ActiveRecord::LockWaitTimeout => e
    Rails.logger.error("Failed to merge duplicate transaction #{params[:id]}: #{e.message}")
    flash[:alert] = t("transactions.merge_duplicate.failure")
    redirect_to transactions_path
  end

  def dismiss_duplicate
    transaction = accessible_transactions.includes(entry: :account).find(params[:id])

    return unless require_account_permission!(transaction.entry.account)

    if transaction.dismiss_duplicate_suggestion!
      flash[:notice] = t("transactions.dismiss_duplicate.success")
    else
      flash[:alert] = t("transactions.dismiss_duplicate.failure")
    end

    redirect_back_or_to transactions_path
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error("Failed to dismiss duplicate suggestion for transaction #{params[:id]}: #{e.message}")
    flash[:alert] = t("transactions.dismiss_duplicate.failure")
    redirect_back_or_to transactions_path
  end

  def convert_to_trade
    @transaction = accessible_transactions.includes(entry: :account).find(params[:id])
    @entry = @transaction.entry

    return unless require_account_permission!(@entry.account)

    unless @entry.account.investment?
      flash[:alert] = t("transactions.convert_to_trade.errors.not_investment_account")
      redirect_back_or_to transactions_path
      return
    end

    render :convert_to_trade
  end

  def create_trade_from_transaction
    @transaction = accessible_transactions.includes(entry: :account).find(params[:id])
    @entry = @transaction.entry

    return unless require_account_permission!(@entry.account)

    # Pre-transaction validations
    unless @entry.account.investment?
      flash[:alert] = t("transactions.convert_to_trade.errors.not_investment_account")
      redirect_back_or_to transactions_path
      return
    end

    if @entry.excluded?
      flash[:alert] = t("transactions.convert_to_trade.errors.already_converted")
      redirect_back_or_to transactions_path
      return
    end

    # Resolve security before transaction
    security = resolve_security_for_conversion
    return if performed? # Early exit if redirect already happened

    # Validate and calculate qty/price before transaction
    qty, price = calculate_qty_and_price
    return if performed? # Early exit if redirect already happened

    activity_label = params[:investment_activity_label].presence
    # Infer sell from amount sign: negative amount = money coming in = sell
    is_sell = activity_label == "Sell" || (activity_label.blank? && @entry.amount < 0)

    ActiveRecord::Base.transaction do
      # For trades: positive qty = buy (money out), negative qty = sell (money in)
      signed_qty = is_sell ? -qty : qty
      trade_amount = qty * price
      # Sells bring money in (negative amount), Buys take money out (positive amount)
      signed_amount = is_sell ? -trade_amount : trade_amount

      # Default activity label if not provided
      activity_label ||= is_sell ? "Sell" : "Buy"

      # Create trade entry with note about conversion
      conversion_note = t("transactions.convert_to_trade.conversion_note",
        original_name: @entry.name,
        original_date: I18n.l(@entry.date, format: :long))

      new_entry = @entry.account.entries.create!(
        name: params[:trade_name] || Trade.build_name(is_sell ? "sell" : "buy", qty, security.ticker),
        date: @entry.date,
        amount: signed_amount,
        currency: @entry.currency,
        notes: conversion_note,
        entryable: Trade.new(
          security: security,
          qty: signed_qty,
          price: price,
          currency: @entry.currency,
          investment_activity_label: activity_label
        )
      )

      # Mark the new trade as user-modified to protect from sync
      new_entry.lock_saved_attributes!
      new_entry.mark_user_modified!

      # Mark original transaction as excluded (soft delete)
      @entry.update!(excluded: true)
    end

    flash[:notice] = t("transactions.convert_to_trade.success")
    redirect_to account_path(@entry.account), status: :see_other
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    flash[:alert] = t("transactions.convert_to_trade.errors.conversion_failed", error: e.message)
    redirect_back_or_to transactions_path, status: :see_other
  rescue StandardError => e
    flash[:alert] = t("transactions.convert_to_trade.errors.unexpected_error", error: e.message)
    redirect_back_or_to transactions_path, status: :see_other
  end

  def unlock
    return unless require_account_permission!(@entry.account)

    @entry.unlock_for_sync!
    flash[:notice] = t("entries.unlock.success")

    redirect_back_or_to transactions_path
  end

  def mark_as_recurring
    transaction = accessible_transactions.includes(entry: :account).find(params[:id])

    return unless require_account_permission!(transaction.entry.account)

    # Check if a recurring transaction already exists for this pattern.
    # The UI disables the button ahead of time using the same lookup, but this
    # guard remains as the authoritative check (e.g. stale page, direct POST).
    existing = transaction.existing_manual_recurring_transaction

    if existing
      flash[:alert] = t("recurring_transactions.already_exists")
      redirect_back_or_to transactions_path
      return
    end

    begin
      recurring_transaction = RecurringTransaction.create_from_transaction(transaction)

      respond_to do |format|
        format.html do
          flash[:notice] = t("recurring_transactions.marked_as_recurring")
          redirect_back_or_to transactions_path
        end
      end
    rescue ActiveRecord::RecordInvalid => e
      respond_to do |format|
        format.html do
          flash[:alert] = t("recurring_transactions.creation_failed")
          redirect_back_or_to transactions_path
        end
      end
    rescue ActiveRecord::RecordNotUnique
      # Another request created the same (account, name/merchant, amount,
      # currency) pattern between the check above and this create — the DB
      # unique index is the authoritative backstop for that race.
      respond_to do |format|
        format.html do
          flash[:alert] = t("recurring_transactions.already_exists")
          redirect_back_or_to transactions_path
        end
      end
    rescue StandardError => e
      respond_to do |format|
        format.html do
          flash[:alert] = t("recurring_transactions.unexpected_error")
          redirect_back_or_to transactions_path
        end
      end
    end
  end

  def exchange_rate
    account = Current.family.accounts.find(params[:account_id])
    currency_from = params[:currency]
    date = params[:date]&.to_date || Date.current

    if account.currency == currency_from
      render json: { same_currency: true, rate: 1.0 }
    else
      rate_obj = ExchangeRate.find_or_fetch_rate(
        from: currency_from,
        to: account.currency,
        date: date
      )

      if rate_obj.nil?
        return render json: { error: "Exchange rate not found" }, status: :not_found
      end

      rate_value = rate_obj.is_a?(Numeric) ? rate_obj : rate_obj.rate

      render json: { rate: rate_value.to_f, account_currency: account.currency }
    end
  end

  private
    # Scoped by user (not just family) because Current.accessible_entries is
    # user-scoped for family sharing (see Current#accessible_entries).
    #
    # Includes Family#accounts_status_version because `uncategorized_transactions`
    # filters on account status (draft/active), and toggling an account's
    # active status (AccountsController#toggle_active) doesn't touch `entries`
    # or `AccountShare`, so it wouldn't otherwise bust this cache.
    def uncategorized_count_cache_key
      "transactions_uncategorized_count/v3/#{Current.family.id}/#{Current.user.id}/" \
        "#{Current.family.entries_version}/#{Current.family.accounts_status_version}/#{Current.account_share_version}"
    end

    # Scoped additionally by Date.current since the "next 10 days" window is
    # date-dependent and would otherwise return a stale window on a cache hit
    # from an earlier day.
    #
    # Includes Family#recurring_transaction_merchants_version because the
    # cached records are preloaded with :merchant and rendered with its
    # name/logo, but editing a FamilyMerchant or a shared ProviderMerchant
    # doesn't touch `recurring_transactions`.
    def projected_recurring_cache_key
      "transactions_projected_recurring/v5/#{Current.family.id}/#{Current.user.id}/#{Date.current}/" \
        "#{Current.family.recurring_transactions_version}/#{Current.family.accounts_status_version}/" \
        "#{Current.family.recurring_transaction_merchants_version}/#{Current.account_share_version}"
    end

    # The "Mark as Recurring" block is only ever rendered under these same
    # conditions (see transactions/show.html.erb), so skip the extra query
    # entirely when it won't be used — this runs on every show/failed-update
    # render, including read-only viewers and split-child transactions.
    def assign_mark_recurring_state
      return unless can_edit_entry? && !@entry.split_child?

      existing = @entry.transaction.existing_manual_recurring_transaction

      @mark_recurring_href = mark_as_recurring_transaction_path(@entry.transaction)
      @mark_recurring_subtitle_class = existing ? "text-subdued" : "text-secondary"
      @mark_recurring_subtitle = existing ? t("recurring_transactions.already_exists") : t("transactions.show.mark_recurring_subtitle")
      @mark_recurring_disabled = existing.present?
      @mark_recurring_title = existing ? t("recurring_transactions.already_exists") : nil
      @mark_recurring_button_class = existing ? "disabled:opacity-50" : nil
    end

    def accessible_transactions
      Current.family.transactions
        .joins(entry: :account)
        .merge(Account.accessible_by(Current.user))
    end

    def duplicate_source
      return @duplicate_source if defined?(@duplicate_source)
      @duplicate_source = if params[:duplicate_entry_id].present?
        source = Current.family.entries.joins(:account).merge(Account.accessible_by(Current.user)).find_by(id: params[:duplicate_entry_id])
        source if source&.transaction?
      end
    end

    def prefill_params_from_duplicate!
      return unless duplicate_source
      params[:nature] ||= duplicate_source.amount.negative? ? "inflow" : "outflow"
      params[:account_id] ||= duplicate_source.account_id.to_s
    end

    def apply_duplicate_attributes!
      return unless duplicate_source
      @entry.assign_attributes(
        name: duplicate_source.name,
        amount: duplicate_source.amount.abs,
        currency: duplicate_source.currency,
        notes: duplicate_source.notes
      )
      @entry.entryable.assign_attributes(
        category_id: duplicate_source.entryable.category_id,
        merchant_id: duplicate_source.entryable.merchant_id
      )
      @entry.entryable.tag_ids = duplicate_source.entryable.tag_ids
    end

    def set_entry_for_unlock
      transaction = accessible_transactions.find(params[:id])
      @entry = transaction.entry
    end

    def needs_rule_notification?(transaction)
      return false if Current.user.rule_prompts_disabled

      if Current.user.rule_prompt_dismissed_at.present?
        time_since_last_rule_prompt = Time.current - Current.user.rule_prompt_dismissed_at
        return false if time_since_last_rule_prompt < 1.day
      end

      transaction.saved_change_to_category_id? && transaction.category_id.present? &&
      transaction.eligible_for_category_rule?
    end

    def entry_params
      entry_params = params.require(:entry).permit(
        :name, :date, :amount, :currency, :excluded, :notes, :nature, :entryable_type,
        entryable_attributes: [ :id, :category_id, :merchant_id, :kind, :investment_activity_label, :exchange_rate, { tag_ids: [] } ]
      )

      nature = entry_params.delete(:nature)

      entry_params.delete(:amount) if entry_params[:amount].blank?
      entry_params.delete(:date) if entry_params[:date].blank?

      if nature.present? && entry_params[:amount].present?
        signed_amount = nature == "inflow" ? -entry_params[:amount].to_d : entry_params[:amount].to_d
        entry_params = entry_params.merge(amount: signed_amount)
      end

      entry_params
    end

    def entry_params_with_idempotency_key(idempotency_key)
      return entry_params unless idempotency_key

      # A dedicated column, deliberately not external_id/source: those are
      # provider-linkage fields (Entry#linked? = external_id.present?), and
      # reusing them here would make a manual entry look provider-synced -
      # disabling its date/nature/amount/currency fields in the editor, and
      # hiding it from future provider dedup matching.
      entry_params.merge(idempotency_key: idempotency_key)
    end

    def find_duplicate_manual_entry(account, idempotency_key)
      account.entries.find_by(idempotency_key: idempotency_key)
    end

    # The hidden "entry[idempotency_key]" field is rendered fresh (a random
    # UUID) every time the new-transaction form loads, and echoed back
    # unchanged by the browser on submit. It's never trusted for anything but
    # de-duplication scoped to the current user's own account (see #create),
    # so we only require that it looks like a UUID we could have generated -
    # anything else (missing field, tampered value, non-string type from a
    # malformed request) just disables the idempotency check for that
    # request rather than being treated as an error.
    UUID_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
    private_constant :UUID_FORMAT

    def submitted_idempotency_key
      key = params.dig(:entry, :idempotency_key)
      key if key.is_a?(String) && key.match?(UUID_FORMAT)
    end

    def new_transaction_idempotency_key
      @new_transaction_idempotency_key ||= submitted_idempotency_key || SecureRandom.uuid
    end

    def respond_with_created_entry(entry)
      flash[:notice] = t(".created")

      respond_to do |format|
        format.html { redirect_back_or_to account_path(entry.account) }
        format.turbo_stream { stream_redirect_back_or_to(account_path(entry.account)) }
      end
    end

    def tag_ids_param
      Array(params[:tag_ids]).reject(&:blank?)
    end

    def set_entry_for_tags
      set_entry
    end

    def set_new_transaction_form_options
      accessible_accounts_scope = accessible_accounts

      @account_currencies = accessible_accounts_scope.pluck(:id, :currency).to_h
      @manual_accounts = accessible_accounts_scope
        .manual
        .active
        .alphabetically
        .includes(:account_providers, logo_attachment: :blob)
        .to_a
      @categories = Current.family.categories.alphabetically_by_hierarchy.to_a
      @merchants = Current.family.available_merchants_for(Current.user).alphabetically.to_a
      @tags = Current.family.tags.alphabetically.to_a
    end

    # Filters entry_params based on the user's permission on the account.
    # read_write users can only annotate (category, tags, notes, merchant).
    # read_only users cannot update anything.
    def permitted_entry_params
      case entry_permission
      when :owner, :full_control
        entry_params
      when :read_write
        # Annotate only: category, tags, merchant, notes
        ep = entry_params.slice(:notes)
        if entry_params[:entryable_attributes].present?
          ep[:entryable_attributes] = entry_params[:entryable_attributes].slice(:id, :category_id, :merchant_id, :tag_ids)
        end
        ep
      else
        {} # read_only — no edits allowed
      end
    end

    def search_params
      cleaned_params = params.fetch(:q, {})
              .permit(
                :start_date, :end_date, :search, :amount,
                :amount_operator, :active_accounts_only,
                accounts: [], account_ids: [],
                categories: [], merchants: [], types: [], tags: [], status: []
              )
              .to_h
              .compact_blank

      cleaned_params.delete(:amount_operator) unless cleaned_params[:amount].present?


      cleaned_params
    end

    def store_params!
      if should_restore_params?
        params_to_restore = {}

        params_to_restore[:q] = stored_params["q"].presence || {}
        params_to_restore[:page] = stored_params["page"].presence || 1
        params_to_restore[:per_page] = stored_params["per_page"].presence || 50

        redirect_to transactions_path(params_to_restore)
      else
        Current.session.update!(
          prev_transaction_page_params: {
            q: search_params,
            page: params[:page],
            per_page: params[:per_page].presence || stored_params["per_page"]
          }
        )
      end
    end

    def should_restore_params?
      request.query_parameters.blank? && (stored_params["q"].present? || stored_params["page"].present? || stored_params["per_page"].present?)
    end

    def stored_params
      Current.session.prev_transaction_page_params
    end

    # Helper methods for convert_to_trade

    def resolve_security_for_conversion
      user_country = Current.family.country

      if params[:security_id] == "__custom__"
        # User selected "Enter custom ticker" - check for combobox selection or manual entry
        if params[:ticker].present?
          # Combobox selection: format is "SYMBOL|EXCHANGE|PROVIDER"
          parsed = Security.parse_combobox_id(params[:ticker])
          if parsed[:ticker].blank?
            flash[:alert] = t("transactions.convert_to_trade.errors.enter_ticker")
            redirect_back_or_to transactions_path
            return nil
          end
          Security::Resolver.new(
            parsed[:ticker].strip,
            exchange_operating_mic: parsed[:exchange_operating_mic] || params[:exchange_operating_mic].presence,
            country_code: user_country,
            price_provider: parsed[:price_provider]
          ).resolve
        elsif params[:custom_ticker].present?
          # Manual entry from combobox's name_when_new or fallback text field
          Security::Resolver.new(
            params[:custom_ticker].strip,
            exchange_operating_mic: params[:exchange_operating_mic].presence,
            country_code: user_country
          ).resolve
        else
          flash[:alert] = t("transactions.convert_to_trade.errors.enter_ticker")
          redirect_back_or_to transactions_path
          return nil
        end
      elsif params[:security_id].present?
        found = Security.find_by(id: params[:security_id])
        unless found
          flash[:alert] = t("transactions.convert_to_trade.errors.security_not_found")
          redirect_back_or_to transactions_path
          return nil
        end
        found
      elsif params[:ticker].present?
        # Direct combobox (no existing holdings) - format is "SYMBOL|EXCHANGE|PROVIDER"
        parsed = Security.parse_combobox_id(params[:ticker])
        if parsed[:ticker].blank?
          flash[:alert] = t("transactions.convert_to_trade.errors.enter_ticker")
          redirect_back_or_to transactions_path
          return nil
        end
        Security::Resolver.new(
          parsed[:ticker].strip,
          exchange_operating_mic: parsed[:exchange_operating_mic] || params[:exchange_operating_mic].presence,
          country_code: user_country,
          price_provider: parsed[:price_provider]
        ).resolve
      elsif params[:custom_ticker].present?
        # Manual entry from combobox's name_when_new (no existing holdings path)
        Security::Resolver.new(
          params[:custom_ticker].strip,
          exchange_operating_mic: params[:exchange_operating_mic].presence,
          country_code: user_country
        ).resolve
      end.tap do |security|
        if security.nil? && !performed?
          flash[:alert] = t("transactions.convert_to_trade.errors.select_security")
          redirect_back_or_to transactions_path
        end
      end
    end

    def calculate_qty_and_price
      amount = @entry.amount.abs
      qty = params[:qty].present? ? params[:qty].to_d.abs : nil
      price = params[:price].present? ? params[:price].to_d : nil

      if qty.nil? && price.nil?
        flash[:alert] = t("transactions.convert_to_trade.errors.enter_qty_or_price")
        redirect_back_or_to transactions_path, status: :see_other
        return [ nil, nil ]
      elsif qty.nil? && price.present? && price > 0
        qty = (amount / price).round(6)
      elsif price.nil? && qty.present? && qty > 0
        price = (amount / qty).round(4)
      end

      if qty.nil? || qty <= 0 || price.nil? || price <= 0
        flash[:alert] = t("transactions.convert_to_trade.errors.invalid_qty_or_price")
        redirect_back_or_to transactions_path, status: :see_other
        return [ nil, nil ]
      end

      [ qty, price ]
    end
end
