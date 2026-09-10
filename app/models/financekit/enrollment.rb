class Financekit::Enrollment
  def self.validate_consent!(consent)
    Financekit::Payload.shape!(consent, %w[version upload_authorized source_ids enrichment_acknowledged])
    Financekit.require!(consent["version"] == 1 && consent["upload_authorized"] == true && consent["enrichment_acknowledged"] == true, "consent_required")
    ids = consent["source_ids"]
    Financekit.require!(ids.is_a?(Array) && ids.size.between?(1, Financekit::MAX_ACCOUNTS) && ids.uniq == ids)
    ids.each { |id| Financekit::Payload.uuid!(id) }
  end

  def self.create!(user, input)
    Financekit::Payload.shape!(input, %w[enrollment_id device_public_key consent protocol])
    Financekit.require!(input["protocol"] == Financekit::VERSION, "unsupported_protocol", 400)
    Financekit::Payload.uuid!(input["enrollment_id"])
    Financekit::Crypto.public_device_key(input["device_public_key"])
    validate_consent!(input["consent"])
    # Hash canonical key ordering, but preserve array ordering and scalar types.
    digest = Digest::SHA256.hexdigest(canonical(input))
    user.family.with_lock do
      existing = user.family.financekit_items.find_by(enrollment_id: input["enrollment_id"])
      if existing
        Financekit.require!(existing.enrollment_digest == digest && existing.user_id == user.id, "enrollment_conflict", 409)
        return existing
      end
      Financekit.require!(user.family.financekit_items.where(status: "active").count < 20, "connection_limit", 429)
      user.family.financekit_items.create!(user: user, enrollment_id: input["enrollment_id"], enrollment_digest: digest,
        device_public_key: input["device_public_key"], consent: input["consent"].merge("recorded_at" => Time.current.iso8601))
    end
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
