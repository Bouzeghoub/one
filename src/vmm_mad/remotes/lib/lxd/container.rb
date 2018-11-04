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

#
# LXD Container abstraction
#
class Container
    CONTAINERS = 'containers'.freeze

    CONTAINER_ATTRIBUTES = %w{name status status_code devices config profile 
        expanded_config expanded_devices}.freeze

    CONTAINER_ATTRIBUTES.each { |attr|
        define_method(attr.to_sym) do
            @info[attr]
        end

        define_method("#{attr}=".to_sym) do |value|
            @info[attr] = value
        end
    }

    # Creates the container object in memory.
    # Can be later created in LXD using create method
    def initialize(info, client)
        @client = client
        @info   = info
    end

    class << self
        # Returns specific container, by its name
        # Params:
        # +name+:: container name
        def get(name, client)
            info = client.get("#{CONTAINERS}/#{name}")['metadata']
            Container.new(info, client)
        rescue LXDError => exception
            raise exception
        end

        # Returns an array of container objects
        def get_all(client)
            containers = []

            container_names = client.get(CONTAINERS)['metadata']
            container_names.each do |name|
                name = name.split('/').last
                containers.push(get(name, client))
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

    # Create a container without a base image
    def create(wait: true, timeout: '')
        @info['source'] = { 'type' => 'none' }
        wait?(@client.post(CONTAINERS, @info), wait, timeout)
        
        @info = @client.get("#{CONTAINERS}/#{name}")['metadata']
    end

    # Delete container
    def delete(wait: true, timeout: '')
        wait?(@client.delete("#{CONTAINERS}/#{name}"), wait, timeout)
    end

    # Updates the container in LXD server with the new configuration
    def update(wait: true, timeout: '')
        wait?(@client.put("#{CONTAINERS}/#{name}", @info), wait, timeout)
    end

    # Returns the container current state
    def monitor
        @client.get("#{CONTAINERS}/#{name}/state")
    end

    # Status Control

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

    private
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

        @info = @client.get("#{CONTAINERS}/#{name}")['metadata']

        status
    end
end
