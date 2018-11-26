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

require 'fileutils'
require 'json'

require 'opennebula_vm'
require 'command'

#require_relative '../../scripts_common'

# Mappers class provides an interface to map devices into the host filesystem
# This class uses an array of partitions as output by lsblk in JSON:
#  [ 
#    {
#     "name"   : "loop1p3", 
#     "path"   : "/dev/mapper/loop1p3",
#     "type"   : "part",
#     "fstype" : "..", 
#     "label"  : null, 
#     "uuid"   : null, 
#     "fsavail": "...M", 
#     "fsuse%" : "..%", 
#     "mountpoint":"/boot" 
#     },
#     {
#      ....
#      children : [
#      ]
#     }
# ]
class Mapper
    #---------------------------------------------------------------------------
    # Class constants
    #---------------------------------------------------------------------------
    COMMANDS = {
        :lsblk   => 'sudo lsblk',
        :losetup => 'sudo losetup',
        :mount   => 'sudo mount',
        :umount  => 'sudo umount',
        :kpartx  => 'sudo kpartx',
        :nbd     => 'sudo qemu-nbd',
        :mkdir_p => 'sudo mkdir -p',
        :cat     => 'sudo cat',
        :file    => 'file',
    }

    #---------------------------------------------------------------------------
    # Interface to be implemented by specific mapper modules
    #---------------------------------------------------------------------------

    # Maps the disk to host devices
    # @param onevm [OpenNebulaVM] with the VM description
    # @param disk [XMLElement] with the disk data
    # @param directory [String] where the disk has to be mounted
    # @return [String] Name of the mapped device, empty in case of error. 
    #
    # Errors should be log using OpenNebula driver functions
    def do_map(one_vm, disk, directory)
        OpenNebula.log_error("map function not implemented for #{self.class}")
        return nil
    end

    # Unmaps a previously mapped partition
    # @param device [String] where the disk is mapped
    # @param disk [XMLElement] with the disk data
    # @param directory [String] where the disk has to be mounted
    #
    # @return nil 
    def do_unmap(device, one_vm, disk, directory)
        OpenNebula.log_error("unmap function not implemented for #{self.class}")
        return nil
    end

    #---------------------------------------------------------------------------
    # Mapper Interface 'map' & 'unmap' methods
    #---------------------------------------------------------------------------

    # Maps a disk to a given directory
    # @param onevm [OpenNebulaVM] with the VM description
    # @param disk [XMLElement] with the disk data
    # @param directory [String] Path to the directory where the disk has to be 
    # mounted. Example: /var/lib/one/datastores/100/3/mapper/disk.2
    #
    # @return true on success
    def map(one_vm, disk, directory)
        device = do_map(one_vm, disk, directory)

        OpenNebula.log_info "Mapping disk at #{directory} using device #{device}"

        return false if !device

        partitions = lsblk(device)

        return false if !partitions

        mount(partitions, directory)
    end

    # Unmaps a disk from a given directory
    # @param disk [XMLElement] with the disk data
    # @param directory [String] Path to the directory where the disk has to be 
    # mounted. Example: /var/lib/one/datastores/100/3/mapper/disk.2
    #
    # @return true on success
    def unmap(one_vm, disk, directory)
        OpenNebula.log_info "Unmapping disk at #{directory}"

        sys_parts  = lsblk('')
        partitions = []
        device     = ''

        return false if !sys_parts

        sys_parts.each { |d|
            if d['mountpoint'] == directory
                partitions = [d]
                device     = d['path']
                break
            end

            d['children'].each { |c|
                if c['mountpoint'] == directory
                    partitions = d['children']
                    device     = d['path']
                    break
                end
            } if d['children']

            break if !partitions.empty?
        }

        partitions.delete_if { |p| !p['mountpoint'] }

        partitions.sort! { |a,b|  
            b['mountpoint'].length <=> a['mountpoint'].length 
        }

        umount(partitions)

        do_unmap(device, one_vm, disk, directory)

        return true
    end

    private
    #---------------------------------------------------------------------------
    # Methods to mount/umount partitions         
    #---------------------------------------------------------------------------

    # Umounts partitions
    # @param partitions [Array] with partition device names
    def umount(partitions)
        partitions.each { |p|
            next if !p['mountpoint']

            umount_dev(p['path'])
        }
    end

    # Mounts partitions
    # @param partitions [Array] with partition device names
    # @param path [String] to directory to mount the disk partitions
    def mount(partitions, path)
        # Single partition
        # ----------------
        return  mount_dev(partitions[0]['path'], path) if partitions.size == 1

        # Multiple partitions
        # -------------------
        rc    = true
        fstab = ''

        # Look for fstab and mount rootfs in path. First partition with
        # a /etc/fstab file is used as rootfs and it is kept mounted
        partitions.each do |p|
            rc = mount_dev(p['path'], path)

            return false if !rc

            cmd = "#{COMMANDS[:cat]} #{path}/etc/fstab"

            rc, fstab, e = Command.execute(cmd, false)

            if fstab.empty?
                umount_dev(p['path'])
                next
            end

            break
        end

        if fstab.empty?
            OpenNebula.log_error("mount: No fstab file found in disk partitions")
            return false
        end

        # Parse fstab contents & mount partitions
        fstab.each_line do |l|
            next if l.strip.chomp.empty?
            next if l =~ /\s*#/

            fs, mount_point, type, opts, dump, pass = l.split

            if l =~ /^\s*LABEL=/ # disk by LABEL
                value = fs.split("=").last.strip.chomp
                key   = 'label'
            elsif l =~ /^\s*UUID=/ #disk by UUID
                value = fs.split("=").last.strip.chomp
                key   = 'uuid'
            else #disk by device - NOT SUPPORTED or other FS
                next
            end

            next if mount_point == '/' || mount_point == 'swap'

            partitions.each { |p|
                next if p[key] != value

                rc = mount_dev(p['path'], path + mount_point)
                return false if !rc
                break
            }
        end

        return rc
    end

    # Functions to mount/umount devices
    def mount_dev(dev, path)
        OpenNebula.log_info "Mounting #{dev} at #{path}"

        Command.execute("#{COMMANDS[:mkdir_p]} #{path}", false)

        rc, out, err = Command.execute("#{COMMANDS[:mount]} #{dev} #{path}",true)

        if rc != 0 
            OpenNebula.log_error("mount_dev: #{err}")
            return false
        end

        true
    end

    def umount_dev(dev)
        OpenNebula.log_info "Umounting disk mapped at #{dev}"

        Command.execute("#{COMMANDS[:umount]} #{dev}", true)
    end

    #---------------------------------------------------------------------------
    # Mapper helper functions
    #---------------------------------------------------------------------------
    # Get the partitions on the system or device
    # @param device [String] to get the partitions from. Use and empty string
    # for host partitions
    # @return [Hash] with partitions
    def lsblk(device)
        rc, o, e = Command.execute("#{COMMANDS[:lsblk]} -OJ #{device}", false)

        if rc != 0 || o.empty?
            OpenNebula.log_error("lsblk: #{e}")
            return nil
        end

        partitions = nil

        begin
            partitions = JSON.parse(o)['blockdevices']
            
            if !device.empty?
                partitions = partitions[0]

                if partitions['children']
                    partitions = partitions['children']
                else
                    partitions = [partitions]
                end

                partitions.delete_if { |p|  
                    p['fstype'].casecmp?('swap') if p['fstype']
                }
            end
        rescue
            OpenNebula.log_error("lsblk: error parsing lsblk -OJ #{device}")
            return nil
        end

        # Fix for lsblk paths for version < 2.33
        partitions.each { |p|
            lsblk_path(p)

            p['children'].each { |q| lsblk_path(q) } if p['children']
        }

        partitions
    end

    # @return [String] the canonical disk path for the given disk
    def disk_source(one_vm, disk)
        ds_path = one_vm.ds_path
        ds_id   = one_vm.sysds_id

        vm_id   = one_vm.vm_id
        disk_id = disk['DISK_ID']

         "#{ds_path}/#{ds_id}/#{vm_id}/disk.#{disk_id}"
    end

    #  Adds path to the partition Hash. This is needed for lsblk version < 2.33
    def lsblk_path(p)
        return unless !p['path'] && p['name']

        if File.exists?("/dev/#{p['name']}")
            p['path'] = "/dev/#{p['name']}"
        elsif File.exists?("/dev/mapper/#{p['name']}")
            p['path'] = "/dev/mapper/#{p['name']}"
        end
    end
end

