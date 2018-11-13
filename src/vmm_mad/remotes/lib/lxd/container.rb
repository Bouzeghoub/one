#!/usr/bin/ruby

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

$LOAD_PATH.unshift File.dirname(__FILE__)

require 'client'

require 'opennebula_vm'

require 'raw'
require 'qcow2'
require 'rbd'

# This class interacts with the LXD container on REST level
class Container

    #---------------------------------------------------------------------------
    # Class Constants API and Containers Paths
    #---------------------------------------------------------------------------
    CONTAINERS = 'containers'.freeze

    #---------------------------------------------------------------------------
    # Methods to access container attributes
    #---------------------------------------------------------------------------
    CONTAINER_ATTRIBUTES = %w[name status status_code devices config profile
                              expanded_config expanded_devices architecture].freeze

    CONTAINER_ATTRIBUTES.each do |attr|
        define_method(attr.to_sym) do
            @lxc[attr]
        end

        define_method("#{attr}=".to_sym) do |value|
            @lxc[attr] = value
        end
    end

    # Return if this is a wild container. Needs the associated OpenNebulaVM
    # description
    def wild?
        @one.wild? if @one
    end

    #---------------------------------------------------------------------------
    # Class constructors & static methods
    #---------------------------------------------------------------------------
    # Creates the container object in memory.
    # Can be later created in LXD using create method
    def initialize(lxc, one, client)
        @client = client

        @lxc = lxc
        @one = one

        # TODO: use defaulter
        @containers_path = @one.lxdrc['CONTAINERS']
        @containers_path ||= '/var/lib/lxd/storage-pools/default/containers'
    end

    class << self

    # Returns specific container, by its name
    # Params:
    # +name+:: container name
    def get(name, one_xml, client)
        info = client.get("#{CONTAINERS}/#{name}")['metadata']

        one  = nil
        one  = OpenNebulaVM.new(one_xml) if one_xml

        Container.new(info, one, client)
    rescue LXDError => exception
        raise exception
    end

    # Creates container from a OpenNebula VM xml description
    def new_from_xml(one_xml, client)
        one = OpenNebulaVM.new(one_xml)

        Container.new(one.to_lxc, one, client)
    end

    # Returns an array of container objects
    def get_all(client)
        containers = []

        container_names = client.get(CONTAINERS)['metadata']
        container_names.each do |name|
            name = name.split('/').last
            containers.push(get(name, nil, client))
        end

        containers
    end

    # Returns boolean indicating if the container exists(true) or not (false)
    def exist?(name, client)
        client.get("#{CONTAINERS}/#{name}")
        true
    rescue LXDError => exception
        raise exception if exception.body['error_code'] != 404

        false
    end

    end

    #---------------------------------------------------------------------------
    # Container Management & Monitor
    #---------------------------------------------------------------------------
    # Create a container without a base image
    def create(wait: true, timeout: '')
        @lxc['source'] = { 'type' => 'none' }
        wait?(@client.post(CONTAINERS, @lxc), wait, timeout)

        @lxc = @client.get("#{CONTAINERS}/#{name}")['metadata']
    end

    # Delete container
    def delete(wait: true, timeout: '')
        wait?(@client.delete("#{CONTAINERS}/#{name}"), wait, timeout)
    end

    # Updates the container in LXD server with the new configuration
    def update(wait: true, timeout: '')
        wait?(@client.put("#{CONTAINERS}/#{name}", @lxc), wait, timeout)
    end

    # Returns the container current state
    def monitor
        @client.get("#{CONTAINERS}/#{name}/state")
    end

    # Retreive metadata for the container
    def get_metadata
        @lxc = @client.get("#{CONTAINERS}/#{name}")['metadata']
    end

    #---------------------------------------------------------------------------
    # Contianer Status Control
    #---------------------------------------------------------------------------
    def start(options = {})
        change_state(__method__, options)
    end

    def stop(options = {})
        change_state(__method__, options)
    end

    def restart(options = {})
        change_state(__method__, options)
    end

    def freeze(options = {})
        change_state(__method__, options)
    end

    def unfreeze(options = {})
        change_state(__method__, options)
    end

    #---------------------------------------------------------------------------
    # Container Networking
    #---------------------------------------------------------------------------
    def attach_nic(mac)
        return unless @one

        nic_xml = @one.get_nic_by_mac(mac)

        return unless nic_xml

        nic_config = @one.nic(nic_xml)

        @lxc['devices'].update(nic_config)

        update
    end

    def detach_nic(mac)
        @lxc['devices'].delete_if do |device, config|
            device.include?('eth') && config['hwaddr'] == mac
        end

        update
    end

    #---------------------------------------------------------------------------
    # Container Storage
    #---------------------------------------------------------------------------
    # Sets up the container mounts for type: disk devices.
    def setup_storage(operation)
        return unless @one

        @one.get_disks.each do |disk|
            setup_disk(disk, operation)
        end

        if @one.has_context?
            csrc = @lxc['devices']['context']['source'].clone
            csrc.slice!('/mapper')

            RAW.new.run(operation, @lxc['devices']['context']['source'], csrc)
        end
    end

    # Generate the context devices and maps the context the device
    def attach_context
        @one.context(@lxc['devices'])

        csrc = @lxc['devices']['context']['source'].clone
        csrc.slice!('/mapper')

        RAW.new.run('map', @lxc['devices']['context']['source'], csrc)

        update
    end

    # Removes the context section from the LXD configuration and unmap the
    # context device
    def detach_context
        return unless @one.has_context?

        csrc = @lxc['devices']['context']['source'].clone
        csrc.slice!('/mapper')

        ctgt = @lxc['devices'].delete('context')['source']

        update

        RAW.new.run('unmap', ctgt, csrc)
    end

    # Attach disk to container (ATTACH = YES) in VM description
    def attach_disk(source = nil, path = nil)
        return unless @one

        disk_a = @one.get_disks.select do |disk|
            disk['ATTACH'].casecmp('YES').zero?
        end

        disk_element = disk_a.first

        return unless disk_element

        setup_disk(disk_element, 'map')

        if source
            source2 = source.dup
            mapper_location = source2.index('/disk.')
            source2.insert(mapper_location, '/mapper')
        end

        disk_hash = @one.disk(disk_element, source2, path)

        @lxc['devices'].update(disk_hash)

        update
    end

    # Detach disk to container (ATTACH = YES) in VM description
    def detach_disk
        return unless @one

        disk_a = @one.get_disks.select do |disk|
            disk['ATTACH'].casecmp('YES').zero?
        end

        disk_element = disk_a.first

        return unless disk_element

        disk_name = "disk#{disk_element['DISK_ID']}"

        csrc = @lxc['devices'][disk_name]['source'].clone

        OpenNebula.log @lxc['devices']

        @lxc['devices'].delete(disk_name)

        update

        OpenNebula.log @lxc['devices']

        mapper = select_driver(disk_element)
        mapper.run('unmap', csrc)
    end

    # Setup the disk by mapping/unmapping the disk device
    def setup_disk(disk, operation)
        return unless @one

        ds_path = @one.ds_path
        ds_id   = @one.sysds_id

        vm_id   = @one.vm_id
        vm_name = @one.vm_name

        disk_id = disk['DISK_ID']

        if disk_id == @one.rootfs_id
            # TODO: Verify rootfs is empty
            target = "#{@containers_path}/#{vm_name}/rootfs"
        else
            target = "#{ds_path}/#{ds_id}/#{vm_id}/mapper/disk.#{disk_id}"
        end

        source = case disk['TYPE']
                 when 'FILE'
                     "#{ds_path}/#{ds_id}/#{vm_id}/disk.#{disk_id}"
                 when 'RBD'
                     if disk['DISK_CLONE'] == 'YES'
                         "#{disk['SOURCE']}-#{vm_id}-#{disk_id}"
                     else
                         disk['SOURCE']
                     end
                 end

        mapper = select_driver(disk)

        mapper.run(operation, target, source)
    end

    # Returns a mapper object depending on the driver string
    def select_driver(info)
        case info['TYPE']
        when 'FILE'
            case info['DRIVER']
            when 'raw'
                RAW.new
            when 'qcow2'
                QCOW2.new
            when ''
                log = 'Missing DRIVER field in VM template: trying raw image'
                OpenNebula.log log
                RAW.new
            end
        when 'RBD'
            RBD.new(info['CEPH_USER'])
        end
    end

    # Start the svncterm server if it is down.
    def vnc(signal)
        command = @one.vnc_command(signal)
        return if command.nil?

        # TODO: Create function on openvm
        defaulter = lambda {|value, key|
            vnc_arg = @one.lxdrc[key]
            vnc_arg ||= value
        }

        w = defaulter.call('800', 'VNC_WIDTH')
        h = defaulter.call('600', 'VNC_HEIGTH')
        t = defaulter.call('300', 'VNC_TIMEOUT')

        vnc_args = "-w #{w} -h #{h} -t #{t}"

        bin = 'svncterm_server'
        server = "#{__dir__}/#{bin} #{vnc_args}"

        Process.detach(spawn(server)) unless running?(bin)

        `#{command}`
    end

    private

    # Return an array of pids matching the command or nil if not found
    def running?(command)
        pids = `ps -C #{command} | grep -w #{command} | awk '{print $1}'`
        pids = pids.chomp("\n").split("\n")
        return pids unless pids.empty?

        nil
    end

    # Waits or no for response depending on wait value
    def wait?(response, wait, timeout)
        @client.wait(response, timeout) unless wait == false
    end

    # Performs an action on the container that changes the execution status.
    # Accepts optional args
    def change_state(action, options)
        options.update(:action => action)

        response = @client.put("#{CONTAINERS}/#{name}/state", options)
        wait?(response, options[:wait], options[:timeout])

        @lxc = @client.get("#{CONTAINERS}/#{name}")['metadata']

        status
    end

end
