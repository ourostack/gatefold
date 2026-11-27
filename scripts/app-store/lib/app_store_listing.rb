# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "net/http"
require "openssl"
require "uri"

# Stages the App Store listing in distribution/app-store/listing.json into App Store Connect.
# It never creates a review submission: submitting stays a human action in App Store Connect.
#
# Vendored from spoonjoy/spoonjoy-apple scripts/lib/app_store_listing.rb at ae4b5c4c5be9. Changes for Gatefold:
# What's New from changelog fragments is left out (a first version can't carry it; listing.json writes it from 1.1),
# `with_identity` fills the {{name}} placeholders, and the review contact email can come from a secret. When this
# and Spoonjoy's copy drift apart, the fix is one shared tool, not two copies.
module AppStoreListing
  LIMITS = {
    "name" => 30,
    "subtitle" => 30,
    "promotionalText" => 170,
    "description" => 4000,
    "whatsNew" => 4000
  }.freeze
  KEYWORDS_BYTES = 100
  REVIEW_NOTES_LIMIT = 4000
  MAX_SCREENSHOTS = 10
  URL_FIELDS = %w[privacyPolicyUrl supportUrl marketingUrl].freeze
  APP_INFO_LOCALIZATION_FIELDS = %w[name subtitle privacyPolicyUrl].freeze
  VERSION_LOCALIZATION_FIELDS = %w[description keywords promotionalText supportUrl marketingUrl whatsNew].freeze
  REVIEW_FIELDS = %w[contactFirstName contactLastName contactEmail contactPhone demoAccountName demoAccountRequired notes].freeze
  SCREENSHOT_NAME = /\A\d{2}-[a-z0-9-]+\.png\z/.freeze
  # iOS 27 product page creative assets, one per page, placed through the Asset Library API. Image sizes are Apple's
  # (GET /v1/appAssetLibraryRefData, read 2026-11-11); the 3:2 search results art may be any size in its range.
  CREATIVE_ASSET_SIZES = {
    "PRODUCT_PAGE_HEADER_ASSET" => ->(w, h) { [[5244, 2950], [3840, 1646]].include?([w, h]) },
    "APP_STORE_SEARCH_RESULTS_ASSET" => ->(w, h) { [w, h] == [5244, 2950] || (w * 2 == h * 3 && w.between?(1920, 3840)) }
  }.freeze
  CREATIVE_ASSET_HINTS = {
    "PRODUCT_PAGE_HEADER_ASSET" => "5244x2950 or 3840x1646",
    "APP_STORE_SEARCH_RESULTS_ASSET" => "5244x2950, or 3:2 from 1920x1280 to 3840x2560"
  }.freeze
  # listing.json describes the iOS version. Another platform's version reads its overrides from the named section.
  PLATFORM_SECTIONS = { "IOS" => nil, "MAC_OS" => "mac" }.freeze
  PLATFORM_NAMES = { "IOS" => "iOS", "MAC_OS" => "macOS" }.freeze
  # App-level data (name, categories, age rating, price, availability...) is shared by every platform, so only the
  # iOS listing writes it.
  APP_LEVEL_PLATFORM = "IOS"

  class Error < StandardError; end

  # Width, height and whether a PNG can carry transparency (an alpha channel or a tRNS chunk).
  PngInfo = Struct.new(:width, :height, :alpha, keyword_init: true)

  def self.png_info(path)
    data = File.binread(path)
    raise Error, "#{path} is not a PNG" unless data.start_with?("\x89PNG\r\n\x1A\n".b)

    offset = 8
    width = height = color_type = nil
    transparency = false
    while offset + 8 <= data.bytesize
      length = data.byteslice(offset, 4).unpack1("N")
      type = data.byteslice(offset + 4, 4)
      if type == "IHDR"
        width, height = data.byteslice(offset + 8, 8).unpack("NN")
        color_type = data.getbyte(offset + 17)
      end
      transparency = true if type == "tRNS"
      break if type == "IEND"

      offset += 12 + length
    end
    raise Error, "#{path} has no IHDR chunk" unless width

    PngInfo.new(width: width, height: height, alpha: transparency || [4, 6].include?(color_type))
  end

  # The listing as one platform's version sees it. IOS returns listing.json unchanged. Another platform takes its
  # section's localization fields, review fields, version fields and screenshot folders over the iOS ones.
  def self.for_platform(listing, platform)
    raise Error, "Unknown platform #{platform}; choose #{PLATFORM_SECTIONS.keys.join(' or ')}" unless PLATFORM_SECTIONS.key?(platform)
    return listing if platform == listing.fetch("platform")

    key = PLATFORM_SECTIONS.fetch(platform)
    section = listing[key]
    raise Error, "listing.json has no \"#{key}\" section for #{platform}" unless section.is_a?(Hash)

    effective = JSON.parse(JSON.generate(listing.reject { |name, _| PLATFORM_SECTIONS.value?(name) }))
    effective["platform"] = platform
    effective["version"] = effective.fetch("version").merge(section.fetch("version", {}))
    effective["review"] = effective.fetch("review").merge(section.fetch("review", {}))
    # What's New is told against that platform's own last version, so another platform never inherits it.
    effective["localizations"].each_value { |fields| fields.delete("whatsNew") }
    section.fetch("localizations", {}).each do |locale, fields|
      effective["localizations"][locale] = effective["localizations"].fetch(locale, {}).merge(fields)
    end
    effective["screenshots"] = section.fetch("screenshots")
    effective["creativeAssets"] = section.fetch("creativeAssets", {})
    effective
  end

  PLACEHOLDER = /\{\{(\w+)\}\}/.freeze

  # listing.json writes {{name}} wherever the app's name goes, because the name is chosen elsewhere; identity.json
  # holds it once chosen. Returns the listing with every placeholder filled, and the keys it had no value for.
  def self.with_identity(listing, identity)
    missing = []
    fill = lambda do |value|
      case value
      when String
        value.gsub(PLACEHOLDER) do
          key = Regexp.last_match(1)
          filler = identity[key]
          if filler.to_s.strip.empty?
            missing << key
            Regexp.last_match(0)
          else
            filler
          end
        end
      when Hash then value.transform_values { |v| fill.call(v) }
      when Array then value.map { |v| fill.call(v) }
      else value
      end
    end
    [fill.call(listing), missing.uniq]
  end

  def self.app_level?(listing)
    listing.fetch("platform") == APP_LEVEL_PLATFORM
  end

  # Every problem with the listing and its screenshots, as human-readable strings. Empty means valid.
  def self.validate(listing, screenshot_root)
    errors = []
    listing.fetch("localizations").each do |locale, fields|
      LIMITS.each do |field, limit|
        value = fields[field]
        next if value.nil?

        errors << "#{locale} #{field} is #{value.length} characters; the limit is #{limit}" if value.length > limit
      end
      %w[name description keywords supportUrl privacyPolicyUrl].each do |field|
        errors << "#{locale} #{field} is required" if fields[field].to_s.strip.empty?
      end
      keywords = fields["keywords"].to_s
      errors << "#{locale} keywords are #{keywords.bytesize} bytes; the limit is #{KEYWORDS_BYTES}" if keywords.bytesize > KEYWORDS_BYTES
      errors << "#{locale} keywords have an empty entry" if keywords.split(",", -1).any? { |word| word.strip.empty? }
      URL_FIELDS.each do |field|
        value = fields[field]
        next if value.nil?

        errors << "#{locale} #{field} must be an https URL" unless value.start_with?("https://")
      end
    end
    notes = listing.dig("review", "notes").to_s
    errors << "review notes are #{notes.length} characters; the limit is #{REVIEW_NOTES_LIMIT}" if notes.length > REVIEW_NOTES_LIMIT
    errors.concat(validate_screenshots(listing, screenshot_root))
    errors.concat(validate_creative_assets(listing, screenshot_root))
    errors
  end

  # listing.json "creativeAssets": {placementType => PNG path relative to the screenshots folder}. Optional.
  def self.validate_creative_assets(listing, screenshot_root)
    assets = listing.fetch("creativeAssets", {})
    return ["creativeAssets must be an object of placement type to file"] unless assets.is_a?(Hash)

    assets.flat_map do |type, relative|
      next ["unknown creative asset type #{type}; use #{CREATIVE_ASSET_SIZES.keys.join(' or ')}"] unless CREATIVE_ASSET_SIZES.key?(type)

      path = File.join(screenshot_root, relative)
      next ["#{type} #{relative} does not exist"] unless File.file?(path)

      info = png_info(path)
      errors = []
      unless CREATIVE_ASSET_SIZES.fetch(type).call(info.width, info.height)
        errors << "#{type} #{relative} is #{info.width}x#{info.height}; allowed: #{CREATIVE_ASSET_HINTS.fetch(type)}"
      end
      errors << "#{type} #{relative} has transparency; App Store creative assets must not" if info.alpha
      errors
    rescue Error => e
      [e.message]
    end
  end

  def self.validate_screenshots(listing, screenshot_root)
    errors = []
    listing.fetch("screenshots").each do |folder, spec|
      files = screenshot_files(screenshot_root, folder)
      errors << "#{folder} has #{files.length} screenshots; the limit is #{MAX_SCREENSHOTS}" if files.length > MAX_SCREENSHOTS
      Dir.children(File.join(screenshot_root, folder)).sort.each do |name|
        next if name.start_with?(".")

        errors << "#{folder}/#{name} must be named NN-name.png" unless name.match?(SCREENSHOT_NAME)
      end
      # The same file twice in one set: the iPhone Duo listing once showed two pictures twice each.
      # scripts/store-frames/distinct.mjs also catches the same picture at another size.
      files.group_by { |path| Digest::MD5.file(path).hexdigest }.each_value do |same|
        next if same.length < 2

        errors << "#{folder} has the same screenshot more than once: #{same.map { |path| File.basename(path) }.join(', ')}"
      end
      files.each do |path|
        info = png_info(path)
        size = [info.width, info.height]
        unless spec.fetch("sizes").include?(size)
          errors << "#{folder}/#{File.basename(path)} is #{size.join('x')}; allowed: #{spec['sizes'].map { |s| s.join('x') }.join(', ')}"
        end
        errors << "#{folder}/#{File.basename(path)} has transparency; App Store screenshots must not" if info.alpha
      rescue Error => e
        errors << e.message
      end
    end
    errors
  end

  def self.screenshot_files(screenshot_root, folder)
    dir = File.join(screenshot_root, folder)
    return [] unless Dir.exist?(dir)

    Dir.children(dir).select { |name| name.match?(SCREENSHOT_NAME) }.sort.map { |name| File.join(dir, name) }
  end

  # What App Store Connect holds now, read before any write. Plain hashes so tests can build fixtures.
  #   app: {id, contentRightsDeclaration}
  #   appInfo: {id, primaryCategory, secondaryCategory, ageRatingId, ageRating: {...}, localization: {id, attributes}|nil}
  #   version: {id, attributes, buildId, localization: {id, attributes}|nil, reviewDetail: {id, attributes}|nil,
  #             screenshotSets: {displayType => {id, checksums: [...]}}}|nil
  #   build: {id}|nil      price: {scheduled: bool, freePricePointId}      availability: {exists: bool, territoryIds: [...]}
  # app, appInfo, price and availability are app-level: only the iOS listing reads or writes them.
  #
  # Returns the writes needed, in order. Each step: {"action", "summary", ...data the executor needs}.
  def self.plan(listing:, snapshot:, screenshots:, secrets:, locale: "en-US", creative_assets: {})
    steps = []
    fields = listing.fetch("localizations").fetch(locale)
    steps.concat(app_level_steps(listing, snapshot, fields, locale)) if app_level?(listing)

    version = snapshot["version"]
    # phasedRelease is its own App Store Connect object, so it never travels as a version attribute.
    wanted_version = listing.fetch("version").reject { |key, _| key == "phasedRelease" }
    if version.nil?
      platform = listing.fetch("platform")
      steps << { "action" => "create_version", "summary" => "Create #{PLATFORM_NAMES.fetch(platform)} version #{wanted_version['versionString']}",
                 "platform" => platform, "attributes" => wanted_version }
      version = { "id" => "$version", "attributes" => wanted_version, "localization" => nil, "reviewDetail" => nil,
                  "screenshotSets" => {} }
    else
      version_changes = changed(version["attributes"] || {}, wanted_version)
      unless version_changes.empty?
        steps << { "action" => "patch_version", "summary" => "Update version #{version_changes.keys.join(', ')}",
                   "versionId" => version["id"], "attributes" => version_changes }
      end
    end

    if listing.fetch("version")["phasedRelease"] == true && version["phasedRelease"].nil?
      steps << { "action" => "create_phased_release", "summary" => "Release automatically in phases over 7 days",
                 "versionId" => version["id"] }
    end

    build = snapshot["build"]
    if build && version["buildId"] != build["id"]
      steps << { "action" => "attach_build", "summary" => "Attach build #{build['version']}", "versionId" => version["id"],
                 "buildId" => build["id"] }
    end

    # The first version of an app cannot carry What's New, so a null leaves it out entirely.
    wanted_version_localization = fields.slice(*VERSION_LOCALIZATION_FIELDS).reject { |_, value| value.nil? }
    localization_steps = localization_step("version_localization", version["localization"], wanted_version_localization, locale,
                                           "versionId" => version["id"])
    steps.concat(localization_steps)

    steps.concat(review_steps(listing.fetch("review"), version, secrets))
    steps.concat(pricing_steps(listing, snapshot)) if app_level?(listing)

    localization_ref = version["localization"] ? version["localization"]["id"] : "$version_localization"
    listing.fetch("screenshots").each do |folder, spec|
      files = screenshots.fetch(folder, [])
      next if files.empty?

      existing = version.dig("screenshotSets", spec["displayType"])
      checksums = files.map { |file| file["checksum"] }
      next if existing && existing["checksums"] == checksums

      steps << { "action" => "sync_screenshots",
                 "summary" => "Replace #{spec['displayType']} screenshots with #{files.length} from #{folder}",
                 "displayType" => spec["displayType"], "localizationId" => localization_ref,
                 "setId" => existing && existing["id"], "files" => files }
    end
    creative_assets.each do |type, file|
      existing = (version["creativePlacements"] || {})[type]
      next if existing && existing["referenceName"] == file["referenceName"] && !existing["failed"]

      steps << { "action" => "sync_creative_asset", "summary" => "Place #{type} #{File.basename(file['path'])}",
                 "placementType" => type, "placementId" => existing && existing["id"], "localizationId" => localization_ref,
                 "file" => file }
    end
    steps
  end

  # Content rights, categories, age rating and the app name, subtitle and privacy URL. Shared by every platform.
  def self.app_level_steps(listing, snapshot, fields, locale)
    steps = []
    app = snapshot.fetch("app")

    if app["contentRightsDeclaration"] != listing["contentRightsDeclaration"]
      steps << { "action" => "patch_app", "summary" => "Set content rights to #{listing['contentRightsDeclaration']}",
                 "attributes" => { "contentRightsDeclaration" => listing["contentRightsDeclaration"] } }
    end

    info = snapshot.fetch("appInfo")
    categories = listing.fetch("categories")
    if info["primaryCategory"] != categories["primary"] || info["secondaryCategory"] != categories["secondary"]
      steps << { "action" => "patch_categories", "summary" => "Set categories to #{categories['primary']} / #{categories['secondary']}",
                 "appInfoId" => info["id"], "primary" => categories["primary"], "secondary" => categories["secondary"] }
    end

    age_changes = changed(info["ageRating"] || {}, listing.fetch("ageRating"))
    unless age_changes.empty?
      steps << { "action" => "patch_age_rating", "summary" => "Update #{age_changes.length} age rating answers",
                 "ageRatingId" => info["ageRatingId"], "attributes" => age_changes }
    end

    wanted_info = fields.slice(*APP_INFO_LOCALIZATION_FIELDS)
    steps.concat(localization_step("app_info_localization", info["localization"], wanted_info, locale, "appInfoId" => info["id"]))
    steps
  end

  # Free in every territory. Shared by every platform.
  def self.pricing_steps(listing, snapshot)
    steps = []
    price = snapshot.fetch("price")
    unless price["scheduled"]
      steps << { "action" => "set_free_price", "summary" => "Make the app free in every territory (base #{listing.dig('price', 'baseTerritory')})",
                 "baseTerritory" => listing.dig("price", "baseTerritory"), "pricePointId" => price["freePricePointId"] }
    end

    availability = snapshot.fetch("availability")
    unless availability["exists"]
      steps << { "action" => "set_availability", "summary" => "Make the app available in all #{availability['territoryIds'].length} territories",
                 "territoryIds" => availability["territoryIds"],
                 "availableInNewTerritories" => listing.dig("availability", "availableInNewTerritories") }
    end
    steps
  end

  def self.changed(current, wanted)
    wanted.each_with_object({}) { |(key, value), out| out[key] = value unless current[key] == value }
  end

  def self.localization_step(kind, existing, wanted, locale, parent)
    if existing.nil?
      [{ "action" => "create_#{kind}", "summary" => "Create #{locale} #{kind.tr('_', ' ')}", "locale" => locale,
         "attributes" => wanted }.merge(parent)]
    else
      changes = changed(existing["attributes"] || {}, wanted)
      return [] if changes.empty?

      [{ "action" => "patch_#{kind}", "summary" => "Update #{locale} #{kind.tr('_', ' ')}: #{changes.keys.join(', ')}",
         "id" => existing["id"], "attributes" => changes }]
    end
  end

  def self.review_steps(review, version, secrets)
    wanted = review.slice(*REVIEW_FIELDS)
    wanted["contactPhone"] = secrets["contactPhone"] if secrets["contactPhone"]
    wanted["contactEmail"] = secrets["contactEmail"] if secrets["contactEmail"]
    wanted.delete("contactEmail") if wanted["contactEmail"].nil?
    wanted["demoAccountName"] = secrets["demoAccountName"] if secrets["demoAccountName"]
    existing = version["reviewDetail"]
    changes = changed(existing ? existing["attributes"] || {} : {}, wanted)
    # App Store Connect does not return the demo password, so it is always sent when known.
    changes["demoAccountPassword"] = secrets["demoAccountPassword"] if secrets["demoAccountPassword"]
    return [] if changes.empty?

    if existing
      [{ "action" => "patch_review_detail", "summary" => "Update review details: #{changes.keys.join(', ')}",
         "id" => existing["id"], "attributes" => changes }]
    else
      [{ "action" => "create_review_detail", "summary" => "Create review details: #{changes.keys.join(', ')}",
         "versionId" => version["id"], "attributes" => changes }]
    end
  end

  # A printable copy of the plan: secrets redacted and screenshot files reduced to names.
  def self.describe(steps)
    steps.map do |step|
      line = "- #{step['summary']}"
      attributes = step["attributes"]
      if attributes&.key?("demoAccountPassword")
        line += " (demo password: redacted)"
      end
      if step["files"]
        line += " [#{step['files'].map { |file| File.basename(file['path']) }.join(', ')}]"
      end
      line
    end
  end

  def self.local_screenshots(listing, screenshot_root)
    listing.fetch("screenshots").keys.each_with_object({}) do |folder, out|
      out[folder] = screenshot_files(screenshot_root, folder).map do |path|
        { "path" => path, "checksum" => Digest::MD5.file(path).hexdigest, "size" => File.size(path) }
      end
    end
  end

  # The image's referenceName carries its MD5, because Asset Library images have no checksum App Store Connect echoes.
  def self.local_creative_assets(listing, screenshot_root)
    assets = listing.fetch("creativeAssets", {})
    return {} unless assets.is_a?(Hash)

    assets.to_h do |type, relative|
      path = File.join(screenshot_root, relative)
      checksum = Digest::MD5.file(path).hexdigest
      [type, { "path" => path, "checksum" => checksum, "size" => File.size(path),
               "referenceName" => "#{checksum}-#{File.basename(path)}" }]
    end
  end

  # App Store Connect API client: ES256 JWT auth, JSON:API requests, and asset upload operations.
  class Client
    BASE = "https://api.appstoreconnect.apple.com"

    def initialize(key_id:, issuer_id:, private_key_pem:)
      @key_id = key_id
      @issuer_id = issuer_id
      @key = OpenSSL::PKey.read(private_key_pem)
    end

    def token
      now = Time.now.to_i
      header = { alg: "ES256", kid: @key_id, typ: "JWT" }
      payload = { iss: @issuer_id, iat: now, exp: now + 1100, aud: "appstoreconnect-v1" }
      signing_input = [header, payload].map { |part| base64url(JSON.generate(part)) }.join(".")
      der = @key.sign(OpenSSL::Digest.new("SHA256"), signing_input)
      "#{signing_input}.#{base64url(AppStoreListing::Client.der_to_raw(der))}"
    end

    def self.der_to_raw(der)
      sequence = OpenSSL::ASN1.decode(der)
      sequence.value.map { |integer| integer.value.to_s(2).rjust(32, "\x00".b)[-32, 32] }.join
    end

    def get(path, query = {})
      request(Net::HTTP::Get, path, query: query)
    end

    def get_all(path, query = {})
      body = get(path, query.merge("limit" => 200))
      data = body["data"]
      next_url = body.dig("links", "next")
      while next_url
        page = request(Net::HTTP::Get, URI(next_url).request_uri)
        data += page["data"]
        next_url = page.dig("links", "next")
      end
      data
    end

    def post(path, body)
      request(Net::HTTP::Post, path, body: body)
    end

    def patch(path, body)
      request(Net::HTTP::Patch, path, body: body)
    end

    def delete(path)
      request(Net::HTTP::Delete, path)
    end

    def upload(operation, bytes)
      uri = URI(operation.fetch("url"))
      klass = { "PUT" => Net::HTTP::Put, "POST" => Net::HTTP::Post }.fetch(operation.fetch("method"))
      req = klass.new(uri)
      operation.fetch("requestHeaders", []).each { |header| req[header["name"]] = header["value"] }
      req.body = bytes.byteslice(operation.fetch("offset"), operation.fetch("length"))
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
      raise Error, "Screenshot upload answered HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
    end

    # App Store Connect puts the reason a submission is refused in each error's meta.associatedErrors, keyed by
    # the resource it concerns; the top-level detail only says to look there.
    def self.error_detail(body)
      JSON.parse(body)["errors"].map do |e|
        associated = (e.dig("meta", "associatedErrors") || {}).flat_map do |resource, errors|
          Array(errors).map { |a| "#{resource}: #{[a['code'], a['title'], a['detail']].compact.join(' ')}" }
        end
        (["#{e['title']}: #{e['detail']}"] + associated).join(" | ")
      end.join("; ")
    rescue StandardError
      body.to_s[0, 500]
    end

    private

    def base64url(bytes)
      Base64.urlsafe_encode64(bytes, padding: false)
    end

    def request(klass, path, query: {}, body: nil)
      uri = path.start_with?("https://") ? URI(path) : URI("#{BASE}#{path}")
      uri.query = URI.encode_www_form(query) unless query.empty?
      req = klass.new(uri)
      req["Authorization"] = "Bearer #{token}"
      if body
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
      end
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 120) { |http| http.request(req) }
      unless response.is_a?(Net::HTTPSuccess)
        raise Error, "#{klass::METHOD} #{path} answered HTTP #{response.code}: #{self.class.error_detail(response.body)}"
      end
      response.body.to_s.empty? ? {} : JSON.parse(response.body)
    end
  end

  # Reads App Store Connect into the snapshot shape `plan` takes.
  class Reader
    EDITABLE_VERSION_STATES = %w[PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED REJECTED METADATA_REJECTED INVALID_BINARY].freeze

    def initialize(client, listing, locale: "en-US")
      @client = client
      @listing = listing
      @locale = locale
    end

    def app_id
      @app_id ||= begin
        apps = @client.get("/v1/apps", "filter[bundleId]" => @listing.fetch("bundleId"))["data"]
        raise Error, "No App Store Connect app has bundle ID #{@listing['bundleId']}" if apps.empty?

        apps.first["id"]
      end
    end

    def snapshot(build_number: nil)
      current = version
      # Read outside version, whose rescue turns any 404 into "no version yet".
      current&.store("creativePlacements", creative_placements(current.dig("localization", "id")))
      snapshot = {
        "version" => current,
        "build" => build_number ? build(build_number) : nil
      }
      return snapshot unless AppStoreListing.app_level?(@listing)

      app = @client.get("/v1/apps/#{app_id}")["data"]
      snapshot.merge(
        "app" => { "id" => app_id, "contentRightsDeclaration" => app.dig("attributes", "contentRightsDeclaration") },
        "appInfo" => app_info,
        "price" => price,
        "availability" => availability
      )
    end

    def app_info
      infos = @client.get_all("/v1/apps/#{app_id}/appInfos")
      info = infos.find { |candidate| candidate.dig("attributes", "state") != "READY_FOR_DISTRIBUTION" } || infos.first
      id = info["id"]
      primary = @client.get("/v1/appInfos/#{id}/primaryCategory")["data"]
      secondary = @client.get("/v1/appInfos/#{id}/secondaryCategory")["data"]
      age = @client.get("/v1/appInfos/#{id}/ageRatingDeclaration")["data"]
      localization = @client.get_all("/v1/appInfos/#{id}/appInfoLocalizations").find { |l| l.dig("attributes", "locale") == @locale }
      {
        "id" => id,
        "primaryCategory" => primary && primary["id"],
        "secondaryCategory" => secondary && secondary["id"],
        "ageRatingId" => age["id"],
        "ageRating" => age["attributes"],
        "localization" => localization && { "id" => localization["id"], "attributes" => localization["attributes"] }
      }
    end

    def version
      versions = @client.get_all("/v1/apps/#{app_id}/appStoreVersions", "filter[platform]" => @listing.fetch("platform"))
      current = versions.find { |v| EDITABLE_VERSION_STATES.include?(v.dig("attributes", "appStoreState") || v.dig("attributes", "appVersionState")) }
      return nil unless current

      id = current["id"]
      build = @client.get("/v1/appStoreVersions/#{id}/build")["data"]
      localization = @client.get_all("/v1/appStoreVersions/#{id}/appStoreVersionLocalizations").find { |l| l.dig("attributes", "locale") == @locale }
      review = @client.get("/v1/appStoreVersions/#{id}/appStoreReviewDetail")["data"]
      sets = {}
      if localization
        @client.get_all("/v1/appStoreVersionLocalizations/#{localization['id']}/appScreenshotSets").each do |set|
          shots = @client.get_all("/v1/appScreenshotSets/#{set['id']}/appScreenshots")
          sets[set.dig("attributes", "screenshotDisplayType")] = {
            "id" => set["id"], "checksums" => shots.map { |shot| shot.dig("attributes", "sourceFileChecksum") }
          }
        end
      end
      {
        "id" => id,
        "attributes" => current["attributes"].slice("versionString", "copyright", "releaseType"),
        "buildId" => build && build["id"],
        "phasedRelease" => phased_release(id),
        "localization" => localization && { "id" => localization["id"], "attributes" => localization["attributes"] },
        "reviewDetail" => review && { "id" => review["id"], "attributes" => review["attributes"] },
        "screenshotSets" => sets
      }
    rescue Error => e
      raise unless e.message.include?("HTTP 404")

      nil
    end

    # {placementType => {id, referenceName, failed}} for the version's creative asset placements (header, search
    # results). Read only when the listing names creative assets, so other listings make exactly the calls they did.
    def creative_placements(localization_id)
      return {} if localization_id.nil? || @listing.fetch("creativeAssets", {}).empty?

      body = @client.get("/v1/appStoreVersionLocalizations/#{localization_id}/placements",
                         "filter[placementType]" => CREATIVE_ASSET_SIZES.keys.join(","), "include" => "image",
                         "fields[appAssetLibraryImages]" => "referenceName,state", "limit" => "50")
      images = (body["included"] || []).select { |item| item["type"] == "appAssetLibraryImages" }.to_h { |item| [item["id"], item["attributes"] || {}] }
      (body["data"] || []).each_with_object({}) do |placement, out|
        type = placement.dig("attributes", "placementType")
        next unless CREATIVE_ASSET_SIZES.key?(type)

        # A placement whose image is not returned still holds the page's one slot, so it is replaced, never doubled.
        image = images[placement.dig("relationships", "image", "data", "id")] || { "state" => "FAILED" }
        failed = [placement.dig("attributes", "state"), image["state"]].include?("FAILED")
        out[type] = { "id" => placement["id"], "referenceName" => image["referenceName"], "failed" => failed }
      end
    end

    def phased_release(version_id)
      data = @client.get("/v1/appStoreVersions/#{version_id}/appStoreVersionPhasedRelease")["data"]
      data && { "id" => data["id"], "state" => data.dig("attributes", "phasedReleaseState") }
    rescue Error => e
      raise unless e.message.include?("HTTP 404")

      nil
    end

    def build(build_number)
      builds = @client.get("/v1/builds", "filter[app]" => app_id, "filter[version]" => build_number.to_s,
                                         "filter[processingState]" => "VALID", "filter[preReleaseVersion.platform]" => @listing["platform"])["data"]
      raise Error, "No VALID #{PLATFORM_NAMES.fetch(@listing['platform'])} build #{build_number} in App Store Connect" if builds.empty?

      { "id" => builds.first["id"], "version" => build_number.to_s }
    end

    def price
      schedule = begin
        @client.get("/v1/apps/#{app_id}/appPriceSchedule")["data"]
      rescue Error => e
        raise unless e.message.include?("HTTP 404")

        nil
      end
      if schedule
        # An existing schedule only counts if every manual price is free; otherwise plan to replace it.
        # A new app answers the schedule with a placeholder whose manual prices 404, which means no price yet.
        body = begin
          @client.get("/v1/appPriceSchedules/#{schedule['id']}/manualPrices", "include" => "appPricePoint", "limit" => 200)
        rescue Error => e
          raise unless e.message.include?("HTTP 404")

          {}
        end
        prices = (body["included"] || []).select { |item| item["type"] == "appPricePoints" }
        return { "scheduled" => true } if !prices.empty? && prices.all? { |point| point.dig("attributes", "customerPrice").to_f.zero? }
      end

      territory = @listing.dig("price", "baseTerritory")
      points = @client.get_all("/v1/apps/#{app_id}/appPricePoints", "filter[territory]" => territory)
      free = points.find { |point| point.dig("attributes", "customerPrice").to_f.zero? }
      raise Error, "No free price point in #{territory}" unless free

      { "scheduled" => false, "freePricePointId" => free["id"] }
    end

    def availability
      exists = begin
        @client.get("/v1/apps/#{app_id}/appAvailabilityV2")["data"] ? true : false
      rescue Error => e
        raise unless e.message.include?("HTTP 404")

        false
      end
      ids = exists ? [] : @client.get_all("/v1/territories").map { |territory| territory["id"] }
      { "exists" => exists, "territoryIds" => ids }
    end
  end

  # Applies plan steps. "$version" and "$version_localization" refer to objects created earlier in the run.
  class Executor
    def initialize(client, app_id, log: $stdout)
      @client = client
      @app_id = app_id
      @refs = {}
      @log = log
    end

    def run(steps)
      steps.each do |step|
        @log.puts AppStoreListing.describe([step]).first
        send("apply_#{step.fetch('action')}", step)
      end
    end

    private

    def ref(value)
      value.is_a?(String) && value.start_with?("$") ? @refs.fetch(value) : value
    end

    def apply_patch_app(step)
      @client.patch("/v1/apps/#{@app_id}", data: { type: "apps", id: @app_id, attributes: step["attributes"] })
    end

    def apply_patch_categories(step)
      @client.patch("/v1/appInfos/#{step['appInfoId']}", data: {
        type: "appInfos", id: step["appInfoId"],
        relationships: {
          primaryCategory: { data: { type: "appCategories", id: step["primary"] } },
          secondaryCategory: { data: { type: "appCategories", id: step["secondary"] } }
        }
      })
    end

    def apply_patch_age_rating(step)
      @client.patch("/v1/ageRatingDeclarations/#{step['ageRatingId']}",
                    data: { type: "ageRatingDeclarations", id: step["ageRatingId"], attributes: step["attributes"] })
    end

    def apply_create_app_info_localization(step)
      @client.post("/v1/appInfoLocalizations", data: {
        type: "appInfoLocalizations", attributes: step["attributes"].merge("locale" => step["locale"]),
        relationships: { appInfo: { data: { type: "appInfos", id: step["appInfoId"] } } }
      })
    end

    def apply_patch_app_info_localization(step)
      @client.patch("/v1/appInfoLocalizations/#{step['id']}",
                    data: { type: "appInfoLocalizations", id: step["id"], attributes: step["attributes"] })
    end

    def apply_create_version(step)
      body = @client.post("/v1/appStoreVersions", data: {
        type: "appStoreVersions", attributes: step["attributes"].merge("platform" => step.fetch("platform", "IOS")),
        relationships: { app: { data: { type: "apps", id: @app_id } } }
      })
      @refs["$version"] = body.dig("data", "id")
      # App Store Connect creates the primary-locale localization with the version.
      localizations = @client.get_all("/v1/appStoreVersions/#{@refs['$version']}/appStoreVersionLocalizations")
      @refs["$version_localization"] = localizations.first && localizations.first["id"]
    end

    def apply_patch_version(step)
      @client.patch("/v1/appStoreVersions/#{step['versionId']}",
                    data: { type: "appStoreVersions", id: step["versionId"], attributes: step["attributes"] })
    end

    # INACTIVE until the version is released; App Store Connect then runs the 7-day phased rollout.
    def apply_create_phased_release(step)
      @client.post("/v1/appStoreVersionPhasedReleases", data: {
        type: "appStoreVersionPhasedReleases", attributes: { phasedReleaseState: "INACTIVE" },
        relationships: { appStoreVersion: { data: { type: "appStoreVersions", id: ref(step["versionId"]) } } }
      })
    end

    def apply_attach_build(step)
      @client.patch("/v1/appStoreVersions/#{ref(step['versionId'])}/relationships/build",
                    data: { type: "builds", id: step["buildId"] })
    end

    def apply_create_version_localization(step)
      version_id = ref(step["versionId"])
      existing = @refs["$version_localization"]
      if existing
        @client.patch("/v1/appStoreVersionLocalizations/#{existing}",
                      data: { type: "appStoreVersionLocalizations", id: existing, attributes: step["attributes"] })
        return
      end
      body = @client.post("/v1/appStoreVersionLocalizations", data: {
        type: "appStoreVersionLocalizations", attributes: step["attributes"].merge("locale" => step["locale"]),
        relationships: { appStoreVersion: { data: { type: "appStoreVersions", id: version_id } } }
      })
      @refs["$version_localization"] = body.dig("data", "id")
    end

    def apply_patch_version_localization(step)
      @client.patch("/v1/appStoreVersionLocalizations/#{step['id']}",
                    data: { type: "appStoreVersionLocalizations", id: step["id"], attributes: step["attributes"] })
    end

    def apply_create_review_detail(step)
      @client.post("/v1/appStoreReviewDetails", data: {
        type: "appStoreReviewDetails", attributes: step["attributes"],
        relationships: { appStoreVersion: { data: { type: "appStoreVersions", id: ref(step["versionId"]) } } }
      })
    end

    def apply_patch_review_detail(step)
      @client.patch("/v1/appStoreReviewDetails/#{step['id']}",
                    data: { type: "appStoreReviewDetails", id: step["id"], attributes: step["attributes"] })
    end

    def apply_set_free_price(step)
      @client.post("/v1/appPriceSchedules", {
        data: {
          type: "appPriceSchedules",
          relationships: {
            app: { data: { type: "apps", id: @app_id } },
            baseTerritory: { data: { type: "territories", id: step["baseTerritory"] } },
            manualPrices: { data: [{ type: "appPrices", id: "${free}" }] }
          }
        },
        included: [{
          type: "appPrices", id: "${free}",
          attributes: { startDate: nil },
          relationships: { appPricePoint: { data: { type: "appPricePoints", id: step["pricePointId"] } } }
        }]
      })
    end

    def apply_set_availability(step)
      included = step["territoryIds"].each_with_index.map do |territory, index|
        { type: "territoryAvailabilities", id: "${t#{index}}", attributes: { available: true },
          relationships: { territory: { data: { type: "territories", id: territory } } } }
      end
      @client.post("/v2/appAvailabilities", {
        data: {
          type: "appAvailabilities", attributes: { availableInNewTerritories: step["availableInNewTerritories"] },
          relationships: {
            app: { data: { type: "apps", id: @app_id } },
            territoryAvailabilities: { data: included.map { |item| { type: item[:type], id: item[:id] } } }
          }
        },
        included: included
      })
    end

    # The new image is uploaded to the app's Asset Library (whose id is the app id) first, so a failed upload leaves the
    # live page untouched. A page holds one placement per creative type, so the old placement goes just before the new one.
    def apply_sync_creative_asset(step)
      file = step.fetch("file")
      bytes = File.binread(file["path"])
      image = @client.post("/v1/appAssetLibraryImages", data: {
        type: "appAssetLibraryImages",
        attributes: { category: "CREATIVE_ASSETS", fileName: File.basename(file["path"]), fileSize: bytes.bytesize,
                      referenceName: file["referenceName"] },
        relationships: { assetLibrary: { data: { type: "appAssetLibraries", id: @app_id } } }
      })["data"]
      image.dig("attributes", "uploadOperations").each { |operation| @client.upload(operation, bytes) }
      @client.patch("/v1/appAssetLibraryImages/#{image['id']}", data: {
        type: "appAssetLibraryImages", id: image["id"], attributes: { uploaded: true }
      })
      @client.delete("/v1/appAssetLibraryPlacements/#{step['placementId']}") if step["placementId"]
      @client.post("/v1/appAssetLibraryPlacements", data: {
        type: "appAssetLibraryPlacements",
        attributes: { placementType: step["placementType"], placementGroup: "DEFAULT_PROFILE" },
        relationships: { image: { data: { type: "appAssetLibraryImages", id: image["id"] } },
                         appStoreVersionLocalization: { data: { type: "appStoreVersionLocalizations", id: ref(step["localizationId"]) } } }
      })
    end

    def apply_sync_screenshots(step)
      set_id = step["setId"]
      if set_id
        @client.get_all("/v1/appScreenshotSets/#{set_id}/appScreenshots").each do |shot|
          @client.delete("/v1/appScreenshots/#{shot['id']}")
        end
      else
        body = @client.post("/v1/appScreenshotSets", data: {
          type: "appScreenshotSets", attributes: { screenshotDisplayType: step["displayType"] },
          relationships: { appStoreVersionLocalization: { data: { type: "appStoreVersionLocalizations", id: ref(step["localizationId"]) } } }
        })
        set_id = body.dig("data", "id")
      end
      step["files"].each do |file|
        bytes = File.binread(file["path"])
        reservation = @client.post("/v1/appScreenshots", data: {
          type: "appScreenshots", attributes: { fileName: File.basename(file["path"]), fileSize: bytes.bytesize },
          relationships: { appScreenshotSet: { data: { type: "appScreenshotSets", id: set_id } } }
        })["data"]
        reservation.dig("attributes", "uploadOperations").each { |operation| @client.upload(operation, bytes) }
        @client.patch("/v1/appScreenshots/#{reservation['id']}", data: {
          type: "appScreenshots", id: reservation["id"], attributes: { uploaded: true, sourceFileChecksum: file["checksum"] }
        })
      end
    end
  end
end
