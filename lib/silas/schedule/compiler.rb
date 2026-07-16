require "yaml"

module Silas
  class Schedule
    # Discovery alone doesn't schedule anything: Solid Queue's scheduler reads
    # config/recurring.yml at its own boot, and a running scheduler can't be
    # appended to cleanly. So `bin/rails silas:schedules` compiles the discovered
    # schedules into recurring.yml as a reviewable git diff — cron that fires
    # real side effects stays explicit.
    #
    # Merge is key-scoped: only `silas_schedule_*` keys are managed. Hand-written
    # entries (e.g. silas_dead_job_rescuer) are preserved.
    module Compiler
      module_function

      MANAGED_PREFIX = "silas_schedule_".freeze

      # { recurring_key => entry_hash } for the given schedules.
      def render(schedules)
        schedules.sort_by(&:name).to_h { |s| [ s.recurring_key, s.recurring_entry ] }
      end

      # Merge managed entries into recurring.yml under `env`, preserving
      # everything else. Returns the written YAML string.
      def write!(schedules, root:, env: "production")
        path = root.join("config/recurring.yml")
        doc = path.exist? ? (YAML.safe_load(path.read) || {}) : {}
        doc[env] ||= {}
        # Drop stale managed keys, then merge current ones.
        doc[env].reject! { |k, _| k.to_s.start_with?(MANAGED_PREFIX) }
        doc[env].merge!(render(schedules))
        doc[env] = doc[env].sort.to_h
        yaml = YAML.dump(doc)
        path.write(yaml)
        yaml
      end

      # Names present as files but not compiled into recurring.yml (and vice
      # versa) — the doctor for `silas:schedules:list`.
      def drift(schedules, root:, env: "production")
        path = root.join("config/recurring.yml")
        compiled = path.exist? ? ((YAML.safe_load(path.read) || {}).dig(env) || {}) : {}
        compiled_keys = compiled.keys.select { |k| k.to_s.start_with?(MANAGED_PREFIX) }
        discovered_keys = schedules.map(&:recurring_key)
        {
          uncompiled: schedules.reject { |s| compiled_keys.include?(s.recurring_key) }.map(&:name),
          orphaned: compiled_keys - discovered_keys
        }
      end
    end
  end
end
