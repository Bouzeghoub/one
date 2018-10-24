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

ONE_LOCATION = ENV['ONE_LOCATION'] unless defined?(ONE_LOCATION)
if !ONE_LOCATION
    RUBY_LIB_LOCATION = '/usr/lib/one/ruby' unless defined?(RUBY_LIB_LOCATION)
else
    RUBY_LIB_LOCATION = ONE_LOCATION + '/lib/ruby' unless defined?(RUBY_LIB_LOCATION)
end
[RUBY_LIB_LOCATION, __dir__].each {|dir| $LOAD_PATH << dir }

require 'rest/container'
require 'rest/client'

require 'xml_tools'

require 'mapper/raw'
require 'mapper/qcow2'
require 'mapper/rbd'

require 'scripts_common' # TODO: Check if works on node-only VM
require 'opennebula' # TODO: Check if works on node-only VM

# Tools required by the vmm scripts
module LXDriver

    SEP = '-' * 40
    CONTAINERS = '/var/lib/lxd/containers/' # TODO: Fix hardcode

    class << self

        ###############
        ##   Misc    ##
        ###############

        def log_init
            OpenNebula.log_info('Begin ' + SEP)
        end

        def log_end(time)
            time = time(time)
            OpenNebula.log_info("End #{time} #{SEP[(time.size - 1)..-1]}")
        end

        # Returns the time passed since time
        def time(time)
            (Time.now - time).to_s
        end

        # Creates an XML object from driver action template
        def action_xml(xml = STDIN.read)
            XML.new(xml, XML::HOTPLUG_PREFIX)
        end

        def save_xml(xml, path = '/tmp/deployment.xml')
            File.open(path, 'w') {|file| file.write(xml) }
        end

        # Returns a mapper class depending on the driver string
        def select_driver(info)
            case info['TYPE']
            when 'FILE'
                case info['DRIVER']
                when 'raw'
                    RAW.new
                when 'qcow2'
                    QCOW2.new
                end
            when 'RBD'
                RBD.new(info['CEPH_USER'])
            end
        end

        def device_path(info, disk_info, dir = '')
            disk_id = disk_info['DISK_ID']
            vm_id = info.vm_id
            mount = "#{info.datastores}#{info.sysds_id}/#{vm_id}/#{dir}disk.#{disk_id}"

            return mount if dir != ''

            case disk_info['TYPE']
            when 'FILE'
                mount
            when 'RBD'
                source = disk_info['SOURCE']
                source = source + '-' + vm_id + '-' + disk_id if disk_info['DISK_CLONE'] == 'YES'
                source
            end
        end

        def vnc(info)
            data = nil
            begin
                data = info.complex_element('GRAPHICS')
            rescue StandardError => exception
                return
            end
            return if data['TYPE'] != 'VNC'

            pass = ''
            pass = "-passwd #{data['PASSWD']}" if data['PASSWD']

            # TODO: load command from template?
            command = 'bash'
            command = "lxc exec #{info.vm_name} #{command}"
            command = "svncterm -timeout 0 #{pass} -rfbport #{data['PORT']} -c #{command}"

            command = <<EOT
status='RUNNING'
while test $status = 'RUNNING'
do
	#{command}
    status=$(lxc list #{info.vm_name} --format csv -c s)
done
EOT
            command

            Process.detach(spawn(command))
        end

        ###############
        #  Container  #
        ###############

        # Mount context iso in the LXD node
        def context(mountpoint, action)
            device = mountpoint.dup
            device.slice!('/mapper')
            RAW.new.run(action, mountpoint, device)
        end

        # Sets up the container mounts for type: disk devices
        def container_storage(info, action)
            disks = info.multiple_elements('DISK')

            disks.each do |disk|
                disk_info = disk['DISK']
                disk_id = disk_info['DISK_ID']

                mountpoint = device_path(info, disk_info, 'mapper/')
                mountpoint = CONTAINERS + 'one-' + info.vm_id if disk_id == info.rootfs_id

                device = device_path(info, disk_info)

                mapper = select_driver(disk_info)
                mapper.run(action, mountpoint, device)
            end

            context(info.context['context']['source'], action) if info.single_element('CONTEXT')
        end

        # Reverts changes if container fails to start
        def container_start(container, info)
            raise LXDError, container.status if container.start != 'Running'
        rescue LXDError => e
            container_storage(info, 'unmap')
            OpenNebula.log_error('Container failed to start')
            container.delete
            raise e
        end

        # Creates or overrides a container if one existed
        def container_create(container, client)
            config = container.config
            devices = container.devices
            if Container.exist?(container.name, client)
                OpenNebula.log_info('Overriding container')
                container = Container.get(container.name, client)
                err_msg = 'A container with the same ID is already running'
                raise LXDError, err_msg if container.status == 'Running'

                container.config.update(config)
                container.devices.update(devices)
                container.update
            else
                container.create
            end
        end

    end

end
