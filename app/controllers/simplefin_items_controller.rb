class SimplefinItemsController < ApplicationController
  include SimplefinItems::MapsHelper
  before_action :set_simplefin_item, only: [ :show, :edit, :update, :destroy, :sync, :balances, :setup_accounts, :complete_account_setup ]

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
      # Validate token shape early so the user gets immediate feedback.
      claim_url = Base64.decode64(setup_token)
      URI.parse(claim_url)

      # Updating a SimpleFin connection can involve network retries/backoff and account import.
      # Do it asynchronously so web requests aren't blocked by retry sleeps.
      SimplefinConnectionUpdateJob.perform_later(
        family_id: Current.family.id,
        old_simplefin_item_id: @simplefin_item.id,
        setup_token: setup_token
      )

      if turbo_frame_request?
        flash.now[:notice] = t(".success")
        render turbo_stream: Array(flash_notification_stream_items)
      else
        redirect_to accounts_path, notice: t(".success"), status: :see_other
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
        item_name: "SimpleFIN Connection"
      )

      if turbo_frame_request?
        flash.now[:notice] = t(".success")
        @simplefin_items = Current.family.simplefin_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "simplefin-providers-panel",
            partial: "settings/providers/simplefin_panel",
            locals: { simplefin_items: @simplefin_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to accounts_path, notice: t(".success"), status: :see_other
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
    # Ensure we detach provider links and legacy associations before scheduling deletion
    begin
      @simplefin_item.unlink_all!(dry_run: false)
    rescue => e
      Rails.logger.warn("SimpleFin unlink during destroy failed: #{e.class} - #{e.message}")
    end
    @simplefin_item.destroy_later
    redirect_to accounts_path, notice: t(".success"), status: :see_other
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
    # Create a Sync and enqueue it to run asynchronously with a runtime-only flag
    sync = @simplefin_item.syncs.create!(status: :pending)
    SyncJob.perform_later(sync, balances_only: true)

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { render json: { ok: true, sync_id: sync.id } }
    end
  end

  def setup_accounts
    # Only show unlinked accounts - check both legacy FK and AccountProvider
    @simplefin_accounts = @simplefin_item.simplefin_accounts
      .left_joins(:account, :account_provider)
      .where(accounts: { id: nil }, account_providers: { id: nil })
    @account_type_options = [
      [ "Skip this account", "skip" ],
      [ "Checking or Savings Account", "Depository" ],
      [ "Credit Card", "CreditCard" ],
      [ "Investment Account", "Investment" ],
      [ "Crypto Account", "Crypto" ],
      [ "Loan or Mortgage", "Loan" ],
      [ "Other Asset", "OtherAsset" ]
    ]

    # Compute UI-only suggestions (preselect only when high confidence)
    @inferred_map = {}
    @simplefin_accounts.each do |sfa|
      holdings = sfa.raw_holdings_payload.presence || sfa.raw_payload.to_h["holdings"]
      institution_name = nil
      begin
        od = sfa.org_data
        institution_name = od["name"] if od.is_a?(Hash)
      rescue
        institution_name = nil
      end
      inf = Simplefin::AccountTypeMapper.infer(
        name: sfa.name,
        holdings: holdings,
        extra: sfa.extra,
        balance: sfa.current_balance,
        available_balance: sfa.available_balance,
        institution: institution_name
      )
      @inferred_map[sfa.id] = { type: inf.accountable_type, subtype: inf.subtype, confidence: inf.confidence }
    end

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
      "Crypto" => {
        label: nil,
        options: [],
        message: "Crypto accounts track cryptocurrency holdings."
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

    # Valid account types for this provider (plus Crypto and OtherAsset which SimpleFIN UI allows)
    valid_types = Provider::SimplefinAdapter.supported_account_types + [ "Crypto", "OtherAsset" ]

    created_accounts = []
    skipped_count = 0

    account_types.each do |simplefin_account_id, selected_type|
      # Skip accounts marked as "skip"
      if selected_type == "skip" || selected_type.blank?
        skipped_count += 1
        next
      end

      # Validate account type is supported
      unless valid_types.include?(selected_type)
        Rails.logger.warn("Invalid account type '#{selected_type}' submitted for SimpleFIN account #{simplefin_account_id}")
        next
      end

      # Find account - scoped to this item to prevent cross-item manipulation
      simplefin_account = @simplefin_item.simplefin_accounts.find_by(id: simplefin_account_id)
      unless simplefin_account
        Rails.logger.warn("SimpleFIN account #{simplefin_account_id} not found for item #{@simplefin_item.id}")
        next
      end

      # Skip if already linked (race condition protection)
      if simplefin_account.account.present?
        Rails.logger.info("SimpleFIN account #{simplefin_account_id} already linked, skipping")
        next
      end

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
      # Also create AccountProvider for consistency with the new linking system
      simplefin_account.ensure_account_provider!
      created_accounts << account
    end

    # Clear pending status and mark as complete
    @simplefin_item.update!(pending_account_setup: false)

    # Trigger a sync to process the imported SimpleFin data (transactions and holdings)
    @simplefin_item.sync_later if created_accounts.any?

    # Set appropriate flash message
    if created_accounts.any?
      flash[:notice] = t(".success", count: created_accounts.count)
    elsif skipped_count > 0
      flash[:notice] = t(".all_skipped")
    else
      flash[:notice] = t(".no_accounts")
    end
    if turbo_frame_request?
      # Recompute data needed by Accounts#index partials
      @manual_accounts = Account.uncached {
        Current.family.accounts
          .visible_manual
          .order(:name)
          .to_a
      }
      @simplefin_items = Current.family.simplefin_items.ordered.includes(:syncs)
      build_simplefin_maps_for(@simplefin_items)

      manual_accounts_stream = if @manual_accounts.any?
        turbo_stream.update(
          "manual-accounts",
          partial: "accounts/index/manual_accounts",
          locals: { accounts: @manual_accounts }
        )
      else
        turbo_stream.replace("manual-accounts", view_context.tag.div(id: "manual-accounts"))
      end

      render turbo_stream: [
        manual_accounts_stream,
        turbo_stream.replace(
          ActionView::RecordIdentifier.dom_id(@simplefin_item),
          partial: "simplefin_items/simplefin_item",
          locals: { simplefin_item: @simplefin_item }
        )
      ] + Array(flash_notification_stream_items)
    else
      redirect_to accounts_path, status: :see_other
    end
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])

    # Allow explicit relinking by listing all available SimpleFIN accounts for the family.
    # The UI will surface the current mapping (if any), and the action will move the link.
    @available_simplefin_accounts = Current.family.simplefin_items
      .includes(simplefin_accounts: [ :account, { account_provider: :account } ])
      .flat_map(&:simplefin_accounts)
      # After provider setup, SFAs may already have an AccountProvider (linked to the freshly
      # created duplicate accounts). During relink, we need to show those SFAs until the legacy
      # link (`Account.simplefin_account_id`) has been cleared.
      #
      # Eligibility rule:
      # - Show SFAs that are still legacy-linked (`sfa.account.present?`) => candidates to move.
      # - Show SFAs that are fully unlinked (no legacy account and no account_provider) => candidates to link.
      # - Hide SFAs that are linked via AccountProvider but no longer legacy-linked => already relinked.
      .select { |sfa| sfa.account.present? || sfa.account_provider.nil? }
      .sort_by { |sfa| sfa.updated_at || sfa.created_at }
      .reverse

    # Always render a modal: either choices or a helpful empty-state
    render :select_existing_account, layout: false
  end

  def link_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    simplefin_account = SimplefinAccount.find(params[:simplefin_account_id])

    # Guard: only manual accounts can be linked (no existing provider links or legacy IDs)
    if @account.account_providers.any? || @account.plaid_account_id.present? || @account.simplefin_account_id.present?
      flash[:alert] = t("simplefin_items.link_existing_account.errors.only_manual")
      if turbo_frame_request?
        return render turbo_stream: Array(flash_notification_stream_items)
      else
        return redirect_to account_path(@account), alert: flash[:alert]
      end
    end

    # Verify the SimpleFIN account belongs to this family's SimpleFIN items
    unless Current.family.simplefin_items.include?(simplefin_account.simplefin_item)
      flash[:alert] = t("simplefin_items.link_existing_account.errors.invalid_simplefin_account")
      if turbo_frame_request?
        render turbo_stream: Array(flash_notification_stream_items)
      else
        redirect_to account_path(@account), alert: flash[:alert]
      end
      return
    end

    # Relink behavior: detach any legacy link and point provider link at the chosen account
    Account.transaction do
      simplefin_account.lock!

      # Clear legacy association if present (Account.simplefin_account_id)
      if (legacy_account = simplefin_account.account)
        legacy_account.update!(simplefin_account_id: nil)
      end

      # Upsert the AccountProvider mapping deterministically
      ap = AccountProvider.find_or_initialize_by(provider: simplefin_account)
      previous_account = ap.account
      ap.account_id = @account.id
      ap.save!

      # If the provider was previously linked to a different account in this family,
      # and that account is now orphaned, quietly disable it so it disappears from the
      # visible manual list. This mirrors the unified flow expectation that the provider
      # follows the chosen account.
      if previous_account && previous_account.id != @account.id && previous_account.family_id == @account.family_id
        begin
          previous_account.reload
          # Only hide if the previous account is truly orphaned (no other provider links)
          if previous_account.account_providers.none?
            # Disabled accounts still appear (greyed-out) in the manual list; for relink
            # consolidation we want the duplicate to disappear from the UI.
            # Use the app's standard deletion path (async) so the "pending_deletion" state
            # remains truthful in the UI.
            previous_account.destroy_later if previous_account.may_mark_for_deletion?
          else
            Rails.logger.info("Skipped disabling account ##{previous_account.id} after relink because it still has active provider links")
          end
        rescue => e
          Rails.logger.warn("Failed disabling-orphan check for account ##{previous_account&.id}: #{e.class} - #{e.message}")
        end
      end
    end

    if turbo_frame_request?
      # Reload the item to ensure associations are fresh
      simplefin_account.reload
      item = simplefin_account.simplefin_item
      item.reload

      # Recompute data needed by Accounts#index partials
      @manual_accounts = Account.uncached {
        Current.family.accounts
          .visible_manual
          .order(:name)
          .to_a
      }
      @simplefin_items = Current.family.simplefin_items.ordered.includes(:syncs)
      build_simplefin_maps_for(@simplefin_items)

      flash[:notice] = t("simplefin_items.link_existing_account.success")
      @account.reload
      manual_accounts_stream = if @manual_accounts.any?
        turbo_stream.update(
          "manual-accounts",
          partial: "accounts/index/manual_accounts",
          locals: { accounts: @manual_accounts }
        )
      else
        turbo_stream.replace("manual-accounts", view_context.tag.div(id: "manual-accounts"))
      end

      render turbo_stream: [
        # Optimistic removal of the specific account row if it exists in the DOM
        turbo_stream.remove(ActionView::RecordIdentifier.dom_id(@account)),
        manual_accounts_stream,
        turbo_stream.replace(
          ActionView::RecordIdentifier.dom_id(item),
          partial: "simplefin_items/simplefin_item",
          locals: { simplefin_item: item }
        ),
        turbo_stream.replace("modal", view_context.turbo_frame_tag("modal"))
      ] + Array(flash_notification_stream_items)
    else
      redirect_to accounts_path(cache_bust: SecureRandom.hex(6)), notice: t("simplefin_items.link_existing_account.success"), status: :see_other
    end
  end


  private

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

      if turbo_frame_request?
        # Re-render the SimpleFIN providers panel in place to avoid "Content missing"
        @simplefin_items = Current.family.simplefin_items.ordered
        render turbo_stream: turbo_stream.replace(
          "simplefin-providers-panel",
          partial: "settings/providers/simplefin_panel",
          locals: { simplefin_items: @simplefin_items }
        ), status: :unprocessable_entity
      else
        render context, status: :unprocessable_entity
      end
    end
end
