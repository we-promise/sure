require "digest"

# Connect and reconnect share a durable single-use claim. A queue delivery is
# only a reference to previously authorized input, never a fresh token exchange.
class SimplefinItem::ConnectionUpdate
  Fence = Provider::AccountData::LegacyWriterFence
  Claim = ProviderCredentialClaim
  MAX_URL_BYTES = 16.kilobytes
  RECOVERY_PAGE_SIZE = 20
  RecoveryRequest = Data.define(:id, :created_at, :state, :can_retry, :can_cancel)
  RecoveryPage = Data.define(:requests, :next_cursor)
  class Unauthorized < StandardError; end

  class ReauthorizationRequired < Provider::Simplefin::SimplefinError
    def initialize
      super("The previous SimpleFIN claim needs a new setup token", :claim_uncertain)
    end
  end

  class << self
    def prepare(item, setup_token:)
      original_family_id = item.family_id
      token, fingerprint = normalize_token(setup_token)
      with_item(item) do |current|
        Claim.with_request_lock(provider_key: "simplefin", request_fingerprint: fingerprint) do
          current.with_lock do
            validate_item!(current, family_id: original_family_id)
            existing = Claim.find_by(provider_key: "simplefin", request_fingerprint: fingerprint)
            if existing
              verify_owner!(existing, family_id: current.family_id, operation: "reconnect", item_id: current.id)
              raise ReauthorizationRequired if %w[uncertain cancelled].include?(existing.state)
              next existing
            end
            Claim.create!(family_id: current.family_id, provider_key: "simplefin", operation: "reconnect",
              target_type: "SimplefinItem", target_id: current.id, request_fingerprint: fingerprint,
              request: { "setup_token" => token, "item_name" => nil },
              expected: expected(current), response: {}, state: "prepared")
          end
        end
      end
    end

    def prepare_new(family, setup_token:, item_name: nil)
      token, fingerprint = normalize_token(setup_token)
      existing = Claim.select(:id, :family_id, :operation, :target_type, :target_id, :provider_key)
        .find_by(provider_key: "simplefin", request_fingerprint: fingerprint)
      verify_owner!(existing, family_id: family.id, operation: "connect", item_id: existing.target_id) if existing
      target_id = existing&.target_id || SecureRandom.uuid

      Claim.with_target_lock(target_type: "SimplefinItem", target_id: target_id) do
        Claim.with_request_lock(provider_key: "simplefin", request_fingerprint: fingerprint) do
          Claim.transaction do
            Family.lock("FOR KEY SHARE").find(family.id)
            previous = Claim.find_by(provider_key: "simplefin", request_fingerprint: fingerprint)
            if previous
              verify_owner!(previous, family_id: family.id, operation: "connect", item_id: target_id)
              raise ReauthorizationRequired if %w[uncertain cancelled].include?(previous.state)
              next previous
            end
            raise Fence::OwnershipChanged, "SimpleFIN connection identity is already in use" if SimplefinItem.exists?(target_id)
            Claim.create!(family_id: family.id, provider_key: "simplefin", operation: "connect",
              target_type: "SimplefinItem", target_id: target_id, request_fingerprint: fingerprint,
              request: { "setup_token" => token, "item_name" => item_name.presence || "SimpleFin Connection" },
              expected: { "family_id" => family.id, "item_id" => target_id, "credential_revision" => nil, "writer_epoch" => 0 },
              response: {}, state: "prepared")
          end
        end
      end
    end

    def perform(claim_id:, family_id:)
      header = Claim.select(:id, :family_id, :provider_key, :operation, :target_type, :target_id, :request_fingerprint)
        .find_by!(id: claim_id, family_id: family_id)
      verify_owner!(header, family_id: family_id, operation: header.operation, item_id: header.target_id)
      item = SimplefinItem.select(:id, :family_id).find_by(id: header.target_id)
      if item
        raise Fence::OwnershipChanged, "SimpleFIN claim target changed family" unless item.family_id == family_id
        with_item(item) { |current| execute(header, current) }
      else
        raise Fence::OwnershipChanged, "SimpleFIN reconnect target is missing" unless header.operation == "connect"
        Claim.with_target_lock(target_type: "SimplefinItem", target_id: header.target_id) { execute(header, nil) }
      end
      dispatch(header)
    end

    # Public credential consumers take migration admission before the credential
    # session lock. Reentry is allowed on the same connection; new locks never
    # begin inside a row transaction.
    def with_item(item)
      original_family_id = item.family_id
      Fence.with_item(item, operation: :credentials) do |admitted|
        Claim.with_target_lock(target_type: "SimplefinItem", target_id: admitted.id) do
          Fence.with_item(admitted, operation: :credentials) do |current|
            current.reload
            validate_item!(current, family_id: original_family_id)
            yield current
          end
        end
      end
    rescue Claim::Busy
      raise Fence::Busy, "SimpleFIN credentials are being changed", cause: nil
    rescue ActiveRecord::RecordNotFound
      raise Fence::OwnershipChanged, "SimpleFIN credential target is missing or changed", cause: nil
    end

    def with_locked_item(item)
      original_family_id = item.family_id
      with_item(item) do |current|
        current.with_lock do
          validate_item!(current, family_id: original_family_id)
          yield current
        end
      end
    end

    # Web requests enqueue a previously captured intent; they never exchange a
    # token or reconstruct the request using today's credentials.
    def retry_later(item, claim_id:, actor:)
      family_id = item.family_id
      authorize_actor!(actor, family_id: family_id)
      header = claim_scope(item).select(:id, :request_fingerprint).find(claim_id)
      claim = with_item(item) do |current|
        Claim.with_request_lock(provider_key: "simplefin", request_fingerprint: header.request_fingerprint) do
          current.with_lock do
            authorize_actor!(actor, family_id: family_id, lock: true)
            validate_item!(current, family_id: family_id)
            captured = claim_scope(current).lock.find(header.id)
            case captured.state
            when "prepared", "claimed"
              verify_baseline!(captured, current)
            when "installed"
              sync = installed_sync!(captured, current, lock: true)
              raise Fence::OwnershipChanged, "SimpleFIN original Sync is not awaiting delivery" unless retryable_sync?(sync)
            else
              raise Fence::OwnershipChanged, "SimpleFIN connection update cannot be retried"
            end
            captured
          end
        end
      end
      # A fast worker must be able to acquire the target as soon as it receives
      # the job. Execution revalidates the captured baseline after admission.
      SimplefinConnectionUpdateJob.perform_later(family_id: family_id, claim_id: claim.id)
      claim
    rescue ActiveRecord::LockWaitTimeout
      raise Fence::Busy, "SimpleFIN connection update is being changed", cause: nil
    end

    # Cancellation changes only journal state. Exclusive migration admission also
    # permits resolving requests stranded by an older quiescing/native deployment;
    # it cannot authorize any legacy credential or financial write.
    def cancel(item, claim_id:, actor:)
      family_id = item.family_id
      authorize_actor!(actor, family_id: family_id)
      header = claim_scope(item).select(:id, :request_fingerprint).find(claim_id)
      Fence.with_exclusive(item) do |current|
        Claim.with_target_lock(target_type: "SimplefinItem", target_id: current.id) do
          Claim.with_request_lock(provider_key: "simplefin", request_fingerprint: header.request_fingerprint) do
            current.with_lock do
              authorize_actor!(actor, family_id: family_id, lock: true)
              raise Fence::OwnershipChanged, "SimpleFIN cancellation target changed family" unless current.family_id == family_id
              claim = claim_scope(current).lock.find(header.id)
              next claim if claim.state == "cancelled"
              unless %w[prepared claiming claimed uncertain].include?(claim.state)
                raise Fence::OwnershipChanged, "An installed SimpleFIN connection update cannot be cancelled"
              end
              claim.update!(state: "cancelled", cancelled_at: Time.current, cancelled_by_id: actor.id,
                cancelled_from_state: claim.state, cancellation_reason: "user_cancelled")
              claim
            end
          end
        end
      end
    rescue Claim::Busy, ActiveRecord::LockWaitTimeout
      raise Fence::Busy, "SimpleFIN connection update is still running", cause: nil
    end

    # A read-only, bounded view. Only these value objects may reach a template;
    # encrypted request/response documents stay within the command boundary.
    def recovery_requests(item, actor:, before: nil)
      family_id = item.family_id
      authorize_actor!(actor, family_id: family_id)
      current = SimplefinItem.find_by!(id: item.id, family_id: family_id)
      scope = claim_scope(current)
      pending_syncs = current.syncs.pending.where(cancel_requested_at: nil).select(:id)
      visible = scope.where(state: %w[prepared claiming claimed uncertain])
        .or(scope.where(state: "installed", sync_id: pending_syncs))
      if before.present?
        boundary = scope.select(:id, :created_at).find(before)
        visible = visible.where("created_at < :at OR (created_at = :at AND id < :id)", at: boundary.created_at, id: boundary.id)
      end
      rows = visible.order(created_at: :desc, id: :desc).limit(RECOVERY_PAGE_SIZE + 1).to_a
      source_valid = begin
        validate_item!(current, family_id: family_id)
        true
      rescue Fence::OwnershipChanged
        false
      end
      baseline = expected(current) if source_valid
      syncs = current.syncs.where(id: rows.first(RECOVERY_PAGE_SIZE).filter_map(&:sync_id)).index_by(&:id)
      requests = rows.first(RECOVERY_PAGE_SIZE).map do |claim|
        can_retry = source_valid && case claim.state
        when "prepared", "claimed" then claim.operation == "reconnect" && claim.expected == baseline
        when "installed"
          current.credential_revision == claim.installed_revision && current.access_url == claim.response["access_url"] &&
            baseline.fetch("writer_epoch") == claim.expected["writer_epoch"] && retryable_sync?(syncs[claim.sync_id])
        else false
        end
        RecoveryRequest.new(id: claim.id, created_at: claim.created_at, state: claim.state,
          can_retry: !!can_retry, can_cancel: %w[prepared claiming claimed uncertain].include?(claim.state))
      end
      RecoveryPage.new(requests: requests, next_cursor: rows.size > RECOVERY_PAGE_SIZE ? requests.last.id : nil)
    end

    private
      def claim_scope(item)
        Claim.where(family_id: item.family_id, provider_key: "simplefin", target_type: "SimplefinItem", target_id: item.id)
      end

      def authorize_actor!(actor, family_id:, lock: false)
        unless actor.is_a?(User) && actor.persisted?
          raise Unauthorized, "A family administrator is required"
        end
        users = User.where(id: actor.id, family_id: family_id).select(:id, :family_id, :role, :active)
        users = users.lock("FOR SHARE NOWAIT") if lock
        current = users.first
        raise Unauthorized, "A family administrator is required" unless current&.active? && current.admin?
        current
      end

      def retryable_sync?(sync)
        sync && sync.pending? && !sync.cancel_requested_at? && sync.created_at > Sync::STALE_AFTER.ago
      end

      def installed_sync!(claim, item, lock: false)
        unless claim.state == "installed" && item.credential_revision == claim.installed_revision &&
            item.access_url == claim.response.fetch("access_url") && writer_epoch(item) == claim.expected.fetch("writer_epoch")
          raise Fence::OwnershipChanged, "SimpleFIN installed credentials changed before sync dispatch"
        end
        syncs = item.syncs
        syncs = syncs.lock if lock
        sync = syncs.find_by(id: claim.sync_id)
        raise Fence::OwnershipChanged, "SimpleFIN claim lost its original Sync" unless sync
        sync
      end

      def execute(header, item)
        Claim.with_request_lock(provider_key: "simplefin", request_fingerprint: header.request_fingerprint) do
          claim = Claim.find_by!(id: header.id, family_id: header.family_id)
          case claim.state
          when "prepared"
            begin_claim!(claim, item)
            begin
              provider = item ? item.simplefin_provider : Provider::Simplefin.new
              access_url = validate_access_url!(provider.claim_access_url(claim.request.fetch("setup_token")))
              # Commit the remote result independently of target installation.
              # A later target/SQL failure must not discard this usable response.
              claim.with_lock { claim.update!(state: "claimed", response: { "access_url" => access_url }) }
            rescue StandardError
              mark_uncertain(claim)
              raise
            end
          when "claiming"
            claim.with_lock { claim.update!(state: "uncertain") }
            raise ReauthorizationRequired
          when "uncertain"
            raise ReauthorizationRequired
          when "cancelled"
            raise Fence::OwnershipChanged, "SimpleFIN connection update was cancelled"
          when "claimed", "installed"
            # The stored result is the only permitted source on replay.
          else
            raise Fence::OwnershipChanged, "SimpleFIN claim state is invalid"
          end
          install!(claim, item) unless claim.state == "installed"
        end
      rescue Fence::Busy, Fence::OwnershipChanged, Fence::InvalidSource, Claim::Busy
        raise
      rescue StandardError => error
        DebugLogEntry.capture(category: "provider_sync_error", level: "error",
          message: "SimpleFIN credential claim failed", source: name, provider_key: "simplefin",
          family: Family.find_by(id: header.family_id),
          metadata: { item_id: header.target_id, claim_id: header.id, error_class: error.class.name })
        raise
      end

      def begin_claim!(claim, item)
        Claim.transaction do
          item&.lock!
          claim.lock!
          verify_baseline!(claim, item)
          claim.update!(state: "claiming")
        end
      rescue ActiveRecord::RecordNotFound
        raise Fence::OwnershipChanged, "SimpleFIN claim target is missing or changed", cause: nil
      end

      def install!(claim, item)
        Claim.transaction do
          item&.lock!
          claim.lock!
          verify_baseline!(claim, item)
          access_url = validate_access_url!(claim.response.fetch("access_url"))
          if claim.operation == "connect"
            Family.lock("FOR KEY SHARE").find(claim.family_id)
            item = SimplefinItem.create!(id: claim.target_id, family_id: claim.family_id,
              name: claim.request.fetch("item_name"), access_url: access_url)
          else
            item.update!(access_url: access_url, status: "good")
          end
          item.reload # credential_revision is assigned by the database trigger.
          sync = item.syncs.create!
          claim.update!(state: "installed", installed_revision: item.credential_revision, sync_id: sync.id)
        end
      rescue ActiveRecord::RecordNotFound
        raise Fence::OwnershipChanged, "SimpleFIN claim target is missing or changed", cause: nil
      end

      def dispatch(header)
        item = SimplefinItem.where(family_id: header.family_id).find(header.target_id)
        sync = nil
        current = with_item(item) do |current|
          current.with_lock do
            claim = Claim.lock.find_by!(id: header.id, family_id: header.family_id)
            sync = installed_sync!(claim, current, lock: true)
          end
          current
        end
        # Release credential admission before delivery so an immediate worker
        # can enter the same target. A replay retains this original pending Sync.
        SyncJob.perform_later(sync) if sync.pending? && !sync.cancel_requested_at?
        current
      rescue Fence::Busy, Fence::OwnershipChanged, Fence::InvalidSource, Claim::Busy
        raise
      rescue ActiveRecord::RecordNotFound
        raise Fence::OwnershipChanged, "SimpleFIN installed target is missing or changed", cause: nil
      rescue StandardError => error
        DebugLogEntry.capture(category: "provider_sync_error", level: "error",
          message: "SimpleFIN credential sync dispatch failed", source: name, provider_key: "simplefin",
          family: Family.find_by(id: header.family_id),
          metadata: { item_id: header.target_id, claim_id: header.id, error_class: error.class.name })
        raise
      end

      def verify_baseline!(claim, item)
        Family.find(claim.family_id)
        if claim.operation == "connect"
          if item || SimplefinItem.exists?(claim.target_id) ||
              ProviderMigrationControl.exists?(legacy_type: "SimplefinItem", legacy_id: claim.target_id)
            raise Fence::OwnershipChanged, "SimpleFIN connect target is no longer unused"
          end
        else
          raise Fence::OwnershipChanged, "SimpleFIN reconnect target is missing" unless item
          validate_item!(item, family_id: claim.family_id)
          unless expected(item) == claim.expected
            raise Fence::OwnershipChanged, "SimpleFIN credentials changed since this request was prepared"
          end
        end
      end

      def expected(item)
        { "family_id" => item.family_id, "item_id" => item.id,
          "credential_revision" => item.credential_revision, "writer_epoch" => writer_epoch(item) }
      end

      def writer_epoch(item)
        control = ProviderMigrationControl.find_by(legacy_type: "SimplefinItem", legacy_id: item.id)
        if control && (!control.legacy_owned? || control.family_id != item.family_id || control.provider_key != "simplefin")
          raise Fence::OwnershipChanged, "SimpleFIN credential writer changed ownership"
        end
        control&.writer_epoch || 0
      end

      def validate_item!(item, family_id:)
        unless item.family_id == family_id && !item.scheduled_for_deletion?
          raise Fence::OwnershipChanged, "SimpleFIN credential target is no longer eligible"
        end
        writer_epoch(item)
      end

      def verify_owner!(claim, family_id:, operation:, item_id:)
        unless claim.family_id == family_id && claim.provider_key == "simplefin" && claim.operation == operation &&
            %w[connect reconnect].include?(operation) && claim.target_type == "SimplefinItem" && claim.target_id == item_id
          raise Fence::OwnershipChanged, "SimpleFIN token already belongs to another connection request"
        end
      end

      def normalize_token(value)
        unless value.is_a?(String) && value.present? && value.bytesize <= 24.kilobytes
          raise ArgumentError, "Invalid SimpleFIN setup token"
        end
        decoded = Base64.strict_decode64(value.strip)
        uri = URI.parse(decoded)
        unless decoded.bytesize <= MAX_URL_BYTES && uri.is_a?(URI::HTTPS) && uri.host.present? && !uri.userinfo && !uri.fragment
          raise ArgumentError, "Invalid SimpleFIN setup token"
        end
        [ Base64.strict_encode64(decoded), Digest::SHA256.hexdigest("simplefin:claim:v1\0#{decoded}") ]
      rescue URI::InvalidURIError, ArgumentError
        raise ArgumentError, "Invalid SimpleFIN setup token", cause: nil
      end

      def validate_access_url!(value)
        uri = URI.parse(value) if value.is_a?(String) && value.present? && value.bytesize <= MAX_URL_BYTES
        unless uri.is_a?(URI::HTTPS) && uri.host.present? && !uri.fragment
          raise Provider::Simplefin::SimplefinError.new("SimpleFIN returned an invalid access URL", :invalid_response)
        end
        value
      rescue URI::InvalidURIError
        raise Provider::Simplefin::SimplefinError.new("SimpleFIN returned an invalid access URL", :invalid_response), cause: nil
      end

      def mark_uncertain(claim)
        claim.with_lock { claim.update!(state: "uncertain") if claim.state == "claiming" }
      rescue StandardError => error
        # If persistence is unavailable, the already committed claiming state
        # itself blocks replay when the process resumes.
        Rails.logger.error("SimpleFIN claim recovery state could not be saved (#{error.class})")
      end
  end
end
