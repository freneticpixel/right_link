# TODO figure out what to require for 'minimal' RightLink activation

# A namespace that will someday hold all RightLink functionality. For now, it
# holds a few module methods that are broadly useful across the RightLink
# codebase.
module RightLink
  # @return [Array] ordered list of agent root dirs, suitable for configuring AgentConfig.root_dir
  def self.default_root_dirs
    # RightLink certs are written at enrollment time, and live in the
    # 'certs' subdir of the RightLink agent state dir.
    os_root_dir  = File.join(AgentConfig.agent_state_dir)

    # RightLink actors and the agent init directory are both packaged into the RightLink gem,
    # as subdirectories of the gem base directory (siblings of 'lib' and 'bin' directories).
    gem_root_dir = Gem.loaded_specs['right_link'].full_gem_path

    [os_root_dir, gem_root_dir]
  end
end