class Entry::Timestamp
  # ISO timestamps keep their supplied offset. Local form values must supply a
  # timezone explicitly; neither the server timezone nor today's date is inferred.
  def self.parse(value, timezone: nil)
    text = value.to_s.strip
    match = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d{1,6})?)?(Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)?\z/.match(text)
    raise ArgumentError, "Invalid timestamp" unless match
    raise ArgumentError, "Timestamp requires a timezone" unless match[1] || timezone

    parts = Date._iso8601(text)
    valid = Date.valid_date?(parts[:year], parts[:mon], parts[:mday]) &&
      (0..23).cover?(parts[:hour]) && (0..59).cover?(parts[:min]) && (0..59).cover?(parts[:sec] || 0)
    raise ArgumentError, "Invalid timestamp" unless valid

    if match[1]
      Time.iso8601(text)
    else
      zone = Time.find_zone!(timezone)
      timestamp = zone.iso8601(text)
      # Rails advances nonexistent local times over a DST gap. Reject that
      # adjustment rather than silently recording a different time.
      unless [ timestamp.year, timestamp.month, timestamp.day, timestamp.hour, timestamp.min ] ==
             parts.values_at(:year, :mon, :mday, :hour, :min)
        raise ArgumentError, "Local time does not exist"
      end
      timestamp
    end
  end
end
