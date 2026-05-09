class ProviderConnectionsController < ApplicationController
  include ProviderAuthFlowSession

  before_action :require_admin!
  before_action :set_connection, except: [ :select, :link, :skip ]

  def select
    @provider_key = params[:provider_key] || params[:provider]
    @adapter      = Provider::ConnectionRegistry.adapter_for(@provider_key)
    # connect_actions can be expensive (Plaid hits Provider::Registry per
    # region). Compute once; the view re-uses @connect_actions.
    @connect_actions = @adapter.connect_actions(family: Current.family)
    @configured = if @adapter.requires_family_config?
      Current.family.provider_family_configs.exists?(provider_key: @provider_key)
    else
      # Global-cred providers (e.g. Plaid) — "configured" iff the adapter
      # actually has actionable connect_actions. Empty actions means no
      # region has its app credentials set, so we route the user to the
      # setup-required branch (which links to Settings → Providers).
      @connect_actions.any?
    end
  rescue NotImplementedError
    head :not_found
  end

  def show
    @provider_accounts = @connection.provider_accounts.includes(:account).order(:external_name)
    @has_unlinked = @provider_accounts.any? { |pa| !pa.linked? && !pa.skipped? }
    @family_accounts = Current.family.accounts.alphabetically
  end

  def setup
    @unlinked   = @connection.provider_accounts.where(account_id: nil).reject { |pa| pa.disappeared? }
    @stale      = @connection.provider_accounts.select(&:disappeared?)
    @accounts   = Current.family.accounts.alphabetically
  end

  def save_setup
    mappings = params.permit(mappings: {}).fetch(:mappings, {})
    provider_accounts = @connection.provider_accounts.index_by { |pa| pa.id.to_s }

    ActiveRecord::Base.transaction do
      if (raw = params[:sync_start_date].presence)
        # Coerce to Date explicitly so a hand-crafted POST with a malformed
        # value cannot raise ActiveRecord::ValueValidatorFailed and 500 the
        # whole save_setup. Silently ignore unparseable input — the type=date
        # input on the form makes most malformed values a deliberate POC.
        parsed = (Date.parse(raw) rescue nil)
        @connection.update!(sync_start_date: parsed) if parsed
      end

      mappings.each do |pa_id, account_id|
        pa = provider_accounts[pa_id]
        next unless pa

        if account_id.blank?
          pa.update!(skipped: true)
        elsif account_id == "new"
          account = pa.build_sure_account(family: Current.family)
          account.save!
          pa.update!(account_id: account.id, skipped: false)
        else
          target = Current.family.accounts.find_by(id: account_id)
          next unless target
          pa.update!(account_id: target.id, skipped: false)
        end
      end
    end

    @connection.sync_later
    redirect_to provider_connection_path(@connection),
                notice: t("provider.connections.setup_saved")
  end

  def destroy
    @connection.destroy
    redirect_to settings_providers_path, notice: t("provider.connections.disconnected")
  end

  def reauth
    # Plaid Link reauth opens the JS-driven Link widget in UPDATE mode rather
    # than redirecting to an OAuth endpoint. Other auth backends write a
    # reauth flow record into the same session map the OAuth callback consumes,
    # so the callback knows to update an existing connection rather than create
    # a new one.
    if @connection.auth_type == "embedded_link"
      redirect_to new_provider_link_path(provider_key: @connection.provider_key,
                                         connection_id: @connection.id)
    else
      flow_id = SecureRandom.hex(16)
      write_flow!(flow_id, {
        "kind"          => "reauth",
        "connection_id" => @connection.id,
        "provider_key"  => @connection.provider_key,
        "redirect_uri"  => @connection.metadata["redirect_uri"],
        "created_at"    => Time.current.to_i
      })
      redirect_to @connection.auth.reauth_url(state: flow_id), allow_other_host: true
    end
  end

  def sync
    @connection.sync_later
    redirect_to provider_connection_path(@connection),
                notice: t("provider.connections.sync_queued")
  end

  def link
    pa = find_provider_account_for_family(params[:provider_account_id])
    return head :not_found unless pa

    if params[:account_id] == "new"
      ActiveRecord::Base.transaction do
        account = pa.build_sure_account(family: Current.family)
        account.save!
        pa.update!(account_id: account.id, skipped: false)
      end
    else
      target = Current.family.accounts.find_by(id: params[:account_id])
      return head :unprocessable_entity unless target
      pa.update!(account_id: target.id, skipped: false)
    end

    pa.provider_connection.sync_later
    redirect_to provider_connection_path(pa.provider_connection),
                notice: t("provider.connections.account_linked")
  end

  def skip
    pa = find_provider_account_for_family(params[:provider_account_id])
    return head :not_found unless pa

    pa.update!(skipped: true)
    # Once the user has finished decision-making (link or skip everything),
    # any siblings that were already linked may be ready to sync.
    pa.provider_connection.sync_later
    redirect_to provider_connection_path(pa.provider_connection),
                notice: t("provider.connections.account_skipped")
  end

  private

    def set_connection
      @connection = Current.family.provider_connections.find(params[:id])
    end

    def find_provider_account_for_family(pa_id)
      Provider::Account
        .joins(:provider_connection)
        .where(provider_connections: { family_id: Current.family.id })
        .find_by(id: pa_id)
    end
end
