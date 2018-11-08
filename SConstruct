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

import os
import sys
import shutil
sys.path.append("./share/scons")
from lex_bison import *

# This is the absolute path where the project is located
cwd = os.getcwd()

# Environment that will be applied to each scons child
main_env = Environment()
main_env['ENV']['PATH'] = os.environ['PATH']

# snippet borrowed from http://dev.gentoo.org/~vapier/scons-blows.txt
# makes scons aware of build related environment variables
if os.environ.has_key('CC'):
    main_env['CC'] = os.environ['CC']
if os.environ.has_key('CFLAGS'):
    main_env['CCFLAGS'] += SCons.Util.CLVar(os.environ['CFLAGS'])
if os.environ.has_key('CXX'):
    main_env['CXX'] = os.environ['CXX']
if os.environ.has_key('CXXFLAGS'):
    main_env['CXXFLAGS'] += SCons.Util.CLVar(os.environ['CXXFLAGS'])
if os.environ.has_key('LDFLAGS'):
    main_env['LINKFLAGS'] += SCons.Util.CLVar(os.environ['LDFLAGS'])
else:
    os.environ['LDFLAGS'] = ""

# Add builders for flex and bison
add_lex(main_env)
add_bison(main_env)

# Include dirs
main_env.Append(CPPPATH=[
    cwd+'/include',
    cwd+'/src/parsers'
])

# Library dirs
main_env.Append(LIBPATH=[
    cwd+'/src/parsers',
    cwd+'/src/common',
    cwd+'/src/log',
    cwd+'/src/raft',
    cwd+'/src/sql',
    cwd+'/src/host',
    cwd+'/src/cluster',
    cwd+'/src/datastore',
    cwd+'/src/group',
    cwd+'/src/mad',
    cwd+'/src/nebula',
    cwd+'/src/pool',
    cwd+'/src/template',
    cwd+'/src/vm',
    cwd+'/src/vm_group',
    cwd+'/src/vm_template',
    cwd+'/src/vmm',
    cwd+'/src/lcm',
    cwd+'/src/tm',
    cwd+'/src/dm',
    cwd+'/src/im',
    cwd+'/src/image',
    cwd+'/src/rm',
    cwd+'/src/vnm',
    cwd+'/src/hm',
    cwd+'/src/um',
    cwd+'/src/authm',
    cwd+'/src/acl',
    cwd+'/src/xml',
    cwd+'/src/document',
    cwd+'/src/zone',
    cwd+'/src/client',
    cwd+'/src/secgroup',
    cwd+'/src/vdc',
    cwd+'/src/vrouter',
    cwd+'/src/market',
    cwd+'/src/ipamm'
])

# Compile flags
main_env.Append(CPPFLAGS=[
    "-g",
    "-Wall",
    "-std=c++11"
])

# Linking flags & common libraries
main_env.Append(LINKFLAGS=['-g', '-pthread'])
main_env.Append(LIBS=['z'])

#######################
# EXTRA CONFIGURATION #
#######################

# SQLITE
sqlite_dir = ARGUMENTS.get('sqlite_dir', 'none')
if sqlite_dir != 'none':
    main_env.Append(LIBPATH=[sqlite_dir+"/lib", sqlite_dir+"/lib64"])
    main_env.Append(CPPPATH=[sqlite_dir+"/include"])

sqlite = ARGUMENTS.get('sqlite', 'yes')
if sqlite == 'yes':
    main_env.Append(sqlite='yes')
    main_env.Append(CPPFLAGS=["-DSQLITE_DB"])
    main_env.Append(LIBS=['sqlite3'])
else:
    main_env.Append(sqlite='no')

# MySQL
mysql = ARGUMENTS.get('mysql', 'no')
if mysql == 'yes':
    main_env.Append(mysql='yes')
    main_env.Append(CPPFLAGS=["-DMYSQL_DB"])
    main_env.Append(LIBS=['mysqlclient'])
else:
    main_env.Append(mysql='no')

# Flag to compile with xmlrpc-c versions prior to 1.31 (September 2012)
new_xmlrpc = ARGUMENTS.get('new_xmlrpc', 'no')
if new_xmlrpc == 'yes':
    main_env.Append(new_xmlrpc='yes')
else:
    main_env.Append(new_xmlrpc='no')
    main_env.Append(CPPFLAGS=["-DOLD_XMLRPC"])

