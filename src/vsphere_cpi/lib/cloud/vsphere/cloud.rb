require 'cloud/vsphere/logger'
require 'json'
require 'membrane'
require 'cloud'
require 'cloud/vsphere/cpi_extension'

module VSphereCloud
  class Cloud < Bosh::Cloud
    include VimSdk
    include Logger

    class TimeoutException < StandardError; end
    class NetworkException < StandardError
      attr_accessor :vm_cid

      def message
        super + (vm_cid ? " for VM '#{vm_cid}'" : '')
      end
    end

    attr_accessor :client
    attr_reader :config, :datacenter, :heartbeat_thread, :pbm

    def enable_telemetry
      http_client = VSphereCloud::CpiHttpClient.new
      other_client = VCenterClient.new(
        vcenter_api_uri: @config.vcenter_api_uri,
        http_client: http_client
      )
      other_client.define_singleton_method(:logger) do
        @logger ||= ::Logger.new('/dev/null')
      end
      other_client.login(@config.vcenter_user, @config.vcenter_password, 'en')
      option = Vim::Option::OptionValue.new
      option.key = 'config.SDDC.cpi'
      option.value = 'true'
      other_client.service_content.setting.query_view(option.key)
    rescue => e
      return unless e.fault.is_a?(Vim::Fault::InvalidName)
      other_client.service_content.setting.update_values([option]) rescue nil
    ensure
      other_client.logout rescue nil
    end

    def replace_certs_keys_with_temp_files(nsxt_config)
      if nsxt_config.auth_private_key
        # Configure private key and cert if provided.
        @certificate_file = Tempfile.open('auth_certificate') do |f|
          f << nsxt_config.auth_certificate; f
        end

        @auth_private_key_file = Tempfile.open('auth_private_key') do |f|
          f << nsxt_config.auth_private_key; f
        end

        # Re write values to file paths rather than direct certs.
        nsxt_config.auth_private_key = @auth_private_key_file.path
        nsxt_config.auth_certificate = @certificate_file.path
      end
      nsxt_config
    end

    def initialize(options)
      @config = Config.build(options)

      Logger.logger = config.logger

      if request_id = options['vcenters'][0]['request_id']
        Logger.logger.set_request_id(request_id)
      end

      @http_client = VSphereCloud::CpiHttpClient.new(@config.soap_log)

      @client = VCenterClient.new(
        vcenter_api_uri: @config.vcenter_api_uri,
        http_client: @http_client
      )
      @client.login(@config.vcenter_user, @config.vcenter_password, 'en')

      @cloud_searcher = CloudSearcher.new(@client.service_content)
      @cluster_provider = Resources::ClusterProvider.new(
        datacenter_name: @config.datacenter_name,
        client: @client
      )
      @datacenter = Resources::Datacenter.new(
        client: @client,
        ephemeral_pattern: @config.datacenter_datastore_pattern,
        persistent_pattern: @config.datacenter_persistent_datastore_pattern,
        use_sub_folder: @config.datacenter_use_sub_folder,
        vm_folder: @config.datacenter_vm_folder,
        template_folder: @config.datacenter_template_folder,
        name: @config.datacenter_name,
        disk_path: @config.datacenter_disk_path,
        clusters: @config.datacenter_clusters,
        cluster_provider: @cluster_provider
      )
      @file_provider = FileProvider.new(
        client: @client,
        http_client: @http_client,
        vcenter_host: @config.vcenter_host
      )
      @agent_env = AgentEnv.new(
        client: client,
        file_provider: @file_provider,
      )

      VMAttributeManager.init(@client.service_content.custom_fields_manager)

      @pbm = VSphereCloud::Pbm.new(pbm_api_uri: @config.pbm_api_uri, http_client: @http_client, vc_cookie: @client.soap_stub.vc_cookie)

      if @config.nsxt_enabled?

        nsxt_config =  replace_certs_keys_with_temp_files(@config.nsxt)

        nsxt_client = NSXTApiClientBuilder::build_api_client(nsxt_config, logger)

        # Setup NSX-T Provider
        @nsxt_provider = NSXTProvider.new(nsxt_client, @config.nsxt.default_vif_type, @client, @datacenter)

        @switch_provider = NSXTSwitchProvider.new(nsxt_client)

        @router_provider = NSXTRouterProvider.new(nsxt_client)

        @ip_block_provider = NSXTIpBlockProvider.new(nsxt_client)

        # Create Policy API Client
        nsxt_policy_client = NSXTPolicyApiClientBuilder::build_policy_api_client(nsxt_config, logger)

        @nsxt_policy_provider = NSXTPolicyProvider.new(nsxt_policy_client, @config.nsxt.default_vif_type)
      end

      # Initialize tagging tagger object
      tag_client = TaggingTag::AttachTagToVm.InitializeConnection(@config, logger)
      @tagging_tagger = TaggingTag::AttachTagToVm.new(tag_client)

      # We get disconnected if the connection is inactive for a long period.
      @heartbeat_thread = Thread.new do
        while true do
          sleep(60)
          @client.service_instance.current_time
        end
      end

      setup_at_exit
    end

    def setup_at_exit
      # HACK: finalizer not getting called, so we'll rely on at_exit
      at_exit do
        begin
          @client.logout
        rescue VSphereCloud::VCenterClient::NotLoggedInException
        end
      end
    end

    def has_vm?(vm_cid)
      vm_provider.find(vm_cid)
      true
    rescue Bosh::Clouds::VMNotFound
      false
    end

    def has_disk?(raw_director_disk_cid)
      director_disk_cid = DirectorDiskCID.new(raw_director_disk_cid)
      @datacenter.find_disk(director_disk_cid)
      true
    rescue Bosh::Clouds::DiskNotFound
      false
    end

    def create_stemcell(image, _)
      with_thread_name("create_stemcell(#{image}, _)") do
        # Add cpi telemetry advanced config to vc in a separate thread
        telemetry_thread = Thread.new { enable_telemetry }
        VCPIExtension.create_cpi_extension(client)
        result = nil
        Dir.mktmpdir do |temp_dir|
          logger.info("Extracting stemcell to: #{temp_dir}")
          output = `tar -C #{temp_dir} -xzf #{image} 2>&1`
          raise "Corrupt image '#{image}', tar exit status: #{$?.exitstatus}, output: #{output}" if $?.exitstatus != 0

          ovf_file = Dir.entries(temp_dir).find { |entry| File.extname(entry) == '.ovf' }
          raise "Missing OVF for stemcell '#{image}'" if ovf_file.nil?
          ovf_file = File.join(temp_dir, ovf_file)

          name = "sc-#{SecureRandom.uuid}"
          logger.info("Generated name: #{name}")

          stemcell_size = File.size(image) / (1024 * 1024)
          vm_type = VmType.new(@datacenter, {'ram' => 0}, @pbm)

          # TODO: this code re-use is messy, extract the necessary functionality out of vm_config
          manifest_params = {
            vm_type: vm_type,
            global_clusters: @datacenter.clusters,
            disk_configurations: [
              VSphereCloud::DiskConfig.new(
                size: stemcell_size,
                target_datastore_pattern: @datacenter.ephemeral_pattern,
                ephemeral: true
              )
            ],
          }
          vm_config = VmConfig.new(
            manifest_params: manifest_params
          )

          vm_config.cluster_placements.each do |cluster_placement|
            cluster = cluster_placement.cluster
            datastore_name = cluster_placement.disk_placement.name
            datastore = @datacenter.find_datastore(datastore_name)
            #encryption_policy = @pbm.find_policy(@config.vm_encryption_policy_name) if @config.vm_encryption_policy_name

            logger.info("Deploying to: #{cluster.mob} / #{datastore.mob}")

            import_spec_result = import_ovf(name, ovf_file, cluster.resource_pool.mob, datastore.mob)

            system_disk = import_spec_result.import_spec.config_spec.device_change.find do |change|
              change.device.kind_of?(Vim::Vm::Device::VirtualDisk)
            end
            system_disk.device.backing.thin_provisioned = @config.vcenter_default_disk_type == 'thin'

            # if encryption policy is set, apply encryption policy to Stemcell VM and system_disk
            # if encryption_policy
            #   logger.info("Using encryption policy: #{@config.vm_encryption_policy_name}")
            #   profile_spec = Resources::VM.create_profile_spec(encryption_policy)
            #   import_spec_result.import_spec.config_spec.vm_profile = [profile_spec]
            #   system_disk.profile = [profile_spec]
            # end

            lease_obtainer = LeaseObtainer.new(@cloud_searcher)
            nfc_lease = lease_obtainer.obtain(
              cluster.resource_pool,
              import_spec_result.import_spec,
              @datacenter.template_folder,
            )

            logger.info('Uploading')
            vm = upload_ovf(ovf_file, nfc_lease, import_spec_result.file_item)
            # Under what conditions it can be nil and do we need to retry necessarily after that?
            next if vm.nil?
            result = name

            logger.info('Removing NICs')
            devices = @cloud_searcher.get_property(vm, Vim::VirtualMachine, 'config.hardware.device', ensure_all: true)
            config = Vim::Vm::ConfigSpec.new
            config.device_change = []

            nics = devices.select { |device| device.kind_of?(Vim::Vm::Device::VirtualEthernetCard) }
            nics.each do |nic|
              nic_config = Resources::VM.create_delete_device_spec(nic)
              config.device_change << nic_config
            end

            # add extension managed by info to config spec only if extension exists
            if @client.service_content.extension_manager.find_extension(
              VCPIExtension::DEFAULT_VSPHERE_CPI_EXTENSION_KEY) then
              managed_by_info = VimSdk::Vim::Ext::ManagedByInfo.new
              managed_by_info.extension_key = VCPIExtension::DEFAULT_VSPHERE_CPI_EXTENSION_KEY
              managed_by_info.type =  VCPIExtension::DEFAULT_VSPHERE_MANAGED_BY_INFO_RESOURCE
              config.managed_by = managed_by_info
            end

            client.reconfig_vm(vm, config)

            logger.info('Taking initial snapshot')

            # Despite the naming, this has nothing to do with the Cloud notion of a disk snapshot
            # (which comes from AWS). This is a vm snapshot.
            client.wait_for_task do
              vm.create_snapshot('initial', nil, false, false)
            end
            break
          end
        end
        telemetry_thread.join #Join back the thread created to enable telemetry
        result
      end
    end

    def delete_stemcell(stemcell)
      with_thread_name("delete_stemcell(#{stemcell})") do
        Bosh::ThreadPool.new(max_threads: 32, logger: logger).wrap do |pool|
          logger.info("Looking for stemcell replicas in: #{@datacenter.name}")
          matches = client.find_all_stemcell_replicas(@datacenter.mob, stemcell)

          matches.each do |sc|
            sc_name = sc.name
            logger.info("Found: #{sc_name}")
            pool.process do
              logger.info("Deleting: #{sc_name}")
              client.delete_vm(sc)
              logger.info("Deleted: #{sc_name}")
            end
          end

        end
      end
    end

    def stemcell_vm(name)
      matches = client.find_all_stemcell_replicas(@datacenter.mob, name)
      if matches.nil?
        return nil
      else
        matches[0]
      end
    end

    def create_vm(agent_id, stemcell_cid, vm_type, networks_spec, existing_disk_cids = [], environment = nil)
      with_thread_name("create_vm(#{agent_id}, ...)") do
        verify_props('VM', [ 'cpu', 'ram', 'disk' ], vm_type)

        stemcell_vm = stemcell_vm(stemcell_cid)
        raise "Could not find VM for stemcell '#{stemcell_cid}'" if stemcell_vm.nil?
        begin
          stemcell_size = @cloud_searcher.get_property(
            stemcell_vm,
            VimSdk::Vim::VirtualMachine,
            'summary.storage.committed',
            ensure_all: true
          )
          stemcell_size /= 1024 * 1024

          vm_type = VmType.new(@datacenter, vm_type, @pbm)
          disk_configs, policy_name = disk_configurations(vm_type, existing_disk_cids)
          manifest_params = {
            vm_type: vm_type,
            networks_spec: networks_spec,
            agent_id: agent_id,
            agent_env: environment,
            stemcell: {
              cid: stemcell_cid,
              size: stemcell_size
            },
            global_clusters: @datacenter.clusters,
            disk_configurations: disk_configs,
            storage_policy: policy_name,
            enable_human_readable_name: config.human_readable_name_enabled?
          }

          if config.human_readable_name_enabled?
            manifest_params.update(human_readable_name_info: update_name_info_from_bosh_env(environment))
          end

          vm_config = VmConfig.new(
            manifest_params: manifest_params,
            cluster_provider: @cluster_provider
          )

          #TODO refactor this so that manifest related params are moved to manifest_params hash
          # eg. upgrade_hw_version, default_disk_type, anti_affinity_drs_rules
          vm_creator = VmCreator.new(
            client: @client,
            cloud_searcher: @cloud_searcher,
            cpi: self,
            datacenter: @datacenter,
            agent_env: @agent_env,
            tagging_tagger: @tagging_tagger,
            default_disk_type: @config.vcenter_default_disk_type,
            enable_auto_anti_affinity_drs_rules: @config.vcenter_enable_auto_anti_affinity_drs_rules,
            stemcell: Stemcell.new(stemcell_cid),
            upgrade_hw_version: @config.upgrade_hw_version,
            pbm: @pbm,
          )
          created_vm = vm_creator.create(vm_config)
        rescue => e
          logger.error("Error in creating vm: #{e}, Backtrace - #{e.backtrace.join("\n")}")
          raise e
        end

        begin
          if @config.nsxt_enabled?
            ns_groups = vm_type.ns_groups || []
            if @config.nsxt.use_policy_api?
              @nsxt_policy_provider.add_vm_to_groups(created_vm, ns_groups)
            else
              if vm_type.nsxt_server_pools
                #For static server pools add vm as server pool member
                #For dynamic server pools add vm to the corresponding nsgroup
                static_server_pools, dynamic_server_pools = @nsxt_provider.retrieve_server_pools(vm_type.nsxt_server_pools)
                lb_ns_groups = dynamic_server_pools.map { |server_pool| server_pool.member_group.grouping_object.target_display_name } if dynamic_server_pools
                logger.info("NSGroup names corresponding to load balancer's dynamic server pools are: #{lb_ns_groups}")
                ns_groups.concat(lb_ns_groups) if lb_ns_groups
                @nsxt_provider.add_vm_to_server_pools(created_vm, static_server_pools) if static_server_pools
              end
              @nsxt_provider.add_vm_to_nsgroups(created_vm, ns_groups)
              @nsxt_provider.set_vif_type(created_vm, vm_type.nsxt)
            end
          end
        rescue => e
          logger.info("Failed to apply NSX properties to VM '#{created_vm.cid}' with error: #{e.message}")
          begin
            logger.info("Deleting VM '#{created_vm.cid}'...")
            delete_vm(created_vm.cid)
          rescue => ex
            logger.info("Failed to delete VM '#{created_vm.cid}' with message: #{ex.inspect}")
          end
          raise e
        end

        begin

          if @config.nsx_enabled?
            all_nsx_security_groups = Set.new

            # Gather all security groups from three sources into a Set
            # 1. VM Type
            # 2. BOSH Groups
            # 3. NSX Load Balancers

            # VM Type
            vm_type_security_group = vm_type.nsx_security_groups
            all_nsx_security_groups.merge(vm_type_security_group) unless vm_type_security_group.nil?

            # BOSH Group
            bosh_groups_security_groups = (environment || {}).fetch('bosh', {}).fetch('groups', [])
            all_nsx_security_groups.merge(bosh_groups_security_groups) unless bosh_groups_security_groups.nil?

            # Load Balancer
            unless vm_type.nsx_lbs.nil?
              nsx_lbs_security_groups = vm_type.nsx_lbs.map { |m| m['security_group'] }
              all_nsx_security_groups.merge(nsx_lbs_security_groups.compact)
            end

            # Add vm to security groups
            all_nsx_security_groups.each do |security_group|
              nsx.add_vm_to_security_group(security_group, created_vm.mob_id)
            end

            # Add vm to load balancer
            unless vm_type.nsx_lbs.nil? || vm_type.nsx_lbs.empty?
              nsx.add_members_to_lbs(vm_type.nsx_lbs)
            end
          end

        rescue => e
          logger.info("Failed to apply NSX properties to VM '#{created_vm.cid}' with error: #{e}")
          begin
            logger.info("Deleting VM '#{created_vm.cid}'...")
            delete_vm(created_vm.cid)
          rescue => ex
            logger.info("Failed to delete vm '#{created_vm.cid}' with message:  #{ex.inspect}")
          end
          raise e
        end

        created_vm.cid
      end
    end

    def instant_clone_vm(agent_id, vm_cid, cloud_properties, networks_spec, existing_disk_cids = [], environment = nil)
      with_thread_name("instant_clone_vm(#{agent_id}, ...)") do
        vm = vm_provider.find(vm_cid)
        raise "Could not find VM to instant clone from '#{vm_cid}'" if vm.nil?

        new_vm_cid = "vm-#{SecureRandom.uuid}"
        begin
          relocation_spec = Vim::Vm::RelocateSpec.new
          relocation_spec.datastore = vm.mob.datastore[0]
          relocation_spec.pool = vm.mob.resource_pool
          relocation_spec.folder = @datacenter.vm_folder.mob

          # We ending up with the same number of nics as the original VM, so we probably don't need this?
          #
          # networks_map = {}
          # networks_spec.each_value do |network_spec|
          #   cloud_properties = network_spec['cloud_properties']
          #   unless cloud_properties.nil? || cloud_properties['name'].nil?
          #     name = cloud_properties['name']
          #     networks_map[name] ||= []
          #     networks_map[name] << network_spec['ip']
          #   end
          # end
          # networks_map
          #
          # networks_map.each do |network_name, ips|
          #   network = @client.find_network_retryably(@datacenter, network_name)
          #   ips.each do |_|
          #     virtual_nic = Resources::Nic.create_virtual_nic(
          #         @cloud_searcher,
          #         network_name,
          #         network,
          #         vm.pci_controller.key,
          #         {}
          #     )
          #     nic_config = Resources::VM.create_add_device_spec(virtual_nic)
          #     relocation_spec.device_change << nic_config
          #   end
          # end

          instant_clone_spec = Vim::Vm::InstantCloneSpec.new
          instant_clone_spec.location = relocation_spec
          instant_clone_spec.name = new_vm_cid

          created_vm_mob = @client.wait_for_task do
            vm.mob.instant_clone(instant_clone_spec)
          end

          created_vm = Resources::VM.new(new_vm_cid, created_vm_mob, @client)

          vm_type = VmType.new(@datacenter, cloud_properties, @pbm)
          network_env = generate_network_env(created_vm.devices, networks_spec, {})
          disk_env = generate_disk_env(created_vm.system_disk, created_vm.ephemeral_disk, vm_type)
          env = generate_agent_env(new_vm_cid, created_vm.mob, agent_id, network_env, disk_env)
          env['env'] = environment

          datastore = Resources::Datastore.build_from_client(@client, vm.mob.datastore)
          location = {
              datacenter: @datacenter.name,
              datastore: datastore[0],
              vm: new_vm_cid,
          }

          @agent_env.create_env(created_vm.mob, location, env)
        rescue => e
          logger.error("Error in creating vm: #{e}, Backtrace - #{e.backtrace.join("\n")}")
          raise e
        end

        new_vm_cid
      end
    end

    def calculate_vm_cloud_properties(vm_properties)
      required_properties = ['ram', 'cpu', 'ephemeral_disk_size']
      missing_properties = required_properties.reject { |name| vm_properties.has_key?(name) }
      raise "Missing VM cloud properties: #{missing_properties.map{ |sym| "'#{sym}'"}.join(', ')}" unless missing_properties.empty?
      vm_properties['disk'] = vm_properties.delete 'ephemeral_disk_size'
      vm_properties
    end

    def delete_vm(vm_cid)
      with_thread_name("delete_vm(#{vm_cid})") do
        logger.info("Deleting vm: #{vm_cid}")

        vm = vm_provider.find(vm_cid)
        vm_ip = vm.mob.guest&.ip_address

        # find vm_groups vm is part of before deleting it
        cluster = vm.mob.runtime.host&.parent #host can be nil if vm is not running
        if cluster
          groups = cluster.configuration_ex.group
          vm_groups = groups.select do |group|
            group.is_a?(VimSdk::Vim::Cluster::VmGroup) && group.vm.include?(vm.mob)
          end
          vm_group_names = vm_groups.map(&:name)
        end
        vm.power_off

        persistent_disks = vm.persistent_disks
        unless persistent_disks.empty?
          vm.detach_disks(persistent_disks)
        end

        # Delete env.iso and VM specific files managed by the director
        @agent_env.clean_env(vm.mob) if vm.cdrom

        if @config.nsxt_enabled?
          # POLICY API
          # @TA : TODO : Verify if we can delete logical ports that are still attached to VM.
          if @config.nsxt.use_policy_api?
            # TA: TODO : Should this be rescued? We should fail if we do not delete membership
            # NSX-T group might not work properly if junk is left behind.
            # Rescuing because we rescued earlier too in manager API
            begin
              @nsxt_policy_provider.remove_vm_from_groups(vm)
            rescue => e
              logger.info("Failed to remove VM from Groups with message #{e.message}")
              raise e
            end
          # MANAGER API
          else
            begin
              @nsxt_provider.remove_vm_from_nsgroups(vm)
            rescue => e
              logger.info("Failed to remove VM from NSGroups: #{e.message}")
            end
            begin
              @nsxt_provider.remove_vm_from_server_pools(vm_ip)
            rescue => e
              logger.info("Failed to remove VM from ServerPool: #{e.message}")
            end
          end
        end

        vm.delete
        logger.info("Deleted vm: #{vm_cid}")

        # Delete vm_groups
        unless vm_group_names.nil? || vm_group_names.empty?
          vm_group = VSphereCloud::VmGroup.new(client, cluster)
          vm_group.delete_vm_groups(vm_group_names)
        end
      end
    end

    def reboot_vm(vm_cid)
      with_thread_name("reboot_vm(#{vm_cid})") do
        vm = vm_provider.find(vm_cid)

        logger.info("Reboot vm = #{vm_cid}")

        unless vm.powered_on?
          logger.info("VM not in POWERED_ON state. Current state : #{vm.power_state}")
        end

        begin
          vm.reboot
        rescue => e
          logger.error("Soft reboot failed #{e} -#{e.backtrace.join("\n")}")
          logger.info('Try hard reboot')

          # if we fail to perform a soft-reboot we force a hard-reboot
          vm.power_off if vm.powered_on?

          vm.power_on
        end
      end
    end

    def set_vm_metadata(vm_cid, metadata)
      with_thread_name("set_vm_metadata(#{vm_cid}, ...)") do
        vm = vm_provider.find(vm_cid)
        metadata.each do |name, value|
          client.set_custom_field(vm.mob, name, value)
        end
        if @config.nsxt_enabled?
          unless @config.nsxt.use_policy_api?
            @nsxt_provider.update_vm_metadata_on_logical_ports(vm, metadata)
          end
       end
      end
    end


    def set_disk_metadata(disk_id, metadata)
      # not implemented
    end

    def resize_disk(disk_id, new_size)
      raise Bosh::Clouds::NotImplemented, 'resize_disk has not been implemented'
    end

    def configure_networks(vm_cid, networks)
      raise Bosh::Clouds::NotSupported, 'configure_networks is no longer supported'
    end

    def attach_disk(vm_cid, raw_director_disk_cid)
      with_thread_name("attach_disk(#{vm_cid}, #{raw_director_disk_cid})") do
        director_disk_cid = DirectorDiskCID.new(raw_director_disk_cid)
        vm = vm_provider.find(vm_cid)
        disk_to_attach = @datacenter.find_disk(director_disk_cid, vm)

        disk_config = VSphereCloud::DiskConfig.new(
          cid: disk_to_attach.cid,
          size: disk_to_attach.size_in_mb,
          existing_datastore_name: disk_to_attach.datastore.name,
          target_datastore_pattern: director_disk_cid.target_datastore_pattern || @datacenter.persistent_pattern
        )

        logger.debug("Gathering storage placement accessible from VM: #{vm_cid}")
        accessible_datastores = vm.accessible_datastores

        disk_is_accessible = accessible_datastores.include?(disk_config.existing_datastore_name)

        disk_is_in_target_datastore = disk_config.existing_datastore_name =~ Regexp.new(disk_config.target_datastore_pattern)

        unless disk_is_accessible && disk_is_in_target_datastore
          # Create a new disk selection pipeline with a gathering block.
          pipeline = DiskPlacementSelectionPipeline.new(disk_config.size,
            disk_config.target_datastore_pattern,
            disk_config.existing_datastore_name) do
            logger.info("Gathering storage placement resources for disk allocator pipeline")
            accessible_datastores.values
          end.with_filter do |storage_placement|
            logger.debug("Filter #{storage_placement.name} for accessibility")
            storage_placement.accessible?
          end
          storage_placement_enum = pipeline.each
          storage_placement = storage_placement_enum.first
          raise "Unable to attach disk to the VM. There is no datastore matching pattern or required space available for disk to move" if storage_placement.nil?
          destination_datastore = @datacenter.find_datastore(storage_placement.name)
          disk_to_attach = @datacenter.move_disk_to_datastore(disk_to_attach, destination_datastore)
        end

        disk_spec = vm.attach_disk(disk_to_attach)
        # Overwrite cid with the director cid
        # Since director sends messages with "director cid" to agent, the agent needs that ID in its env, not the clean_cid
        add_disk_to_agent_env(vm, director_disk_cid, disk_spec.device.unit_number)
      end
    end

    def detach_disk(vm_cid, raw_director_disk_cid)
      with_thread_name("detach_disk(#{vm_cid}, #{raw_director_disk_cid})") do
        director_disk_cid = DirectorDiskCID.new(raw_director_disk_cid)

        logger.info("Detaching disk: #{director_disk_cid.value} from vm: #{vm_cid}")

        vm = vm_provider.find(vm_cid)
        disk = vm.disk_by_cid(director_disk_cid.value)
        raise Bosh::Clouds::DiskNotAttached.new(true), "Disk '#{director_disk_cid.value}' is not attached to VM '#{vm_cid}'" if disk.nil?

        vm.detach_disks([disk])
        delete_disk_from_agent_env(vm, director_disk_cid)
      end
    end

    def create_disk(size_in_mb, cloud_properties, vm_cid = nil)
      with_thread_name("create_disk(#{size_in_mb}, _)") do
        logger.info("Cloud properties given : #{cloud_properties}")
        logger.info("Creating disk with size: #{size_in_mb}")
        # Create a disk pool to hold possible datastores
        disk_pool = DiskPool.new(@datacenter,  cloud_properties['datastores'])

        # Get a persistent disk pattern from disk pools. Storage pod names are handled inside this function.
        target_datastore_pattern = StoragePicker.choose_persistent_pattern(disk_pool)

        disk_type = cloud_properties.fetch('type', @config.vcenter_default_disk_type)

        # Create a new disk selection pipeline with a gathering block.
        # Specific filters are pre-defined in the constructor itself
        # Criteria Object for filter passed in the constructor is a hash of size and pattern.
        pipeline = DiskPlacementSelectionPipeline.new(size_in_mb, target_datastore_pattern) do
          logger.info("Gathering storage placement resources for disk allocator pipeline")
          if vm_cid
            logger.debug("Gathering storage placement accessible from VM CID: #{vm_cid}")
            vm = vm_provider.find(vm_cid)
            accessible_datastores = vm.accessible_datastores
          else
            logger.debug("Gathering storage placement accessible from datacenter")
            accessible_datastores = @datacenter.accessible_datastores
          end
          accessible_datastores.values
        end.with_filter do |storage_placement|
          logger.debug("Filter #{storage_placement.name} for accessibility")
          storage_placement.accessible?
        end

        # For each possible placement try to create a disk
        pipeline.each do |storage_placement|
          datastore = storage_placement

          logger.info("Trying to create persistent disk on datastore: #{datastore.name}")
          disk = @datacenter.create_disk(datastore, size_in_mb, disk_type)
          next if disk.nil?

          logger.info("Created disk: #{disk.inspect}")
          raw_director_disk_cid = disk_pool.storage_list.any? ? DirectorDiskCID.encode(disk.cid, target_datastore_pattern: target_datastore_pattern) : disk.cid
          # Return disk cid for the created disk.
          return raw_director_disk_cid
        end
        raise "Unable to create disk on any storage entity provided. Possible errors can be no free space, datastore in maintenance mode or datastores are not accessible by any host"
      end
    end

    def delete_disk(raw_director_disk_cid)
      with_thread_name("delete_disk(#{raw_director_disk_cid})") do
        director_disk_cid = DirectorDiskCID.new(raw_director_disk_cid)
        logger.info("Deleting disk: #{director_disk_cid.value}")
        disk = @datacenter.find_disk(director_disk_cid)
        client.delete_disk(@datacenter.mob, disk.path)

        logger.info('Finished deleting disk')
      end
    end

    def generate_network_env(devices, networks, dvs_index)
      nics = {}

      devices.each do |device|
        next unless device.kind_of?(Vim::Vm::Device::VirtualEthernetCard)
        v_network_name = case device.backing
          when Vim::Vm::Device::VirtualEthernetCard::DistributedVirtualPortBackingInfo
            network = @datacenter.mob.network.select do |n|
              n.is_a?(VimSdk::Vim::Dvs::DistributedVirtualPortgroup)
            end.select do |n|
              # respond_to?(backing_type) indirectly checks if the VC SDK version
              # is 7.0 as #backing_type is introduced in 7.0 SDK
              n.config.respond_to?(:backing_type) && n.config.backing_type == 'nsx'
            rescue
              next  # Skip a network managed object that disappeared on us
            end.detect do |n|
              n.key == device.backing.port.portgroup_key
            rescue
              next  # Skip a network managed object that disappeared on us
            end

            if network.nil?
              dvs_index[device.backing.port.portgroup_key]
            else
              dvs_index[network.config.logical_switch_uuid]
            end
          when Vim::Vm::Device::VirtualEthernetCard::OpaqueNetworkBackingInfo
            dvs_index[device.backing.opaque_network_id]
          else
            PathFinder.new.path(device.backing.network)
        end
        nics[v_network_name] = (nics.fetch(v_network_name, []) << device)
      end

      network_env = {}
      networks.each do |network_name, network|
        network_entry = network.dup
        v_network_name = network['cloud_properties']['name']
        network = nics[v_network_name]
        raise NetworkException, "Could not find network '#{v_network_name}'" if network.nil?
        nic = network.pop
        network_entry['mac'] = nic.mac_address
        network_env[network_name] = network_entry
      end
      network_env
    end

    def generate_disk_env(system_disk, ephemeral_disk, vm_config)

      # When disk.enableUUID is true on the vmx options, consistent volume IDs are requested, and we can use them
      # to ensure the precise ephemeral volume is mounted.   This is mandatory for
      # cases where multiple SCSI controllers are present on the VM, as is common with Kubernetes VMs.
      if vm_config.vmx_options && vm_config.vmx_options['disk.enableUUID'] == "1"
        logger.info("Using ephemeral disk UUID #{ephemeral_disk.backing.uuid.downcase}")
        {
          'system' => system_disk.unit_number.to_s,
          'ephemeral' => { 'id' => ephemeral_disk.backing.uuid.downcase }, 
          'persistent' => {}
        }
      else
        ephemeral_disk_size = ephemeral_disk.nil? ? '0': ephemeral_disk.unit_number.to_s
        logger.info("Using ephemeral disk unit number #{ephemeral_disk_size}")
        {
          'system' => system_disk.unit_number.to_s,
          'ephemeral' => ephemeral_disk_size,
          'persistent' => {}
        }
      end
    end

    def generate_agent_env(name, vm, agent_id, networking_env, disk_env)
      vm_env = {
        'name' => name,
        'id' => vm.__mo_id__
      }

      env = {}
      env['vm'] = vm_env
      env['agent_id'] = agent_id
      env['networks'] = networking_env
      env['disks'] = disk_env
      env.merge!(config.agent)
      env
    end

    def clone_vm(vm, name, folder, resource_pool, options={})
      relocation_spec = Vim::Vm::RelocateSpec.new
      relocation_spec.datastore = options[:datastore] if options[:datastore]
      if options[:linked]
        relocation_spec.disk_move_type = Vim::Vm::RelocateSpec::DiskMoveOptions::CREATE_NEW_CHILD_DISK_BACKING
      end
      relocation_spec.pool = resource_pool
      relocation_spec.host = options[:host] unless options[:host].nil?

      clone_spec = Vim::Vm::CloneSpec.new
      clone_spec.config = options[:config] if options[:config]
      clone_spec.location = relocation_spec
      clone_spec.power_on = options[:power_on] ? true : false
      clone_spec.snapshot = options[:snapshot] if options[:snapshot]
      clone_spec.template = false
      vm.clone(folder, name, clone_spec)
    end

    # This method is used by micro bosh deployment cleaner
    def get_vms
      subfolders = []
      with_thread_name('get_vms') do
        logger.info("Looking for VMs in: #{@datacenter.name} - #{@datacenter.master_vm_folder.path}")
        subfolders += @datacenter.master_vm_folder.mob.child_entity
        logger.info("Looking for Stemcells in: #{@datacenter.name} - #{@datacenter.master_template_folder.path}")
        subfolders += @datacenter.master_template_folder.mob.child_entity
      end
      mobs = subfolders.map { |folder| folder.child_entity }.flatten
      mobs.map do |mob|
        VSphereCloud::Resources::VM.new(mob.name, mob, @client)
      end
    end

    def ping
      'pong'
    end

    def vm_provider
      VMProvider.new(@datacenter, @client)
    end

    def nsx
      return @nsx if @nsx

      @config.validate_nsx_options

      nsx_http_client = NsxHttpClient.new(
        @config.nsx_user,
        @config.nsx_password,
        @config.soap_log,
      )
      @nsx = NSX.new(@config.nsx_url, nsx_http_client)
    end

    def cleanup
      @heartbeat_thread.terminate
      @client.logout
      rescue VSphereCloud::VCenterClient::NotLoggedInException
    end

    def info
      {'stemcell_formats' =>  ['vsphere-ovf', 'vsphere-ova']}
    end

    def create_network(network_definition)
      network_model = NetworkDefinition.new(network_definition)
      raise 'NSXT must be enabled in CPI to use create_network' unless @config.nsxt_enabled?
      network = Network.new(@switch_provider, @router_provider, @ip_block_provider)
      network.create(network_model)
    end

    def delete_network(switch_id)
      raise 'NSXT must be enabled in CPI to use delete_network' unless @config.nsxt_enabled?
      network = Network.new(@switch_provider, @router_provider, @ip_block_provider)
      network.destroy(switch_id)
    end

    private

    def import_ovf(name, ovf, resource_pool, datastore)
      import_spec_params = Vim::OvfManager::CreateImportSpecParams.new
      import_spec_params.entity_name = name
      import_spec_params.locale = 'US'
      import_spec_params.deployment_option = ''

      ovf_file = File.open(ovf)
      ovf_descriptor = ovf_file.read
      ovf_file.close

      @client.service_content.ovf_manager.create_import_spec(ovf_descriptor,
                                                             resource_pool,
                                                             datastore,
                                                             import_spec_params)
    end

    def upload_ovf(ovf, lease, file_items)
      info = @cloud_searcher.get_property(lease, Vim::HttpNfcLease, 'info', ensure_all: true)
      lease_updater = LeaseUpdater.new(client, lease)

      info.device_url.each do |device_url|
        device_key = device_url.import_key
        file_items.each do |file_item|
          if device_key == file_item.device_id
            disk_file_path = File.join(File.dirname(ovf), file_item.path)
            disk_file = File.open(disk_file_path)
            disk_file_size = File.size(disk_file_path)

            progress_thread = Thread.new do
              loop do
                lease_updater.progress = disk_file.pos * 100 / disk_file_size
                sleep(2)
              end
            end

            logger.info("Uploading disk to: #{device_url.url}")

            @file_provider.upload_file_to_url(device_url.url,
                             disk_file,
                             { 'Content-Type' => 'application/x-vnd.vmware-streamVmdk' })

            progress_thread.kill
            disk_file.close
          end
        end
      end
      lease_updater.finish
      info.entity
    end

    def get_vm_env_datastore(vm)
      cdrom = @client.get_cdrom_device(vm.mob)
      vm.accessible_datastores[cdrom.backing.datastore.name]
    end

    def add_disk_to_agent_env(vm, director_disk_cid, device_unit_number)
      env = @agent_env.get_current_env(vm.mob, @datacenter.name)

      env['disks']['persistent'][director_disk_cid.raw] = device_unit_number.to_s

      # For VMs with multiple SCSI controllers, as is common in Kubernetes workers, 
      # it is mandatory that disk.enableUUID is set in the VMX options / extra config of the VM to ensure 
      # that disk mounting can be performed unambigously.   This is typically set as part of a VM extension.
      # Using the relative device unit number (see above), which is the traditional vSphere CPI disk identifier, 
      # only presumes a single SCSI controller.   The BOSH agent however does not distinguish SCSI controllers using
      # this method of volume identification, which can lead to ambiguous mounts, and thus failed agent bootstraps or data loss.
      # The BOSH agent already supports volume UUID identification, which is used below for unambiguous
      # BOSH disk association.   


      if vm.disk_uuid_is_enabled?
        # We have to query the VIM API to learn the freshly attached disk UUID. We must also pick the specific
        # BOSH-managed independent persistent disk and avoid any non-BOSH peristent disks.  Also due to Linux
        # filsystem case-sensitivity, ensure that the UUID is downcased as VIM returns it upper case.
        disk = vm.disk_by_cid(director_disk_cid.value)
        uuid = disk.backing.uuid.downcase
        logger.info("adding disk to env, disk.enableUUID is TRUE, using volume uuid #{uuid} for mounting")
        env['disks']['persistent'][director_disk_cid.raw] = {"id" => uuid}
      else
        logger.info("adding disk to env, disk.enableUUID is FALSE, using relative device number #{device_unit_number.to_s} for mounting")
      end

      location = { datacenter: @datacenter.name, datastore: get_vm_env_datastore(vm), vm: vm.cid }
      @agent_env.set_env(vm.mob, location, env)
    end

    def delete_disk_from_agent_env(vm, director_disk_cid)
      env = @agent_env.get_current_env(vm.mob, @datacenter.name)
      location = { datacenter: @datacenter.name, datastore: get_vm_env_datastore(vm), vm: vm.cid }

      if env['disks']['persistent'][director_disk_cid.raw]
        env['disks']['persistent'].delete(director_disk_cid.raw)

        @agent_env.set_env(vm.mob, location, env)
      end
    end

    def verify_props(type, required_properties, properties)
      for prop in required_properties
        if properties[prop].nil?
          raise "Must specify '#{prop}' in #{type} cloud properties."
        end
      end
    end

    #returns disk_configuration for existing_disks and ephemeral_disk
    def disk_configurations(vm_type, existing_disk_cids=[])
      #existing persistent disk configurations
      disk_configurations = existing_disk_cids.map do |cid|
        directory_disk_cid = DirectorDiskCID.new(cid)
        disk = @datacenter.find_disk(directory_disk_cid)
        VSphereCloud::DiskConfig.new(
          cid: disk.cid,
          size: disk.size_in_mb,
          existing_datastore_name: disk.datastore.name,
          target_datastore_pattern: directory_disk_cid.target_datastore_pattern || @datacenter.persistent_pattern
        )
      end
      #ephemeral disk configuration
      ephemeral_pattern, policy_name = StoragePicker.choose_ephemeral_pattern(config, vm_type)
      ephemeral_disk_config = VSphereCloud::DiskConfig.new(
        size: vm_type.disk,
        ephemeral: true,
        target_datastore_pattern: ephemeral_pattern
      )
      disk_configurations.push(ephemeral_disk_config)
      return disk_configurations, policy_name
    end

    # An alias to {VSphereCloud::Cloud}'s get name information from bosh environment method
    # @param environment [Hash] the BOSH environment setting information
    #  [Array<String>, nil] return a array with 2 strings inside if there are both instance group name and deployment name
    #   or a nil otherwise
    def update_name_info_from_bosh_env(environment)
      return nil if environment.nil?
      instance_group_name = environment.dig('bosh', 'groups', 2)
      deployment_name = environment.dig('bosh', 'groups', 1)
      return nil if instance_group_name.nil? || deployment_name.nil?
      OpenStruct.new(inst_grp: instance_group_name, deployment: deployment_name)
    end
  end
end
