class SimplefinItemsController < ApplicationController
  before_action :set_simplefin_item, only: [ :show, :edit, :update, :destroy, :sync, :balances, :setup_accounts, :complete_account_setup, :errors, :relink, :apply_relink ]

  def index
    @simplefin_items = Current.family.simplefin_items.active.ordered
    render layout: "settings"
  end

  def show
  end

  def edit
    # For SimpleFin, editing means providing a new setup token to replace expired access
    @simplefin_item.setup_token = nil # Clear any existing setup token
  end

  def update
    setup_token = simplefin_params[:setup_token]

    return render_error(t(".errors.blank_token"), context: :edit) if setup_token.blank?

    begin
      # Create new SimpleFin item data with updated token
      updated_item = Current.family.create_simplefin_item!(
        setup_token: setup_token,
        item_name: @simplefin_item.name
      )

      # Ensure new simplefin_accounts are created & have account_id set
      updated_item.import_latest_simplefin_data

      # Transfer accounts from old item to new item
      ActiveRecord::Base.transaction do
        @simplefin_item.simplefin_accounts.each do |old_account|
          if old_account.account.present?
            # Find matching account in new item by account_id
            new_account = updated_item.simplefin_accounts.find_by(account_id: old_account.account_id)
            if new_account
              # Transfer the account directly to the new SimpleFin account
              # This will automatically break the old association
              old_account.account.update!(simplefin_account_id: new_account.id)
            end
          end
        end

        # Mark old item for deletion
        @simplefin_item.destroy_later
      end

      # Clear any requires_update status on new item
      updated_item.update!(status: :good)

      redirect_to accounts_path, notice: t(".success")
    rescue ArgumentError, URI::InvalidURIError
      render_error(t(".errors.invalid_token"), setup_token, context: :edit)
    rescue Provider::Simplefin::SimplefinError => e
      error_message = case e.error_type
      when :token_compromised
        t(".errors.token_compromised")
      else
        t(".errors.update_failed", message: e.message)
      end
      render_error(error_message, setup_token, context: :edit)
    rescue => e
      Rails.logger.error("SimpleFin connection update error: #{e.message}")
      render_error(t(".errors.unexpected"), setup_token, context: :edit)
    end
  end

  def new
    @simplefin_item = Current.family.simplefin_items.build
  end

  def create
    setup_token = simplefin_params[:setup_token]

    return render_error(t(".errors.blank_token")) if setup_token.blank?

    begin
      @simplefin_item = Current.family.create_simplefin_item!(
        setup_token: setup_token,
        item_name: "SimpleFin Connection"
      )

      # Pre-prompt: run a quick balances-only discovery to populate minimal accounts
      begin
        SimplefinItem::Importer.new(@simplefin_item, simplefin_provider: @simplefin_item.simplefin_provider).import_balances_only
        # De-dup any duplicate upstream accounts created previously
        @simplefin_item.dedup_simplefin_accounts!
        # Update freshness timestamp only if the column exists in this schema
        if @simplefin_item.has_attribute?(:last_synced_at)
          @simplefin_item.update!(last_synced_at: Time.current)
        end
      rescue => e
        Rails.logger.warn("SimpleFin pre-prompt balances-only failed: #{e.class} - #{e.message}")
      end

      # If there are manual accounts that look like matches, present the relink modal immediately
      @candidates = compute_relink_candidates
      if @candidates.present?
        respond_to do |format|
          format.turbo_stream do
            # Replace the global modal frame content with the relink UI (use the existing template to keep instance vars)
            html = render_to_string(:relink, layout: false)
            render turbo_stream: turbo_stream.update("modal", html)
          end
          format.html do
            # Fallback: redirect with a flag so the page JS can open the modal
            redirect_to accounts_path(open_relink_for: @simplefin_item.id), notice: t(".success")
          end
          format.json { render json: { ok: true, relink: true, simplefin_item_id: @simplefin_item.id, candidates: @candidates }, status: :created }
        end
        return
      end

      redirect_to accounts_path, notice: t(".success")
    rescue ArgumentError, URI::InvalidURIError
      render_error(t(".errors.invalid_token"), setup_token)
    rescue Provider::Simplefin::SimplefinError => e
      error_message = case e.error_type
      when :token_compromised
        t(".errors.token_compromised")
      else
        t(".errors.create_failed", message: e.message)
      end
      render_error(error_message, setup_token)
    rescue => e
      Rails.logger.error("SimpleFin connection error: #{e.message}")
      render_error(t(".errors.unexpected"), setup_token)
    end
  end

  def destroy
    @simplefin_item.destroy_later
    redirect_to accounts_path, notice: t(".success")
  end

  def sync
    unless @simplefin_item.syncing?
      @simplefin_item.sync_later
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # Starts a balances-only sync for this SimpleFin item
  def balances
    sync = @simplefin_item.syncs.create!(status: :pending, sync_stats: { "balances_only" => true })
    SimplefinItem::Syncer.new(@simplefin_item).perform_sync(sync)

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { render json: { ok: true, sync_id: sync.id } }
    end
  end

  def setup_accounts
    @simplefin_accounts = @simplefin_item.simplefin_accounts.includes(:account).where(accounts: { id: nil })
    @account_type_options = [
      [ "Checking or Savings Account", "Depository" ],
      [ "Credit Card", "CreditCard" ],
      [ "Investment Account", "Investment" ],
      [ "Loan or Mortgage", "Loan" ],
      [ "Other Asset", "OtherAsset" ]
    ]

    # Subtype options for each account type
    @subtype_options = {
      "Depository" => {
        label: "Account Subtype:",
        options: Depository::SUBTYPES.map { |k, v| [ v[:long], k ] }
      },
      "CreditCard" => {
        label: "",
        options: [],
        message: "Credit cards will be automatically set up as credit card accounts."
      },
      "Investment" => {
        label: "Investment Type:",
        options: Investment::SUBTYPES.map { |k, v| [ v[:long], k ] }
      },
      "Loan" => {
        label: "Loan Type:",
        options: Loan::SUBTYPES.map { |k, v| [ v[:long], k ] }
      },
      "OtherAsset" => {
        label: nil,
        options: [],
        message: "No additional options needed for Other Assets."
      }
    }
  end

  def complete_account_setup
    account_types = params[:account_types] || {}
    account_subtypes = params[:account_subtypes] || {}

    # Update sync start date from form
    if params[:sync_start_date].present?
      @simplefin_item.update!(sync_start_date: params[:sync_start_date])
    end

    account_types.each do |simplefin_account_id, selected_type|
      simplefin_account = @simplefin_item.simplefin_accounts.find(simplefin_account_id)
      selected_subtype = account_subtypes[simplefin_account_id]

      # Default subtype for CreditCard since it only has one option
      selected_subtype = "credit_card" if selected_type == "CreditCard" && selected_subtype.blank?

      # Create account with user-selected type and subtype
      account = Account.create_from_simplefin_account(
        simplefin_account,
        selected_type,
        selected_subtype
      )
      simplefin_account.update!(account: account)
    end

    # Clear pending status and mark as complete
    @simplefin_item.update!(pending_account_setup: false)

    # Trigger a sync to process the imported SimpleFin data (transactions and holdings)
    @simplefin_item.sync_later

    redirect_to accounts_path, notice: t(".success")
  end

  # Lists per-account errors from the latest sync in a modal-friendly view
  def errors
    latest_sync = @simplefin_item.syncs.ordered.first
    @stats = latest_sync&.sync_stats || {}

    @error_buckets = @stats["error_buckets"] || {}
    @errors = Array(@stats["errors"]).map do |e|
      {
        account_id: e[:account_id] || e["account_id"],
        name: e[:name] || e["name"],
        category: e[:category] || e["category"],
        message: e[:message] || e["message"]
      }
    end

    render layout: false
  end

  # Presents candidate relinks between SimpleFin upstream accounts and existing manual accounts
  def relink
    @candidates = compute_relink_candidates
    render layout: false
  end

  # Applies selected relinks by migrating data and moving provider links
  def apply_relink
    pairs = Array(params[:pairs]).map { |h| h.permit(:sfa_id, :manual_id, :checked).to_h.symbolize_keys }.select { |p| p[:checked].present? }
    results = []

    SimplefinItem.transaction do
      pairs.each do |pair|
        sfa = @simplefin_item.simplefin_accounts.find_by(id: pair[:sfa_id])
        manual = Current.family.accounts.find_by(id: pair[:manual_id])
        next unless sfa && manual

        a_new = sfa.account
        # If SimpleFin account already linked to the same manual account, skip
        if a_new && a_new.id == manual.id
          results << { sfa_id: sfa.id, manual_id: manual.id, status: "skipped_same" }
          next
        end

        moved_entries = 0; deleted_entries = 0
        moved_holdings = 0; deleted_holdings = 0

        if a_new
          # Move entries with duplicate guard on (external_id, source)
          if a_new.respond_to?(:entries)
            a_new.entries.find_each do |e|
              if e.external_id.present? && e.source.present? && manual.entries.exists?(external_id: e.external_id, source: e.source)
                e.destroy!
                deleted_entries += 1
              else
                # Bypass validations when only reassigning ownership to avoid unrelated validation collisions
                e.update_columns(account_id: manual.id, updated_at: Time.current)
                moved_entries += 1
              end
            end
          end
          # Move holdings with duplicate guard (security,date,currency)
          if a_new.respond_to?(:holdings)
            a_new.holdings.find_each do |h|
              if manual.holdings.exists?(security_id: h.security_id, date: h.date, currency: h.currency)
                h.destroy!
                deleted_holdings += 1
              else
                h.update_columns(account_id: manual.id, updated_at: Time.current)
                moved_holdings += 1
              end
            end
          end

          # Move provider link to manual
          AccountProvider.where(account: a_new, provider_type: "SimplefinAccount", provider_id: sfa.id).delete_all
          AccountProvider.find_or_create_by!(account: manual, provider_type: "SimplefinAccount", provider_id: sfa.id)

          # Link legacy fk
          manual.update!(simplefin_account_id: sfa.id)

          # Remove redundant provider-linked account
          a_new.destroy!
        else
          # No provider-linked account yet, simply attach provider link to manual
          AccountProvider.find_or_create_by!(account: manual, provider_type: "SimplefinAccount", provider_id: sfa.id)
          manual.update!(simplefin_account_id: sfa.id)
        end

        results << {
          sfa_id: sfa.id,
          manual_id: manual.id,
          moved_entries: moved_entries,
          deleted_entries: deleted_entries,
          moved_holdings: moved_holdings,
          deleted_holdings: deleted_holdings,
          status: "ok"
        }
      end
    end

    respond_to do |format|
      # Close the modal and refresh the SimpleFin card so UI updates without a full page reload
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.remove("modal"),
          turbo_stream.replace(view_context.dom_id(@simplefin_item), partial: "simplefin_items/simplefin_item", locals: { simplefin_item: @simplefin_item })
        ]
      end
      format.html { redirect_to accounts_path, notice: "Linked #{results.size} accounts" }
      format.json { render json: { ok: true, results: results } }
    end
  end

  private

    def compute_relink_candidates
      # Best-effort dedup before building candidates
      @simplefin_item.dedup_simplefin_accounts! rescue nil

      family = @simplefin_item.family
      manuals = family.accounts.left_joins(:account_providers).where(account_providers: { id: nil }).to_a
      norm = ->(s){ s.to_s.downcase.gsub(/\s+/, " ").strip }

      # Evaluate only one SimpleFin account per upstream account_id (prefer linked, else newest)
      grouped = @simplefin_item.simplefin_accounts.group_by(&:account_id)
      sfas = grouped.values.map { |list| list.find { |s| s.current_account.present? } || list.max_by(&:updated_at) }

      sfas.filter_map do |sfa|
        next if sfa.name.blank?
        # Heuristics: last4 > balance ±0.01 > name
        raw = (sfa.raw_payload || {}).with_indifferent_access
        sfa_last4 = raw[:mask] || raw[:last4] || raw[:"last-4"] || raw[:"account_number_last4"]
        sfa_last4 = sfa_last4.to_s.strip.presence
        sfa_balance = (sfa.current_balance || sfa.available_balance).to_d rescue 0.to_d

        cand = manuals.find do |a|
          a_last4 = nil
          %i[mask last4 number_last4 account_number_last4].each do |k|
            if a.respond_to?(k)
              val = a.public_send(k)
              a_last4 = val.to_s.strip.presence if val.present?
              break if a_last4
            end
          end
          a_last4.present? && sfa_last4.present? && a_last4 == sfa_last4
        end

        if cand.nil? && sfa_balance.nonzero?
          cand = manuals.find do |a|
            begin
              ab = (a.balance || a.cash_balance || 0).to_d
              (ab - sfa_balance).abs <= BigDecimal("0.01")
            rescue
              false
            end
          end
        end

        cand ||= manuals.find { |a| norm.call(a.name) == norm.call(sfa.name) }

        if cand
          { sfa_id: sfa.id, sfa_name: sfa.name, manual_id: cand.id, manual_name: cand.name }
        end
      end
    end

    def set_simplefin_item
      if defined?(Current) && Current.respond_to?(:family) && Current.family.present?
        @simplefin_item = Current.family.simplefin_items.find(params[:id])
      else
        @simplefin_item = SimplefinItem.find(params[:id])
      end
    end

  private

    def set_simplefin_item
      if defined?(Current) && Current.respond_to?(:family) && Current.family.present?
        @simplefin_item = Current.family.simplefin_items.find(params[:id])
      else
        @simplefin_item = SimplefinItem.find(params[:id])
      end
    end

    def simplefin_params
      params.require(:simplefin_item).permit(:setup_token, :sync_start_date)
    end

    def render_error(message, setup_token = nil, context: :new)
      if context == :edit
        # Keep the persisted record and assign the token for re-render
        @simplefin_item.setup_token = setup_token if @simplefin_item
      else
        @simplefin_item = Current.family.simplefin_items.build(setup_token: setup_token)
      end
      @error_message = message
      render context, status: :unprocessable_entity
    end
end
