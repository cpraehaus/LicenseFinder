# frozen_string_literal: true

require 'pathname'
require 'json'
require 'license_finder/package_utils/possible_license_file'

module LicenseFinder
  class Dotnet < PackageManager
    class AssetFile
      def initialize(path)
        @manifest = JSON.parse(File.read(path))
      end

      def dependencies
        libs = @manifest.fetch('libraries').reject do |_, v|
          v.fetch('type') == 'project'
        end

        libs.keys.map do |name|
          parts = name.split('/')
          PackageMetadata.new(parts[0], parts[1], possible_spec_paths(name))
        end
      end

      def possible_spec_paths(package_key)
        lib = @manifest.fetch('libraries').fetch(package_key)
        spec_filename = lib.fetch('files').find { |f| f.end_with?('.nuspec') }
        return [] if spec_filename.nil?

        @manifest.fetch('packageFolders').keys.map do |root|
          Pathname(root).join(lib.fetch('path'), spec_filename).to_s
        end
      end
    end

    class PackageMetadata
      attr_reader :name, :version, :possible_spec_paths

      def initialize(name, version, possible_spec_paths)
        @name = name
        @version = version
        @possible_spec_paths = possible_spec_paths
      end

      def read_license_urls
        possible_spec_paths.flat_map do |path|
          Nuget.nuspec_license_urls(File.read(path)) if File.exist? path
        end.compact
      end

      def read_package_info
        possible_spec_paths.flat_map do |path|
          Nuget.read_package_info(File.read(path), path) if File.exist? path
        end.compact
      end

      def ==(other)
        other.name == name && other.version == version && other.possible_spec_paths == possible_spec_paths
      end
    end

    def possible_package_paths
      paths = Dir[project_path.join('*.csproj')]
      paths.map { |p| Pathname(p) }
    end

    def current_packages
      package_metadatas = asset_files
                          .flat_map { |path| AssetFile.new(path).dependencies }
                          .uniq { |d| [d.name, d.version] }

      package_metadatas.map do |d|
        path = d.possible_spec_paths.find { |path| File.exist?(path) }
        if path
          path = File.dirname(path)
        else
          path = Dir.glob("#{Dir.home}/.nuget/packages/#{d.name.downcase}/#{d.version}").first
        end
        logger.debug self.class, "install dir: #{path}", color: :red

        opts = d.read_package_info.first
        loc_lic_path = "#{path}/LICENSE.fetched" if path.to_s.length > 0

        if opts[:license_url].to_s.strip.length > 0 && loc_lic_path.to_s.length > 0
          fetched = Nuget.get_license_file(opts[:license_url], loc_lic_path, false)
          if fetched and not opts[:license_type]
            lic_file = PossibleLicenseFile.new(loc_lic_path)
            lic = lic_file.license if lic_file
            opts[:license_type] = lic.name if lic
          end
        end

        opts[:install_path] = path
        opts[:spec_licenses] = opts[:license_type] ? [opts[:license_type]] : nil
        NugetPackage.new(d.name, d.version, opts)
      end
    end

    def asset_files
      Dir[project_path.join('**/project.assets.json')]
    end

    def package_management_command
      'dotnet'
    end

    def prepare_command
      "#{package_management_command} restore"
    end
  end
end
