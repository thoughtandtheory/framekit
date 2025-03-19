require 'sinatra'
require 'mini_magick'
require 'json'
require 'tempfile'
require 'zip'
require 'fileutils'
require 'securerandom'

set :public_folder, File.dirname(__FILE__) + '/public'

# Store previews in memory (in production, use Redis or similar)
$previews = {}

helpers do
  def generate_preview_id
    SecureRandom.uuid
  end

  def save_preview(preview_id, file_path, original_filename)
    $previews[preview_id] = {
      path: file_path,
      filename: "framed_#{original_filename.sub(/\.[^.]+\z/, '')}.jpg",
      selected: false
    }
  end
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

post '/preview' do
  begin
    # Check if files were uploaded
    unless params[:images] && !params[:images].empty?
      status 400
      return "No images uploaded"
    end

    content_type :json
    previews = []

    params[:images].each do |upload|
      begin
        # Save uploaded file to disk temporarily
        temp_upload = Tempfile.new(['upload', File.extname(upload[:filename])])
        temp_upload.binmode
        temp_upload.write(upload[:tempfile].read)
        temp_upload.rewind

        # Process the image
        temp_file, framed_filename = process_image(temp_upload, upload[:filename])
        
        # Generate preview ID and save preview info
        preview_id = generate_preview_id
        preview_path = "public/previews/#{preview_id}.jpg"
        FileUtils.mkdir_p('public/previews')
        FileUtils.mv(temp_file.path, preview_path)
        
        save_preview(preview_id, preview_path, upload[:filename])
        
        previews << {
          id: preview_id,
          url: "/previews/#{preview_id}.jpg",
          filename: upload[:filename]
        }

        temp_upload.close
        temp_upload.unlink
      rescue => e
        puts "Error processing file: #{e.message}"
        return { error: "Error processing #{upload[:filename]}: #{e.message}" }.to_json
      end
    end

    { previews: previews }.to_json
  rescue => e
    status 500
    { error: "Error processing images: #{e.message}" }.to_json
  end
end

post '/export' do
  begin
    content_type :json
    data = JSON.parse(request.body.read)
    selected_ids = data['selectedIds'] || []

    if selected_ids.empty?
      status 400
      return { error: "No images selected" }.to_json
    end

    # Filter valid preview IDs
    valid_previews = selected_ids.map { |id| $previews[id] }.compact

    if valid_previews.empty?
      status 400
      return { error: "No valid images found" }.to_json
    end

    # Ensure downloads directory exists
    FileUtils.mkdir_p('public/downloads')
    timestamp = Time.now.strftime('%Y%m%d_%H%M%S')

    if valid_previews.length == 1
      # For single image, just copy it to downloads
      preview = valid_previews.first
      download_filename = preview[:filename]
      download_path = File.join('public/downloads', download_filename)
      FileUtils.cp(preview[:path], download_path)
      
      {
        url: "/downloads/#{download_filename}",
        filename: download_filename,
        count: 1
      }.to_json
    else
      # For multiple images, create a ZIP
      zip_filename = "framed_images_#{timestamp}.zip"
      zip_path = File.join('public/downloads', zip_filename)

      Zip::File.open(zip_path, Zip::File::CREATE) do |zipfile|
        valid_previews.each do |preview|
          zipfile.add(preview[:filename], preview[:path])
        end
      end

      {
        url: "/downloads/#{zip_filename}",
        filename: zip_filename,
        count: valid_previews.length
      }.to_json
    end
  rescue => e
    status 500
    { error: "Error exporting images: #{e.message}" }.to_json
  end
end
