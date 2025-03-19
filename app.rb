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
      # Load the uploaded image and get dimensions
      image = MiniMagick::Image.open(image_file.path)
      
      # Calculate dimensions to fill the frame while maintaining aspect ratio
      target_width = 3440  # 3840 - (200 * 2)
      target_height = 1760 # 2160 - (200 * 2)
      scale = [target_width.to_f / image.width, target_height.to_f / image.height].max
      new_width = (image.width * scale).to_i
      new_height = (image.height * scale).to_i
      
      # Process everything in a single convert operation
      MiniMagick::Tool::Convert.new do |convert|
        # Input image
        convert << image.path

        # Pre-resize the input image to target dimensions
        convert.resize("#{new_width}x#{new_height}^")
        
        # Center and extend to target dimensions
        convert.background('white')
        convert.gravity('center')
        convert.extent("#{target_width}x#{target_height}")
        
        # Add inner shadow
        convert.shave('2x2')
        convert.border('2')
        convert.bordercolor('rgba(0,0,0,0.1)')
        
        # Create final frame
        convert.background('white')
        convert.gravity('center')
        convert.extent('3840x2160')
        
        # Optimize output
        convert.colorspace('sRGB')
        convert.quality('95')
        convert.strip # Remove metadata to reduce file size
        convert.interlace('Plane') # Progressive JPG
        convert.sampling_factor('4:2:0') # Standard chroma subsampling
        
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
