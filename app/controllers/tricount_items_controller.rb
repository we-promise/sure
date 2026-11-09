# frozen_string_literal: true

class TricountItemsController < ApplicationController
  before_action :require_admin!
  before_action :set_tricount_item, only: [ :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  # Starts following the tricounts behind the links given. A family has one
  # Tricount connection; adding more links later goes through #update.
  # A family has one Tricount connection, following all its links. A
  # repeated create (a second settings tab, a resubmit) adds its links to the
  # existing connection instead of starting another; the family lock keeps
  # two at once from both finding none.
  def create
    saved = false
    unreadable = []
    Current.family.with_lock do
      @tricount_item = Current.family.tricount_items.active.first || Current.family.tricount_items.build(name: t(".default_name"))
      unreadable = @tricount_item.add_sharing_links(sharing_links_param)
      saved = unreadable.none? && @tricount_item.sharing_token_list.any? && @tricount_item.save
    end

    if unreadable.any? || @tricount_item.sharing_token_list.empty?
      render_provider_panel("tricount", alert: t(".invalid_links"))
    elsif saved
      @tricount_item.sync_later unless @tricount_item.syncing?
      redirect_to settings_providers_path, notice: t(".success"), status: :see_other
    else
      render_provider_panel("tricount", alert: @tricount_item.errors.full_messages.join(", "))
    end
  end

  # Merged under the connection's row lock (which reloads it), so links
  # another request added meanwhile are kept.
  def update
    unreadable = []
    saved = false
    @tricount_item.with_lock do
      unreadable = @tricount_item.add_sharing_links(sharing_links_param)
      saved = unreadable.none? && @tricount_item.save
    end

    if unreadable.any?
      render_provider_panel("tricount", alert: t(".invalid_links"))
    elsif saved
      @tricount_item.sync_later unless @tricount_item.syncing?
      render_provider_panel("tricount", notice: t(".success"))
    else
      render_provider_panel("tricount", alert: @tricount_item.errors.full_messages.join(", "))
    end
  end

  def destroy
    @tricount_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  end

  def sync
    @tricount_item.sync_later unless @tricount_item.syncing?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # Adding a Tricount account from the accounts page: every tricount needs its
  # member chosen, so all of these lead to the setup page.

  def preload_accounts
    tricount_item = configured_item
    return frame_redirect_to(settings_providers_path, alert: t(".no_credentials_configured")) unless tricount_item

    tricount_item.sync_later unless tricount_item.syncing?
    frame_redirect_to setup_accounts_tricount_item_path(tricount_item)
  end

  def select_accounts
    tricount_item = configured_item
    return frame_redirect_to(settings_providers_path, alert: t(".no_credentials_configured")) unless tricount_item

    frame_redirect_to setup_accounts_tricount_item_path(tricount_item)
  end

  def link_accounts
    tricount_item = configured_item
    return redirect_to(settings_providers_path, alert: t(".no_credentials_configured")) unless tricount_item

    redirect_to setup_accounts_tricount_item_path(tricount_item)
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    # Family scoping alone would let an admin link a co-member's account they
    # only hold read_write on.
    return unless require_account_permission!(@account, :write, redirect_path: accounts_path)
    return frame_redirect_to(account_path(@account), alert: t(".account_already_linked")) if @account.linked?

    @tricount_item = configured_item
    return frame_redirect_to(settings_providers_path, alert: t(".no_credentials_configured")) unless @tricount_item

    @tricount_accounts = @tricount_item.unlinked_tricount_accounts.order(:name)
  end

  def link_existing_account
    account = Current.family.accounts.find(params[:account_id])
    return unless require_account_permission!(account, :write, redirect_path: accounts_path)

    tricount_item = configured_item
    return redirect_to(settings_providers_path, alert: t(".no_credentials_configured")) unless tricount_item

    # A second provider on the account would overwrite its balance and add
    # Tricount's legs to the other provider's transactions.
    return redirect_to(account_path(account), alert: t(".account_already_linked")) if account.linked?

    tricount_account = tricount_item.tricount_accounts.find(params[:tricount_account_id])
    unless account.accountable_type.in?(Provider::TricountAdapter.supported_account_types)
      return redirect_to(account_path(account), alert: t(".unsupported_account_type"))
    end
    # A sync sets the account's currency to the tricount's, which would leave
    # the account's existing history in another currency.
    if tricount_account.currency.present? && account.currency != tricount_account.currency
      return redirect_to(account_path(account), alert: t(".currency_mismatch", currency: tricount_account.currency))
    end

    # Two requests could both find the tricount, or the account, unlinked and
    # the second fail on the unique link. Under the locks (which reload) the
    # second sees the first's link.
    already_linked = nil
    account.with_lock do
      tricount_account.with_lock do
        if account.linked?
          already_linked = :account_already_linked
        elsif tricount_account.account_provider.present?
          already_linked = :provider_account_already_linked
        elsif tricount_account.currency.present? && account.currency != tricount_account.currency
          # A sync may have changed the tricount's currency since the check above.
          already_linked = :currency_mismatch
        else
          tricount_account.assign_member!(params[:member_uuid])
          tricount_account.ensure_account_provider!(account)
        end
      end
    end
    return redirect_to(account_path(account), alert: t(".#{already_linked}", currency: tricount_account.currency)) if already_linked

    account.update!(institution_domain: TricountItem::INSTITUTION[:domain]) if account.read_attribute(:institution_domain).blank?
    tricount_item.sync_later unless tricount_item.syncing?

    redirect_to account_path(account), notice: t(".success", account_name: account.name)
  rescue ArgumentError
    redirect_to account_path(account), alert: t(".member_required")
  end

  def setup_accounts
    @unlinked_accounts = @tricount_item.unlinked_tricount_accounts.order(:name)

    redirect_to accounts_path, notice: t(".all_accounts_linked") if @unlinked_accounts.empty? && !@tricount_item.syncing?
  end

  # Creates a cash account for each tricount chosen, following the member
  # chosen for it.
  def complete_account_setup
    configs = params.fetch(:accounts, {}).to_unsafe_h
    chosen = configs.select { |_id, config| config["import"] == "1" }
    return redirect_to(setup_accounts_tricount_item_path(@tricount_item), alert: t(".no_accounts")) if chosen.empty?

    if chosen.any? { |_id, config| config["member_uuid"].blank? }
      return redirect_to(setup_accounts_tricount_item_path(@tricount_item), alert: t(".member_required"))
    end

    @tricount_item.update!(prefix_account_names: params[:prefix_account_names] == "1")

    created = 0
    chosen.each do |tricount_account_id, config|
      tricount_account = @tricount_item.unlinked_tricount_accounts.find_by(id: tricount_account_id)
      next unless tricount_account

      linked_meanwhile = false
      TricountAccount.transaction do
        # Another submission may have linked it since the lookup; under the
        # lock (which reloads) this one sees that link and creates nothing.
        tricount_account.lock!
        if tricount_account.account_provider.present?
          linked_meanwhile = true
        else
          tricount_account.assign_member!(config["member_uuid"])
          account = Current.family.accounts.create!(
            name: @tricount_item.account_name_for(tricount_account),
            balance: tricount_account.current_balance || 0,
            currency: tricount_account.currency,
            institution_name: TricountItem::INSTITUTION[:name],
            institution_domain: TricountItem::INSTITUTION[:domain],
            accountable: Depository.new
          )
          account.auto_share_with_family! if Current.family.share_all_by_default?
          tricount_account.ensure_account_provider!(account)
        end
      end
      next if linked_meanwhile

      created += 1
    rescue ArgumentError, ActiveRecord::RecordInvalid => e
      Rails.logger.error "TricountItemsController#complete_account_setup - #{e.class}"
      # An unknown member is the form's to correct; an account that couldn't
      # be saved is support's to look into.
      if e.is_a?(ActiveRecord::RecordInvalid)
        DebugLogEntry.capture(
          category: "provider_sync_error",
          level: "error",
          message: "Tricount account setup failed",
          source: self.class.name,
          provider_key: "tricount",
          family: Current.family,
          metadata: { tricount_item_id: @tricount_item.id, tricount_account_id: tricount_account_id, error_class: e.class.name, error_message: e.message }
        )
      end
    end

    if created.positive?
      @tricount_item.sync_later unless @tricount_item.syncing?
      redirect_to accounts_path, notice: t(".success", count: created)
    else
      redirect_to setup_accounts_tricount_item_path(@tricount_item), alert: t(".creation_failed")
    end
  end

  private

    def set_tricount_item
      @tricount_item = Current.family.tricount_items.find(params[:id])
    end

    def configured_item
      Current.family.tricount_items.active.find(&:credentials_configured?)
    end

    def sharing_links_param
      params.require(:tricount_item).permit(:sharing_links)[:sharing_links]
    end
end
