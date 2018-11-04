# -------------------------------------------------------------------------- #
# Copyright 2002-2018, OpenNebula Project, OpenNebula Systems                #
#                                                                            #
# Licensed under the Apache License, Version 2.0 (the "License"); you may    #
# not use this file except in compliance with the License. You may obtain    #
# a copy of the License at                                                   #
#                                                                            #
# http://www.apache.org/licenses/LICENSE-2.0                                 #
#                                                                            #
# Unless required by applicable law or agreed to in writing, software        #
# distributed under the License is distributed on an "AS IS" BASIS,          #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.   #
# See the License for the specific language governing permissions and        #
# limitations under the License.                                             #
#--------------------------------------------------------------------------- #
require 'rexml/document'

# This class parses and wraps the information in the Driver action data
class OpenNebulaVM
    attr_reader :xml, :vm_id, :vm_name, :sysds_id, :ds_path, :rootfs_id

    #---------------------------------------------------------------------------
    # Class Constructor
    #---------------------------------------------------------------------------
    def initialize(xml)
		@xml = XMLElement.new_s(xml)
        @xml = @xml.element('//VM')

        @vm_id    = @xml['//TEMPLATE/VMID']
        @sysds_id = @xml['//HISTORY_RECORDS/HISTORY/DS_ID']
        
        @vm_name  = @xml['//DEPLOY_ID']
        @vm_name  = "one-#{@vm_id}" if @vm_name.empty?

        return if wild?

        # Sets the Datastore Path for the Container disks
        disk = @xml.element('//TEMPLATE/DISK')

		if disk
            source = disk['SOURCE']
            ds_id  = disk['DATASTORE_ID']

            @ds_path = source.split("#{ds_id}/")[0].chomp
        else
            @ds_path = ''
        end

        # Sets the DISK ID of the root filesystem
        @rootfs_id = '0'
        boot_order = @xml['//TEMPLATE/OS/BOOT']
        @rootfs_id = boot_order.split(',')[0][-1] if !boot_order.empty?
    end

    def has_context?
        !@xml['//TEMPLATE/CONTEXT/DISK_ID'].empty?
    end

    def wild?
        @vm_name && !@vm_name.include?('one-')
    end

    #Returns a Hash representing the LXC configuration for this OpenNebulaVM
    def to_lxc
        lxc = Hash.new

        lxc['name'] = @vm_name

        lxc['config']  = {}
        lxc['devices'] = {}

        profile(lxc)
        memory(lxc['config'])
        cpu(lxc['config'])
        extra_config(lxc['config'])
        network(lxc['devices'])
        storage(lxc['devices']) unless wild?

        return lxc
    end

	#---------------------------------------------------------------------------
	# Container Attribute Mapping
	#---------------------------------------------------------------------------
	# Creates a dictionary for LXD containing $MEMORY RAM allocated
	def memory(hash)
		hash['limits.memory'] = "#{@xml['//TEMPLATE/MEMORY']}MB"
	end

	# Creates a dictionary for LXD  $CPU percentage and cores
	def cpu(hash)
		cpu = @xml['//TEMPLATE/CPU']
		hash['limits.cpu.allowance'] = "#{(cpu.to_f * 100).to_i}%"

		vcpu = @xml['//TEMPLATE/VCPU']
		hash['limits.cpu'] = vcpu unless vcpu.empty?
	end

	#---------------------------------------------------------------------------
	# Container Device Mapping: Networking
	#---------------------------------------------------------------------------
    # Get nic by mac
    def get_nic_by_mac(mac)
        nics = @xml.elements('//TEMPLATE/NIC')

        nics.each { |n| 
            return n if n['MAC'] == mac
        }
    end

    # Sets up the network interfaces configuration in devices
    def network(hash)
        nics = @xml.elements('//TEMPLATE/NIC')

        nics.each { |n| 
            hash.update(nic(n))
        }
    end

	# Creates a nic hash from NIC xml root
	def nic(info)
		eth = { 
            'name'      => "eth#{info['NIC_ID']}", 
            'host_name' => info['TARGET'],
            'parent'    => info['BRIDGE'], 
            'hwaddr'    => info['MAC'],
            'nictype'   => 'bridged', 
            'type'      => 'nic'
		}

        nic_map = {
            'limits.ingress' => 'INBOUND_AVG_BW',
            'limits.egress'  => 'OUTBOUND_AVG_BW'
        }

        io_map(nic_map, eth, info){ |v| "#{v.to_i * 8}kbit" }

		{ "eth#{info['NIC_ID']}" => eth }
	end

	#---------------------------------------------------------------------------
	# Container Device Mapping: Storage
	#---------------------------------------------------------------------------
    # Get disk by target
    def get_disk_by_target(target)
        disks = @xml.elements('//TEMPLATE/DISK')

        disks.each { |n| 
            return n if n['TARGET'] == target
        }
    end

    def get_disks
        @xml.elements('//TEMPLATE/DISK')
    end

    # Sets up the storage devices configuration in devices
    def storage(hash)
        disks = @xml.elements('DISK')

        disks.each { |n| 
            hash.update(disk(n))
        }

        context(hash)
    end

    # Generate Context information
    def context(hash)
        cid = @xml['//TEMPLATE/CONTEXT/DISK_ID']

        return if cid.empty?

        source = "#{@ds_path}/#{@sysds_id}/#{@vm_id}/mapper/disk.#{cid}"

        hash['context'] = {
            'type'   => 'disk',
            'source' => source,
            'path'   => '/context'
        }
    end

	# Creates a disk hash from DISK xml element
    def disk(info)
        disk_id = info['DISK_ID']
        disk    = {}

        #-----------------------------------------------------------------------
        # Source & Path attributes
        #-----------------------------------------------------------------------
        if disk_id == @rootfs_id
            disk = { 'type' => 'disk', 'path' => '/', 'pool' => 'default' }
        else
            source = LXDriver.device_path(self, info, 'mapper/')

            path = info['TARGET']
            path = "/media/#{disk_id}" unless path[0] == '/'

            disk = { 'type' => 'disk', 'source' => source, 'path' => path }
        end
   
        #-----------------------------------------------------------------------
        # Readonly attributes
        #-----------------------------------------------------------------------
        if info['READONLY'].downcase == 'yes'
            disk['readonly'] = 'true'
        else
            disk['readonly'] = 'false'
        end

        #-----------------------------------------------------------------------
        # IO limits
        #-----------------------------------------------------------------------
        tbytes = info['TOTAL_BYTES_SEC']
        tiops  = info['TOTAL_IOPS_SEC']

        if tbytes && !tbytes.empty?
            disk['limits.max'] = tbytes
        elsif tiops && !tiops.empty?
            disk['limits.max'] = "#{tiops}iops"
        end

        if tbyes.empty? && tiops.empty?
            disk_map = {
                'limits.read'  => 'READ_BYTES_SEC',
                'limits.write' => 'WRITE_BYTES_SEC'
            }

            mapped = io_map(disk_map, disk, info){ |v| v }

            if !mapped
                disk_map = {
                    'limits.read'  => 'READ_IOPS_SEC',
                    'limits.write' => 'WRITE_IOPS_SEC'
                }

                io_map(disk_map, disk, info){|v| "#{v}iops" }
            end
        end

        { "disk#{disk_id}" => disk }
    end

	#---------------------------------------------------------------------------
	# Container Mapping: Extra Configuration & Profiles
	#---------------------------------------------------------------------------
    def extra_config(hash)
        security = { 
            'security.privileged' => 'false', 
            'security.nesting'    => 'false' 
        }

        security.each_key do |key|
            item  = "LXD_SECURITY_#{key.split('.').last.swapcase}"

            value = @xml["//USER_TEMPLATE/#{item}"]
            security[key] = value if !value.empty?
        end

        hash.merge!(security)

        raw_data = {}

        data = @xml['//TEMPLATE/RAW/DATA']
        type = @xml['//TEMPLATE/RAW/TYPE']

        if !data.empty? && type.downcase == 'lxd'
            begin
                raw_data = JSON.parse("{#{data}}")
            rescue
            end
        end

        hash.merge!(raw_data) unless raw_data.empty?
    end

    def profile(hash)
        profile = @xml['//USER_TEMPLATE/LXD_PROFILE']
        profile = 'default' if profile.empty?

        hash['profiles'] = [profile]
    end

	#---------------------------------------------------------------------------
	# Container Mapping: Extra Configuration & Profiles
	#---------------------------------------------------------------------------
    def device_info(devices, key, filter)
        devices.each do |device|
            return device[key] if device[key].value?(filter)
        end
    end

    private
    # Maps IO limits from an OpenNebula VM configuration to a LXD configuration
    #   map: Hash that defines LXD name to OpenNebula name mapping
    #   lxd_conf: Hash with LXD configuration
    #   one_conf: XML Element with OpenNebula Configuration
    #
    #   Block: To transform OpenNebula value
    def io_map(map, lxd_conf, one_conf)
        mapped = false

        map.each do |key, value|
            one_value = one_conf[value]

            if !one_value.empty?
                lxd_conf[key] = yield(one_value)

                mapped = true
            end
        end

        return mapped
    end
end

# This class abstracts the access to XML elements. It provides basic methods
# to get elements by their xpath
class XMLElement
    def initialize(xml)
        @xml = xml
    end

    # Create a new XMLElement using a xml document in a string
    def self.new_s(xml_s)
        xml = nil
        xml = REXML::Document.new(xml_s).root unless xml_s.empty?

        new(xml)
    end

    # Gets the text associated to a th element. The element is select by
    # its xpath. If not found an empty string is returned
    def [](key)
        element = @xml.elements[key.to_s]

        return "" if (element && !element.has_text?) || !element
        element.text
    end

    #Return an XMLElement for the given xpath
    def element(key)
        e = @xml.elements[key.to_s]

        element = nil
        element = XMLElement.new(e) if e

        element
    end

    # Get elements by xpath. This function returns an Array of XMLElements
    def elements(key)
        collection = []

        @xml.elements.each(key) { |pelem|
            collection << XMLElement.new(pelem)
        }

        collection
    end
end
