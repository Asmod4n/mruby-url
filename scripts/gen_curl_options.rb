# scripts/gen_curl_options.rb
#
# Generate mrblib/url/curl_options.gen.rb — the per-protocol curl_easy option
# matrix that drives which options each URL scheme class accepts.
#
# The data is curl's own: every CURLOPT_* option ships a doc page under
# deps/curl/docs/libcurl/opts/ whose YAML-ish front matter carries a
# `Protocol:` list (HTTP / FTP / TLS / All / …) — the authoritative statement
# of which protocols the option applies to. The value type (long / string /
# slist / off_t / blob / …) comes from curl's own lib/easyoptions.c table.
# Nothing here is hand-asserted; bump the curl submodule and re-run to expand.
#
# Run from the repo root:
#
#     ruby scripts/gen_curl_options.rb            # rewrite the generated file
#     ruby scripts/gen_curl_options.rb --check    # fail if it would change (CI)
#
# Plain Ruby (MRI) — this is build-time codegen, not part of the mruby image.

ROOT      = File.expand_path("..", __dir__)
OPTS_DIR  = File.join(ROOT, "deps/curl/docs/libcurl/opts")
CURL_H    = File.join(ROOT, "deps/curl/include/curl/curl.h")
OUT_FILE  = File.join(ROOT, "mrblib/url/curl_options.gen.rb")

# ---- 1. name -> CURLOT value type, from curl's include/curl/curl.h -----------
# This mirrors curl's own lib/optiontable.pl (the script that *generates*
# easyoptions.c): walk curl.h, and for each `CURLOPT(name, type, num)` —
# and each multi-line `CURLOPTDEPRECATED(name, type, num, ver, msg)` accumulated
# until its closing `),` — derive the value type the same way the script does.
# curl.h is the source of truth optiontable.pl reads, so there is nothing here
# the generated easyoptions.c could disagree with (and no wrapped lines to trip
# over). The CURLOPTTYPE_ token is normalised to the bare CURLOT word the way
# add() does: drop the prefix, CBPOINT->CBPTR, strip a trailing POINT — yielding
# LONG / STRING / SLIST / OFF_T / OBJECT / BLOB / CBPTR / VALUES / FUNCTION. The
# binding marshals on that; Ruby pre-rejects the types a kwarg can't carry
# (FUNCTION / CBPTR / OBJECT — callbacks/handles we own internally).
def add_type(types, optstr, typestr)
  return if optstr.nil? || typestr.nil?
  return if optstr.include?("OBSOLETE")
  return unless optstr.start_with?("CURLOPT_")
  name = optstr.delete_prefix("CURLOPT_")
  ext  = typestr.gsub(" ", "").delete_prefix("CURLOPTTYPE_")
  ext  = ext.sub("CBPOINT", "CBPTR").delete_suffix("POINT")
  types[name] = ext unless name.empty? || ext.empty?
end

def load_types
  types = {}
  cont  = nil   # accumulator for a CURLOPTDEPRECATED entry spanning lines
  File.foreach(CURL_H) do |line|
    if cont
      if (idx = line.rindex("),"))
        cont += line[0...idx]
        p = cont.split(",").map(&:strip)
        add_type(types, p[0], p[1])
        cont = nil
      else
        cont += line.chomp
      end
    end
    s = line.strip
    if s.start_with?("CURLOPTDEPRECATED(")
      cont = s.delete_prefix("CURLOPTDEPRECATED(").chomp
    elsif s.start_with?("CURLOPT(") && (close = s.rindex(")"))
      inner = s[s.index("(") + 1...close]
      p = inner.split(",").map(&:strip)
      add_type(types, p[0], p[1])
    end
  end
  raise "no options parsed from #{CURL_H}" if types.empty?
  types
end

# ---- 2. name -> Protocol tokens, from each option's doc front matter ---------
# This mirrors curl's own scripts/cd2nroff exactly: read the file line by line,
# enter the header at the first `---`, leave at the next `---`. A `Protocol:`
# line arms the protocol list; each subsequent `  - TOKEN` line is an item of
# whichever list is currently armed (See-also / Protocol / TLS-backend). Tokens
# are curl's protocol *families* (HTTP, FTP, SMTP, …) plus the cross-cutting
# pseudo-tokens `All`, `TLS` and `TCP`; we keep them verbatim — expanding a token
# to concrete scheme classes is the curated wiring in endpoints.rb, deliberately
# NOT baked into this data.
def load_protocols
  protos = {}
  Dir.glob(File.join(OPTS_DIR, "CURLOPT_*.md")).sort.each do |path|
    title  = nil
    tokens = []
    started = false   # have we seen the opening `---`?
    list = nil        # which YAML list `  - ` items belong to right now
    File.foreach(path) do |line|
      line = line.chomp
      unless started
        started = true if line.start_with?("---")
        next
      end
      break if line.start_with?("---")                 # end of header
      if line.start_with?("Title:")
        title = line.split(":", 2)[1].strip.delete_prefix("CURLOPT_")
        list = nil
      elsif line.start_with?("See-also:")
        list = :seealso
      elsif line.start_with?("Protocol:")
        list = :protocol
      elsif line.start_with?("TLS-backend:")
        list = :tls
      elsif (line.start_with?(" ") || line.start_with?("\t")) && line.lstrip.start_with?("- ")
        tokens << line.lstrip.delete_prefix("- ").strip if list == :protocol
      elsif !line.start_with?(" ") && line.include?(":")
        list = nil                                     # any other header key ends the list
      end
    end
    protos[title] = tokens if title
  end
  raise "no option docs parsed from #{OPTS_DIR}" if protos.empty?
  protos
