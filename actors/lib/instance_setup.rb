#
# Copyright (c) 2009 RightScale Inc
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

class InstanceSetup

  include Nanite::Actor

  expose :report_state

  # Number of seconds to wait before switching to offline mode
  RECONNECT_GRACE_PERIOD = 30

  # Boot if and only if instance state is 'booting'
  #
  # === Parameters
  # agent_identity<String>:: Serialized agent identity for current agent
  def initialize(agent_identity)
    @boot_retries = 0
    @agent_identity = agent_identity
    RightScale::InstanceState.init(agent_identity)
    EM.threadpool_size = 1
    # Schedule boot sequence, don't run it now so agent is registered first
    EM.next_tick { init_boot } if RightScale::InstanceState.value == 'booting'
  end

  # Retrieve current instance state
  #
  # === Return
  # state<RightScale::OperationResult>:: Success operation result containing instance state
  def report_state
    state = RightScale::OperationResult.success(RightScale::InstanceState.value)
  end

  # Handle deconnection notification from broker
  # Start timer to give the amqp gem some time to retry connecting
  #
  # === Parameters
  # status<Symbol>:: Connection status, one of :connected or :deconnected
  #
  # === Return
  # true:: Always return true
  def connection_status(status)
    if status == :deconnected
      @offline_timer ||= EM::Timer.new(RECONNECT_GRACE_PERIOD) { RightScale::RequestForwarder.enable_offline_mode }
    else
      # Cancel offline timer if there was one
      if @offline_timer
        @offline_timer.cancel
        @offline_timer = nil
      end
      RightScale::RequestForwarder.disable_offline_mode
    end
    true
  end

  protected

  # We start off by setting the instance 'r_s_version' in the core site and
  # then proceed with the actual boot sequence
  #
  # === Return
  # true:: Always return true
  def init_boot
    request("/booter/set_r_s_version", { :agent_identity => @agent_identity, :r_s_version => 6 }) do |r|
      res = RightScale::OperationResult.from_results(r)
      strand("Failed to set_r_s_version", res) unless res.success?
      enable_managed_login
    end
    true
  end

  # Enable managed SSH for this instance, then continue with boot. Ensures that
  # managed SSH users can login to troubleshoot stranded and other 'interesting' events
  #
  # === Return
  # true:: Always return true
  def enable_managed_login
    request('/booter/get_login_policy', {:agent_identity => @agent_identity}) do |r|
      res = RightScale::OperationResult.from_results(r)

      if res.success?
        policy  = res.content
        auditor = RightScale::AuditorProxy.new(policy.audit_id)
        begin
          audit = RightScale::LoginManager.instance.update_policy(policy)
          auditor.create_new_section("Managed login enabled")
          auditor.append_info(audit)
        rescue Exception => e
          auditor.create_new_section('Failed to enable managed login')
          auditor.append_error("Error applying policy: #{e.message}")
          RightScale::RightLinkLog.error("#{e.class.name}: #{e.message}\n#{e.backtrace.join("\n")}")
        end
      else
        RightScale::RightLinkLog.error("Could not get login policy: #{res.content}")
      end

      boot
    end
  end

  # Retrieve software repositories and configure mirrors accordingly then proceed to
  # retrieving and running boot bundle.
  #
  # === Return
  # true:: Always return true
  def boot
    request("/booter/get_repositories", @agent_identity) do |r|
      res = RightScale::OperationResult.from_results(r)
      if res.success?
        reps = res.content.repositories
        @auditor = RightScale::AuditorProxy.new(res.content.audit_id)
        audit = "Using the following software repositories:\n"
        reps.each { |rep| audit += "  - #{rep.to_s}\n" }
        @auditor.create_new_section("Software repositories configured")
        @auditor.append_info(audit)
        configure_repositories(reps)
        prepare_boot_bundle do |prep_res|
          if prep_res.success?
            run_boot_bundle(prep_res.content) do |boot_res|
              if boot_res.success?
                RightScale::InstanceState.value = 'operational'
              else
                strand("Failed to run boot sequence", boot_res)
              end
            end
          else
            strand("Failed to retrieve missing inputs", prep_res)
          end
        end
      else
        strand("Failed to retrieve software repositories", res)
      end
    end
    true
  end

  # Log error to local log file and set instance state to stranded
  #
  # === Parameters
  # msg<String>:: Error message that will be audited and logged
  # res<RightScale::OperationResult>:: Operation result with additional information
  #
  # === Return
  # true:: Always return true
  def strand(msg, res)
    RightScale::InstanceState.value = 'stranded'
    msg += ": #{res.content}" if res.content
    @auditor.append_error(msg) if @auditor
    true
  end

  # Configure software repositories
  # Note: the configurators may return errors when the platform is not what they expect,
  # for now log error and keep going (to replicate legacy behavior).
  #
  # === Parameters
  # repositories<Array[<RepositoryInstantiation>]>:: repositories to be configured
  #
  # === Return
  # true:: Always return true
  def configure_repositories(repositories)
    repositories.each do |repo|
      begin
        klass = repo.name.to_const
        unless klass.nil?
          fz = nil
          if repo.frozen_date
            # gives us date for yesterday since the mirror for today may not have been generated yet
            fz = (Date.parse(repo.frozen_date) - 1).to_s
            fz.gsub!(/-/,"")
          end
          klass.generate("none", repo.base_urls, fz)
        end
      rescue Exception => e
        RightScale::RightLinkLog.error(e.message)
      end
    end
    if system('which apt-get')
      ENV['DEBIAN_FRONTEND'] = 'noninteractive' # this prevents prompts
      @auditor.append_output(`apt-get update 2>&1`)
    end
    true
  end

  # Retrieve missing inputs if any
  #
  # === Block
  # Calls given block passing in one argument of type RightScale::OperationResult
  # The argument contains either a failure with associated message or success
  # with the corresponding boot bundle.
  #
  # === Return
  # true:: Always return true
  def prepare_boot_bundle(&cb)
    query_tags(:agent_ids => @agent_identity) do |res|
      RightScale::InstanceState.startup_tags = res.results
      options = { :agent_identity => @agent_identity, :audit_id => @auditor.audit_id }
      request("/booter/get_boot_bundle", options) do |r|
        res = RightScale::OperationResult.from_results(r)
        if res.success?
          bundle = res.content
          if bundle.executables.any? { |e| !e.ready }
            retrieve_missing_inputs(bundle) { cb.call(RightScale::OperationResult.success(bundle)) }
          else
            yield RightScale::OperationResult.success(bundle)
          end
        else
          msg = "Failed to retrieve boot scripts"
          msg += ": #{res.content}" if res.content
          yield RightScale::OperationResult.error(msg)
        end
      end
    end
  end

  # Retrieve missing inputs for recipes and RightScripts stored in
  # @recipes and @scripts respectively, update recipe attributes, RightScript
  # parameters and ready fields (set ready field to true if attempt was successful,
  # false otherwise).
  # This is for environment variables that we are waiting on.
  # Retries forever.
  #
  # === Block
  # Continuation block, will be called once attempt to retrieve attributes is completed
  #
  # === Return
  # true:: Always return true
  def retrieve_missing_inputs(bundle, &cb)
    scripts = bundle.executables.select { |e| e.is_a?(RightScale::RightScriptInstantiation) }
    recipes = bundle.executables.select { |e| e.is_a?(RightScale::RecipeInstantiation) }
    scripts_ids = scripts.select { |s| !s.ready }.map { |s| s.id }
    recipes_ids = recipes.select { |r| !r.ready }.map { |r| r.id }
    RightScale::RequestForwarder.request('/booter/get_missing_attributes', { :agent_identity => @agent_identity,
                                                                             :scripts_ids    => scripts_ids,
                                                                             :recipes_ids    => recipes_ids }) do |r|
      res = RightScale::OperationResult.from_results(r)
      if res.success?
        res.content.each do |e|
          if e.is_a?(RightScale::RightScriptInstantiation)
            if script = scripts.detect { |s| s.id == e.id }
              script.ready = true
              script.parameters = e.parameters
            end
          else
            if recipe = recipes.detect { |s| s.id == e.id }
              recipe.ready = true
              recipe.attributes = e.attributes
            end
          end
        end
        pending_executables = bundle.executables.select { |e| !e.ready }
        if pending_executables.empty?
          yield
        else
          titles = pending_executables.map { |e| RightScale::RightScriptsCookbook.recipe_title(e.nickname) }
          @auditor.append_info("Missing inputs for #{titles.join(", ")}, waiting...")
          sleep(20)
          retrieve_missing_inputs(bundle, &cb)
        end
      else
        strand("Failed to retrieve missing inputs", res)
      end
    end
  end

  # Retrieve and run boot scripts
  #
  # === Return
  # true:: Always return true
  def run_boot_bundle(bundle)
    # Force full converge on boot so that Chef state gets persisted
    bundle.full_converge = true
    sequence = RightScale::ExecutableSequence.new(bundle)
    sequence.callback do
      EM.next_tick do
        yield RightScale::OperationResult.success
      end
    end
    sequence.errback  do
      EM.next_tick do
        yield RightScale::OperationResult.error("Failed to run boot bundle")
      end
    end

    # We want to be able to use Chef providers which use EM (e.g. so they can use RightScale::popen3), this means
    # that we need to synchronize the chef thread with the EM thread since providers run synchronously. So create
    # a thread here and run the sequence in it. Use EM.next_tick to switch back to EM's thread.
    EM.defer { sequence.run }
    
    true
  end

end
