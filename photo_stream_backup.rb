#!/usr/bin/ruby

# Requires:
# sudo gem install rsync sqlite3 colorize

# Authors:
# Braxton Ehle (https://github.com/braxtone/shared-photo-stream-backupper)
# Adam Candy (https://github.com/adamcandy/shared-photo-stream-backupper)

# Useful for epoch time investigations:
# for f in path/to/output/photos/*; do b="$(basename "$f" | sed -e 's/\.0.*//')"; a=$(expr $b + 978310800); echo $(date -d @$a) $f; done

require 'optparse'

class PhotoStreamBackUpper
  require 'fileutils'
  require 'rsync'
  require 'shellwords'
  require 'sqlite3'
  require 'date'
  require 'colorize'

  PHOTO_STREAM_DIR="#{ENV['HOME']}/Library/Containers/com.apple.cloudphotosd/Data/Library/Application Support/com.apple.cloudphotosd/services/com.apple.photo.icloud.sharedstreams"

  def initialize(streams, destination, verbose = false)
    #raise ArgumentError, "Unable to read destination directory" unless File.readable? File.expand_path(destination)
    @destination = File.expand_path(destination)
    unless File.directory?(destination)
      FileUtils.mkdir_p(destination)
    end

    if streams.nil? 
      @streams = get_all_ps_names
      puts "Defaulting to all streams (no streams selected):"
			puts "  #{@streams.join("\n  ")}"
    elsif streams == ['all']
      @streams = get_all_ps_names
    else
      @streams = streams
    end

    @verbose = verbose
  end

  # Grabs the filename for the Photo Stream tracking SQLITE database
  def get_ps_db_file
    return @ps_sql_file if @ps_sql_file

    share_dir = "#{PHOTO_STREAM_DIR}/coremediastream-state/"

    # Probably a lazy way to do this with the .last method, but all 
    # you should ever get out of this query is ['.', '..', interesting_dir]
    sqlite_dir = Dir.entries(share_dir).select do |entry| 
      File.directory? File.join(share_dir, entry) 
    end.last

    @ps_sql_file = "#{share_dir}#{sqlite_dir}/Model.sqlite"
  end

  # Returns a SQLite DB object if one hasn't already been created
  def get_db_conn
    return @db if @db
    @db = SQLite3::Database.open get_ps_db_file
  end

  # Returns an array of Strings of the shared photo stream names synced to this computer
  def get_all_ps_names
    sql = "SELECT name FROM Albums;"

    get_db_conn.execute(sql).flatten
  end

  # Returns a hash of Photo Stream names to arrays of image UUIDs 
  def get_all_ps_img_uuids
    # Returns a hash of arrays, keys being the names of the shared photostreams
    # and the keys being an array of the UUIDs for each photo
    @streams.reduce( Hash.new { |h,k| h[k] = [] } ) do |acc, stream|
      acc[stream] = get_ps_img_uuids(stream)
    end
  end

  def get_ps_img_uuids(stream_name)
    sql ="SELECT ac.GUID AS 'uuid', ac.photoDate AS 'date'
              FROM AssetCollections AS ac
                JOIN Albums AS a ON a.GUID = ac.albumGUID
              WHERE a.name = \"#{stream_name}\";"

    get_db_conn
    results = @db.execute(sql)
  end

  def get_ps_album_uuid(stream_name)
    sql ="SELECT a.GUID AS 'uuid'
              FROM Albums AS a
              WHERE a.name = \"#{stream_name}\";"

    get_db_conn
    results = @db.execute(sql).flatten.at(0)
  end

  def backup_image(source, dest)
    # Pretty vanilla rsync here, additional --update option added to only copy
    # over files that have changes/are new
    Rsync.run(source, dest, ['--update']) do |result|
      if result.success?
        result.changes.each do |change|
          puts "#{change.filename} (#{change.summary})"
        end
      else
        puts result.error
        puts result.inspect
      end
    end
  end

  # All together now... Main execution for the script that takes in the list
  # of photo streams and copies the images within them to the specified directory
  def run
    @streams.each do |stream|

      streamfolder = "Photostream #{stream}"

      FileUtils::mkdir_p "#{@destination}/#{streamfolder}"

      stream_id = get_ps_album_uuid(stream)

      ids = get_ps_img_uuids(stream)

      puts "Backing up stream '#{stream}', #{ids.size} images"

      count = 0
      errors = 0
      # here we go!  each folder contains 1 or 2 files, either a image, and movie, or both
      # in the case of the live images (which are actually just a two second movie and a picture)
      ids.each do |id|

        folder = Shellwords.escape("#{PHOTO_STREAM_DIR}/assets/#{stream_id}/#{id[0]}/") + '*'
        files = Dir[folder].reject{|f| File.directory?(f) || f.include?('thumbnail')}

        unless id[1].nil?
          time_epoch = 978310800 + Integer(id[1])
        else
          time_epoch = 0
        end
        timestamp = DateTime.strptime("#{time_epoch}",'%s').strftime("%Y%m%d_%H%M%S")
        uuid = "#{id[0]}".tr('-', '').downcase

        if files.size == 0
          puts "  ERROR".red + ", no files found in: #{folder}" if @verbose
          errors += 1
        end

        # files.each do |file|
        #   if file.include?('.5.jpg')
        #     puts "  WARN".yellow + ", found pesky video thumbnail: #{file}"
        #   end
        # #  if File.extname(file).downcase == '.mp4'
        # #    puts files
        # #    base = File.basename(file, '.mp4')
        # #    puts "#{base}.5.jpg"
        # #  end
        # end

        files.each do |file|
          if file.include?('.5.jpg')
            puts "  WARN".yellow + ", found pesky video thumbnail: #{file}  (skipping)" if @verbose
						next
          end
          count += 1
          base = File.basename(file).downcase
          if File.extname(base).downcase == '.jpeg'
            base = File.basename(file, '.jpeg').downcase + '.jpg'
          end
          src_file = Shellwords.escape("#{file}")

          dest_file_plain = "#{@destination}/#{streamfolder}/#{timestamp}-#{uuid}-#{base}"
          dest_file = Shellwords.escape(dest_file_plain)
          puts "#{count}. #{src_file}" if @verbose
          # TODO Add option to overwrite, if needed
          if File.file?(dest_file_plain)
            puts "  (exists) #{dest_file}" if @verbose
          else
            puts "  -> #{dest_file}" if @verbose
            backup_image(src_file, dest_file)
          end
        end

      end

      filecount = Dir[File.join("#{@destination}/#{streamfolder}", '**', '*')].count { |file| File.file?(file) }
      if count != ids.size
        if filecount != ids.size
          puts "  ERROR".red + ", processed #{count} of total #{ids.size}  (#{filecount} files in folder, #{errors} reported errors)"
        else
          puts "  WARN".yellow + ", processed #{count} of total #{ids.size}  (#{filecount} files in folder, #{errors} reported errors)"
        end
      else
        if filecount != count
          msg = "  (" + "WARN".yellow + ": count mismatch, #{filecount} files in folder)"
        else
          msg = ""
        end
        puts "  completed #{count} of total #{ids.size}" + msg
      end

    end
  end
end

if __FILE__ == $0
  options = {}
  OptionParser.new do |opts|
    opts.banner = "Usage: #{__FILE__} [options]"

    opts.on('-s', '--streams X,Y,Z', Array, 'The name of one or more streams that will be backed up, use "all" to back all of them up') do |streams|
      options[:streams] = streams.map(&:strip)
    end

    opts.on('-d', '--destination DEST', 'The destination folder for the images found, ie ~/Dropbox, etc') do |destination|
      options[:destination] = destination
    end

    opts.on("-v", "--[no-]verbose", "Run verbosely") do |v|
      options[:verbose] = v
    end

    opts.on( '-h', '--help', 'Display this screen' ) do
      puts opts
      exit
    end
  end.parse!

   # Validate the options
   required_opts = [:destination]
   missing_opts = required_opts.select { |opt| options[opt].nil? }

   unless missing_opts.empty?
     raise ArgumentError, "Missing required options, please specify the following required options: #{missing_opts.join(',')}"
     puts opts
     exit 1
   end

  # Run all the things!!
  psb = PhotoStreamBackUpper.new(
          options[:streams], 
          options[:destination], 
          options[:verbose]
       )
  psb.run
end
