#!/usr/bin/env ruby
# Assembles the docs-site sources. The markdown source of record is ../docs
# (shipped inside the gem, frontmatter-free); this script copies each page in
# and prepends the just-the-docs nav frontmatter + an SEO description, so the
# site gets grouped navigation and per-page meta without the gem's files
# carrying site metadata. Also emits llms-full.txt (every doc concatenated,
# answer-engine food; llms.txt is the curated index).
#
# Run from site/ (locally and in CI): ruby assemble.rb
#
# A docs/*.md file with no NAV entry FAILS the build on purpose — add the
# page here when you add it there, or the site would silently omit it.

require "fileutils"

NAV = {
  "tutorial"      => { title: "Tutorial", order: 2,
                       desc: "Build a durable refund-desk agent in Rails, one Silas primitive per chapter — tools, evals, schedules, Slack, memory, staff, deploy." },
  "guarantees"    => { title: "Guarantees", order: 3,
                       desc: "What Silas actually guarantees: exactly-once tool effects, in-doubt parking, crash-safe turns — and the kill -9 chaos harness that verifies each claim." },

  "tools"         => { title: "Tools & approvals", parent: "Core", order: 1,
                       desc: "Silas tools: one file per tool, keyword signature as the schema, three effect modes (transactional, at-most-once, idempotent), and approval policies that hold risky calls for a person." },
  "agents"        => { title: "Agents & staff",    parent: "Core", order: 2,
                       desc: "The root agent, named agents with their own tools and schedules, subagent delegation, and durable handoffs between staff." },
  "memory"        => { title: "Memory",            parent: "Core", order: 3,
                       desc: "Approval-gated agent memory: subject-attribute-content triples with provenance and supersession, injected per turn, private or shared." },
  "channels"      => { title: "Channels",          parent: "Core", order: 4,
                       desc: "Bind Slack and email to the durable loop, with approve/decline from either — and generate a signature-verifying webhook for any other transport." },
  "inbox-and-api" => { title: "Inbox & API",       parent: "Core", order: 5,
                       desc: "The mounted operator inbox (live traces, approval cards, audit trail, cost) and the same surface over JSON with SSE streaming and structured answers." },
  "headless"      => { title: "Headless",          parent: "Core", order: 6,
                       desc: "Run the durable runtime with no screens of ours: drive approve, decline and answer from your own UI via the model API, and mount the inbox as an engine-room audit surface behind staff auth." },

  "connections"   => { title: "Connections",  parent: "Advanced", order: 1,
                       desc: "Remote MCP servers as one YAML file each: namespaced tools under the same ledger, credential paths (never secrets), https enforced for auth." },
  "evals"         => { title: "Evals",        parent: "Advanced", order: 2,
                       desc: "Deterministic agent evals: script the model's decisions, run the real ledger and real tools, assert on the durable transcript — a keyless deploy gate." },
  "budgets"       => { title: "Budgets",      parent: "Advanced", order: 3,
                       desc: "Per-turn caps on steps, tokens, dollars, and active wall-clock. Breaches park the turn for a human top-up instead of destroying work." },
  "cancellation"  => { title: "Cancellation", parent: "Advanced", order: 4,
                       desc: "What cancel means mid-flight: parked turns settle immediately, running turns honor the flag at the next step boundary." },
  "sandbox"       => { title: "Sandbox",      parent: "Advanced", order: 5,
                       desc: "Code execution off by default; an interim Docker seam; microVM-class isolation via the hermetic gem, with the trust axis visible." },

  "configuration" => { title: "Configuration", parent: "Reference", order: 1,
                       desc: "Every Silas.configure option with its default — adapter, compaction, approvals, memory, inbox, API, evals, sandbox — plus the fail-loud boot guards." },
  "providers"     => { title: "Providers & gateways", parent: "Reference", order: 2,
                       desc: "Run Silas agents on any provider RubyLLM speaks — Anthropic direct, OpenRouter's 300+ model catalog with one key, OpenAI-compatible gateways like LiteLLM and Vercel AI Gateway, Bedrock, Vertex AI, Azure, and local runtimes." },
  "deploy"        => { title: "Deploy",        parent: "Reference", order: 3,
                       desc: "Deploying Silas apps with Kamal: the worker contract, the rescuer, worker liveness, and the operational lessons from the chaos harness." },
  "conventions"   => { title: "Conventions",   parent: "Reference", order: 4,
                       desc: "The contracts the UI and API keep, including the held/clear UI labels over unchanged database states." },

  "why-silas"     => { title: "Why Silas",    parent: "About", order: 1,
                       desc: "Build agents the way you build Rails apps — and get exactly-once effects, holds at zero compute, and crash-safe turns no external runtime can offer." },
  "vs-eve"        => { title: "Silas vs eve", parent: "About", order: 2,
                       desc: "An honest, date-stamped comparison of Silas and Vercel's eve: same authoring idea, different homes, and where each goes further." }
}.freeze

root = File.expand_path("..", __dir__)
site = __dir__

sources = Dir[File.join(root, "docs", "*.md")].to_h { |f| [ File.basename(f, ".md"), f ] }
sources["deploy"] = File.join(root, "DEPLOY.md")

missing = sources.keys - NAV.keys
abort "assemble.rb: no NAV entry for docs page(s): #{missing.join(', ')}" if missing.any?

sources.each do |slug, path|
  meta = NAV.fetch(slug)
  front = +"---\ntitle: \"#{meta[:title]}\"\n"
  front << "description: \"#{meta[:desc]}\"\n" if meta[:desc]
  front << "parent: #{meta[:parent]}\n" if meta[:parent]
  front << "nav_order: #{meta[:order]}\n---\n\n"
  File.write(File.join(site, "#{slug}.md"), front + File.read(path))
end

# llms-full.txt: the whole docs surface as one plain-text file for answer
# engines and coding agents that want everything in a single fetch.
full = +"# silas — full documentation\n\n"
full << "> Concatenation of every silas doc. Curated index: llms.txt\n\n"
ordered = %w[tutorial guarantees tools agents memory channels inbox-and-api
             headless connections evals budgets cancellation sandbox
             configuration providers deploy conventions why-silas vs-eve]
ordered.each do |slug|
  full << "\n\n---\n\n" << File.read(sources.fetch(slug))
end
File.write(File.join(site, "llms-full.txt"), full)

FileUtils.mkdir_p(File.join(site, "assets"))
%w[silas-mark.svg silas-wordmark.svg silas-favicon.svg].each do |asset|
  FileUtils.cp(File.join(root, "brand", asset), File.join(site, "assets", asset))
end

puts "assembled #{sources.size} pages + llms-full.txt (#{full.bytesize} bytes) + 3 assets"
