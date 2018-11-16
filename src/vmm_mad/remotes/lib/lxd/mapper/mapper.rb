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

require 'fileutils'
require 'json'
require 'fstab'

# Mapping disks on the host
class Mapper

    FILTER = /\d+p\d+\b/
    TMP_FSTAB = '/tmp/one-fstab'

    # TODO: validate mounts with unmaps
    def mount(block, path)
        mount_simple(block, path)
    rescue StandardError
        raise "cannot mount partition #{block}" if partition?(block)

        parts = get_parts(block)

        return multimap(parts, path) unless parts == block

        unmap(block)
        raise "cannot mount device #{block}"
    end

    def mount_simple(block, path)
        shell("sudo mount #{block} #{path} 2>/dev/null")
    end

    def umount(path)
        shell("sudo umount #{path}")
    end

    # Returns the block device associated to a mount
    def detect(path)
        `sudo df -h #{path} | grep /dev | awk '{print $1}'`.chomp("\n")
    end

    # TODO: mount fstab on container rootfs
    # TODO: seize root part on container rootfs, multimap dir
    def detect_fstab(parts, directory)
        fstab = nil

        parts.each do |part|
            mount_simple(part['name'], directory)
            cp("#{directory}/etc/fstab", TMP_FSTAB, true)

            begin
                # TODO: Validate fstab is an fstab
                fstab = Fstab.new(TMP_FSTAB)
            rescue StandardError => exception
                umount(directory)
                raise exception
            end

            break fstab if fstab

            umount(directory)
        end

        fstab
    end

    # Returns a hash  with part => mountpoint
    def parse_fstab(fstab, partitions)
        mounts = {}
        fstab.entries.each_value do |val|
            mounts[val[:uuid]] = val[:mount_point]
        end
        partitions.entries.each do |part|
            next unless mounts.key?(part['uuid'])

            mounts[part['name']] = mounts[part['uuid']]
            mounts.delete(part['uuid'])
        end
        mounts
    end

    def sort_mounts(mounts, invert)
        parts = []
        paths = []
        mounts.each do |key, value|
            if value == '/'
                parts.prepend(key)
                paths.prepend(value)
            else
                value.slice!(-1) if value[-1] == '/'
                root = value.count('/')
                parts.insert(root, key)
                paths.insert(root, value)
            end
        end

        [parts, paths].each {|array| array.delete_if {|mount| mount.nil? } }

        sorted = {}
        0.upto(paths.length - 1) {|i| sorted[parts[i]] = paths[i] }

        return sorted unless invert

        Hash[sorted.to_a.reverse]
    end

    # Return an array of possibly unmountable partitions from block
    def detect_parts(block)
        command = `lsblk #{block} -f -J`
        # TODO: validate non-existing block
        JSON.parse(command)['blockdevices'][0]['children']
    end

    # Returns an array of mountable partitions from block
    def get_parts(block)
        parts = detect_parts(block)
        return block if parts.nil?

        parts.each {|part| parts.delete(part) if part['uuid'].nil? || part['fstype'] == 'swap' }
        parts.each {|part| part['name'].insert(0, '/dev/') }

        parts
    end

    # returns the parent device of a partition
    def get_parent_device(partition)
        piece = partition.slice! FILTER
        device_id = piece[0..1 - piece.index('p')]
        partition.insert(-1, device_id)
    end

    def multimap(parts, directory)
        fstab = detect_fstab(parts, directory)

        mounts = parse_fstab(fstab, parts)
        mounts = sort_mounts(mounts, false)
        mounts.each do |part, dest|
            next if dest == '/'

            mount_simple(part, directory + dest)
        end
    end

    def multiunmap(device, directory)
        get_parent_device(device) # part becomes dev
        parts = get_parts(device)

        cp("#{directory}/etc/fstab", TMP_FSTAB, true)
        fstab = Fstab.new(TMP_FSTAB)

        mounts = parse_fstab(fstab, parts)
        mounts = sort_mounts(mounts, true)
        mounts.each do |_part, dest|
            umount(directory + dest)
        end

        unmap(device)
    end

    # Maps/unmamps a disk file to/from a directory
    def run(action, directory, disk = nil)
        case action
        when 'map'
            device = map(disk)
            mkdir(directory)
            mount(device, directory)
        when 'unmap'
            device = detect(directory)
            return STDERR.puts "#{directory} has no associated device" if device == ''

            return multiunmap(device, directory) if partition?(device)

            umount(directory)
            unmap(device)
        end
    end

    def cp(src, dst, sudo = false)
        sudo = 'sudo' if sudo == true
        `#{sudo} cp #{src} #{dst}`
    end

    def mkdir(directory)
        FileUtils.mkdir_p directory
    rescue StandardError
        `sudo mkdir -p #{directory}`
    end

    def partition?(device)
        FILTER.match? device
    end

    def format(block, file_system)
        shell("sudo mkfs.#{file_system} #{block}")
    end

    def shell(command)
        raise 'command failed to execute' unless system(command)
    end

end
