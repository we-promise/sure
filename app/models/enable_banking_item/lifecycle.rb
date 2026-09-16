require "securerandom"

# A current consent attempt, not a historical claim journal. The committed
# claiming marker makes an uncertain single-use exchange require new consent.
class EnableBankingItem::Lifecycle
  Fence = Provider::AccountData::LegacyWriterFence
  Access = EnableBankingItem::LegacyAccess
  KEY = "enable_banking_consent_attempt".freeze
  FORMAT = "enable-banking-consent/v1".freeze
  PURPOSE = "enable-banking-consent-state/v1".freeze
  FIELDS = %w[actor_id context family_id format inventory issued_at item_id nonce operation state sync_id].freeze
  STATES = %w[starting authorized claiming uncertain completed disconnect_pending revoking revoked].freeze
  SETTINGS = %w[name application_id client_certificate country_code sync_start_date].freeze
  LINK_COLUMNS = %i[id account_id provider_id family_id provider_key external_account_id lock_version].freeze
  MAX_BYTES = 16 * 1024 * 1024

  def self.attempt(item)
    data = item.raw_institution_payload
    return nil if data.nil?
    refuse! unless data.is_a?(Hash) && data.to_json.bytesize <= MAX_BYTES
    return nil unless data.key?(KEY)
    value = data[KEY]
    refuse! unless value.is_a?(Hash) && value.keys.all? { |key| key.is_a?(String) } && value.keys.sort == FIELDS && value.values.all? { |field| field.is_a?(String) } &&
      value["format"] == FORMAT && STATES.include?(value["state"]) && %w[authorize revoke disconnect].include?(value["operation"]) && value["item_id"] == item.id &&
      value["family_id"] == item.family_id && value["nonce"].match?(Fence::UUID) && value["actor_id"].match?(Fence::UUID)
    completed = value["operation"] == "authorize" && value["state"] == "completed"
    valid_sync = completed ? value["sync_id"].match?(Fence::UUID) && value["inventory"].present? : value["sync_id"].empty? && value["inventory"].empty?
    refuse! unless valid_sync
    Time.iso8601(value.fetch("issued_at"))
    value
  rescue ArgumentError
    refuse!
  end

  def self.assert_copyable!(item)
    return true unless item.is_a?(EnableBankingItem)
    receipt = attempt(item)
    refuse! if item.authorization_id.present? || (receipt && !%w[completed revoked].include?(receipt["state"]))
    true
  end

  def self.from_state(state, actor:, item: nil)
    refuse! unless state.is_a?(String) && state.bytesize <= 8192 && actor.is_a?(User)
    claims = verifier.verified(state, purpose: PURPOSE)
    refuse! unless claims.is_a?(Hash) && claims.keys.sort == %w[actor_id family_id item_id nonce] &&
      claims.values.all? { |value| value.is_a?(String) } && claims["actor_id"] == actor.id && claims["family_id"] == actor.family_id
    refuse! if item && (item.id != claims["item_id"] || item.family_id != claims["family_id"])
    current = EnableBankingItem.find_by(id: claims["item_id"], family_id: claims["family_id"])
    refuse! unless current
    new(item: current, actor: actor, nonce: claims["nonce"])
  end

  def self.verifier = Rails.application.message_verifier(PURPOSE)
  def self.refuse! = raise(Fence::OwnershipChanged, "Enable Banking consent or ownership changed; begin authorization again")

  def initialize(item:, actor:, nonce: nil)
    unless item.is_a?(EnableBankingItem) && item.persisted? && !item.destroyed?
      raise Fence::InvalidSource, "Expected a persisted Enable Banking connection"
    end
    @item_id, @family_id, @actor_id = item.id.to_s.dup.freeze, item.family_id.to_s.dup.freeze, actor&.id&.dup&.freeze
    @original_context = Access.transport_context(item)
    @nonce = nonce
  end

  def update_settings(attributes)
    operate do |item|
      locked(item) do |current|
        refuse_unresolved_revocation!(current)
        values = attributes.to_h.stringify_keys.slice(*SETTINGS)
        %w[application_id client_certificate].each { |key| values.delete(key) if values[key].blank? }
        # A changed application cannot keep an institution grant authenticated by
        # the former application. Preserve it for recovery, but stop ordinary use.
        credentials_changed = %w[application_id client_certificate country_code].any? { |key| values.key?(key) && values[key] != current[key] }
        values["status"] = "requires_update" if credentials_changed
        current.update(values)
        current
      end
    end
  end

  def duplicate
    operate do |item|
      locked(item) { |current| current.family.enable_banking_items.create!(current.attributes.slice(*SETTINGS)) }
    end
  end

  def banks
    operate do |item|
      current = locked(item) { |fresh| fresh }
      response = provider(current).get_aspsps(country: current.country_code)
      locked(item) { |_fresh| response }
    end
  end

  def begin_authorization!(redirect_url:, aspsp_name: nil, psu_type: nil, language: nil, last_psu_ip: nil)
    operate do |item|
      current = locked(item) { |fresh| fresh }
      name = aspsp_name.presence || current.aspsp_name
      refuse! unless name.is_a?(String) && name.present?
      response = provider(current).get_aspsps(country: current.country_code)
      rows = response[:aspsps] || response["aspsps"]
      refuse! unless rows.is_a?(Array) && rows.size <= 10_000 && rows.all? { |row| row.is_a?(Hash) } && rows.to_json.bytesize <= MAX_BYTES
      data = rows.find { |row| (row[:name] || row["name"]) == name }
      start_admitted(item, aspsp_name: name, redirect_url: redirect_url, psu_type: psu_type.presence || current.psu_type || "personal",
        aspsp_data: data, language: language, last_psu_ip: last_psu_ip)
    end
  end

  def start_authorization(aspsp_name:, redirect_url:, psu_type: "personal", aspsp_data: nil, language: nil, last_psu_ip: nil)
    operate do |item|
      start_admitted(item, aspsp_name: aspsp_name, redirect_url: redirect_url, psu_type: psu_type,
        aspsp_data: aspsp_data, language: language, last_psu_ip: last_psu_ip)
    end
  end

  def complete_authorization(code:, last_psu_ip: nil)
    refuse! unless @nonce.is_a?(String) && code.is_a?(String) && code.present? && code.bytesize <= 8192
    sync = nil
    item = operate do |original|
      current = locked(original) do |fresh|
        receipt = self.class.attempt(fresh)
        if receipt && receipt["state"] == "completed"
          verify_attempt!(fresh, receipt, "completed")
          sync = replay_sync!(fresh, receipt)
          next fresh
        end
        verify_attempt!(fresh, receipt, "authorized")
        receipt = receipt.merge("state" => "claiming")
        fresh.update!(status: "requires_update", raw_institution_payload: document(fresh, receipt))
        @attempt = receipt
        fresh
      end
      next current if sync
      begin
        result = provider(current).create_session(code: code)
        validate_session!(result)
        locked(original) do |fresh|
          refuse! unless self.class.attempt(fresh) == @attempt
          install_accounts!(fresh, result[:accounts] || result["accounts"])
          fresh.assign_attributes(session_id: result[:session_id] || result["session_id"],
            session_expires_at: fresh.send(:parse_session_expiry, result.with_indifferent_access), authorization_id: nil, status: "good")
          fresh.last_psu_ip = last_psu_ip if last_psu_ip.present?
          sync = fresh.syncs.create!
          completed = @attempt.merge("state" => "completed", "context" => Access.transport_context(fresh),
            "sync_id" => sync.id, "inventory" => inventory_fingerprint(fresh))
          fresh.raw_institution_payload = document(fresh, completed)
          fresh.save!
          fresh
        end
      rescue Exception => error # rubocop:disable Lint/RescueException -- retain ambiguity after interruption
        mark_uncertain(original, error)
        raise
      end
    end
    SyncJob.perform_later(sync)
    item
  end

  def authorization_failed!
    operate do |item|
      locked(item) do |fresh|
        receipt = self.class.attempt(fresh)
        verify_attempt!(fresh, receipt, "authorized")
        fresh.update!(status: "requires_update", raw_institution_payload: document(fresh, receipt.merge("state" => "uncertain")))
      end
    end
  end

  def revoke_session
    operate do |item|
      current = locked(item) do |fresh|
        refuse_unresolved_revocation!(fresh)
        next fresh if fresh.session_id.blank?
        @attempt = new_attempt(fresh, "revoking", operation: "revoke")
        fresh.update!(status: "requires_update", raw_institution_payload: document(fresh, @attempt))
        fresh
      end
      next current if current.session_id.blank?
      begin
        provider(current).delete_session(session_id: current.session_id)
        locked(item) do |fresh|
          finish_revocation!(fresh)
        end
      rescue StandardError => error
        mark_uncertain(item, error)
        raise
      end
    end
  end

  def disconnect(schedule: true, dry_run: false)
    scheduled = nil
    result = operate(allow_scheduled: true) do |item|
      detached = []
      current = locked(item) do |fresh|
        receipt = self.class.attempt(fresh)
        if receipt && receipt["operation"] == "disconnect"
          refuse! unless %w[disconnect_pending revoked].include?(receipt["state"]) && receipt["context"] == Access.transport_context(fresh)
          refuse! unless @inventory[:links].empty?
          @attempt = receipt
        else
          refuse_unresolved_revocation!(fresh)
          detached = unlink_admitted!(fresh, dry_run: dry_run)
          next fresh if dry_run
          @attempt = new_attempt(fresh, "disconnect_pending", operation: "disconnect")
          fresh.update!(status: "requires_update", raw_institution_payload: document(fresh, @attempt))
          # This inventory change is our committed local unlink, not adoption of
          # another request's replacement link.
          @inventory = inventory(fresh)
        end
        fresh
      end
      next detached if dry_run
      unless @attempt["state"] == "revoked"
        current = locked(item) do |fresh|
          refuse! unless self.class.attempt(fresh) == @attempt
          @attempt = @attempt.merge("state" => "revoking")
          fresh.update!(raw_institution_payload: document(fresh, @attempt))
          fresh
        end
        begin
          provider(current).delete_session(session_id: current.session_id) if current.session_id.present?
          current = locked(item) { |fresh| finish_revocation!(fresh) }
          @context = Access.transport_context(current)
          @attempt = self.class.attempt(current)
        rescue Exception => error # rubocop:disable Lint/RescueException -- do not replay an uncertain DELETE
          mark_uncertain(item, error)
          raise
        end
      end
      if schedule
        scheduled = locked(item) do |fresh|
          refuse! unless self.class.attempt(fresh) == @attempt && fresh.session_id.nil?
          fresh.update!(scheduled_for_deletion: true) unless fresh.scheduled_for_deletion?
          fresh
        end
      end
      detached
    end
    DestroyJob.perform_later(scheduled) if scheduled
    result
  end

  def unlink_all(dry_run: false)
    operate { |item| locked(item) { |fresh| unlink_admitted!(fresh, dry_run: dry_run) } }
  end

  private
    def operate(allow_scheduled: false)
      @allow_scheduled = allow_scheduled
      Access.assert_transport!
      item = EnableBankingItem.find_by!(id: @item_id, family_id: @family_id)
      Fence.with_exclusive(item) do |current|
        authorize!(current)
        verify_legacy!(current)
        Access.verify_transport!(current, @original_context)
        @context = @original_context
        @inventory = inventory(current)
        yield current
      end
    rescue ActiveRecord::RecordNotFound
      refuse!
    rescue ActiveRecord::LockWaitTimeout
      raise Fence::Busy, "Enable Banking consent management is busy", cause: nil
    end

    def locked(item)
      EnableBankingItem.transaction(requires_new: true) do
        ids = @inventory[:links].map { |row| row[1] }.uniq.sort
        accounts = Account.where(id: ids).order(:id).lock("FOR UPDATE NOWAIT").to_a
        refuse! unless accounts.size == ids.size && accounts.all? { |account| account.family_id == @family_id && !account.pending_deletion? }
        current = EnableBankingItem.where(id: @item_id, family_id: @family_id).lock("FOR UPDATE NOWAIT").first!
        User.where(id: (accounts.map(&:owner_id) + [ @actor_id ]).compact.uniq).order(:id).lock("FOR UPDATE NOWAIT").load
        actor = authorize!(current)
        accounts.each do |account|
          AccountShare.where(account_id: account.id, user_id: actor.id).order(:id).lock("FOR UPDATE NOWAIT").load
          refuse! unless actor.accessible_accounts.exists?(account.id) && %i[owner full_control].include?(account.permission_for(actor))
        end
        current.enable_banking_accounts.select(:id).order(:id).lock("FOR UPDATE NOWAIT").load
        AccountProvider.where(id: @inventory[:links].map(&:first)).order(:id).lock("FOR UPDATE NOWAIT").load
        verify_legacy!(current, lock: true)
        Access.verify_transport!(current, @context)
        refuse! unless inventory(current) == @inventory
        yield current
      end
    end

    def authorize!(item)
      actor = User.find_by(id: @actor_id, family_id: @family_id)
      receipt = self.class.attempt(item)
      replay = @allow_scheduled && receipt && receipt["operation"] == "disconnect" && receipt["state"] == "revoked" &&
        receipt["context"] == Access.transport_context(item) && item.session_id.nil?
      refuse! unless item.id == @item_id && item.family_id == @family_id && (!item.scheduled_for_deletion? || replay) && actor&.active? && actor.admin?
      actor
    end

    def verify_legacy!(item, lock: false)
      scope = ProviderMigrationControl.where(legacy_type: "EnableBankingItem", legacy_id: item.id)
      scope = scope.lock("FOR UPDATE NOWAIT") if lock
      control = scope.first
      refuse! if control && !(control.family_id == @family_id && control.provider_key == "enable_banking" && control.legacy_owned?)
    end

    def inventory(item)
      sources = item.enable_banking_accounts.order(:id).limit(Access::MAX_ACCOUNTS + 1)
        .pluck(:id, :enable_banking_item_id, :uid, :account_id, Arel.sql("xmin::text"), Arel.sql("ctid::text"))
      refuse! if sources.size > Access::MAX_ACCOUNTS
      links = AccountProvider.where(provider_type: "EnableBankingAccount", provider_id: sources.map(&:first)).order(:id)
        .limit(Access::MAX_ACCOUNTS + 1).pluck(*LINK_COLUMNS)
      refuse! if links.size > Access::MAX_ACCOUNTS || links.map { |row| row[2] }.uniq.size != links.size ||
        links.any? { |row| (row[3] && row[3] != @family_id) || (row[4] && row[4] != "enable_banking") }
      { sources: sources, links: links }
    end

    def start_admitted(item, aspsp_name:, redirect_url:, psu_type:, aspsp_data:, language:, last_psu_ip:)
      current = locked(item) do |fresh|
        refuse_unresolved_revocation!(fresh)
        fresh.last_psu_ip = last_psu_ip if last_psu_ip.present?
        @attempt = new_attempt(fresh, "starting")
        fresh.raw_institution_payload = document(fresh, @attempt)
        fresh.save!
        @context = Access.transport_context(fresh)
        fresh
      end
      claims = @attempt.slice("item_id", "family_id", "actor_id", "nonce")
      state = self.class.verifier.generate(claims, purpose: PURPOSE, expires_in: 1.hour)
      data = (aspsp_data || {}).with_indifferent_access
      types = Array(data[:psu_types]).map(&:to_s)
      psu_type = types.first if types.any? && !types.include?(psu_type)
      method = current.send(:select_auth_method, data, psu_type)
      result = provider(current).start_authorization(aspsp_name: aspsp_name, aspsp_country: current.country_code,
        redirect_url: redirect_url, state: state, psu_type: psu_type,
        maximum_consent_validity: data[:maximum_consent_validity] || current.aspsp_maximum_consent_validity,
        language: language, auth_method: method&.dig(:name))
      refuse! unless result.is_a?(Hash) && (result[:authorization_id] || result["authorization_id"]).is_a?(String) &&
        (result[:authorization_id] || result["authorization_id"]).present? && (result[:url] || result["url"]).is_a?(String)
      locked(item) do |fresh|
        refuse! unless self.class.attempt(fresh) == @attempt
        fresh.assign_attributes(authorization_id: result[:authorization_id] || result["authorization_id"], aspsp_name: aspsp_name, psu_type: psu_type)
        if aspsp_data.present?
          fresh.assign_attributes(aspsp_required_psu_headers: data[:required_psu_headers] || [],
            aspsp_maximum_consent_validity: data[:maximum_consent_validity], aspsp_auth_approach: method&.dig(:approach), aspsp_psu_types: types)
        end
        fresh.raw_institution_payload = document(fresh, @attempt.merge("state" => "authorized", "context" => Access.transport_context(fresh)))
        fresh.save!
      end
      result[:url] || result["url"]
    rescue Exception => error # rubocop:disable Lint/RescueException -- retain interrupted current attempts
      mark_uncertain(item, error) if @attempt
      raise
    end

    def verify_attempt!(item, receipt, state)
      refuse! unless receipt && receipt["operation"] == "authorize" && receipt["nonce"] == @nonce && receipt["actor_id"] == @actor_id && receipt["state"] == state &&
        receipt["context"] == Access.transport_context(item) && Time.iso8601(receipt["issued_at"]) > 1.hour.ago
    end

    def new_attempt(item, state, operation: "authorize")
      { "format" => FORMAT, "nonce" => SecureRandom.uuid, "actor_id" => @actor_id, "family_id" => @family_id,
        "item_id" => @item_id, "state" => state, "operation" => operation, "issued_at" => Time.current.utc.iso8601(6),
        "context" => Access.transport_context(item), "sync_id" => "", "inventory" => "" }
    end

    def inventory_fingerprint(item)
      Provider::AccountData::RuntimeInputs.fingerprint(inventory(item), purpose: "enable-banking-consent-inventory/v1")
    end

    def replay_sync!(item, receipt)
      refuse! unless receipt["inventory"] == inventory_fingerprint(item)
      sync = Sync.where(id: receipt["sync_id"], syncable_type: "EnableBankingItem", syncable_id: item.id).lock("FOR UPDATE NOWAIT").first
      refuse! unless sync && sync.pending? && sync.cancel_requested_at.nil? && sync.created_at > Sync::STALE_AFTER.ago &&
        sync.parent_id.nil? && sync.predecessor_id.nil? && sync.window_start_date.nil? && sync.window_end_date.nil?
      sync
    end

    def refuse_unresolved_revocation!(item)
      receipt = self.class.attempt(item)
      refuse! if receipt && %w[revoke disconnect].include?(receipt["operation"]) && receipt["state"] != "revoked"
    end

    def finish_revocation!(fresh)
      refuse! unless self.class.attempt(fresh) == @attempt
      fresh.assign_attributes(session_id: nil, session_expires_at: nil, authorization_id: nil, status: "requires_update")
      fresh.raw_institution_payload = document(fresh, @attempt.merge("state" => "revoked", "context" => Access.transport_context(fresh)))
      fresh.save!
      fresh
    end

    def unlink_admitted!(item, dry_run:)
      links = AccountProvider.where(provider_type: "EnableBankingAccount", provider_id: @inventory[:sources].map(&:first)).order(:id).to_a
      refuse! if links.any?(&:external_account_id?) || Account::SourcePolicy.where(account_provider_id: links.map(&:id)).exists?
      result = links.map { |link| { account_id: link.account_id, provider_link_id: link.id } }
      return result if dry_run
      holdings = Holding.where(account_provider_id: links.map(&:id)).order(:id).lock("FOR UPDATE NOWAIT").to_a
      owners = links.to_h { |link| [ link.id, link.account_id ] }
      refuse! unless holdings.all? { |holding| holding.account_id == owners[holding.account_provider_id] }
      Holding.where(id: holdings.map(&:id)).update_all(account_provider_id: nil)
      links.each(&:destroy!)
      result
    end

    def document(item, receipt)
      self.class.attempt(item)
      result = (item.raw_institution_payload || {}).merge(KEY => receipt)
      refuse! unless result.to_json.bytesize <= MAX_BYTES
      result
    end

    def validate_session!(result)
      refuse! unless result.is_a?(Hash) && result.to_json.bytesize <= MAX_BYTES
      session = result[:session_id] || result["session_id"]
      rows = result[:accounts] || result["accounts"]
      refuse! unless session.is_a?(String) && session.present? && session.bytesize <= 8192 && rows.is_a?(Array) &&
        rows.size <= Access::MAX_ACCOUNTS && rows.all? { |row| row.is_a?(Hash) }
    end

    def install_accounts!(item, rows)
      originals = Access.bounded_sources(item.enable_banking_accounts)
      seen, routes, targets = [], [], []
      assignments = rows.map do |row|
        data = row.with_indifferent_access
        id = (data[:identification_hash].presence || data[:uid].presence)&.to_s
        route = data[:uid]
        refuse! if id.blank? || seen.include?(id) || !route.is_a?(String) || route.blank? || routes.include?(route)
        seen << id
        routes << route
        matches = originals.select { |source| [ source.uid, *Array(source.identification_hashes) ].include?(id) }
        refuse! if matches.size > 1
        source = matches.first || item.enable_banking_accounts.build(uid: id)
        refuse! if source.persisted? && targets.include?(source.id)
        targets << source.id if source.persisted?
        [ source, data ]
      end
      assignments.each { |source, data| source.send(:persist_enable_banking_snapshot!, data) }
    end

    def provider(item)
      Access.assert_transport!
      item.enable_banking_provider || raise(Fence::InvalidSource, "Enable Banking application is not configured")
    end

    def mark_uncertain(item, error)
      locked(item) do |fresh|
        next unless self.class.attempt(fresh) == @attempt
        fresh.update!(status: "requires_update", raw_institution_payload: document(fresh, @attempt.merge("state" => "uncertain")))
      end
      report_failure(error, "consent")
    rescue StandardError
      # The committed starting/claiming marker still refuses replay when another
      # owner or a failed database prevents this best-effort classification.
      nil
    end

    def report_failure(error, action)
      DebugLogEntry.capture(category: "provider_sync_error", level: "warning", source: self.class.name,
        provider_key: "enable_banking", family_id: @family_id, message: "Enable Banking consent requires review",
        metadata: { item_id: @item_id, action: action, error_class: error.class.name })
    rescue StandardError
      nil
    end

    def refuse! = self.class.refuse!
end
