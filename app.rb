require 'sinatra'
require 'mini_magick'
require 'json'
require 'tempfile'

set :public_folder, File.dirname(__FILE__) + '/public'

get '/' do
  erb :index
end

post '/frame' do
  begin
    # Get the uploaded file
    image_file = params[:image][:tempfile]
    original_filename = params[:image][:filename]
    
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
    
    # Set response headers
    content_type 'image/jpeg'
    attachment "framed_#{original_filename.sub(/\.[^.]+\z/, '')}.jpg"
    
    # Send the file
    send_file temp_file.path
  rescue => e
    status 500
    "Error processing image: #{e.message}"
  end
end
