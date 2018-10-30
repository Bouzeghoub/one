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

require_relative 'mapper'

# Mapping RAW disks
class RAW < Mapper

    def map(disk)
        `sudo losetup -f --show #{disk}`.chomp
    end

    def unmap(block)
        shell("sudo losetup -d #{block}")
    end

    # Return an array of partitions of block if they exist
    def get_parts(block)
        return block if `sudo kpartx -av #{block}` == ''

        parts = super(block)
        parts.each do |part|
            match = 'dev'
            index = part['name'].index(match) + match.length
            part['name'].insert(index, '/mapper')
        end
        parts
    end

    def hide_parts(block)
        shell("sudo kpartx -dv #{block}")
    end

    def get_parent_device(partition)
        partition.slice!('/mapper')
        super(partition)
    end

end
