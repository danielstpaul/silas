require "yaml"

module Silas
  # A schedule is a TRIGGER: it fires on a cron cadence and starts a normal,
  # fully-durable turn. Two forms (eve's shapes):
  #   .md with cron frontmatter — "task mode": the body becomes the turn input,
  #     output discarded (fire-and-forget).
  #   .rb subclassing Silas::Schedule::Handler — programmatic control (fan-out,
  #     continue an existing session, conditional start).
  #
  # Identity is the filesystem path under app/agent/schedules (subdirs included):
  # schedules/billing/sweep.rb -> "billing/sweep" -> Agent::Schedules::Billing::Sweep.
  # Named agents own their schedules the same way they own tools and skills:
  # app/agents/analyst/schedules/monday_kpis.md -> "agents/analyst/monday_kpis",
  # and its ticks start THAT agent — a staff member's cron never wakes the root
  # agent. Schedules are NOT model-visible capabilities, so they never enter
  # the definitions digest — adding or removing one cannot diverge an
  # in-flight turn.
  class Schedule
    KINDS = %i[task handler].freeze

    attr_reader :name, :cron, :queue, :kind, :payload, :agent_name

    def initialize(name:, cron:, queue:, kind:, payload:, agent_name: nil)
      @name = name
      @cron = cron
      @queue = queue
      @kind = kind
      @payload = payload
      @agent_name = agent_name
    end

    def self.parse(path, root:)
      agents_dir = root.join("app/agents")
      if path.to_s.start_with?("#{agents_dir}#{File::SEPARATOR}")
        parse_named(path, agents_dir: agents_dir)
      else
        rel = path.relative_path_from(root.join("app/agent/schedules"))
        name = rel.sub_ext("").to_s
        case path.extname
        when ".md" then from_markdown(name, path)
        when ".rb"
          const = "Agent::Schedules::" + name.split("/").map(&:camelize).join("::")
          from_handler(name, const.constantize)
        end
      end
    end

    # app/agents/<agent>/schedules/<rel> — the "agents/" name prefix keeps
    # names (and therefore recurring keys) collision-free against a root
    # schedule that happens to share the path shape.
    def self.parse_named(path, agents_dir:)
      rel = path.relative_path_from(agents_dir)          # analyst/schedules/monday_kpis.md
      agent = rel.each_filename.first
      sched = rel.relative_path_from(Pathname(agent).join("schedules")).sub_ext("").to_s
      name = "agents/#{agent}/#{sched}"
      case path.extname
      when ".md" then from_markdown(name, path, agent_name: agent)
      when ".rb"
        const = "Agents::#{agent.camelize}::Schedules::" + sched.split("/").map(&:camelize).join("::")
        from_handler(name, const.constantize, agent_name: agent)
      end
    end

    def self.from_markdown(name, path, agent_name: nil)
      content = File.read(path)
      # Tolerate leading whitespace/blank lines (e.g. an ERB comment in a
      # generator template renders to an empty first line).
      if content.sub(/\A\s+/, "") =~ /\A---\s*\n(.*?)\n---\s*\n(.*)\z/m
        frontmatter = YAML.safe_load(Regexp.last_match(1)) || {}
        body = Regexp.last_match(2)
      else
        frontmatter = {}
        body = content
      end
      cron = frontmatter["cron"] || frontmatter["schedule"]
      raise Error, "schedule #{name}: missing `cron:` frontmatter" if cron.nil?

      new(name: name, cron: cron.to_s, queue: (frontmatter["queue"] || Silas.config.queue_name).to_s,
          kind: :task, payload: body.strip, agent_name: agent_name)
    end

    def self.from_handler(name, klass, agent_name: nil)
      unless klass.ancestors.include?(Schedule::Handler)
        raise Error, "#{klass} (schedule #{name}) must inherit Silas::Schedule::Handler"
      end
      cron = klass.cron
      raise Error, "schedule #{name}: handler must declare `cron` or `every`" if cron.nil?

      new(name: name, cron: cron, queue: (klass.queue || Silas.config.queue_name).to_s,
          kind: :handler, payload: klass, agent_name: agent_name)
    end

    # The only behavioural difference between the two forms. A named agent's
    # task starts THAT agent (its tools, instructions, digest — the loop swaps
    # the scope in for every turn of the session it creates).
    def trigger!
      case kind
      when :task
        owner = agent_name ? Silas.agent(agent_name) : Silas.agent
        owner.start(input: payload, metadata: { "trigger" => "schedule", "schedule" => name })
      when :handler
        payload.new(schedule: self).call
      end
    end

    def recurring_key = "silas_schedule_#{name.tr('/', '_')}"

    def recurring_entry
      { "class" => "Silas::ScheduleJob", "args" => [ name ], "schedule" => cron, "queue" => queue }
    end

    # Base class for .rb handler schedules.
    class Handler
      class << self
        def cron(expr = nil)
          expr ? @schedule_expr = expr.to_s : @schedule_expr
        end

        def every(expr)
          @schedule_expr = "every #{expr}"
        end

        def queue(name = nil)
          name ? @queue = name.to_s : @queue
        end
      end

      attr_reader :schedule

      def initialize(schedule:)
        @schedule = schedule
      end

      def call
        raise NotImplementedError, "#{self.class}#call"
      end
    end
  end
end
