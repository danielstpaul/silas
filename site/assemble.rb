#!/usr/bin/env ruby
# Assembles the docs-site sources. The markdown source of record is ../docs
# (shipped inside the gem, frontmatter-free); this script copies each page in
# and prepends the just-the-docs nav frontmatter, so the site gets grouped,
# ordered navigation without the gem's files carrying site metadata.
#
# Run from site/ (locally and in CI): ruby assemble.rb
#
# A docs/*.md file with no NAV entry FAILS the build on purpose — add the
# page here when you add it there, or the site would silently omit it.

require "fileutils"

NAV = {
  "tutorial"      => { title: "Tutorial", order: 2 },
  "guarantees"    => { title: "Guarantees", order: 3 },

  "tools"         => { title: "Tools & approvals", parent: "Core", order: 1 },
  "agents"        => { title: "Agents & staff",    parent: "Core", order: 2 },
  "memory"        => { title: "Memory",            parent: "Core", order: 3 },
  "channels"      => { title: "Channels",          parent: "Core", order: 4 },
  "inbox-and-api" => { title: "Inbox & API",       parent: "Core", order: 5 },

  "connections"   => { title: "Connections",  parent: "Advanced", order: 1 },
  "evals"         => { title: "Evals",        parent: "Advanced", order: 2 },
  "budgets"       => { title: "Budgets",      parent: "Advanced", order: 3 },
  "cancellation"  => { title: "Cancellation", parent: "Advanced", order: 4 },
  "sandbox"       => { title: "Sandbox",      parent: "Advanced", order: 5 },

  "configuration" => { title: "Configuration", parent: "Reference", order: 1 },
  "deploy"        => { title: "Deploy",        parent: "Reference", order: 2 },
  "conventions"   => { title: "Conventions",   parent: "Reference", order: 3 },

  "why-silas"     => { title: "Why Silas",    parent: "About", order: 1 },
  "vs-eve"        => { title: "Silas vs eve", parent: "About", order: 2 }
}.freeze

root = File.expand_path("..", __dir__)
site = __dir__

sources = Dir[File.join(root, "docs", "*.md")].to_h { |f| [File.basename(f, ".md"), f] }
sources["deploy"] = File.join(root, "DEPLOY.md")

missing = sources.keys - NAV.keys
abort "assemble.rb: no NAV entry for docs page(s): #{missing.join(', ')}" if missing.any?

sources.each do |slug, path|
  meta = NAV.fetch(slug)
  front = +"---\ntitle: \"#{meta[:title]}\"\n"
  front << "parent: #{meta[:parent]}\n" if meta[:parent]
  front << "nav_order: #{meta[:order]}\n---\n\n"
  File.write(File.join(site, "#{slug}.md"), front + File.read(path))
end

FileUtils.mkdir_p(File.join(site, "assets"))
%w[silas-mark.svg silas-wordmark.svg silas-favicon.svg].each do |asset|
  FileUtils.cp(File.join(root, "brand", asset), File.join(site, "assets", asset))
end

puts "assembled #{sources.size} pages + #{3} assets"
