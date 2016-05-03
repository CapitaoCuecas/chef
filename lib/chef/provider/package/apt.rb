#
# Author:: Adam Jacob (<adam@chef.io>)
# Copyright:: Copyright 2008-2016, Chef Software Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require "chef/provider/package"
require "chef/resource/apt_package"

class Chef
  class Provider
    class Package
      class Apt < Chef::Provider::Package
        use_multipackage_api

        provides :package, platform_family: "debian"
        provides :apt_package, os: "linux"

        # return [Hash] mapping of package name to Boolean value
        attr_accessor :is_virtual_package

        def initialize(new_resource, run_context)
          super
          @is_virtual_package = {}
        end

        def load_current_resource
          @current_resource = Chef::Resource::AptPackage.new(new_resource.name)
          current_resource.package_name(new_resource.package_name)
          check_all_packages_state(new_resource.package_name)
          current_resource
        end

        def define_resource_requirements
          super

          requirements.assert(:all_actions) do |a|
            a.assertion { !new_resource.source }
            a.failure_message(Chef::Exceptions::Package, "apt package provider cannot handle source attribute. Use dpkg provider instead")
          end
        end

        def default_release_options
          # Use apt::Default-Release option only if provider supports it
          "-o APT::Default-Release=#{new_resource.default_release}" if new_resource.respond_to?(:default_release) && new_resource.default_release
        end

        # FIXME: need spec to check that candidate_version is set correctly on a virtual package
        # FIXME: need spec to check that packages missing a candidate_version can be removed/purged

        def get_package_versions(pkg)
          installed_version  = nil
          candidate_version  = nil
          run_noninteractive("apt-cache", default_release_options, "policy", pkg).stdout.each_line do |line|
            case line
            when /^\s{2}Installed: (.+)$/
              installed_version = ( $1 != "(none)" ) ? $1 : nil
              Chef::Log.debug("#{new_resource} installed version for #{pkg} is #{$1}")
            when /^\s{2}Candidate: (.+)$/
              candidate_version = ( $1 != "(none)" ) ? $1 : nil
              Chef::Log.debug("#{new_resource} candidate version for #{pkg} is #{$1}")
            end
          end
          [ installed_version, candidate_version ]
        end

        def resolve_virtual_package_name(pkg)
          showpkg = run_noninteractive("apt-cache showpkg", pkg).stdout
          partitions = showpkg.rpartition(/Reverse Provides: ?#{$/}/)
          return nil if partitions[0] == "" && partitions[1] == ""  # not found in output
          set = partitions[2].lines.each_with_object(Set.new) do |line, acc|
            # there may be multiple reverse provides for a single package
            acc.add(line.split[0])
          end
          if set.size > 1
            raise Chef::Exceptions::Package, "#{new_resource.package_name} is a virtual package provided by multiple packages, you must explicitly select one"
          end
          return set.to_a.first
        end

        def check_package_state(pkg)
          is_virtual_package = false
          installed_version  = nil
          candidate_version  = nil


          installed_version, candidate_version = get_package_versions(pkg)

          if candidate_version.nil?
            newpkg = resolve_virtual_package_name(pkg)

            if newpkg
              is_virtual_package = true
              Chef::Log.info("#{new_resource} is a virtual package, actually acting on package[#{newpkg}]")
              installed_version, candidate_version = get_package_versions(newpkg)
            end
          end

          return {
            installed_version:   installed_version,
            candidate_version:   candidate_version,
            is_virtual_package:  is_virtual_package,
          }
        end

        def check_all_packages_state(package)
          installed_version = {}
          candidate_version = {}

          [package].flatten.each do |pkg|
            ret = check_package_state(pkg)
            is_virtual_package[pkg] = ret[:is_virtual_package]
            installed_version[pkg]  = ret[:installed_version]
            candidate_version[pkg]  = ret[:candidate_version]
          end

          if package.is_a?(Array)
            @candidate_version = []
            final_installed_version = []
            [package].flatten.each do |pkg|
              candidate_version << candidate_version[pkg]
              final_installed_version << installed_version[pkg]
            end
            current_resource.version(final_installed_version)
          else
            @candidate_version = candidate_version[package]
            current_resource.version(installed_version[package])
          end
        end

        def install_package(name, version)
          package_name = name.zip(version).map do |n, v|
            is_virtual_package[n] ? n : "#{n}=#{v}"
          end.join(" ")
          run_noninteractive("apt-get -q -y", default_release_options, new_resource.options, "install", package_name)
        end

        def upgrade_package(name, version)
          install_package(name, version)
        end

        def remove_package(name, version)
          run_noninteractive("apt-get -q -y", new_resource.options, "remove", name)
        end

        def purge_package(name, version)
          run_noninteractive("apt-get -q -y", new_resource.options, "purge", name)
        end

        def preseed_package(preseed_file)
          Chef::Log.info("#{new_resource} pre-seeding package installation instructions")
          run_noninteractive("debconf-set-selections", preseed_file)
        end

        def reconfig_package(name, version)
          Chef::Log.info("#{new_resource} reconfiguring")
          run_noninteractive("dpkg-reconfigure", name)
        end

        private

        # Runs command via shell_out with magic environment to disable
        # interactive prompts. Command is run with default localization rather
        # than forcing locale to "C", so command output may not be stable.
        def run_noninteractive(*args)
          shell_out_with_timeout!(a_to_s(*args), :env => { "DEBIAN_FRONTEND" => "noninteractive" })
        end

      end
    end
  end
end
