require "securerandom"

# Transitional ownership for legacy deferred work. Native syncs use shared
# continuations; this receipt must be settled and archived before handoff.
class QuestradeAccount::ActivitiesRequest
  Session = QuestradeItem::CredentialSession
  Fence = Provider::AccountData::LegacyWriterFence
  FORMAT = "questrade-activity-request/v1".freeze
  ACTIVE = %w[queued running retry_wait].freeze
  TERMINAL = %w[completed failed cancelled].freeze
  MAX_RETRIES = 6
  RETRY_DELAY = 10.seconds
  RECOVERY_DELAY = 5.minutes
  MAX_BYTES = 32.kilobytes
  CONTEXT_KEYS = %w[source_id item_id family_id remote_id source_currency account_id account_currency accountable_type accountable_id link_id link_revision sync_lineage].sort.freeze
  Ticket = Data.define(:source_id, :request_id, :revision, :document)

  def self.enqueue(source, start_date:, sync: nil)
    Session.with(source.questrade_item, sync: sync) do |session, current_sync|
      context = context_for(source.reload, sync: current_sync)
      session.after_release do
        ticket = nil
        Session.with(source.questrade_item, sync: current_sync, allow_completed: true) do
          with_locked(source) do |fresh|
            refuse! unless context_for(fresh, sync: current_sync) == context
            previous = read(fresh)
            if previous && ACTIVE.include?(previous["state"]) && eligible?(fresh, previous)
              ticket = ticket_for(fresh, previous) if fresh.activities_fetch_due_at <= Time.current
              next
            end
            refuse!("Unowned historical Questrade job requires disposition") if !previous && fresh.activities_fetch_pending?
            date = start_date.to_date
            raise ArgumentError, "Activity window is invalid" if date > Date.current
            document = { "format" => FORMAT, "id" => SecureRandom.uuid, "origin" => "admitted",
              "context" => context, "start_date" => date.iso8601, "end_date" => Date.current.iso8601,
              "state" => "queued", "retry_count" => 0, "attempt" => 0,
              "replaces_id" => previous&.fetch("id"), "disposition" => nil }
            ticket = save!(fresh, document, due_at: Time.current)
          end
        end
        dispatch(ticket) if ticket
      end
    end
  end

  # A queue acknowledgement is not a commit. Failed/lost dispatch leaves this
  # same due receipt discoverable; duplicate jobs are rejected by its revision.
  def self.dispatch(ticket)
    QuestradeActivitiesFetchJob.set(wait_until: Time.iso8601(ticket.document.fetch("resume_at"))).perform_later(
      QuestradeAccount.find(ticket.source_id), request_id: ticket.request_id, revision: ticket.revision)
  end

  def self.recover_due!(limit: 100)
    raise ArgumentError, "Recovery limit is invalid" unless limit.is_a?(Integer) && (1..500).cover?(limit)
    QuestradeAccount.where(activities_fetch_pending: true).where("activities_fetch_due_at <= ?", Time.current)
      .order(:activities_fetch_due_at, :id).limit(limit).each do |source|
      ticket = nil
      Session.with(source.questrade_item, allow_unusable: true) do
        with_locked(source) do |fresh|
          document = read(fresh)
          next unless document && ACTIVE.include?(document["state"]) && fresh.activities_fetch_due_at <= Time.current
          if eligible?(fresh, document)
            # Advance the dispatch deadline even if the queue raises. The
            # document's request and current attempt remain unchanged.
            ticket = ticket_for(fresh, document)
            fresh.update!(activities_fetch_due_at: Time.current + RECOVERY_DELAY)
          else
            finish!(fresh, document, "cancelled", "original_context_unavailable")
          end
        end
      end
      dispatch(ticket) if ticket
    rescue *Session::DENIAL_ERRORS => error
      capture(source, error)
    rescue StandardError => error
      capture(source, error)
    end
  end

  # Acquire the session without binding the old parent first: a cancelled parent
  # can terminalize its own receipt, but can never authorize publication.
  def self.with_claim(source, request_id:, revision:)
    refuse!("Activity delivery has no durable request identity") unless request_id.to_s.match?(Fence::UUID) && revision.is_a?(Integer) && revision.positive?
    document = read(source.reload)
    return unless document && document["id"] == request_id && source.activities_fetch_revision == revision
    refuse! unless source.questrade_item_id == document.dig("context", "item_id")
    item = QuestradeItem.find_by(id: document.dig("context", "item_id"), family_id: document.dig("context", "family_id"))
    refuse! unless item
    Session.with(item, allow_unusable: true) do |session|
      ticket = nil
      with_locked(source) do |fresh|
        current = read(fresh)
        next unless current && current["id"] == request_id && fresh.activities_fetch_revision == revision && ACTIVE.include?(current["state"])
        next if Time.iso8601(current.fetch("resume_at")) > Time.current
        unless eligible?(fresh, current)
          finish!(fresh, current, "cancelled", "original_context_unavailable")
          next
        end
        ticket = save!(fresh, current.merge("state" => "running", "attempt" => current.fetch("attempt") + 1), due_at: Time.current + RECOVERY_DELAY)
      end
      next unless ticket
      sync_id = ticket.document.dig("context", "sync_lineage", 0, "id")
      sync = item.syncs.find(sync_id) if sync_id
      session.bind_sync!(sync, allow_completed: true)
      yield session, new(ticket)
    end
  end

  def initialize(ticket)
    @ticket = ticket
  end

  def document
    @ticket.document
  end

  def verify!(source, _financial = nil)
    current = self.class.read(source)
    unless source.id == @ticket.source_id && source.activities_fetch_revision == @ticket.revision && current == document &&
        current["state"] == "running" && self.class.eligible?(source, current)
      self.class.refuse!("Questrade activity publication lost its original request")
    end
    true
  end

  def complete!(source)
    self.class.with_locked(source) do |fresh|
      verify!(fresh)
      # Delayed work proves its fixed window, not the day its worker finally
      # finishes. A wall-clock marker can skip history beyond the 30-day overlap.
      fresh.last_activities_sync = Date.iso8601(document.fetch("end_date")).end_of_day
      self.class.finish!(fresh, document, "completed", nil)
    end
  end

  # Completion is already committed and its original credential session released.
  # Recheck the exact completed receipt before choosing its original UI target;
  # broadcasting itself happens outside row locks and cannot fail the request.
  def self.broadcast_completed(ticket)
    value = ticket.document
    return unless value["state"] == "completed"
    context = value.fetch("context")
    item = QuestradeItem.find_by(id: context.fetch("item_id"), family_id: context.fetch("family_id"))
    source = item&.questrade_accounts&.find_by(id: ticket.source_id)
    return unless source

    recipient = nil
    QuestradeItem::LegacyAccess.with_snapshot(source) do |fresh, financial|
      if financial && fresh.activities_fetch_revision == ticket.revision && read(fresh) == value && eligible?(fresh, value)
        recipient = financial
      end
    end
    recipient&.broadcast_sync_complete
  rescue StandardError => error
    begin
      DebugLogEntry.capture(category: "background_jobs", level: "warning", message: "Questrade activity completion notification failed",
        source: name, provider_key: "questrade", family_id: ticket.document.dig("context", "family_id"),
        metadata: { questrade_account_id: ticket.source_id, request_id: ticket.request_id, error_class: error.class.name })
    rescue StandardError
      # A diagnostic failure must not replace an already committed completion.
      nil
    end
  end

  def defer!(source)
    self.class.with_locked(source) do |fresh|
      verify!(fresh)
      self.class.save!(fresh, document.merge("state" => "retry_wait", "retry_count" => document.fetch("retry_count") + 1),
        due_at: Time.current + RETRY_DELAY)
    end
  end

  def fail!(source)
    self.class.with_locked(source) do |fresh|
      verify!(fresh)
      self.class.finish!(fresh, document, "failed", "fetch_or_processing_failed")
    end
  end

  # Explicit nonfinancial disposition of pre-upgrade flags. Unknown context is
  # retained as unknown; this never records a successful fetch or invents a Sync.
  def self.dispose_unowned!(source, family:)
    refuse! unless source.questrade_item.family_id == family.id
    Session.with(source.questrade_item, allow_unusable: true) do
      with_locked(source) do |fresh|
        refuse! unless read(fresh).nil? && fresh.activities_fetch_pending?
        document = { "format" => FORMAT, "id" => SecureRandom.uuid, "origin" => "legacy_unowned",
          "context" => { "source_id" => fresh.id, "item_id" => fresh.questrade_item_id, "family_id" => family.id },
          "start_date" => nil, "end_date" => nil, "state" => "cancelled", "retry_count" => 0, "attempt" => 0,
          "replaces_id" => nil, "disposition" => "historical_owner_unknown" }
        save!(fresh, document, due_at: nil)
      end
    end
  end

  def self.assert_settled_for!(item)
    return unless item.is_a?(QuestradeItem)
    Fence.assert_exclusive!(item)
    item.questrade_accounts.find_each do |source|
      document = read(source)
      refuse!("Settle Questrade activity work before quiescing") if source.activities_fetch_pending? ||
        (document && !TERMINAL.include?(document["state"]))
    end
  end

  def self.read(source)
    value = source.activities_fetch_request
    if value.nil?
      refuse! unless source.activities_fetch_revision.zero? && source.activities_fetch_due_at.nil?
      return
    end
    unless value.is_a?(Hash) && JSON.generate(value).bytesize <= MAX_BYTES && value["format"] == FORMAT &&
        value["id"].is_a?(String) && value["id"].match?(Fence::UUID) && source.activities_fetch_revision.positive? &&
        (ACTIVE + TERMINAL).include?(value["state"]) && %w[admitted legacy_unowned].include?(value["origin"]) &&
        value["context"].is_a?(Hash) && value.dig("context", "source_id") == source.id &&
        value["attempt"].is_a?(Integer) && value["attempt"] >= 0 && value["retry_count"].is_a?(Integer) &&
        (0..MAX_RETRIES).cover?(value["retry_count"]) &&
        source.activities_fetch_pending? == ACTIVE.include?(value["state"])
      refuse!("Malformed Questrade activity receipt")
    end
    if value["origin"] == "admitted"
      first, last = Date.iso8601(value.fetch("start_date")), Date.iso8601(value.fetch("end_date"))
      chain = value.dig("context", "sync_lineage")
      refuse! unless first <= last && value.fetch("context").keys.sort == CONTEXT_KEYS && chain.is_a?(Array) && chain.size <= 64 &&
        chain.all? { |row| row.is_a?(Hash) && row.keys.sort == %w[id parent_id syncable_id syncable_type] }
    else
      refuse! unless value["state"] == "cancelled" && value["start_date"].nil? && value["end_date"].nil?
    end
    if ACTIVE.include?(value["state"])
      Time.iso8601(value.fetch("resume_at"))
      refuse! if source.activities_fetch_due_at.nil?
    else
      refuse! unless value["resume_at"].nil? && source.activities_fetch_due_at.nil?
    end
    value.deep_dup
  rescue KeyError, TypeError, ArgumentError
    refuse!("Malformed Questrade activity receipt")
  end

  def self.with_locked(source)
    Session.with(source.questrade_item, allow_unusable: true) do
      QuestradeItem::LegacyAccess.with_snapshot(source) do |fresh, _financial|
        yield fresh
      end
    end
  rescue ActiveRecord::RecordNotFound
    refuse!
  rescue ActiveRecord::LockWaitTimeout
    raise Fence::Busy, "Questrade activity request is busy", cause: nil
  end

  def self.context_for(source, sync: nil)
    link = AccountProvider.find_by(provider_type: "QuestradeAccount", provider_id: source.id)
    account = link && Account.find_by(id: link.account_id, family_id: source.questrade_item.family_id)
    refuse! unless account && !account.pending_deletion?
    { "source_id" => source.id, "item_id" => source.questrade_item_id, "family_id" => account.family_id,
      "remote_id" => source.questrade_account_id, "source_currency" => source.currency,
      "account_id" => account.id, "account_currency" => account.currency, "accountable_type" => account.accountable_type,
      "accountable_id" => account.accountable_id, "link_id" => link.id, "link_revision" => link.lock_version,
      "sync_lineage" => lineage(source.questrade_item, sync) }
  end

  def self.lineage(item, sync)
    rows = []
    while sync
      refuse! unless rows.size < 64 && rows.none? { |row| row["id"] == sync.id } &&
        ((sync.syncable_type == "QuestradeItem" && sync.syncable_id == item.id) ||
          (sync.syncable_type == "Family" && sync.syncable_id == item.family_id))
      refuse! unless sync.cancel_requested_at.nil? && (sync.in_progress? || sync.completed?)
      rows << sync.attributes.slice("id", "syncable_type", "syncable_id", "parent_id")
      sync = sync.parent_id ? Sync.find(sync.parent_id) : nil
    end
    rows
  end

  def self.eligible?(source, document)
    return false unless document["origin"] == "admitted"
    original = document.fetch("context")
    if ApplicationRecord.connection.open_transactions.positive?
      Sync.where(id: original.fetch("sync_lineage").map { |row| row.fetch("id") }).order(:id).lock("FOR UPDATE NOWAIT").load
    end
    sync_id = original.fetch("sync_lineage").first&.fetch("id")
    sync = source.questrade_item.syncs.find(sync_id) if sync_id
    context_for(source, sync: sync) == original
  rescue Fence::OwnershipChanged, ActiveRecord::RecordNotFound
    false
  end

  def self.save!(source, document, due_at:)
    value = document.merge("resume_at" => due_at&.utc&.iso8601(6))
    source.update!(activities_fetch_request: value, activities_fetch_revision: source.activities_fetch_revision + 1,
      activities_fetch_pending: ACTIVE.include?(value["state"]), activities_fetch_due_at: due_at)
    ticket_for(source, value)
  end

  def self.finish!(source, document, state, disposition)
    save!(source, document.merge("state" => state, "disposition" => disposition), due_at: nil)
  end

  def self.ticket_for(source, document)
    Ticket.new(source_id: source.id, request_id: document.fetch("id"), revision: source.activities_fetch_revision,
      document: Provider::AccountData::MigrationManifest.copy_value(document))
  end

  def self.refuse!(message = "Questrade activity request ownership changed")
    raise Fence::OwnershipChanged, message, cause: nil
  end

  def self.capture(source, error)
    DebugLogEntry.capture(category: "background_jobs", level: "warning", message: "Questrade activity recovery requires retry or review",
      source: name, provider_key: "questrade", family_id: source.questrade_item.family_id,
      metadata: { questrade_account_id: source.id, error_class: error.class.name })
  end
end
