require 'sinatra'
require 'mini_magick'
require 'json'
require 'tempfile'
require 'zip'
require 'fileutils'

set :public_folder, File.dirname(__FILE__) + '/public'

helpers do
  def process_image(image_file, original_filename)
    # Create a temporary file for the result
    temp_file = Tempfile.new(['framed', '.jpg'])
    
    begin
      # Load the uploaded image
      puts "Loading image from: #{image_file.path}"
      image = MiniMagick::Image.open(image_file.path)
      puts "Image loaded successfully. Format: #{image.type}, Dimensions: #{image.width}x#{image.height}"
      
      # Calculate dimensions to fill the frame while maintaining aspect ratio
      # Target dimensions are frame size minus 200px border on each side
      target_width = 3440  # 3840 - (200 * 2)
      target_height = 1760 # 2160 - (200 * 2)
      
      # Calculate scale to fill the inner frame area
      scale = [target_width.to_f / image.width, target_height.to_f / image.height].max
      new_width = (image.width * scale).to_i
      new_height = (image.height * scale).to_i
      
      puts "Calculated dimensions: #{new_width}x#{new_height}"
      
      # Create a white background
      puts "Creating white background"
      result = MiniMagick::Tool::Convert.new do |convert|
        convert << "-size" << "3840x2160"
        convert << "xc:white"
        convert << "PNG:-"
      end
      result = MiniMagick::Image.read(result)
      
      # Process the image
      puts "Processing image"
      image.format 'png'
      
      # Resize and position the image
      puts "Resizing image"
      image = MiniMagick::Tool::Convert.new do |convert|
        convert << image.path
        convert.resize("#{new_width}x#{new_height}^")
        convert.colorspace('sRGB')
        convert << "PNG:-"
      end
      image = MiniMagick::Image.read(image)
      
      # Create a new image with white background and centered content
      puts "Creating frame"
      framed = MiniMagick::Tool::Convert.new do |convert|
        convert << image.path
        convert.background('white')
        convert.gravity('center')
        convert.extent("#{target_width}x#{target_height}")
        convert.colorspace('sRGB')
        convert << "PNG:-"
      end
      image = MiniMagick::Image.read(framed)
      
      # Add inner shadow
      puts "Adding inner shadow"
      image = MiniMagick::Tool::Convert.new do |convert|
        convert << image.path
        convert.shave('2x2')
        convert.border('2')
        convert.bordercolor('rgba(0,0,0,0.1)')
        convert.colorspace('sRGB')
        convert << "PNG:-"
      end
      image = MiniMagick::Image.read(image)
      
      # Composite onto white background
      puts "Compositing image"
      final = MiniMagick::Tool::Convert.new do |convert|
        convert << result.path
        convert << image.path
        convert.gravity('center')
        convert.compose('Over')
        convert.colorspace('sRGB')
        convert.composite
        convert << "PNG:-"
      end
      result = MiniMagick::Image.read(final)
      
      # Convert to JPEG and save with high quality
      puts "Saving result"
      result = MiniMagick::Tool::Convert.new do |convert|
        convert << result.path
        convert.colorspace('sRGB')
        convert.quality('95')
        convert << "JPG:-"
      end
      result = MiniMagick::Image.read(result)
      result.write(temp_file.path)
      
      puts "Image processing completed successfully"
    rescue MiniMagick::Error => e
      puts "MiniMagick error: #{e.message}"
      puts "Command output: #{e.output}" if e.respond_to?(:output)
      raise
    rescue => e
      puts "Unexpected error: #{e.message}"
      raise
    end
    
    # Return the temp file and the framed filename
    [temp_file, "framed_#{original_filename.sub(/\.[^.]+\z/, '')}.jpg"]
  end
end

get '/' do
  erb :index
end

post '/frame' do
  begin
    # Debug output
    puts "Received params: #{params.inspect}"
    
    # Check if files were uploaded
    unless params[:images] && !params[:images].empty?
      status 400
      return "No images uploaded"
    end

    content_type :json

    # Create a temporary directory for processed images
    temp_dir = Dir.mktmpdir
    processed_files = []
    errors = []

    # Process each uploaded file
    params[:images].each do |upload|
      begin
        puts "Processing file: #{upload.inspect}"
        
        # Save uploaded file to disk temporarily
        temp_upload = Tempfile.new(['upload', File.extname(upload[:filename])])
        temp_upload.binmode
        temp_upload.write(upload[:tempfile].read)
        temp_upload.rewind
        
        puts "Saved temp file at: #{temp_upload.path}"
        puts "File size: #{File.size(temp_upload.path)} bytes"
        
        # Process the image
        temp_file, framed_filename = process_image(temp_upload, upload[:filename])
        
        # Move the processed file to temp directory
        FileUtils.mv(temp_file.path, File.join(temp_dir, framed_filename))
        processed_files << framed_filename
        puts "Successfully processed: #{framed_filename}"
        
        # Clean up temp file
        temp_upload.close
        temp_upload.unlink
      rescue => e
        puts "Error processing file: #{e.message}"
        puts "Error class: #{e.class}"
        puts e.backtrace.join("\n")
        errors << "Error processing #{upload[:filename]}: #{e.message}"
      end
    end

    if errors.any?
      status 500
      return "Errors occurred: #{errors.join(', ')}"
    end

    # Ensure public/downloads directory exists
    FileUtils.mkdir_p('public/downloads')
    timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
    
    if processed_files.length == 1
      # For single image, just move it to downloads directory
      filename = processed_files.first
      download_path = File.join('public/downloads', filename)
      FileUtils.cp(File.join(temp_dir, filename), download_path)
      download_url = "/downloads/#{filename}"
    else
      # For multiple images, create a ZIP file
      zip_filename = "framed_images_#{timestamp}.zip"
      zip_path = File.join('public/downloads', zip_filename)
      
      # Create the ZIP file in the downloads directory
      Zip::File.open(zip_path, Zip::File::CREATE) do |zipfile|
        processed_files.each do |filename|
          zipfile.add(filename, File.join(temp_dir, filename))
        end
      end
      download_url = "/downloads/#{zip_filename}"
    end

    # Clean up the temporary directory
    FileUtils.remove_entry temp_dir

    # Return the download URL, count, and filename
    {
      url: download_url,
      count: processed_files.length,
      filename: processed_files.length == 1 ? processed_files.first : "framed_images_#{timestamp}.zip"
    }.to_json
  rescue => e
    status 500
    "Error processing images: #{e.message}"
  end
end
