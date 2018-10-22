#!/usr/bin/ruby

require_relative 'lxd_driver'

module LXDriver

    # Container XML to Hash parser
    class XML

        TEMPLATE_PREFIX = '//TEMPLATE/'
        HOTPLUG_PREFIX = 'VMM_DRIVER_ACTION_DATA/'
        USER_TEMPLATE = '//USER_TEMPLATE/'
        CONTEXT = '/context'

        attr_reader :xml, :vm_id, :vm_name, :wild, :sysds_id, :datastores, :rootfs_id

        def initialize(xml_file, root = '')
            @xml = OpenNebula::XMLElement.new
            @xml.initialize_xml(xml_file, root + 'VM')
            @vm_id = single_element('VMID')
            @sysds_id = xml_single_element('//HISTORY_RECORDS/HISTORY/DS_ID')

            deploy_id = xml_single_element('//DEPLOY_ID')
            @vm_name = deploy_id

            @wild = false
            @wild = true unless (deploy_id == '') || deploy_id.include?('one-')
            return if @wild

            @vm_name = 'one-' + @vm_id
            @datastores = datastores
            @rootfs_id = rootfs_id
        end

        # Returns the diskid corresponding to the root device
        def rootfs_id
            # TODO: root partition from BOOT->Root device
            # TODO: Add support when path is /
            bootme = '0'
            boot_order = single_element('OS/BOOT')
            bootme = boot_order.split(',')[0][-1] if boot_order != ''
            bootme
        end

        # gets opennebula datastores path
        def datastores
            disk = complex_element('DISK')
            source = disk['SOURCE']
            ds_id = disk['DATASTORE_ID']
            source.split(ds_id + '/')[0].chomp
        end

        ###############
        #   Mapping   #
        ###############

        # Creates a dictionary for LXD containing $MEMORY RAM allocated
        def memory(hash)
            ram = single_element('MEMORY')
            ram = ram.to_s + 'MB'
            hash['limits.memory'] = ram
        end

        # Creates a dictionary for LXD  $CPU percentage and cores
        def cpu(hash)
            cpu = single_element('CPU')
            cpu = (cpu.to_f * 100).to_i.to_s + '%'
            hash['limits.cpu.allowance'] = cpu

            vcpu = single_element('VCPU')
            hash['limits.cpu'] = vcpu if vcpu
        end

        # Sets up the network interfaces configuration in devices
        def network(hash)
            nics = multiple_elements('NIC')
            nics.each {|nic| hash.update(nic(nic['NIC'])) }
        end

        # Sets up the storage devices configuration in devices
        def storage(hash)
            disks = multiple_elements('DISK')

            # disks
            if disks.length > 1
                disks.each {|d| disks.insert(0, d).uniq if d['ID'] == @rootfs_id }
                disks[1..-1].each {|disk| hash.update(disk(disk['DISK'])) }
            end

            # root
            info = disks[0]['DISK']
            root = { 'type' => 'disk', 'path' => '/', 'pool' => 'default' }
            hash['root'] = root.update(disk_common(info))

            # context
            hash.update(context) if single_element('CONTEXT')
        end

        def extra(hash)
            [security, raw_data].each {|i| hash.update(i) }
        end

        ###############
        #   LXD_raw   #
        ###############

        def profile(hash)
            profile = single_element('LXD_PROFILE', USER_TEMPLATE)
            profile ||= 'default'
            hash['profile'] = profile
        end

        # TODO: Get data from USER_TEMPLATE(current) or TEMPLATE/FEATURES
        def security
            security = { 'security.privileged' => 'false', 'security.nesting' => 'false' }
            security.each_key do |key|
                item = "LXD_SECURITY_#{key.split('.').last.swapcase}"
                sec = single_element(item, USER_TEMPLATE)
                security[key] = sec if sec
            end
            security
        end

        # TODO: test hash values like raw.lxc
        def raw_data
            data = single_element('RAW/DATA')
            return {} unless data

            data.insert(0, '{')
            data.insert(-1, '}')
            JSON.parse(data)
        end

        ###############
        #   Network   #
        ###############

        # Creates a nic hash from NIC xml root
        def nic(info)
            name = 'eth' + info['NIC_ID']
            eth = { 'name' => name, 'host_name' => info['TARGET'],
                    'parent' => info['BRIDGE'], 'hwaddr' => info['MAC'],
                    'nictype' => 'bridged', 'type' => 'nic' }
            { name => eth.update(nic_io(info)) }
        end

        # Returns a hash with QoS NIC values if defined
        def nic_io(info)
            lxdl = %w[limits.ingress limits.egress]
            onel = %w[INBOUND_AVG_BW OUTBOUND_AVG_BW]

            nic_limits = io(lxdl, onel, info)
            nic_limits.each do |key, value|
                nic_limits[key] = nic_unit(value)
            end
            nic_limits
        end

        def nic_unit(limit)
            (limit.to_i * 8).to_s + 'kbit'
        end

        ###############
        #   Storage   #
        ###############

        # Creates the context iso device hash
        def context
            info = complex_element('CONTEXT')
            disk_id = info['DISK_ID']
            source = LXDriver.device_path(self, disk_id, 'mapper/')
            data = disk_basic(source, CONTEXT)
            { 'context' => data }
        end

        def disk(info)
            disk = disk_common(info)
            disk_id = info['DISK_ID']
            source = LXDriver.device_path(self, disk_id, 'mapper/')
            path = info['TARGET'] # TODO: path is TARGET: hda, hdc, hdd
            path = "/media/#{disk_id}" unless path.include?('/')
            { "disk#{disk_id}" => disk.update(disk_basic(source, path)) }
        end

        # Creates the minial disk hash
        def disk_basic(source, path)
            { 'type' => 'disk', 'source' => source, 'path' => path }
        end

        def disk_common(info)
            config = { 'readonly' => 'false' }
            config['readonly'] = 'true' if info['READONLY'] == 'yes'
            config.update(disk_io(info))
        end

        # TODO: TOTAL_IOPS_SEC
        def disk_io(info)
            lxdl = %w[limits.read limits.write limits.max]
            onel = %w[READ_BYTES_SEC WRITE_BYTES_SEC TOTAL_BYTES_SEC]
            io(lxdl, onel, info)
        end

        ###############
        #    Misc     #
        ###############

        # Creates a hash with the keys defined in lxd_keys if the
        # corresponding key in xml_keys with the same index is defined in info
        def keyfexist(lxd_keys, xml_keys, info)
            hash = {}
            0.upto(lxd_keys.length) do |i|
                value = info[xml_keys[i]]
                hash[lxd_keys[i]] = value if value
            end
            hash
        end

        # Maps existing one_limits into lxd_limits
        def io(lxdl, onel, info)
            limits = keyfexist(lxdl, onel, info)
            if limits != {}
                limits.each do |limit, value|
                    limits[limit] = value
                end
            end
            limits
        end

        ###############
        # XML Parsing #
        ###############

        def device_info(devices, key, filter)
            devices.each do |device|
                return device[key] if device[key].value?(filter)
            end
        end

        # Returns PATH's instance in XML
        def xml_single_element(path)
            @xml[path]
        end

        def single_element(path, pre = TEMPLATE_PREFIX)
            xml_single_element(pre + path)
        end

        # Returns an Array with PATH's instances in XML
        def xml_multiple_elements(path)
            elements = []
            @xml.retrieve_xmlelements(path).each {|d| elements.append(d.to_hash) }
            elements
        end

        def multiple_elements(path, pre = TEMPLATE_PREFIX)
            xml_multiple_elements(pre + path)
        end

        def complex_element(path)
            multiple_elements(path)[0][path]
        end

    end

    # Container description hash
    class YAML < Hash

        def initialize(xml)
            self['name'] = xml.vm_name
            self['config'] = {}
            self['devices'] = {}

            xml.memory(self['config'])
            xml.cpu(self['config'])
            xml.profile(self)
            xml.extra(self['config'])
            xml.network(self['devices'])
            xml.storage(self['devices'])
        end

    end

end
