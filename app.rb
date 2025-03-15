require 'sinatra'
require 'mini_magick'
require 'json'
require 'tempfile'
require 'zip'

set :public_folder, File.dirname(__FILE__) + '/public'

helpers do
  def process_image(image_file, original_filename)
    # Create a temporary file for the result
    temp_file = Tempfile.new(['framed', '.jpg'])
    
    # Load the uploaded image
    image = MiniMagick::Image.new(image_file.path)
    
    # Calculate dimensions to fill the frame while maintaining aspect ratio
    # Target dimensions are frame size minus 200px border on each side
    target_width = 3440  # 3840 - (200 * 2)
    target_height = 1760 # 2160 - (200 * 2)
    
    # Calculate scale to fill the inner frame area
    scale = [target_width.to_f / image[:width], target_height.to_f / image[:height]].max
    new_width = (image[:width] * scale).to_i
    new_height = (image[:height] * scale).to_i
    
    # Create a white background
    result = MiniMagick::Image.new(3840, 2160) { |b| b.background "white" }
    
    # Process the image
    image.resize "#{new_width}x#{new_height}^"
    image.gravity 'center'
    image.background 'white'
    image.extent "#{target_width}x#{target_height}"
    
    # Add inner shadow
    image.shave '2x2'
    image.border '2'
    image.bordercolor 'rgba(0,0,0,0.1)'
    
    # Composite onto white background
    result = result.composite(image) do |c|
      c.compose 'Over'
      c.gravity 'center'
    end
    
    # Save to temp file
    result.write temp_file.path
    
    # Return the temp file and the framed filename
    [temp_file, "framed_#{original_filename.sub(/\.[^.]+\z/, '')}.jpg"]
  end
end

get '/' do
  erb :index
end

post '/frame' do
  begin
    # Check if files were uploaded
    unless params[:images] && params[:images].any?
      status 400
      return "No images uploaded"
    end

    # Create a temporary directory for processed images
    temp_dir = Dir.mktmpdir
    processed_files = []
    errors = []

    # Process each uploaded file
    params[:images].each do |upload|
      begin
        temp_file, framed_filename = process_image(upload[:tempfile], upload[:filename])
        
        # Move the processed file to temp directory
        FileUtils.mv(temp_file.path, File.join(temp_dir, framed_filename))
        processed_files << framed_filename
      rescue => e
        errors << "Error processing #{upload[:filename]}: #{e.message}"
      end
    end

    if errors.any?
      status 500
      return "Errors occurred: #{errors.join(', ')}"
    end

    # Create a ZIP file containing all processed images
    zip_file = Tempfile.new(['framed_images', '.zip'])
    
    Zip::File.open(zip_file.path, Zip::File::CREATE) do |zipfile|
      processed_files.each do |filename|
        zipfile.add(filename, File.join(temp_dir, filename))
      end
    end

    # Clean up the temporary directory
    FileUtils.remove_entry temp_dir

    # Send the ZIP file
    content_type 'application/zip'
    attachment "framed_images_#{Time.now.strftime('%Y%m%d_%H%M%S')}.zip"
    send_file zip_file.path
  rescue => e
    status 500
    "Error processing images: #{e.message}"
  end
end
