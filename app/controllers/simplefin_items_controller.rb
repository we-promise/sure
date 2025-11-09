require "set"
class SimplefinItemsController < ApplicationController
  include SimplefinItems::RelinkHelpers
  before_action :set_simplefin_item, only: [ :show, :edit, :update, :destroy, :sync, :balances, :setup_accounts, :complete_account_setup, :errors, :relink, :manual_relink, :apply_relink ]

  def index
    @simplefin_items = Current.family.simplefin_items.active.ordered.includes(:syncs)

    # Precompute per-item maps used by the item partial to avoid inline queries and N+1
    build_simplefin_maps_for(@simplefin_items)

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

      # Post-update: schedule a balances-only discovery to refresh SFAs and balances
      SimplefinItem::BalancesOnlyJob.perform_later(updated_item.id)

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

      # Attempt to auto-open relink modal only when there are actionable items
      @simplefin_item = updated_item
      @candidates = compute_relink_candidates
      Rails.logger.info("SimpleFin update: relink candidates count=#{@candidates.size} for item_id=#{@simplefin_item.id}")

      # Ensure flash is set regardless of format/branch so IntegrationTest can see it
      flash[:notice] = "SimpleFin connection updated"

      manuals_exist = @simplefin_item.family.accounts
        .left_joins(:account_providers)
        .where(account_providers: { id: nil })
        .exists?
      auto_open = (@candidates.present?) || ((unlinked.to_i > 0) && manuals_exist)
      if auto_open
        respond_to do |format|
          format.html { redirect_to accounts_path(open_relink_for: @simplefin_item.id), notice: "SimpleFin connection updated" }
          format.turbo_stream { redirect_to accounts_path(open_relink_for: @simplefin_item.id), notice: "SimpleFin connection updated" }
          format.json { render json: { ok: true, relink: true, simplefin_item_id: @simplefin_item.id, candidates: @candidates }, status: :ok }
        end
      else
        # No new/unlinked accounts or candidates detected — keep modal opt-in
        redirect_to accounts_path, notice: "SimpleFin connection updated"
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
      Rails.logger.error("SimpleFin connection update error: #{e.class} - #{e.message}")
      flash[:alert] = "SimpleFin update failed. Please relink your connection."
      redirect_to accounts_path(open_relink_for: @simplefin_item&.id || updated_item&.id), alert: "SimpleFin update failed. Please relink your connection."
    end
  end

  def new
    @simplefin_item = Current.family.simplefin_items.build
  end

  def create
    setup_token = simplefin_params[:setup_token]

    # Inline validation for providers panel (Turbo)
    if setup_token.blank?
      return render_error(t(".errors.blank_token"), setup_token, context: :providers_panel)
    end

    begin
      @simplefin_item = Current.family.create_simplefin_item!(
        setup_token: setup_token,
        item_name: "SimpleFin Connection"
      )

      # Pre-prompt: schedule a balances-only discovery to populate minimal accounts
      SimplefinItem::BalancesOnlyJob.perform_later(@simplefin_item.id)

      # Recompute unlinked count and clear pending flag when zero
      begin
        unlinked = compute_unlinked_count(@simplefin_item)
        Rails.logger.info("SimpleFin create: unlinked_count=#{unlinked} (controls setup CTA) for item_id=#{@simplefin_item.id}")
        if unlinked.zero? && @simplefin_item.respond_to?(:pending_account_setup?) && @simplefin_item.pending_account_setup?
          @simplefin_item.update!(pending_account_setup: false)
          Rails.logger.info("SimpleFin create: cleared pending_account_setup (no unlinked accounts) for item_id=#{@simplefin_item.id}")
        end
      rescue => e
        Rails.logger.warn("SimpleFin create: failed to compute unlinked_count: #{e.class} - #{e.message}")
      end

      # If the request came from the Providers page (Turbo), refresh the panel in place for immediate feedback.
      respond_to do |format|
        format.turbo_stream do
          # Re-render the providers SimpleFin panel with status light/message
          @simplefin_items = Current.family.simplefin_items.ordered.includes(:syncs)
          build_simplefin_maps_for(@simplefin_items)
          html = render_to_string(partial: "settings/providers/simplefin_panel", formats: [ :html ])
          render turbo_stream: turbo_stream.replace("simplefin-providers-panel", html), status: :created
        end

        format.html do
          # If there are manual accounts that look like matches, consider auto-opening the relink modal
          @candidates = compute_relink_candidates
          Rails.logger.info("SimpleFin create: relink candidates count=#{@candidates.size} for item_id=#{@simplefin_item.id}")

          manuals_exist = @simplefin_item.family.accounts
            .left_joins(:account_providers)
            .where(account_providers: { id: nil })
            .exists?
          auto_open = (@candidates.present?) || ((unlinked.to_i > 0) && manuals_exist)
          if auto_open
            redirect_to accounts_path(open_relink_for: @simplefin_item.id), notice: t(".success")
          else
            redirect_to accounts_path, notice: t(".success")
          end
        end

        format.json { render json: { ok: true, simplefin_item_id: @simplefin_item.id }, status: :created }
      end
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
      @simplefin_item.unlink_all!(dry_run: false)
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
      format.html { redirect_back_or_to accounts_path, notice: t("simplefin_items.balances.success") }
      format.json { render json: { ok: true, sync_id: sync.id } }
    end
  end

  def setup_accounts
    raw_unlinked = @simplefin_item.simplefin_accounts
      .includes(:account, :account_provider)
      .where(accounts: { id: nil })
      .where(account_providers: { id: nil })
      .to_a

    # De‑duplicate by upstream account_id (prefer newer record)
    grouped = raw_unlinked.group_by(&:account_id)
    @simplefin_accounts = grouped.values.map { |list| list.max_by(&:updated_at) }

    # Logging for observability of Setup Accounts filtering
    Rails.logger.info(
      "SimpleFin setup_accounts: raw=#{ raw_unlinked.size } unique=#{ @simplefin_accounts.size } unlinked SF accounts (item_id=#{ @simplefin_item.id })"
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

    redirect_to accounts_path, notice: t("simplefin_items.setup_accounts.success")
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
    prepare_relink_data
    render layout: false
  end

  # Explicit manual relink endpoint (identical to relink, provided for clarity of flow)
  def manual_relink
    prepare_relink_data
    render layout: false
  end

  # Applies selected relinks by migrating data and moving provider links
  def apply_relink
    raw_pairs = Array(params[:pairs])
    sanitized = raw_pairs.map { |h| h.permit(:sfa_id, :manual_id, :checked).to_h.symbolize_keys }
    # Treat a row as selected only when the user explicitly checked it AND chose a manual account.
    pairs = sanitized.select { |p| p[:sfa_id].present? && p[:manual_id].present? && p[:checked].present? }
    Rails.logger.info("SimpleFin apply_relink: received #{pairs.size} checked pairs for item_id=#{@simplefin_item.id}")

    relink = SimplefinItem::RelinkService.new.apply!(
      simplefin_item: @simplefin_item,
      pairs: pairs,
      current_family: Current.family
    )

    # Reload the item and its associations so rendered partials reflect the new links immediately
    @simplefin_item = SimplefinItem.includes(:accounts, :simplefin_accounts, :syncs).find(@simplefin_item.id)

    # Prepare maps used by the simplefin_item partial before rendering
    build_simplefin_maps_for(@simplefin_item)

    respond_to do |format|
      format.turbo_stream do
        card_html = render_to_string(partial: "simplefin_items/simplefin_item", formats: [ :html ], locals: { simplefin_item: @simplefin_item })

        # Also refresh the Manual Accounts group on the Accounts page so duplicates are cleaned up immediately
        manual_accounts = @simplefin_item.family.accounts
          .left_joins(:account_providers)
          .where(account_providers: { id: nil })
          .order(:name)
        manual_html = render_to_string(partial: "accounts/index/manual_accounts", formats: [ :html ], locals: { accounts: manual_accounts })

        render turbo_stream: [
          turbo_stream.remove("modal"),
          turbo_stream.replace(view_context.dom_id(@simplefin_item), card_html),
          turbo_stream.replace("manual-accounts", manual_html)
        ], status: :ok
      end
      format.html { redirect_to accounts_path, notice: t("simplefin_items.apply_relink.success") }
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

    # Shared data preparation for relink and manual_relink actions
    def prepare_relink_data
      @candidates = compute_relink_candidates

      # Provide full SFA list (show linked as disabled/grayed in UI) — de‑dupe by upstream account_id
      raw_sfas = @simplefin_item.simplefin_accounts
        .includes(:account, :account_provider)
        .order(:name)
        .to_a
      grouped = raw_sfas.group_by(&:account_id)
      @sfas_all = grouped.values.map { |list| list.find { |s| s.current_account.present? } || list.max_by(&:updated_at) }

      # Manual accounts available to link (unlinked)
      @manual_accounts = @simplefin_item.family.accounts
        .left_joins(:account_providers)
        .where(account_providers: { id: nil })
        .order(:name)
    end

    def render_error(message, setup_token = nil, context: :new)
      if context == :providers_panel
        # Re-render the providers SimpleFin panel with inline error via Turbo Stream
        @error_message = message
        @simplefin_items = Current.family.simplefin_items.ordered.includes(:syncs)
        build_simplefin_maps_for(@simplefin_items)
        html = render_to_string(partial: "settings/providers/simplefin_panel", formats: [ :html ])
        respond_to do |format|
          format.turbo_stream { render turbo_stream: turbo_stream.replace("simplefin-providers-panel", html), status: :unprocessable_entity }
          format.html { render :new, status: :unprocessable_entity }
        end
        return
      end

      if context == :edit
        # Keep the persisted record and assign the token for re-render
        @simplefin_item.setup_token = setup_token if @simplefin_item
      else
        @simplefin_item = Current.family.simplefin_items.build(setup_token: setup_token)
      end
      @error_message = message
      render context, status: :unprocessable_entity
    end

    # Build per-item maps consumed by the simplefin_item partial.
    # Accepts a single SimplefinItem or a collection.
    def build_simplefin_maps_for(items)
      items = Array(items).compact

      @simplefin_sync_stats_map ||= {}
      @simplefin_has_unlinked_map ||= {}
      @simplefin_unlinked_count_map ||= {}
      @simplefin_duplicate_only_map ||= {}
      @simplefin_show_relink_map ||= {}

      items.each do |item|
        # Latest sync stats (avoid N+1; rely on includes(:syncs) where appropriate)
        latest_sync = if item.syncs.loaded?
          item.syncs.max_by(&:created_at)
        else
          item.syncs.ordered.first
        end
        stats = (latest_sync&.sync_stats || {})
        @simplefin_sync_stats_map[item.id] = stats

        # Whether the family has any manual accounts available to link
        @simplefin_has_unlinked_map[item.id] = item.family.accounts
          .left_joins(:account_providers)
          .where(account_providers: { id: nil })
          .exists?

        # Count of SimpleFin accounts for this item that have neither legacy account nor AccountProvider
        count = item.simplefin_accounts
          .left_joins(:account, :account_provider)
          .where(accounts: { id: nil }, account_providers: { id: nil })
          .count
        @simplefin_unlinked_count_map[item.id] = count

        # Whether all reported errors for this item are duplicate-account warnings
        @simplefin_duplicate_only_map[item.id] = compute_duplicate_only_flag(stats)

        # Compute CTA visibility: show relink only when there are zero unlinked SFAs,
        # there exist manual accounts to link, and the item has at least one SFA
        begin
          unlinked_count = @simplefin_unlinked_count_map[item.id] || 0
          manuals_exist = @simplefin_has_unlinked_map[item.id]
          sfa_any = if item.simplefin_accounts.loaded?
            item.simplefin_accounts.any?
          else
            item.simplefin_accounts.exists?
          end
          @simplefin_show_relink_map[item.id] = (unlinked_count.to_i == 0 && manuals_exist && sfa_any)
        rescue => e
          Rails.logger.warn("SimpleFin card: CTA computation failed for item #{item.id}: #{e.class} - #{e.message}")
          @simplefin_show_relink_map[item.id] = false
        end
      end

      # Ensure maps are hashes even when items empty
      @simplefin_sync_stats_map ||= {}
      @simplefin_has_unlinked_map ||= {}
      @simplefin_unlinked_count_map ||= {}
      @simplefin_duplicate_only_map ||= {}
      @simplefin_show_relink_map ||= {}
    end

    def compute_duplicate_only_flag(stats)
      errs = Array(stats && stats["errors"]).map do |e|
        if e.is_a?(Hash)
          e["message"] || e[:message]
        else
          e.to_s
        end
      end
      errs.present? && errs.all? { |m| m.to_s.downcase.include?("duplicate upstream account detected") }
    rescue
      false
    end
end