end

# ---- 3. curl version, for a provenance line in the generated header ---------
def curl_version
  vh = File.join(ROOT, "deps/curl/include/curl/curlver.h")
  File.foreach(vh) do |line|
    s = line.strip
    next unless s.start_with?("#define") && s.include?("LIBCURL_VERSION ")
    return s.split('"')[1] || "unknown"
  end
  "unknown"
rescue
  "unknown"
end

types     = load_types
protocols = load_protocols

# Only options curl actually exposes in its setopt table are usable; a doc page
# without a matching easyoptions.c entry is deprecated/aliased — skip it, but
# record it so the diff makes the omission visible.
known     = types.keys
documented = protocols.keys
usable    = (known & documented).sort
skipped   = (documented - known).sort

# token -> sorted Array of option symbols (downcased canonical names)
by_protocol = Hash.new { |h, k| h[k] = [] }
usable.each do |name|
  protocols[name].each { |tok| by_protocol[tok] << name.downcase.to_sym }
end
by_protocol.each_value(&:sort!)
by_protocol.each_value(&:uniq!)

# option symbol -> CURLOT type word, for the usable set only
type_map = usable.map { |n| [n.downcase.to_sym, types[n]] }.to_h

def fmt_symlist(syms, indent)
  pad = " " * indent
  out = +"%i[\n"
  line = pad + "  "
  syms.each do |s|
    tok = s.to_s
    if line.length + tok.length + 1 > 96
      out << line.rstrip << "\n"
      line = pad + "  "
    end
    line << tok << " "
  end
  out << line.rstrip << "\n" unless line.strip.empty?
  out << pad << "]"
  out
end

io = +""
io << <<~HEAD
  # mrblib/url/curl_options.gen.rb
  #
  # GENERATED by scripts/gen_curl_options.rb from libcurl #{curl_version}'s own
  # option docs (deps/curl/docs/libcurl/opts) and the CURLOPT macros in
  # include/curl/curl.h. DO NOT EDIT BY HAND -- re-run the generator after
  # bumping the curl submodule.
  #
  # BY_PROTOCOL maps each curl "Protocol:" token to the curl_easy options curl
  # documents as applying to it. "All" is every protocol; "TLS" and "TCP" are
  # cross-cutting (TLS-capable / TCP-based) -- endpoints.rb decides which scheme
  # classes compose which tokens. TYPES gives each option's curl value type so
  # the binding can marshal it generically and reject the callback/handle types
  # a kwarg can't carry.

  class URL
    module CurlOptions
HEAD

io << "      # #{usable.size} options across #{by_protocol.size} protocol tokens.\n"
io << "      BY_PROTOCOL = {\n"
by_protocol.keys.sort.each do |tok|
  io << %(        #{tok.inspect} => #{fmt_symlist(by_protocol[tok], 8)},\n)
end
io << "      }.freeze\n\n"

io << "      # option => curl value type (LONG STRING SLIST OFF_T OBJECT BLOB CBPTR VALUES FUNCTION)\n"
io << "      TYPES = {\n"
type_map.keys.sort.each do |sym|
  io << %(        #{sym.inspect} => #{type_map[sym].inspect},\n)
end
io << "      }.freeze\n"

unless skipped.empty?
  io << "\n      # Documented but absent from curl's setopt table (deprecated/aliased), skipped:\n"
  skipped.each_slice(4) { |grp| io << "      #   #{grp.join(', ')}\n" }
end

io << <<~TAIL
    end
  end
TAIL

if ARGV.include?("--check")
  # Compare bytes, not encoding-tagged strings: io is UTF-8 (source literals)
  # while File.read tags with the locale's default_external, so a plain == can
  # report a false mismatch even when the bytes are identical.
  current = File.exist?(OUT_FILE) ? File.binread(OUT_FILE) : "".b
  if current == io.b
    puts "up to date: #{OUT_FILE}"
    exit 0
  else
    warn "OUT OF DATE: #{OUT_FILE} — run `ruby scripts/gen_curl_options.rb`"
    exit 1
  end
else
  File.write(OUT_FILE, io)
  puts "wrote #{OUT_FILE} (#{usable.size} options, #{by_protocol.size} tokens, #{skipped.size} skipped)"
end
