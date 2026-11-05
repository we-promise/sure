# Wraps Gem::Version for CalVer release tags, while accepting legacy tags and
# development versions. Numeric version ordering does not validate calendar dates.
class Calver
  attr_reader :version

  def initialize(version_string)
    @version_string = version_string
    @version = Gem::Version.new(version_string)
  end

  def > (other)
    @version > other.version
  end

  def < (other)
    @version < other.version
  end

  def == (other)
    @version == other.version
  end

  def prerelease?
    @version.prerelease?
  end

  def to_s
    @version_string
  end

  def to_release_tag
    "v#{@version_string}"
  end

  def self.from_release_tag(tag)
    new(tag.sub(/^v/, ""))
  end
end
