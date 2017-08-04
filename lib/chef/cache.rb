#
# Copyright:: Copyright (c) 2016 Chef Software, Inc.
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

require "fileutils"
require "chef/project_manifest"
require "mixlib/install/product"
require "open-uri"

class Chef
  class Cache
    class MissingManifestFile < StandardError; end

    # TODO: whitelist of projects and channels - look at project_allowed in src
    KNOWN_PROJECTS = PRODUCT_MATRIX.products

    KNOWN_CHANNELS = %w(
      current
      stable
      unstable
    )

    attr_reader :metadata_dir
    attr_reader :sync_min_version
    attr_reader :package_host
    attr_reader :package_protocol
    attr_reader :package_port
    attr_reader :package_dir

    #
    # Initializer for the cache.
    #
    # @param [String] metadata_dir
    #   the directory which will be used to create files in & read files from.
    #
    def initialize(config = {})
      if config.is_a?(String)
        @metadata_dir = config
        @sync_min_version = nil
        @package_host = nil
        @package_protocol = nil
        @package_port = nil
        @package_dir = './public'
      else
        @metadata_dir = config.key?('metadata_dir') ? config['metadata_dir'] : './metadata_dir'
         # If this remains nil it will suck in everything
        @sync_min_version = config.key?('sync_min_version') ? config['sync_min_version'] : nil
        # If this remains nil it will pass the original manifest location through
        @package_host = config.key?('package_host') ? config['package_host'] : nil
        # Neither of these will matter if the first one is nil
        @package_protocol = config.key?('package_protocol') ? config['package_protocol'] : 'http'
        @package_port = config.key?('package_port') ? config['package_port'] : 80
        @package_dir = config.key?('package_dir') ? config['package_dir'] : './public'
      end

      KNOWN_CHANNELS.each do |channel|
        FileUtils.mkdir_p(File.join(metadata_dir, channel))
      end
    end

    #
    # Updates the cache
    #
    # @return [void]
    #
    def update
      KNOWN_PROJECTS.each do |project|
        next unless project == 'chef'
        KNOWN_CHANNELS.each do |channel|
          next unless channel == 'stable'
          manifest = ProjectManifest.new(project, channel)
          manifest.generate

          packages = []
          manifest.manifest.each do |platform_name, platform|
            platform.each do |version_name, version|
              version.each do |arch_name, arch|
                arch.each do |pkg_name, pkg|
                  if sync_min_version.nil?
                    packages.push(pkg.dup)
                  else
                    packages.push(pkg.dup) if Gem::Version.new(pkg_name) > Gem::Version.new(sync_min_version)
                  end

                  # Change URI to local
                  download_uri = URI(manifest.manifest[platform_name][version_name][arch_name][pkg_name][:url])

                  if ! package_host.nil?
                    download_uri.scheme = package_protocol
                    download_uri.host = package_host
                    download_uri.port = package_port
                  end
                  manifest.manifest[platform_name][version_name][arch_name][pkg_name][:url] = download_uri.to_s
                end
              end
            end
          end

          packages.each do |pkg|
            mirror_package(pkg)
          end

          File.open(project_manifest_path(project, channel), "w") do |f|
            f.puts manifest.serialize
          end
        end
      end
    end

    def mirror_package(pkg)
      cache_path = "#{package_dir}#{URI(pkg[:url]).path}"
      if File.exists?(cache_path) && Digest::SHA256.hexdigest(File.read(cache_path)) == pkg[:sha256]
        puts "#{URI(pkg[:url]).path} is already in cache"
      else
        puts "Downloading #{pkg[:url]}"

        dir = File.dirname(cache_path)
        FileUtils.mkdir_p(dir) unless File.exists?(dir)

        IO.copy_stream(open(pkg[:url]), cache_path)
      end
    end

    #
    # Returns the file path for the manifest file that belongs to the given
    # project & channel.
    #
    # @parameter [String] project
    # @parameter [String] channel
    #
    # @return [String]
    #   File path of the manifest file.
    #
    def project_manifest_path(project, channel)
      File.join(metadata_dir, channel, "#{project}-manifest.json")
    end

    #
    # Returns the manifest for a given project and channel from the cache.
    #
    # @parameter [String] project
    # @parameter [String] channel
    #
    # @return
    #   [Hash] contents of the manifest file
    #
    def manifest_for(project, channel)
      manifest_path = project_manifest_path(project, channel)

      if File.exist?(manifest_path)
        JSON.parse(File.read(manifest_path))
      else
        raise MissingManifestFile, "Can not find the manifest file for '#{project}' - '#{channel}'"
      end
    end

    #
    # Returns the last updated time of the manifest for a given project and channel.
    #
    # @parameter [String] project
    # @parameter [String] channel
    #
    # @return
    #   [String] timestamp for the last modified time.
    #
    def last_modified_for(project, channel)
      manifest_path = project_manifest_path(project, channel)

      if File.exist?(manifest_path)
        manifest = JSON.parse(File.read(manifest_path))
        manifest["run_data"]["timestamp"]
      else
        raise MissingManifestFile, "Can not find the manifest file for '#{project}' - '#{channel}'"
      end
    end

  end
end
