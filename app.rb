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

  def save_preview(preview_id, file_path, original_path, original_filename, gravity)
    $previews[preview_id] = {
      path: file_path,
      original_path: original_path,
      filename: original_filename,
      gravity: gravity
    }
  end
  def process_image(image_file, original_filename, gravity = 'center')
    # Create a temporary file for the result
    temp_file = Tempfile.new(['framed', '.jpg'])
    
    begin
      # Load the uploaded image and get dimensions
      image = MiniMagick::Image.open(image_file.path)
      
      # Calculate dimensions to fill the frame while maintaining aspect ratio
      target_width = 3440  # 3840 - (200 * 2)
      target_height = 1760 # 2160 - (200 * 2)
      
      # Calculate scale to fill the frame (cover) while maintaining aspect ratio
      scale = [target_width.to_f / image.width, target_height.to_f / image.height].max
      
      # Calculate dimensions that maintain aspect ratio and ensure coverage
      new_width = (image.width * scale).to_i
      new_height = (image.height * scale).to_i
      
      # Process everything in a single convert operation
      MiniMagick::Tool::Convert.new do |convert|
        # Input image
        convert << image.path

        # Set up initial parameters for cropping
        convert.background('white')
        
        # Apply gravity for initial crop
        case gravity
        when 'top'
          convert.gravity('north')
        when 'bottom'
          convert.gravity('south')
        else
          convert.gravity('center')
        end

        # Resize larger than needed to ensure we have enough image to crop from
        convert.resize("#{new_width}x#{new_height}^")
        
        # Crop to exact dimensions using the specified gravity
        convert.extent("#{target_width}x#{target_height}")
        
        # Create the frame with the cropped image centered
        convert.gravity('center')
        convert.background('white')
        convert.extent('3840x2160')
        
        # Add inner shadow
        convert.shave('2x2')
        convert.border('2')
        convert.bordercolor('rgba(0,0,0,0.1)')
        
        # Optimize JPEG output
        convert.colorspace('sRGB')
        convert.quality('95')       # High quality for frame images
        convert.strip               # Remove metadata
        convert.interlace('Plane')  # Progressive loading
        convert.sampling_factor('4:2:0')  # Standard chroma subsampling
        
        # Output as high-quality JPEG
        convert << temp_file.path
      end
      
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

    # Validate gravity
    gravity = params[:gravity] || 'center'
    unless ['top', 'center', 'bottom'].include?(gravity)
      status 400
      return { error: "Invalid gravity: #{gravity}" }.to_json
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

        # Save original file for reprocessing
        original_path = "public/originals/#{File.basename(temp_upload.path)}"
        FileUtils.mkdir_p('public/originals')
        FileUtils.cp(temp_upload.path, original_path)

        # Process the image with specified gravity
        temp_file, framed_filename = process_image(File.new(original_path), upload[:filename], gravity)
        
        # Generate preview ID and save preview info
        preview_id = generate_preview_id
        preview_path = "public/previews/#{preview_id}.jpg"
        FileUtils.mkdir_p('public/previews')
        FileUtils.mv(temp_file.path, preview_path)
        
        # Save preview with gravity setting for reprocessing
        save_preview(preview_id, preview_path, original_path, upload[:filename], gravity)
        
        previews << {
          id: preview_id,
          url: "/previews/#{preview_id}.jpg",
          filename: upload[:filename],
          gravity: gravity
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

post '/reprocess' do
  content_type :json
  begin
    data = JSON.parse(request.body.read)
    preview_id = data['previewId']
    gravity = data['gravity'] || 'center'

    # Validate parameters
    unless preview_id && $previews[preview_id]
      status 400
      return { error: "Invalid preview ID" }.to_json
    end

    unless ['top', 'center', 'bottom'].include?(gravity)
      status 400
      return { error: "Invalid gravity: #{gravity}" }.to_json
    end

    preview = $previews[preview_id]
    original_file = File.new(preview[:original_path])

    # Process the image with new gravity setting
    temp_file, _ = process_image(original_file, preview[:filename], gravity)
    preview_path = "public/previews/#{preview_id}.jpg"
    FileUtils.mv(temp_file.path, preview_path)

    # Update preview info
    $previews[preview_id][:gravity] = gravity

    {
      url: "/previews/#{preview_id}.jpg",
      gravity: gravity
    }.to_json
  rescue JSON::ParserError
    status 400
    { error: "Invalid JSON in request" }.to_json
  rescue => e
    status 500
    { error: "Error reprocessing image: #{e.message}" }.to_json
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

    # Clean up old downloads
    FileUtils.rm_rf('public/downloads')
    FileUtils.mkdir_p('public/downloads')
    timestamp = Time.now.strftime('%Y%m%d_%H%M%S')

    if valid_previews.length == 1
      # For single image, just copy it to downloads
      preview = valid_previews.first
      # Ensure .jpg extension
      base_filename = preview[:filename].sub(/\.[^.]+\z/, '')
      download_filename = "framed_#{base_filename}.jpg"
      download_path = File.join('public/downloads', download_filename)
      FileUtils.cp(preview[:path], download_path)
      
      # Return JSON response for single file
      {
        url: "/downloads/#{download_filename}",
        filename: download_filename,
        count: 1
      }.to_json
    else
      # For multiple images, create a ZIP
      zip_filename = "framed_images_#{timestamp}.zip"
      zip_path = File.join('public/downloads', zip_filename)

      # Create ZIP file with all images
      begin
        # Ensure all source files exist before creating ZIP
        missing_files = valid_previews.reject { |preview| File.exist?(preview[:path]) }
        if missing_files.any?
          status 500
          return { error: "Some source images are missing" }.to_json
        end

        # Create ZIP with proper error handling
        Zip::File.open(zip_path, Zip::File::CREATE) do |zipfile|
          valid_previews.each do |preview|
            base_filename = preview[:filename].sub(/\.[^.]+\z/, '')
            source_path = preview[:path]
            
            # Verify source file again before adding to ZIP
            unless File.exist?(source_path) && File.size(source_path) > 0
              raise "Source file missing or empty: #{source_path}"
            end
            
            zipfile.add("framed_#{base_filename}.jpg", source_path)
          end
        end

        # Verify ZIP was created successfully
        unless File.exist?(zip_path) && File.size(zip_path) > 0
          raise "ZIP file creation failed or file is empty"
        end

        # Return JSON response for ZIP file
        {
          url: "/downloads/#{zip_filename}",
          filename: zip_filename,
          count: valid_previews.length
        }.to_json
      rescue => e
        puts "ZIP creation error: #{e.message}"
        status 500
        return { error: "Error creating ZIP file: #{e.message}" }.to_json
      end
    end
  rescue => e
    status 500
    { error: "Error exporting images: #{e.message}" }.to_json
  end
end
