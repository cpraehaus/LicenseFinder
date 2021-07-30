# frozen_string_literal: true

require 'rexml/document'
require 'zip'
require 'open-uri'

module LicenseFinder
  class Nuget < PackageManager
    class Assembly
      attr_reader :name, :path

      def initialize(path, name)
        @path = path
        @name = name
      end

      def dependencies
        xml = REXML::Document.new(File.read(path.join('packages.config')))
        packages = REXML::XPath.match(xml, '//package')
        packages.map do |p|
          attrs = p.attributes
          Dependency.new(attrs['id'], attrs['version'], name)
        end
      end
    end

    Dependency = Struct.new(:name, :version, :assembly)

    def possible_package_paths
      path = project_path.join('vendor/*.nupkg')
      nuget_dir = Dir[path].map { |pkg| File.dirname(pkg) }.uniq

      # Presence of a .sln is a good indicator for a dotnet solution
      # cf.: https://docs.microsoft.com/en-us/nuget/tools/cli-ref-restore#remarks
      path = project_path.join('*.sln')
      solution_file = Dir[path].first

      possible_paths = [project_path.join('packages.config'), project_path.join('.nuget')]
      possible_paths.unshift(Pathname(solution_file)) unless solution_file.nil?
      possible_paths.unshift(Pathname(nuget_dir.first)) unless nuget_dir.empty?
      possible_paths
    end

    def assemblies
      Dir.glob(project_path.join('**', 'packages.config'), File::FNM_DOTMATCH).map do |d|
        path = Pathname.new(d).dirname
        name = path.basename.to_s
        Assembly.new path, name
      end
    end

    def current_packages
      dependencies.each_with_object({}) do |dep, memo|
        licenses = license_urls(dep)
        path = Dir.glob("#{Dir.home}/.nuget/packages/#{dep.name.downcase}/#{dep.version}").first

        memo[dep.name] ||= NugetPackage.new(dep.name, dep.version, spec_licenses: licenses, install_path: path)
        memo[dep.name].groups << dep.assembly unless memo[dep.name].groups.include? dep.assembly
      end.values
    end

    def license_urls(dep)
      files = Dir["**/#{dep.name}.#{dep.version}.nupkg"]
      return nil if files.empty?

      file = files.first
      Zip::File.open file do |zipfile|
        content = zipfile.read(dep.name + '.nuspec')
        Nuget.nuspec_license_urls(content)
      end
    end

    def dependencies
      assemblies.flat_map(&:dependencies)
    end

    def nuget_binary
      legacy_vcproj = Dir['**/*.vcproj'].any?

      if legacy_vcproj
        '/usr/local/bin/nugetv3.5.0.exe'
      else
        '/usr/local/bin/nuget.exe'
      end
    end

    def package_management_command
      return 'nuget' if LicenseFinder::Platform.windows?

      "mono #{nuget_binary}"
    end

    def prepare
      Dir.chdir(project_path) do
        cmd = prepare_command
        stdout, stderr, status = Cmd.run(cmd)
        return if status.success?

        log_errors stderr

        if stderr.include?('-PackagesDirectory')
          logger.info cmd, 'trying fallback prepare command', color: :magenta

          cmd = "#{cmd} -PackagesDirectory /#{Dir.home}/.nuget/packages"
          stdout, stderr, status = Cmd.run(cmd)
          return if status.success?

          log_errors_with_cmd(cmd, stderr)
        end

        error_message = "Prepare command '#{cmd}' failed\n#{stderr}"
        error_message += "\n#{stdout}\n" if !stdout.nil? && !stdout.empty?
        raise error_message unless @prepare_no_fail
      end
    end

    def prepare_command
      cmd = package_management_command
      sln_files = Dir['*.sln']
      cmds = []
      if sln_files.count > 1
        sln_files.each do |sln|
          cmds << "#{cmd} restore #{sln}"
        end
      else
        cmds << "#{cmd} restore"
      end

      cmds.join(' && ')
    end

    def installed?(logger = Core.default_logger)
      _stdout, _stderr, status = Cmd.run(nuget_check)
      if status.success?
        logger.debug self.class, 'is installed', color: :green
      else
        logger.info self.class, 'is not installed', color: :red
      end
      status.success?
    end

    def nuget_check
      return 'where nuget' if LicenseFinder::Platform.windows?

      "which mono && ls #{nuget_binary}"
    end

    def self.nuspec_license_urls(specfile_content)
      xml = REXML::Document.new(specfile_content)
      REXML::XPath.match(xml, '//metadata//licenseUrl')
                  .map(&:get_text)
                  .map(&:to_s)
    end

    def self.read_package_info(specfile_content, path)
      opts = {}
      xml = REXML::Document.new(specfile_content)
      xmlMeta = xml.root.elements['metadata']
      opts[:authors] = xmlMeta.elements['authors'].text
      opts[:homepage] = xmlMeta.elements['projectUrl'].text
      opts[:description] = xmlMeta.elements['description'].text
      opts[:summary] = opts[:description].lines.first
      opts[:license_type] = nil
      if xmlMeta.elements['license'] && xmlMeta.elements['license'].attributes['type'] == 'expression'
        opts[:license_type] = xmlMeta.elements['license'].text
      elsif xmlMeta.elements['license'] && xmlMeta.elements['license'].attributes['type'] == 'file'
        pkg_dir = File.dirname(path)
        loc_lic_path = File.join(pkg_dir, xmlMeta.elements['license'].text)
        #Core.default_logger.info "read_package_info", "loc_lic_path: #{loc_lic_path}"
        lic_file = PossibleLicenseFile.new(loc_lic_path)
        lic = lic_file.license if lic_file
        opts[:license_type] = lic.name if lic
      end
      # Handle license type 'file'
      opts[:license_url] = xmlMeta.elements['licenseUrl'] ? xmlMeta.elements['licenseUrl'].text : nil
      return opts
    end

    def self.get_license_file(lic_url, local_file, force = false)
      if !File.exists?(local_file) || force
        #Core.default_logger.info "get_license_file", "get_license_file: #{lic_url}"
        dl_url = lic_url&.gsub('github.com', 'raw.githubusercontent.com')&.gsub('blob/', '')
        
        URI.open(dl_url) do |uri|
          # Try to detect redirect of the form https://go.microsoft.com/fwlink/?linkid=864965 => https://github.com/xamarin/XamarinComponents/blob/main/Util/Xamarin.Build.Download/LICENSE
          # Since this often redirects to github.com we have a chance to get the raw license file by recursion
          final_url = uri.base_uri.to_s
          if final_url != lic_url
            Core.default_logger.info "get_license_file", "redirect detected: #{lic_url} -> #{final_url}"
            self.get_license_file(final_url, local_file, force)
          else
            # Save the file
            File.open(local_file, "wb") do |file|
              file.write(uri.read)
            end
          end
        end
      end
    end
  end
end
