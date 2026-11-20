# The key a name sorts by wherever names are listed side by side: the
# sidebar, the portfolio's account cards and its holdings table. Case and
# accent marks are set aside, so "écu" sits with "e" rather than after "z",
# whatever the database's collation. Letters that decomposition leaves whole
# are spelled out as the letters they are written as (Æ as "ae", ß as "ss",
# Ø as "o", dotless ı as "i"), which puts them with those letters rather than where a Danish
# or German alphabet would. A name with no Latin form keeps its characters.
module NameSortKey
  SPELLED_OUT = {
    "æ" => "ae", "œ" => "oe", "ø" => "o", "ß" => "ss",
    "ł" => "l", "đ" => "d", "ð" => "d", "þ" => "th",
    "ı" => "i", "ħ" => "h", "ŧ" => "t", "ŋ" => "n", "ĸ" => "k"
  }.freeze
  SPELLED_OUT_PATTERN = Regexp.union(SPELLED_OUT.keys)

  def self.for(name)
    name.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.gsub(SPELLED_OUT_PATTERN, SPELLED_OUT)
  end
end
