# Builds an OS X installer package from an installed formula.
require 'formula'
require 'optparse'
require 'tmpdir'
require 'open3'
require 'pathname'

module Homebrew extend self
  def elf_file?(file_path)
    # Check if the file exists
    return false unless File.exist?(file_path)

    stdout, status = Open3.capture2("file -bL --mime-encoding \"#{file_path}\"")

    return stdout.strip == 'binary'
  end

  def patchelf(root_dir, prefix_path, binary, format='@executable_path')
    full_prefix_path = File.join(root_dir, prefix_path)

    # Get the full binary path and check if it's a valid ELF
    binary_path = File.realpath(File.join(full_prefix_path, binary))

    # Check if file exists and it is an executable
    return unless elf_file?(binary_path)

    # Get the list of linked libraries with otool
    stdout, status = Open3.capture2("otool -L #{binary_path}")

    # Debug information
    puts "Before patching:"
    puts "#{stdout}"

    # Remove the first line which is unnecesary
    stdout_lines = stdout.lines[1..-1]

    # Get all the paths from the prefix path and strip left and remove the right data inside the parenthesis
    lib_paths = stdout_lines.grep(/#{prefix_path}/).map(&:lstrip).map { |path| path.sub(/ \(.*$/m, '') }

    # Iterate through all libraries that the binary is linked to
    lib_paths.each do |lib|
      lib_path = (File.realpath(File.join(root_dir, lib)) rescue nil)

      if lib_path == nil
        opoo "File 'File.realpath(File.join(#{root_dir}, #{lib})' not found"
        next
      end

      # Define new library relative path
      if lib_path == binary_path
        # When it is referring to itself, it means that it is the id of the name path,
        # obtain the relative path from binary folder (it is the same as the lib folder,
        # so we can use @loader_path for covering the executable and library paths)
        relative_path = Pathname.new(lib).relative_path_from(Pathname.new(File.join(prefix_path, 'bin')))
        new_lib = File.join('@loader_path', relative_path)

        # Patch the library path name
        puts "install_name_tool -id #{new_lib} #{binary_path}"
        system("install_name_tool", "-id", new_lib, binary_path)
      else
        # Obtain the relative path from the executable or library
        lib_relative_path = lib_path.delete_prefix(full_prefix_path)
        binary_relative_path = File.dirname(binary_path).delete_prefix(full_prefix_path)
        relative_path = Pathname.new(lib_relative_path).relative_path_from(Pathname.new(binary_relative_path))
        new_lib = File.join(format, relative_path)

        # Patch the library path relative to the binary path
        puts "install_name_tool -change #{lib} #{new_lib} #{binary_path}"
        system("install_name_tool", "-change", lib, new_lib, binary_path)
      end

      # Debug information
      stdout, status = Open3.capture2("otool -L #{binary_path}")
      puts "After patching:"
      puts "#{stdout}"

      if lib_path != binary_path
        # Recursively iterate through libraries
        puts "patchelf(#{root_dir}, #{prefix_path}, #{lib.delete_prefix(prefix_path)})"
        patchelf(root_dir, prefix_path, lib.delete_prefix(prefix_path), '@loader_path')
      end
    end
  end

  def pkg
    options = {
      identifier_prefix: 'org.homebrew',
      with_deps: false,
      without_kegs: false,
      scripts_path: '',
      output_dir: '',
      compress: false,
      package_name: '',
      ownership: '',
      additional_deps: [],
      relocatable: false
    }
    packages = []

    option_parser = OptionParser.new do |opts|
      opts.banner = <<-EOS
Usage: brew pkg [--identifier-prefix] [--with-deps] [--without-kegs] [--name] [--output-dir] [--compress] [--additional-deps] [--relocatable] formula

Build an OS X installer package from a formula. It must be already
installed; 'brew pkg' doesn't handle this for you automatically. The
'--identifier-prefix' option is strongly recommended in order to follow
the conventions of OS X installer packages.
      EOS

      opts.on('-i', '--identifier-prefix identifier_prefix', 'Set a custom identifier prefix to be prepended') do |o|
        options[:identifier_prefix] = o.chomp('.')
      end

      opts.on('-d', '--with-deps', 'Include all the package\'s dependencies in the built package') do
        options[:with_deps] = true
      end

      opts.on('-k', '--without-kegs', 'Exclude package contents at /usr/local/Cellar/packagename') do
        options[:without_kegs] = true
      end

      opts.on('-s', '--scripts scripts_path', 'Set the path to custom preinstall and postinstall scripts') do |o|
        options[:scripts_path] = o
      end

      opts.on('-o', '--output-dir output_dir', 'Define the output dir where files will be copied') do |o|
        options[:output_dir] = o
      end

      opts.on('-c', '--compress', 'Generate a tgz file with the package files into the current folder') do
        options[:compress] = true
      end

      opts.on('-n', '--name package_name', 'Define a custom output package name') do |o|
        options[:package_name] = o
      end

      ownership_options = ['recommended', 'preserve', 'preserve-other']
      opts.on('-w', '--ownership ownership_mode', 'Define the ownership as: recommended, preserve or preserve-other') do |o|
        if ownership_options.include?(o)
          options[:ownership] = value
          puts "Setting pkgbuild option --ownership with value #{value}"
        else
          opoo "#{value} is not a valid value for pkgbuild --ownership option, ignoring"
        end
      end

      opts.on('-a', '--additional-deps deps_separated_by_coma', 'Provide additional dependencies in order to package all them together') do |o|
        options[:additional_deps] = o.split(',')
      end

      opts.on('-r', '--relocatable', 'Make the package relocatable so it does not depend on the path where it is located') do
        options[:relocatable] = true
      end
    end

    # Parse the command line arguments
    option_parser.parse!(ARGV)

    # Exit if there's no formula or there's more than one
    abort option_parser.banner if ARGV.length != 1

    # ARGV now contains the free arguments after parsing the options
    packages = [ARGV.first] + options[:additional_deps]
    puts "Building packages: #{packages.join(', ')}"

    # Define the formula
    dependencies = []
    formulas = packages.map do |formula|
      f = Formulary.factory(formula)

      # Make sure it's installed first
      if !f.any_version_installed?
        onoe "#{f.name} is not installed. First install it with 'brew install #{f.name}'."
        abort
      end

      # Add deps if we specified --with-deps
      dependencies += f.recursive_dependencies if options[:with_deps]

      # TODO: Implement proper filtering
      # if options[:with_deps]
      #   dependencies += f.recursive_dependencies.reject do |dep|
      #     dep.build? || dep.test?
      #   end
      # end

      f
    end

    # Add the dependencies to the rest of formulas if any
    formulas += dependencies

    # Define the first package which is the main one
    f = formulas.first
    name = f.name
    identifier = options[:identifier_prefix] + ".#{name}"
    version = f.version.to_s
    version += "_#{f.revision}" if f.revision.to_s != '0'

    # If the package name is not defined, define the default one
    if options[:package_name] == ''
      options[:package_name] = "#{name}-#{version}"
    end

    # Setup staging dir
    if options[:output_dir] == ''
      options[:output_dir] = Dir.mktmpdir('brew-pkg')
    end

    staging_root = options[:output_dir] + HOMEBREW_PREFIX
    puts "Creating package staging root using Homebrew prefix #{HOMEBREW_PREFIX} inside #{staging_root}"
    FileUtils.mkdir_p staging_root

    puts "Listing staging root:"
    system("ls -la #{staging_root}")

    puts "Listing lib folder:"
    system("ls -la #{staging_root}/lib")

    formulas.each do |pkg|
      formula = Formulary.factory(pkg.to_s)

      dep_version = formula.version.to_s
      dep_version += "_#{formula.revision}" if formula.revision.to_s != '0'

      puts "Staging formula #{formula.name}"

      # Get all directories for this keg, rsync to the staging root
      if File.exist?(File.join(HOMEBREW_CELLAR, formula.name, dep_version))
        dirs = Pathname.new(File.join(HOMEBREW_CELLAR, formula.name, dep_version)).children.select { |c| c.directory? }.collect { |p| p.to_s }

        dirs.each { |d| safe_system "rsync", "-a", "#{d}", "#{staging_root}/" }
        puts "DEBUG: contents after rsync"
        puts "DEBUG: staging_root"
        system("ls -la #{staging_root}")
        puts "DEBUG: staging_root/bin"
        system("ls -la #{staging_root}/bin")
        puts "DEBUG: staging_root/lib"
        system("ls -la #{staging_root}/lib")
        puts "DEBUG: staging_root/Cellar"
        system("ls -la #{staging_root}/Cellar")
        puts "DEBUG: staging_root/Cellar/formula.name"
        system("ls -la #{staging_root}/Cellar/#{formula.name}")
        puts "DEBUG: staging_root/Cellar/formula.name/dep_version"
        system("ls -la #{staging_root}/Cellar/#{formula.name}/#{dep_version}")

        if File.exist?("#{HOMEBREW_CELLAR}/#{formula.name}/#{dep_version}") && !options[:without_deps]
          puts "Staging directory #{HOMEBREW_CELLAR}/#{formula.name}/#{dep_version}"
          safe_system "mkdir", "-p", "#{staging_root}/Cellar/#{formula.name}/"
          safe_system "rsync", "-a", "#{HOMEBREW_CELLAR}/#{formula.name}/#{dep_version}", "#{staging_root}/Cellar/#{formula.name}/"
          safe_system "mkdir", "-p", "#{staging_root}/opt"
          safe_system "ln", "-s", "../Cellar/#{formula.name}/#{dep_version}", "#{staging_root}/opt/#{formula.name}"
        end
      end

      # Write out a LaunchDaemon plist if we have one
      if formula.service?
        puts "Plist found at #{formula.plist_name}, staging for /Library/LaunchDaemons/#{formula.plist_name}.plist"
        launch_daemon_dir = File.join staging_root, "Library", "LaunchDaemons"
        FileUtils.mkdir_p launch_daemon_dir
        fd = File.new(File.join(launch_daemon_dir, "#{formula.plist_name}.plist"), "w")
        fd.write formula.service.to_plist
        fd.close
      end
    end

    # Patchelf
    if options[:relocatable]
      files = Dir.entries(File.join(staging_root, 'bin')).reject { |e| e == '.' || e == '..' }
      files.each { |file| patchelf(options[:output_dir], "#{HOMEBREW_PREFIX}/", File.join('bin', file)) }
    end

    # Zip it
    if options[:compress]
      tgzfile = "#{options[:package_name]}.tar.gz"
      puts "Compressing package #{tgzfile}"
      args = [ "-czf", tgzfile, "-C", options[:output_dir], "." ]
      safe_system "tar", *args
    end

    # Add scripts if we specified --scripts
    found_scripts = false
    if options[:scripts_path] != ''
      if File.directory?(options[:scripts_path])
        pre = File.join(options[:scripts_path],"preinstall")
        post = File.join(options[:scripts_path],"postinstall")
        if File.exist?(pre)
          File.chmod(0755, pre)
          found_scripts = true
          puts "Adding preinstall script"
        end
        if File.exist?(post)
          File.chmod(0755, post)
          found_scripts = true
          puts "Adding postinstall script"
        end
      end
      if not found_scripts
        opoo "No scripts found in #{options[:scripts_path]}"
      end
    end

    # Build it
    pkgfile = "#{options[:package_name]}.pkg"
    puts "Building package #{pkgfile}"
    args = [
      "--quiet",
      "--root", "#{options[:output_dir]}",
      "--identifier", identifier,
      "--version", version
    ]
    if found_scripts
      args << "--scripts"
      args << options[:scripts_path]
    end
    if options[:ownership] != ''
      args << "--ownership"
      args << options[:ownership]
    end
    args << "#{pkgfile}"
    safe_system "pkgbuild", *args

    FileUtils.rm_rf options[:output_dir]
  end
end

Homebrew.pkg
