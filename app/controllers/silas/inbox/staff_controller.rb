module Silas
  module Inbox
    # The roster: every agent this deployment runs — the root agent, the named
    # staff discovered on disk, and any agent that only exists as history
    # (sessions whose directory has since been deleted, marked as such rather
    # than hidden). One card per agent; the record page behind it.
    class StaffController < BaseController
      def index
        @roster = roster
        session_ids_by_agent = Silas::Session.group(:agent_name).count
        @session_counts = session_ids_by_agent
        @held_counts = Silas::ToolInvocation.joins(turn: :session)
                                            .where(approval_state: "required")
                                            .group("silas_sessions.agent_name").count
        @active_counts = Silas::Turn.joins(:session)
                                    .where(status: Silas::Turn::ACTIVE_STATUSES)
                                    .group("silas_sessions.agent_name").count
        @last_activity = Silas::Session.group(:agent_name).maximum(:updated_at)
      end

      def show
        @name = params[:name].to_s
        return head :not_found unless roster.key?(@name)

        @scope = Silas.named_agent_scopes[@name]
        @on_disk = roster.fetch(@name)
        @definitions = definitions_for(@name)
        @tools = @definitions.map { |d| [ d, tool_facts(@name, d["name"]) ] }
        @cost = Silas::Inbox::Cost.for_agent(@name)
        @memories = memories_for(@name)
        @sessions = Silas::Session.where(agent_name: @name).order(id: :desc)
                                  .limit(20).includes(:turns, :parent_session)
        @pending_counts = Silas::ToolInvocation.joins(:turn)
                                               .where(approval_state: "required",
                                                      silas_turns: { session_id: @sessions.map(&:id) })
                                               .group("silas_turns.session_id").count
        @instructions = instructions_for(@name)
      end

      private

      # name => still on disk? The root agent is always "agent"; named agents
      # come from app/agents/; history-only names come from sessions.
      def roster
        on_disk = [ "agent", *Silas.named_agent_scopes.keys ]
        historical = Silas::Session.distinct.pluck(:agent_name)
        (on_disk | historical).sort.index_with { |name| on_disk.include?(name) }
      end

      def definitions_for(name)
        return Array(Silas.named_agent_scopes[name]&.definitions) unless name == "agent"

        Silas.tool_definitions
      end

      # Effect mode and approval policy, read from the class — the two facts
      # an operator needs per tool, resolved through the agent's OWN scope so
      # a staff tool answers as itself.
      def tool_facts(name, tool_name)
        resolver = name == "agent" ? Silas.tool_resolver : Silas.named_agent_scopes[name]&.resolver
        tool = resolver&.call(tool_name)
        { effect_mode: tool.respond_to?(:effect_mode) ? tool.effect_mode.to_s : "at_most_once",
          approval: approval_label(tool) }
      rescue StandardError
        { effect_mode: "?", approval: "?" }
      end

      def approval_label(tool)
        policy = tool.respond_to?(:approval_policy) ? tool.approval_policy : :never
        policy.is_a?(Proc) ? "graded (lambda)" : policy.to_s
      end

      def memories_for(name)
        return [] unless Silas.memory_enabled?

        Silas::Memory.active.where(agent_name: name).order(id: :desc).limit(10)
      end

      def instructions_for(name)
        dir = if name == "agent"
                Silas.instructions_dir || Rails.root.join("app/agent")
        else
                Silas.named_agent_scopes[name]&.dir
        end
        path = dir && Pathname(dir).join("instructions.md")
        path&.exist? ? path.read : nil
      end
    end
  end
end
