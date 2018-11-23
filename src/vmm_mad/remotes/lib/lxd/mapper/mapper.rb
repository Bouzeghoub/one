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
require 'tempfile'

# Mapping disks on the host
class Mapper

    FILTER = /\d+p\d+\b/

    # TODO: Add shell command wrapper, with optional redir, sudo, chomp, etc.
    # TODO: Implement classes for devices, partitions
    BASH_NIL = '> /dev/null 2>&1'

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
        mkdir(path)
        shell("sudo mount #{block} #{path} #{BASH_NIL}")
    end

    def umount(path)
        shell("sudo umount #{path}")
    end

    # Returns the block device associated to a mount
    def detect(path)
        `sudo df -h #{path} | grep /dev | awk '{print $1}'`.chomp("\n")
    end

    # Extends a block device depending on the filesystem
    def resize(block, directory, fs_format)
        case fs_format
        when 'ext4'
            `sudo e2fsck -f -y #{block} #{BASH_NIL}; sudo resize2fs #{block} #{BASH_NIL}`
        when 'xfs'
            mount_simple(block, directory)
            `sudo xfs_growfs -d #{directory} #{BASH_NIL}`
            umount(directory)
        else
            STDERR.puts "format #{fs_format} not supported"
            exit 1
        end
    end

    # Returns the fstab object from an array of partitions. These partitions should belong
    # to the same partition table. Each parition will be mounted in +directory+ until it is found
    # in one of them a file in directory/etc/fstab
    def detect_fstab(parts, directory)
        fstab = nil

        parts.each do |part|
            mount_simple(part['name'], directory)

            tmp_fstab = fstab_name

            begin
                cp("#{directory}/etc/fstab", tmp_fstab, true)
            rescue StandardError
                umount(directory)
                next
            end

            fstab = Fstab.new(tmp_fstab) # TODO: Validate fstab is an fstab

            File.delete tmp_fstab

            break fstab if fstab

            umount(directory)
        end

        fstab
    end

    # Returns a hash  with part => mountpoint
    def parse_fstab(fstab, partitions)
        mounts = {}
        fstab.entries.each_value do |entry|
            mounts[entry[:uuid]] = entry[:mount_point]
        end
        partitions.entries.each do |part|
            next unless mounts.key?(part['uuid'])

            mounts[part['name']] = mounts[part['uuid']]
            mounts.delete(part['uuid'])
        end

        # Remmove fstab anomalies
        STDERR.puts mounts
        mounts.each_key do |device|
            STDERR.puts device
            mounts.delete(device) unless device.class == String && device.include?('/dev')
        end

        mounts
    end

    # Returns the partitions sorted by / ocurrences in the mountpoints. Can be inverted
    def sort_mounts(partitions, invert)
        parts = []
        paths = []
        partitions.each do |key, value|
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

    # Returns the partitions of the block device and mounts them in directory, according to their fstab
    def multimap(parts, directory)
        STDERR.puts '----------------'

        fstab = detect_fstab(parts, directory)

        mounts = parse_fstab(fstab, parts)
        mounts = sort_mounts(mounts, false)
        STDERR.puts mounts

        STDERR.puts '----------------'
        mounts.each do |part, dest|
            next if dest == '/'

            mount_simple(part, directory + dest)
        end
    end

    # Umounts the partitions of a block device and finally unmaps de block
    def multiunmap(device, directory)
        get_parent_device(device) # part becomes dev
        parts = get_parts(device)

        tmp_fstab = fstab_name
        cp("#{directory}/etc/fstab", tmp_fstab, true)
        fstab = Fstab.new(tmp_fstab)
        File.delete(tmp_fstab)

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

            fs_format = get_format(device)
            resize(device, directory, fs_format) unless fs_format.nil? || fs_format == 'iso9660'

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
        shell("#{sudo} cp #{src} #{dst} && #{sudo} chown oneadmin:oneadmin #{dst}")
    end

    def mkdir(directory)
        FileUtils.mkdir_p directory
    rescue StandardError
        `sudo mkdir -p #{directory}`
    end

    def fstab_name
        file = Tempfile.new('fstab')
        path = file.path
        file.unlink
        path
    end

    def partition?(device)
        FILTER.match? device
    end

    def partitions?(block)
        parts = get_parts(block)
        return false if parts == block

        true
    end

    # Returns the filesystem type of a block device
    def get_format(block)
        return if partitions?(block)

        fs_format = `lsblk -f #{block} | grep -w #{block.split('/dev/')[-1]} | awk  \'{print $2}\'`.chomp
        return fs_format if fs_format != '' # Linux takes a bit to prepare the info

        get_format(block)
    end

    def shell(command)
        raise 'command failed to execute' unless system(command)
    end

end
