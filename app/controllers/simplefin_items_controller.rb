class SimplefinItemsController < ApplicationController
  before_action :set_simplefin_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup, :errors ]

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

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])

    # Get all SimpleFIN accounts from this family's SimpleFIN items
    # that are not yet linked to any account
    @available_simplefin_accounts = Current.family.simplefin_items
      .includes(:simplefin_accounts)
      .flat_map(&:simplefin_accounts)
      .select { |sa| sa.account_provider.nil? && sa.account.nil? } # Not linked via new or legacy system

    if @available_simplefin_accounts.empty?
      redirect_to account_path(@account), alert: "No available SimpleFIN accounts to link. Please connect a new SimpleFIN account first."
    end
  end

  def link_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    simplefin_account = SimplefinAccount.find(params[:simplefin_account_id])

    # Verify the SimpleFIN account belongs to this family's SimpleFIN items
    unless Current.family.simplefin_items.include?(simplefin_account.simplefin_item)
      redirect_to account_path(@account), alert: "Invalid SimpleFIN account selected"
      return
    end

    # Verify the SimpleFIN account is not already linked
    if simplefin_account.account_provider.present? || simplefin_account.account.present?
      redirect_to account_path(@account), alert: "This SimpleFIN account is already linked"
      return
    end

    # Create the link via AccountProvider
    AccountProvider.create!(
      account: @account,
      provider: simplefin_account
    )

    redirect_to accounts_path, notice: "Account successfully linked to SimpleFIN"
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
      @simplefin_item = Current.family.simplefin_items.find(params[:id])
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
