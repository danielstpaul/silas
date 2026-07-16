module Silas
  # A flat markdown playbook with a description: frontmatter key — the
  # description is advertised to the model; the body loads on demand via the
  # load_skill tool (eve's progressive-disclosure mechanism).
  Skill = Data.define(:name, :description, :path) do
    def self.parse(path)
      content = File.read(path)
      description =
        if content =~ /\A---\s*\n(.*?)\n---\s*\n/m
          Regexp.last_match(1)[/^description:\s*(.+)$/, 1].to_s.strip
        else
          ""
        end
      new(name: File.basename(path, ".md"), description: description, path: path.to_s)
    end

    def body
      File.read(path).sub(/\A---\s*\n.*?\n---\s*\n/m, "")
    end
  end
end
