require "set"
class SimplefinItemsController < ApplicationController
  include SimplefinItems::RelinkHelpers
  before_action :set_simplefin_item, only: [ :show, :edit, :update, :destroy, :sync, :balances, :setup_accounts, :complete_account_setup, :errors, :relink, :manual_relink, :apply_relink ]

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

      # Run a quick balances-only discovery on the new item to ensure SFAs exist and are fresh
      begin
        SimplefinItem::Importer.new(updated_item, simplefin_provider: updated_item.simplefin_provider).import_balances_only
        updated_item.dedup_simplefin_accounts!
        # Merge any duplicate provider-linked Accounts as a safe cleanup
        updated_item.merge_duplicate_provider_accounts! rescue nil
        updated_item.update!(last_synced_at: Time.current) if updated_item.has_attribute?(:last_synced_at)
      rescue Provider::Simplefin::SimplefinError, ArgumentError, StandardError => e
        Rails.logger.warn("SimpleFin update balances-only failed: #{e.class} - #{e.message}")
      end

      # Recompute unlinked count and clear pending flag when zero
      begin
        unlinked = compute_unlinked_count(updated_item)
        Rails.logger.info("SimpleFin update: unlinked_count=#{unlinked} (controls setup CTA) for item_id=#{updated_item.id}")
        if unlinked.zero? && updated_item.respond_to?(:pending_account_setup?) && updated_item.pending_account_setup?
          updated_item.update!(pending_account_setup: false)
          Rails.logger.info("SimpleFin update: cleared pending_account_setup (no unlinked accounts) for item_id=#{updated_item.id}")
        end
      rescue => e
        Rails.logger.warn("SimpleFin update: failed to compute unlinked_count: #{e.class} - #{e.message}")
      end

      # Attempt to auto-open relink modal when viable pairs exist after update
      @simplefin_item = updated_item
      @candidates = compute_relink_candidates
      Rails.logger.info("SimpleFin update: relink candidates count=#{@candidates.size} for item_id=#{@simplefin_item.id}")
      if @candidates.present?
        respond_to do |format|
          format.html { redirect_to accounts_path(open_relink_for: @simplefin_item.id), notice: t(".success") }
          format.turbo_stream { redirect_to accounts_path(open_relink_for: @simplefin_item.id), notice: t(".success") }
          format.json { render json: { ok: true, relink: true, simplefin_item_id: @simplefin_item.id, candidates: @candidates }, status: :ok }
        end
      else
        redirect_to accounts_path, notice: t(".success")
      end
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
      rescue Provider::Simplefin::SimplefinError, ArgumentError, StandardError => e
        Rails.logger.warn("SimpleFin pre-prompt balances-only failed: #{e.class} - #{e.message}")
      end

      # Recompute unlinked count and clear pending flag when zero
      begin
        unlinked = @simplefin_item.simplefin_accounts
          .left_joins(:account, :account_provider)
          .where(accounts: { id: nil }, account_providers: { id: nil })
          .count
        Rails.logger.info("SimpleFin create: unlinked_count=#{unlinked} (controls setup CTA) for item_id=#{@simplefin_item.id}")
        if unlinked.zero? && @simplefin_item.respond_to?(:pending_account_setup?) && @simplefin_item.pending_account_setup?
          @simplefin_item.update!(pending_account_setup: false)
          Rails.logger.info("SimpleFin create: cleared pending_account_setup (no unlinked accounts) for item_id=#{@simplefin_item.id}")
        end
      rescue => e
        Rails.logger.warn("SimpleFin create: failed to compute unlinked_count: #{e.class} - #{e.message}")
      end

      # If there are manual accounts that look like matches, present the relink modal immediately
      @candidates = compute_relink_candidates
      Rails.logger.info("SimpleFin create: relink candidates count=#{@candidates.size} for item_id=#{@simplefin_item.id}")
      if @candidates.present?
        respond_to do |format|
          format.html { redirect_to accounts_path(open_relink_for: @simplefin_item.id), notice: t(".success") }
          format.turbo_stream { redirect_to accounts_path(open_relink_for: @simplefin_item.id), notice: t(".success") }
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
    begin
      # Ensure any provider links are removed so accounts move to "Other accounts" before deletion
      SimplefinItem::Unlinker.new(@simplefin_item, dry_run: false).unlink_all!
      @simplefin_item.destroy_later
      redirect_to accounts_path, notice: t(".success")
    rescue => e
      Rails.logger.error("SimplefinItemsController#destroy unlink error: #{e.class} - #{e.message}")
      redirect_to accounts_path, alert: t(".errors.destroy_failed", message: e.message)
    end
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
    # Ensure we don't present duplicates if upstream produced duplicate rows for the same account_id
    begin
      @simplefin_item.dedup_simplefin_accounts!
    rescue => e
      Rails.logger.warn("SimpleFin setup_accounts: dedup failed: #{e.class} - #{e.message}")
    end

    @simplefin_accounts = @simplefin_item.simplefin_accounts
      .includes(:account, :account_provider)
      .where(accounts: { id: nil })
      .where(account_providers: { id: nil })

    # Logging for observability of Setup Accounts filtering
    Rails.logger.info(
      "SimpleFin setup_accounts: listing #{ @simplefin_accounts.size } unlinked SF accounts (item_id=#{ @simplefin_item.id })"
    )

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

  # Presents candidate relinks (manual flow) between SimpleFin upstream accounts and existing manual accounts
  def relink
    @candidates = compute_relink_candidates
    render layout: false
  end

  # Explicit manual relink endpoint (identical to relink, provided for clarity of flow)
  def manual_relink
    @candidates = compute_relink_candidates
    render layout: false
  end

  # Applies selected relinks by migrating data and moving provider links
  def apply_relink
    pairs = Array(params[:pairs]).map { |h| h.permit(:sfa_id, :manual_id, :checked).to_h.symbolize_keys }.select { |p| p[:checked].present? }
    Rails.logger.info("SimpleFin apply_relink: received #{pairs.size} checked pairs for item_id=#{@simplefin_item.id}")

    relink = SimplefinItem::RelinkService.new.apply!(
      simplefin_item: @simplefin_item,
      pairs: pairs,
      current_family: Current.family
    )

    respond_to do |format|
      format.turbo_stream do
        card_html = render_to_string(partial: "simplefin_items/simplefin_item", formats: [ :html ], locals: { simplefin_item: @simplefin_item })
        render turbo_stream: [
          turbo_stream.remove("modal"),
          turbo_stream.replace(view_context.dom_id(@simplefin_item), card_html)
        ], status: :ok
      end
      format.html { redirect_to accounts_path, notice: "Linked #{relink.results.size} accounts" }
      format.json { render json: { ok: true, results: relink.results, merge: relink.merge_stats, sfa: relink.sfa_stats, unlinked: relink.unlinked_count } }
    end
  end

  private




    def set_simplefin_item
      scope = Current.respond_to?(:family) && Current.family.present? ? Current.family.simplefin_items : SimplefinItem
      @simplefin_item = scope.find(params[:id])
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