# xmlrpc
xmlrpc_dir = ARGUMENTS.get('xmlrpc', 'none')
if xmlrpc_dir != 'none':
    main_env.Append(LIBPATH=[xmlrpc_dir+"/lib", xmlrpc_dir+"/lib64"])
    main_env.Append(CPPPATH=[xmlrpc_dir+"/include"])

# systemd
systemd = ARGUMENTS.get('systemd', 'no')
if systemd == 'yes':
    main_env.Append(systemd='yes')
    main_env.Append(CPPFLAGS=["-DSYSTEMD"])
    main_env.Append(LIBS=['systemd'])
else:
    main_env.Append(systemd='no')

# build lex/bison
build_parsers = ARGUMENTS.get('parsers', 'no')
if build_parsers == 'yes':
    main_env.Append(parsers='yes')
else:
    main_env.Append(parsers='no')

# Rubygem generation
main_env.Append(rubygems=ARGUMENTS.get('rubygems', 'no'))

# Sunstone minified files generation
main_env.Append(sunstone=ARGUMENTS.get('sunstone', 'no'))

# Docker-machine addon generation
main_env.Append(docker_machine=ARGUMENTS.get('docker_machine', 'no'))

if not main_env.GetOption('clean'):
    try:
        if mysql == 'yes':
            main_env.ParseConfig('mysql_config --cflags --libs')
    except Exception, e:
        print ""
        print "mysql_config was not found in the path"
        print ""
        print "Check that mysql development package is installed and"
        print "mysql_config is in the path. If your mysql config tool"
        print "is called mysql5_config make a symlink as mysql_config"
        print "to a directory in the path."
        print ""
        exit(-1)

    try:
        main_env.ParseConfig(("LDFLAGS='%s' share/scons/get_xmlrpc_config" +
                              " server") % (os.environ['LDFLAGS'],))
        main_env.ParseConfig(("LDFLAGS='%s' share/scons/get_xmlrpc_config" +
                              " client") % (os.environ['LDFLAGS'],))

    except Exception, e:
        print ""
        print "Error searching for xmlrpc-c libraries. Please check this" +\
            " things:"
        print ""
        print " * You have installed development libraries for xmlrpc-c. One" +\
            " way to check"
        print "   this is calling xmlrpc-c-config that is provided with the" +\
            " development"
        print "   package."
        print " * Check that the version of xmlrpc-c is at least 1.06. You" +\
            " can do this also"
        print "   calling:"
        print "   $ xmlrpc-c-config --version"
        print " * If all this requirements are already met please send log" +\
            " files located in"
        print "   .xmlrpc_test to the mailing list."
        print ""
        exit(-1)
else:
    main_env.Replace(mysql='yes')
    shutil.rmtree('.xmlrpc_test', True)
    shutil.rmtree('src/nebula/.xmlrpc_test', True)
    shutil.rmtree('src/scheduler/.xmlrpc_test', True)


# libxml2
main_env.ParseConfig('xml2-config --libs --cflags')


# SCONS scripts to build
pre_build_scripts = [
    'src/parsers',
    'src/sql',
    'src/log',
    'src/raft',
    'src/common',
    'src/template',
    'src/host',
    'src/cluster',
    'src/datastore',
    'src/group',
    'src/mad',
    'src/mad/utils',
    'src/nebula',
    'src/pool',
    'src/vm',
    'src/vm_group',
    'src/vm_template',
    'src/vmm',
    'src/lcm',
    'src/rm',
    'src/tm',
    'src/im',
    'src/image',
    'src/dm',
    'src/scheduler',
    'src/vnm',
    'src/hm',
    'src/um',
    'src/authm',
    'src/acl',
    'src/xml',
    'src/document',
    'src/zone',
    'src/secgroup',
    'src/vdc',
    'src/vrouter',
    'src/market',
    'src/ipamm',
    'src/sunstone/public/locale/languages',
    'src/sunstone/public',
    'share/rubygems',
    'src/im_mad/collectd',
    'src/client',
    'src/docker_machine',
    'src/vmm_mad/remotes/lib/lxd/svncterm_server'
]

build_scripts = []
for x in pre_build_scripts:
    build_scripts.append(x + '/SConstruct')

for script in build_scripts:
    env = main_env.Clone()
    SConscript(script, exports='env')
