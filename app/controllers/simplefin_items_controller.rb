require "set"
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

  # Presents candidate relinks between SimpleFin upstream accounts and existing manual accounts
  def relink
    @candidates = compute_relink_candidates
    render layout: false
  end

  # Applies selected relinks by migrating data and moving provider links
  def apply_relink
    pairs = Array(params[:pairs]).map { |h| h.permit(:sfa_id, :manual_id, :checked).to_h.symbolize_keys }.select { |p| p[:checked].present? }
    Rails.logger.info("SimpleFin apply_relink: received #{pairs.size} checked pairs for item_id=#{@simplefin_item.id}")
    results = []

    SimplefinItem.transaction do
      pairs.each do |pair|
        sfa = @simplefin_item.simplefin_accounts.find_by(id: pair[:sfa_id])
        manual = Current.family.accounts.find_by(id: pair[:manual_id])
        next unless sfa && manual

        a_new = sfa.current_account
        # Defensive lookup in case associations are not loaded
        if a_new.nil?
          ap = AccountProvider.find_by(provider_type: "SimplefinAccount", provider_id: sfa.id)
          a_new = Account.find_by(id: ap&.account_id)
        end

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

          # Remove redundant provider-linked account (duplicate)
          a_new.destroy!
        else
          # No provider-linked account yet; ensure no stale links exist, then attach provider link to manual
          # Capture any previously linked account id (if present) to remove the orphaned duplicate
          prev_ap = AccountProvider.find_by(provider_type: "SimplefinAccount", provider_id: sfa.id)
          prev_account_id = prev_ap&.account_id
          AccountProvider.where(provider_type: "SimplefinAccount", provider_id: sfa.id).delete_all
          AccountProvider.find_or_create_by!(account: manual, provider_type: "SimplefinAccount", provider_id: sfa.id)
          manual.update!(simplefin_account_id: sfa.id)

          # If there was a previous duplicate provider-linked account, remove it now
          if prev_account_id.present? && prev_account_id != manual.id
            Account.where(id: prev_account_id).destroy_all
          end
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

    # Final cleanup: merge any duplicate provider-linked Accounts that may have been created previously
    begin
      merge_stats = @simplefin_item.merge_duplicate_provider_accounts!
      sfa_stats = @simplefin_item.dedup_simplefin_accounts!
      Rails.logger.info("SimpleFin apply_relink: cleanup merge_stats=#{merge_stats.inspect} sfa_stats=#{sfa_stats.inspect} for item_id=#{@simplefin_item.id}")
    rescue => e
      Rails.logger.warn("SimpleFin apply_relink cleanup failed: #{e.class} - #{e.message}")
    end

    # Recompute unlinked count and clear pending flag when zero
    begin
      unlinked = @simplefin_item.simplefin_accounts
        .left_joins(:account, :account_provider)
        .where(accounts: { id: nil }, account_providers: { id: nil })
        .count
      Rails.logger.info("SimpleFin apply_relink: unlinked_count=#{unlinked} (controls setup CTA) for item_id=#{@simplefin_item.id}")
      if unlinked.zero? && @simplefin_item.respond_to?(:pending_account_setup?) && @simplefin_item.pending_account_setup?
        @simplefin_item.update!(pending_account_setup: false)
        Rails.logger.info("SimpleFin apply_relink: cleared pending_account_setup (no unlinked accounts) for item_id=#{@simplefin_item.id}")
      end
    rescue => e
      Rails.logger.warn("SimpleFin apply_relink: failed to compute unlinked_count: #{e.class} - #{e.message}")
    end

    respond_to do |format|
      # Close the modal and refresh the SimpleFin card so UI updates without a full page reload
      format.turbo_stream do
        # Render the card partial to HTML to avoid passing a Hash to the stream builder
        # Force HTML format explicitly so Rails does not look for a turbo_stream variant of the partial
        card_html = render_to_string(partial: "simplefin_items/simplefin_item", formats: [ :html ], locals: { simplefin_item: @simplefin_item })
        render turbo_stream: [
          turbo_stream.remove("modal"),
          turbo_stream.replace(view_context.dom_id(@simplefin_item), card_html)
        ], status: :ok
      end
      format.html { redirect_to accounts_path, notice: "Linked #{results.size} accounts" }
      format.json { render json: { ok: true, results: results } }
    end
  end

  private

    NAME_NORM_RE = /\s+/.freeze

    def compute_unlinked_count(item)
      item.simplefin_accounts
          .left_joins(:account, :account_provider)
          .where(accounts: { id: nil }, account_providers: { id: nil })
          .count
    end

    def normalize_name(str)
      s = str.to_s.downcase.strip
      return s if s.empty?
      s.gsub(NAME_NORM_RE, " ")
    end

    def compute_relink_candidates
      # Best-effort dedup before building candidates
      @simplefin_item.dedup_simplefin_accounts! rescue nil

      family = @simplefin_item.family
      manuals = family.accounts.left_joins(:account_providers).where(account_providers: { id: nil }).to_a

      # Evaluate only one SimpleFin account per upstream account_id (prefer linked, else newest)
      grouped = @simplefin_item.simplefin_accounts.group_by(&:account_id)
      sfas = grouped.values.map { |list| list.find { |s| s.current_account.present? } || list.max_by(&:updated_at) }

      Rails.logger.info("SimpleFin compute_relink_candidates: manuals=#{manuals.size} sfas=#{sfas.size} (item_id=#{@simplefin_item.id})")

      used_manual_ids = Set.new
      pairs = []

      sfas.each do |sfa|
        next if sfa.name.blank?
        # Heuristics (with ambiguity guards): last4 > balance ±0.01 > name
        raw = (sfa.raw_payload || {}).with_indifferent_access
        sfa_last4 = raw[:mask] || raw[:last4] || raw[:"last-4"] || raw[:"account_number_last4"]
        sfa_last4 = sfa_last4.to_s.strip.presence
        sfa_balance = (sfa.current_balance || sfa.available_balance).to_d rescue 0.to_d

        chosen = nil
        reason = nil

        # 1) last4 match: compute all candidates not yet used
        if sfa_last4.present?
          last4_matches = manuals.reject { |a| used_manual_ids.include?(a.id) }.select do |a|
            a_last4 = nil
            %i[mask last4 number_last4 account_number_last4].each do |k|
              if a.respond_to?(k)
                val = a.public_send(k)
                a_last4 = val.to_s.strip.presence if val.present?
                break if a_last4
              end
            end
            a_last4.present? && a_last4 == sfa_last4
          end
          # Ambiguity guard: skip if multiple matches
          if last4_matches.size == 1
            cand = last4_matches.first
            # Conflict guard: if both have balances and differ wildly, skip
            begin
              ab = (cand.balance || cand.cash_balance || 0).to_d
              if sfa_balance.nonzero? && ab.nonzero? && (ab - sfa_balance).abs > BigDecimal("1.00")
                cand = nil
              end
            rescue
              # ignore balance parsing errors
            end
            if cand
              chosen = cand
              reason = "last4"
            end
          end
        end

        # 2) balance proximity
        if chosen.nil? && sfa_balance.nonzero?
          balance_matches = manuals.reject { |a| used_manual_ids.include?(a.id) }.select do |a|
            begin
              ab = (a.balance || a.cash_balance || 0).to_d
              (ab - sfa_balance).abs <= BigDecimal("0.01")
            rescue
              false
            end
          end
          if balance_matches.size == 1
            chosen = balance_matches.first
            reason = "balance"
          end
        end

        # 3) exact normalized name
        if chosen.nil?
          name_matches = manuals.reject { |a| used_manual_ids.include?(a.id) }.select { |a| normalize_name(a.name) == normalize_name(sfa.name) }
          if name_matches.size == 1
            chosen = name_matches.first
            reason = "name"
          end
        end

        if chosen
          used_manual_ids << chosen.id
          pairs << { sfa_id: sfa.id, sfa_name: sfa.name, manual_id: chosen.id, manual_name: chosen.name, reason: reason }
        end
      end

      Rails.logger.info("SimpleFin compute_relink_candidates: built #{pairs.size} pairs (item_id=#{@simplefin_item.id})")

      # Return without the reason field to the view
      pairs.map { |p| p.slice(:sfa_id, :sfa_name, :manual_id, :manual_name) }
    end

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
