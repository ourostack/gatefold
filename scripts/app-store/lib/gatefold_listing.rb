# frozen_string_literal: true

require "digest"
require "fileutils"

# Gatefold's own rules for its App Store listing, on top of the stager's field limits (AppStoreListing.validate).
# Each returns human-readable problems; empty means the listing passes.
module GatefoldListing
  # Other companies' marks. Guideline 2.3.7 keeps them out of the name, subtitle and keywords; 5.2.1 lets the
  # description say what the app works with, with the non-affiliation line.
  TRADEMARKS = [/pocket\s*book/i, /\binkpad\b/i, /\bkindle\b/i, /\bkobo\b/i, /apple\s*books/i, /\bkoreader\b/i].freeze
  NON_AFFILIATION = "is not made by, affiliated with, or endorsed by PocketBook International SA"

  # Release builds send counts-only telemetry (Gatefold/Sync/GatefoldTelemetry.swift, docs/privacy/), so the
  # listing may not claim it collects nothing (Guidelines 2.3.1 and 5.1.1).
  CONTRADICTED = [/no analytics/i, /collects nothing/i, /collect(s)? no data/i, /only server .* talks to/i,
                  /no data (is )?collected/i].freeze

  def self.trademark_problems(listing)
    problems = []
    listing.fetch("localizations").each do |locale, fields|
      %w[name subtitle keywords].each do |field|
        TRADEMARKS.each do |mark|
          problems << "#{locale} #{field} names #{mark.source} (Guideline 2.3.7)" if fields[field].to_s.match?(mark)
        end
      end
      text = "#{fields['description']} #{fields['promotionalText']}"
      if text.match?(TRADEMARKS.first) && !fields["description"].to_s.include?(NON_AFFILIATION)
        problems << "#{locale} description names PocketBook without the line saying the app is not affiliated with it"
      end
    end
    notes = listing.dig("review", "notes").to_s
    if notes.match?(TRADEMARKS.first) && !notes.include?("not affiliated")
      problems << "review notes name PocketBook without saying the app is not affiliated with it"
    end
    problems
  end

  def self.claim_problems(listing)
    listing.fetch("localizations").flat_map do |locale, fields|
      text = fields.values_at("description", "promotionalText", "subtitle").join("\n")
      CONTRADICTED.select { |claim| text.match?(claim) }.map do |claim|
        "#{locale} says /#{claim.source}/, but release builds send counts-only telemetry (docs/privacy/)"
      end
    end
  end

  def self.problems(listing)
    trademark_problems(listing) + claim_problems(listing)
  end

  # What has to be true of the repository before a real staging, beyond the listing itself: the privacy policy the
  # listing links says what the app does (Guideline 5.1.1), and every button the review notes tell App Review to tap
  # is in the app (2.1). A validation reports these as warnings; --apply refuses on any.
  PRIVACY_PAGE = "docs/privacy/index.html"
  PAGE_CONTRADICTED = CONTRADICTED + [/password is never (stored|kept|saved)/i]

  def self.release_problems(listing, root)
    problems = []
    page = File.file?(File.join(root, PRIVACY_PAGE)) ? File.read(File.join(root, PRIVACY_PAGE)) : ""
    problems << "#{PRIVACY_PAGE} is missing" if page.empty?
    PAGE_CONTRADICTED.each do |claim|
      problems << "#{PRIVACY_PAGE} says /#{claim.source}/, which the app contradicts" if page.match?(claim)
    end
    code = Dir.glob(File.join(root, "Gatefold/**/*.swift")).map { |file| File.read(file) }.join("\n")
    listing.dig("review", "notes").to_s.scan(/"([^"]+)"/).flatten.uniq.each do |label|
      problems << "the review notes say to tap \"#{label}\", which is not in the app's code" unless code.include?("\"#{label}\"")
    end
    problems
  end

  # The Screenshots workflow's artifact (listing-screenshots-<fingerprint>) holds <folder>/<scene>.png, the raw
  # captures under <folder>/raw/ and a SHA256SUMS per folder. App Store Connect shows a set in file-name order, so this
  # copies each folder's composed shots into `out` as NN-<scene>.png, in screenshots/spec.json's scene order, after
  # checking them against SHA256SUMS. Returns problems; empty means `out` is ready to stage.
  def self.arrange(set_dir, spec, listing, out)
    problems = []
    devices = spec.fetch("devices")
    listing.fetch("screenshots").each_key do |folder|
      device, = devices.find { |_, d| d["folder"] == folder }
      next problems << "#{folder}: screenshots/spec.json renders no such folder" unless device

      FileUtils.mkdir_p(File.join(out, folder))
      sums = File.join(set_dir, folder, "SHA256SUMS")
      next problems << "#{folder}: the screenshot set has no #{folder}/SHA256SUMS" unless File.file?(sums)

      want = File.readlines(sums, chomp: true).to_h { |line| line.split(/\s+/, 2).reverse }
      scenes = spec.fetch("scenes").select { |s| s.fetch("devices").include?(device) }.map { |s| s.fetch("id") }
      scenes.each_with_index do |id, index|
        source = File.join(set_dir, folder, "#{id}.png")
        unless File.file?(source)
          problems << "#{folder}: the screenshot set has no #{id}.png"
          next
        end
        if Digest::SHA256.file(source).hexdigest != want["#{folder}/#{id}.png"]
          problems << "#{folder}/#{id}.png does not match its SHA256SUMS line"
          next
        end
        FileUtils.cp(source, File.join(out, folder, format("%02d-%s.png", index + 1, id)))
      end
    end
    problems
  end
end
