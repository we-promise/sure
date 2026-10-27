require "date"

# Release identity is shared by the artifact publishers, not inferred from aliases.
class ReleaseVersion
  FORMAT = /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(alpha|beta|rc)(?:\.(0|[1-9]\d*))?)?\z/
  attr_reader :version, :modifier, :compatibility_version

  def initialize(version, aliases: {})
    match = FORMAT.match(version)
    raise ArgumentError, "Invalid release version: #{version}" unless match

    @version = version
    @modifier = match[4]
    @year, @month, @day = match.captures.first(3).map(&:to_i)
    Date.new(@year, @month, @day) if calver?
    @compatibility_version = aliases[version]
    if compatibility_version
      unless calver? && stable? && @year == 2026 && compatibility_version.match?(/\A0\.\d+\.\d+\z/)
        raise ArgumentError, "Compatibility aliases are only allowed for stable 2026 releases"
      end
    end
  end

  def calver?
    @year >= 2000
  end

  def stable?
    modifier.nil?
  end

  def tag
    "v#{version}"
  end

  def alias_tag
    "v#{compatibility_version}" if compatibility_version
  end

  def channel
    return "stable" if stable?
    "latest" if modifier == "alpha"
  end

  def image_versions
    [ version, compatibility_version, channel ].compact
  end

  def publish_tag?(ref)
    return false if alias_tag && ref == "refs/tags/#{alias_tag}"
    raise ArgumentError, "Tag #{ref} does not match #{tag}" unless ref == "refs/tags/#{tag}"
    true
  end
end
