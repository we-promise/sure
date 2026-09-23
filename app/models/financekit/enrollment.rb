class Financekit::Enrollment
  Result = Data.define(:item, :created)

  def self.validate_consent!(consent)
    Financekit::Payload.shape!(consent,
      %w[version granted_at selected_source_account_ids upload_authorized family_visibility_acknowledged remote_processing_acknowledged])
    Financekit.require!(consent["version"] == 1 && consent["upload_authorized"] == true &&
      consent["family_visibility_acknowledged"] == true && consent["remote_processing_acknowledged"] == true,
      "consent_required")
    Financekit::Payload.timestamp!(consent["granted_at"])
    ids = consent["selected_source_account_ids"]
    Financekit.require!(ids.is_a?(Array) && ids.size.between?(1, Financekit::MAX_ACCOUNTS) &&
      ids.map { |id| id.to_s.downcase }.uniq.size == ids.size)
    ids.each { |id| Financekit::Payload.uuid!(id) }
  end

  def self.create!(user, input)
    Financekit::Payload.shape!(input, %w[enrollment_id consent protocol_version], %w[replaces_connection_id])
    Financekit.require!(input["protocol_version"] == Financekit::VERSION, "unsupported_protocol", 400)
    Financekit::Payload.uuid!(input["enrollment_id"])
    validate_consent!(input["consent"])
    digest = Digest::SHA256.hexdigest(canonical(input))

    result = nil
    user.family.with_lock do
      existing = user.family.financekit_items.find_by(enrollment_id: input["enrollment_id"])
      if existing
        Financekit.require!(existing.enrollment_digest == digest && existing.user_id == user.id,
          "enrollment_conflict", 409)
        result = Result.new(item: existing, created: false)
        next
      end

      Financekit.require!(user.family.financekit_items.where(status: %w[pending_mapping active repair_required]).count < 20,
        "connection_limit", 429)
      replacement = if input["replaces_connection_id"]
        user.family.financekit_items.where(user: user).find(input["replaces_connection_id"])
      end
      generation = replacement ? replacement.generation + 1 : 1
      item = user.family.financekit_items.create!(user: user, enrollment_id: input["enrollment_id"],
        publisher_id: SecureRandom.uuid, generation: generation, enrollment_digest: digest,
        replaces_financekit_item: replacement, consent: input["consent"].merge("recorded_at" => Time.current.iso8601))
      result = Result.new(item: item, created: true)
    end
    result
  end

  def self.canonical(value)
    JSON.generate(case value
    when Hash
      value.keys.sort.to_h { |key| [ key, JSON.parse(canonical(value[key])) ] }
    when Array
      value.map { |entry| JSON.parse(canonical(entry)) }
    else
      value
    end)
  end
end
