require 'sinatra'
require 'mini_magick'
require 'json'
require 'tempfile'
require 'zip'
require 'fileutils'

require 'securerandom'

set :public_folder, File.dirname(__FILE__) + '/public'

# Define valid gravity settings
VALID_GRAVITIES = ['center', 'north', 'south', 'west', 'east', 'northwest', 'northeast', 'southwest', 'southeast', 'top', 'bottom'].freeze

# Store previews in memory (in production, use Redis or similar)
$previews = {}

helpers do
  def partial(template, locals = {})
    # Pass all locals from parent template
    erb("partials/#{template}".to_sym, locals: locals.merge(local_variables.each_with_object({}) { |v, h| h[v] = binding.local_variable_get(v) }))
  end

  def current_page
    case request.path_info
    when '/' then 'single'
    when '/double' then 'double'
    when '/triple' then 'triple'
    end
  end

  def generate_preview_id
    SecureRandom.uuid
  end

  def save_preview(preview_id, file_path, original_path, original_filename, gravity)
    $previews[preview_id] = {
      'path' => file_path,
      'original_path' => original_path,
      'filename' => original_filename,
      'gravity' => gravity
    }
  end

  def save_uploaded_file(upload)
    temp = Tempfile.new(['upload', File.extname(upload[:filename])])
    temp.binmode
    temp.write(upload[:tempfile].read)
    temp.rewind
    temp
  end

  def save_original_file(temp_file)
    original_path = "public/originals/#{File.basename(temp_file.path)}"
    FileUtils.mkdir_p('public/originals')
    FileUtils.cp(temp_file.path, original_path)
    original_path
  end
  def process_image(image_file, original_filename, gravity = 'center', target_width = 3440, target_height = 1760, skip_frame = false)
    # Create a temporary file for the result
    temp_file = Tempfile.new(['framed', '.jpg'])
    
    begin
      # Load the uploaded image and get dimensions
      image = MiniMagick::Image.open(image_file.path)
      
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
        when 'top', 'north'
          convert.gravity('north')
        when 'bottom', 'south'
          convert.gravity('south')
        when 'west'
          convert.gravity('west')
        when 'east'
          convert.gravity('east')
        when 'northwest'
          convert.gravity('northwest')
        when 'northeast'
          convert.gravity('northeast')
        when 'southwest'
          convert.gravity('southwest')
        when 'southeast'
          convert.gravity('southeast')
        else
          convert.gravity('center')
        end

        # Resize larger than needed to ensure we have enough image to crop from
        convert.resize("#{new_width}x#{new_height}^")
        
        # Crop to exact dimensions using the specified gravity
        convert.extent("#{target_width}x#{target_height}")
        
        unless skip_frame
          # Create the frame with the cropped image centered
          convert.gravity('center')
          convert.background('white')
          convert.extent("#{target_width + 400}x#{target_height + 400}")
          
          # Add inner shadow
          convert.shave('2x2')
          convert.border('2')
          convert.bordercolor('rgba(0,0,0,0.1)')
        end
        
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

  def process_with_shadow(image_file, filename, gravity, width, height)
    temp = Tempfile.new(['shadow', '.jpg'])
    begin
      # Account for shadow border in dimensions
      shadow_width = width - 4  # 2px on each side
      shadow_height = height - 4  # 2px on each side
      
      # Process image without frame and shadow
      processed, _ = process_image(image_file, filename, gravity, shadow_width, shadow_height, true)
      
      # Add inset shadow
      MiniMagick::Tool::Convert.new do |convert|
        convert << processed.path
        convert.shave('1x1')  # Reduced from 2x2 to account for border
        convert.border('1')   # Reduced from 2 to stay within dimensions
        convert.bordercolor('rgba(0,0,0,0.08)')  # Slightly reduced opacity
        convert << temp.path
      end
      temp
    ensure
      processed&.close
      processed&.unlink
    end
  end

  def process_triple_image(left_file, middle_file, right_file, left_filename, middle_filename, right_filename, left_gravity = 'center', middle_gravity = 'center', right_gravity = 'center')
    # Create a temporary file for the result
    temp_file = Tempfile.new(['framed_triple', '.jpg'])
    
    begin
      # Calculate dimensions ensuring we stay within 3840x2160
      border_spacing = 140  # Reduced to give more space to images
      total_width = 3840
      total_height = 2160
      
      # Available space for images after borders
      available_width = total_width - (border_spacing * 4)  # 4 borders: left, between images, and right
      single_width = (available_width / 3).floor  # Divide remaining space equally and ensure integer
      height = (total_height - (border_spacing * 2)).floor  # Top and bottom borders, ensure integer
      
      # Process images with shadow effect
      left_temp = process_with_shadow(left_file, left_filename, left_gravity, single_width, height)
      middle_temp = process_with_shadow(middle_file, middle_filename, middle_gravity, single_width, height)
      right_temp = process_with_shadow(right_file, right_filename, right_gravity, single_width, height)
      
      # Combine images with white borders
      MiniMagick::Tool::Convert.new do |convert|
        # Create a white canvas for the background
        convert.size("#{total_width}x#{total_height}")
        convert.xc('white')
        
        # Calculate positions
        left_x = border_spacing
        middle_x = left_x + single_width + border_spacing
        right_x = middle_x + single_width + border_spacing
        y = border_spacing
        
        # Place images
        convert.draw("image over #{left_x},#{y} 0,0 '#{left_temp.path}'")
        convert.draw("image over #{middle_x},#{y} 0,0 '#{middle_temp.path}'")
        convert.draw("image over #{right_x},#{y} 0,0 '#{right_temp.path}'")
        
        # Optimize output
        convert.colorspace('sRGB')
        convert.quality('95')
        convert.strip
        convert.interlace('Plane')
        convert.sampling_factor('4:2:0')
        
        # Output final image
        convert << temp_file.path
      end
      
      puts "Triple image processing completed successfully"
    rescue MiniMagick::Error => e
      puts "MiniMagick error: #{e.message}"
      puts "Command output: #{e.output}" if e.respond_to?(:output)
      raise
    rescue => e
      puts "Unexpected error: #{e.message}"
      raise
    ensure
      # Clean up temporary files
      [left_temp, middle_temp, right_temp].each do |temp|
        temp&.close
        temp&.unlink
      end
    end
    
    # Return the temp file and the framed filename
    [temp_file, "framed_triple_#{Time.now.strftime('%Y%m%d_%H%M%S')}.jpg"]
  end

  def process_double_image(left_file, right_file, left_filename, right_filename, left_gravity = 'center', right_gravity = 'center')
    # Create a temporary file for the result
    temp_file = Tempfile.new(['framed_double', '.jpg'])
    
    begin
      # Calculate dimensions
      # Total width: 3840px
      # Total height: 2160px
      # Border: 200px on all sides and between images
      # Available width for images: 3840 - (200 * 3) = 3240px
      # Each image width: 3240 / 2 = 1620px
      # Available height: 2160 - (200 * 2) = 1760px
      
      left_width = right_width = 1620  # (3840 - (200 * 3)) / 2
      height = 1760                    # 2160 - (200 * 2)
      
      left_temp, _ = process_image(left_file, left_filename, left_gravity, left_width, height, true)
      right_temp, _ = process_image(right_file, right_filename, right_gravity, right_width, height, true)
      
      # Combine images with white border
      MiniMagick::Tool::Convert.new do |convert|
        # Create a white canvas for the background
        convert.size('3840x2160')
        convert.xc('white')
        
        # Place left image (200px from left edge)
        convert.draw("image over #{200},200 0,0 '#{left_temp.path}'")
        
        # Place right image (200px from left image)
        convert.draw("image over #{200 + left_width + 200},200 0,0 '#{right_temp.path}'")
        
        # Optimize output
        convert.colorspace('sRGB')
        convert.quality('95')
        convert.strip
        convert.interlace('Plane')
        convert.sampling_factor('4:2:0')
        
        # Output final image
        convert << temp_file.path
      end
      
      puts "Double image processing completed successfully"
    rescue MiniMagick::Error => e
      puts "MiniMagick error: #{e.message}"
      puts "Command output: #{e.output}" if e.respond_to?(:output)
      raise
    rescue => e
      puts "Unexpected error: #{e.message}"
      raise
    ensure
      # Clean up temporary files
      left_temp&.close
      right_temp&.close
      left_temp&.unlink
      right_temp&.unlink
    end
    
    # Return the temp file and the framed filename
    [temp_file, "framed_double_#{Time.now.strftime('%Y%m%d_%H%M%S')}.jpg"]
  end
end

get '/' do
  erb :index, locals: { title: 'Single Frame', frame_type: 'one' }
end

get '/double' do
  erb :double, locals: { title: 'Double Frame', frame_type: 'two' }
end

get '/triple' do
  erb :triple, locals: { title: 'Triple Frame', frame_type: 'three' }
end

post '/preview-triple' do
  begin
    # Check if files were uploaded
    unless params[:leftImage] && params[:middleImage] && params[:rightImage]
      status 400
      return "Missing required images"
    end

    content_type :json

    # Generate a preview ID
    preview_id = generate_preview_id

    # Save uploaded files to disk temporarily
    left_temp = save_uploaded_file(params[:leftImage])
    middle_temp = save_uploaded_file(params[:middleImage])
    right_temp = save_uploaded_file(params[:rightImage])

    # Save original files for reprocessing
    left_original = save_original_file(left_temp)
    middle_original = save_original_file(middle_temp)
    right_original = save_original_file(right_temp)

    # Process the triple image
    temp_file, filename = process_triple_image(
      File.new(left_temp.path),
      File.new(middle_temp.path),
      File.new(right_temp.path),
      params[:leftImage][:filename],
      params[:middleImage][:filename],
      params[:rightImage][:filename]
    )

    # Save the preview
    preview_path = "public/previews/#{File.basename(temp_file.path)}"
    FileUtils.cp(temp_file.path, preview_path)

    # Store preview information
    $previews[preview_id] = {
      'path' => preview_path,
      'left_original' => left_original,
      'middle_original' => middle_original,
      'right_original' => right_original,
      'left_filename' => params[:leftImage][:filename],
      'middle_filename' => params[:middleImage][:filename],
      'right_filename' => params[:rightImage][:filename],
      'left_gravity' => 'center',
      'middle_gravity' => 'center',
      'right_gravity' => 'center'
    }

    # Return preview information
    {
      'id' => preview_id,
      'url' => "/previews/#{File.basename(temp_file.path)}?t=#{Time.now.to_i}",
      'leftGravity' => 'center',
      'middleGravity' => 'center',
      'rightGravity' => 'center'
    }.to_json
  rescue => e
    puts "Error: #{e.message}"
    puts e.backtrace
    status 500
    { 'error' => e.message }.to_json
  ensure
    # Clean up temporary files
    [left_temp, middle_temp, right_temp, temp_file].each do |temp|
      temp&.close
      temp&.unlink
    end
  end
end

post '/reprocess-triple' do
  content_type :json
  begin
    puts "Received reprocess-triple request"
    data = JSON.parse(request.body.read)
    puts "Request data: #{data.inspect}"
    preview_id = data['previewId']
    position = data['position']
    gravity = data['gravity']

    puts "Validating parameters: preview_id=#{preview_id}, position=#{position}, gravity=#{gravity}"
    unless preview_id && position && gravity && VALID_GRAVITIES.include?(gravity)
      error_msg = "Invalid parameters: preview_id=#{preview_id}, position=#{position}, gravity=#{gravity}, valid_gravity=#{VALID_GRAVITIES.include?(gravity)}"
      puts error_msg
      status 400
      return { 'error' => error_msg }.to_json
    end

    preview = $previews[preview_id]
    puts "Found preview: #{preview ? 'yes' : 'no'}"
    unless preview
      status 404
      return { 'error' => 'Preview not found' }.to_json
    end

    puts "Preview data: #{preview.inspect}"

    # Update gravity for the specified position
    puts "Before update: #{position}_gravity = #{preview["#{position}_gravity"]}"
    preview["#{position}_gravity"] = gravity
    puts "After update: #{position}_gravity = #{preview["#{position}_gravity"]}"
    puts "All gravities: left=#{preview['left_gravity']}, middle=#{preview['middle_gravity']}, right=#{preview['right_gravity']}"

    # Process the triple image with updated gravity settings
    puts "Starting image processing"
    temp_file, _ = process_triple_image(
      File.new(preview['left_original']),
      File.new(preview['middle_original']),
      File.new(preview['right_original']),
      preview['left_filename'],
      preview['middle_filename'],
      preview['right_filename'],
      preview['left_gravity'],
      preview['middle_gravity'],
      preview['right_gravity']
    )
    puts "Processing complete with gravities: left=#{preview['left_gravity']}, middle=#{preview['middle_gravity']}, right=#{preview['right_gravity']}"

    # Update the preview file
    puts "Copying temp file to preview path"
    FileUtils.cp(temp_file.path, preview['path'])

    # Return the updated preview URL with cache-busting timestamp
    response = { 'url' => "/previews/#{File.basename(preview['path'])}?t=#{Time.now.to_i}" }
    puts "Sending response: #{response.inspect}"
    response.to_json
  rescue => e
    puts "Error: #{e.message}"
    puts e.backtrace
    status 500
    { 'error' => e.message }.to_json
  ensure
    temp_file&.close
    temp_file&.unlink
  end
end

post '/preview' do
  begin
    # Check if files were uploaded
    unless params[:images] && !params[:images].empty?
      content_type :json
      status 400
      return { 'error' => 'No images uploaded' }.to_json
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

        # Process the image with center gravity by default
        temp_file, framed_filename = process_image(File.new(original_path), upload[:filename], 'center')
        
        # Generate preview ID and save preview info
        preview_id = generate_preview_id
        preview_path = "public/previews/#{preview_id}.jpg"
        FileUtils.mkdir_p('public/previews')
        FileUtils.mv(temp_file.path, preview_path)
        
        # Save preview with gravity setting for reprocessing
        save_preview(preview_id, preview_path, original_path, upload[:filename], 'center')
        
        previews << {
          'id' => preview_id,
          'url' => "/previews/#{preview_id}.jpg",
          'filename' => upload[:filename],
          'gravity' => 'center'
        }

        temp_upload.close
        temp_upload.unlink
      rescue => e
        puts "Error processing file: #{e.message}"
        return { 'error' => "Error processing #{upload[:filename]}: #{e.message}" }.to_json
      end
    end

    { 'previews' => previews }.to_json
  rescue => e
    status 500
    { 'error' => "Error processing images: #{e.message}" }.to_json
  end
end

post '/preview-double' do
  begin
    # Check if exactly two files were uploaded
    unless params[:images] && params[:images].length == 2
      status 400
      return { 'error' => "Please upload exactly two images" }.to_json
    end

    content_type :json
    left_upload = params[:images][0]
    right_upload = params[:images][1]

    # Save uploaded files to disk temporarily
    left_temp = Tempfile.new(['upload_left', File.extname(left_upload[:filename])])
    right_temp = Tempfile.new(['upload_right', File.extname(right_upload[:filename])])

    begin
      # Save left image
      left_temp.binmode
      left_temp.write(left_upload[:tempfile].read)
      left_temp.rewind

      # Save right image
      right_temp.binmode
      right_temp.write(right_upload[:tempfile].read)
      right_temp.rewind

      # Save original files for reprocessing
      left_original = "public/originals/#{File.basename(left_temp.path)}"
      right_original = "public/originals/#{File.basename(right_temp.path)}"
      FileUtils.mkdir_p('public/originals')
      FileUtils.cp(left_temp.path, left_original)
      FileUtils.cp(right_temp.path, right_original)

      # Process both images with west/east gravity by default for better side-by-side alignment
      temp_file, framed_filename = process_double_image(
        File.new(left_original),
        File.new(right_original),
        left_upload[:filename],
        right_upload[:filename],
        'east',  # Right-align left image
        'west'   # Left-align right image
      )

      # Generate preview ID and save preview info
      preview_id = generate_preview_id
      preview_path = "public/previews/#{preview_id}.jpg"
      FileUtils.mkdir_p('public/previews')
      FileUtils.mv(temp_file.path, preview_path)

      # Save preview info for both images
      $previews[preview_id] = {
        'path' => preview_path,
        'left_original' => left_original,
        'right_original' => right_original,
        'left_filename' => left_upload[:filename],
        'right_filename' => right_upload[:filename],
        'left_gravity' => 'east',   # Right-align left image
        'right_gravity' => 'west'  # Left-align right image
      }

      {
        'preview' => {
          'id' => preview_id,
          'url' => "/previews/#{preview_id}.jpg",
          'leftGravity' => 'east',   # Right-align left image
          'rightGravity' => 'west'  # Left-align right image
        }
      }.to_json

    ensure
      left_temp.close
      right_temp.close
      left_temp.unlink
      right_temp.unlink
    end

  rescue => e
    status 500
    { 'error' => "Error processing images: #{e.message}" }.to_json
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
      return { 'error' => "Invalid preview ID" }.to_json
    end

    unless VALID_GRAVITIES.include?(gravity)
      status 400
      return { 'error' => "Invalid gravity: #{gravity}" }.to_json
    end

    preview = $previews[preview_id]
    original_file = File.new(preview['original_path'])

    # Process the image with new gravity setting
    temp_file, _ = process_image(original_file, preview['filename'], gravity)
    preview_path = "public/previews/#{preview_id}.jpg"
    FileUtils.mv(temp_file.path, preview_path)

    # Update preview info
    $previews[preview_id]['gravity'] = gravity

    {
      'url' => "/previews/#{preview_id}.jpg",
      'gravity' => gravity
    }.to_json
  rescue JSON::ParserError
    status 400
    { 'error' => "Invalid JSON in request" }.to_json
  rescue => e
    status 500
    { 'error' => "Error reprocessing image: #{e.message}" }.to_json
  end
end

post '/reprocess-double' do
  content_type :json
  begin
    data = JSON.parse(request.body.read)
    preview_id = data['previewId']
    position = data['position']
    gravity = data['gravity'] || 'center'

    # Validate parameters
    unless preview_id && $previews[preview_id]
      status 400
      return { 'error' => "Invalid preview ID" }.to_json
    end

    unless ['left', 'right'].include?(position)
      status 400
      return { 'error' => "Invalid position: #{position}" }.to_json
    end

    unless VALID_GRAVITIES.include?(gravity)
      status 400
      return { 'error' => "Invalid gravity: #{gravity}" }.to_json
    end

    preview = $previews[preview_id]
    
    # Update the gravity for the specified position
    if position == 'left'
      preview['left_gravity'] = gravity
    else
      preview['right_gravity'] = gravity
    end

    # Process both images with updated gravity settings
    temp_file, _ = process_double_image(
      File.new(preview['left_original']),
      File.new(preview['right_original']),
      preview['left_filename'],
      preview['right_filename'],
      preview['left_gravity'],
      preview['right_gravity']
    )

    # Update preview file
    preview_path = "public/previews/#{preview_id}.jpg"
    FileUtils.mv(temp_file.path, preview_path)

    {
      'url' => "/previews/#{preview_id}.jpg",
      'leftGravity' => preview['left_gravity'],
      'rightGravity' => preview['right_gravity']
    }.to_json
  rescue JSON::ParserError
    status 400
    { error: "Invalid JSON in request" }.to_json
  rescue => e
    status 500
    { error: "Error reprocessing double frame: #{e.message}" }.to_json
  end
end

post '/export' do
  begin
    content_type :json
    data = JSON.parse(request.body.read)
    # Handle both single previewId and selectedIds array
    selected_ids = if data['previewId']
      [data['previewId']]
    else
      data['selectedIds'] || []
    end

    if selected_ids.empty?
      status 400
      return { 'error' => "No images selected" }.to_json
    end

    # Filter valid preview IDs
    valid_previews = selected_ids.map { |id| $previews[id] }.compact

    if valid_previews.empty?
      status 400
      return { 'error' => "No valid images found" }.to_json
    end

    # Clean up old downloads
    FileUtils.rm_rf('public/downloads')
    FileUtils.mkdir_p('public/downloads')
    timestamp = Time.now.strftime('%Y%m%d_%H%M%S')

    if valid_previews.length == 1
      # For single image, just copy it to downloads
      preview = valid_previews.first
      
      # Handle triple frame preview
      if preview['left_original'] && preview['middle_original'] && preview['right_original'] &&
         preview['left_filename'] && preview['middle_filename'] && preview['right_filename'] &&
         File.exist?(preview['left_original']) && File.exist?(preview['middle_original']) && File.exist?(preview['right_original'])
        # Process triple frame with current gravity settings
        temp_file, _ = process_triple_image(
          File.new(preview['left_original']),
          File.new(preview['middle_original']),
          File.new(preview['right_original']),
          preview['left_filename'],
          preview['middle_filename'],
          preview['right_filename'],
          preview['left_gravity'],
          preview['middle_gravity'],
          preview['right_gravity']
        )
        download_filename = "framed_triple_#{timestamp}.jpg"
        download_path = File.join('public/downloads', download_filename)
        FileUtils.mv(temp_file.path, download_path)
      # Handle double frame preview
      elsif preview['left_original'] && preview['right_original'] &&
            preview['left_filename'] && preview['right_filename'] &&
            File.exist?(preview['left_original']) && File.exist?(preview['right_original'])
        # Process double frame with current gravity settings
        temp_file, _ = process_double_image(
          File.new(preview['left_original']),
          File.new(preview['right_original']),
          preview['left_filename'],
          preview['right_filename'],
          preview['left_gravity'],
          preview['right_gravity']
        )
        download_filename = "framed_double_#{timestamp}.jpg"
        download_path = File.join('public/downloads', download_filename)
        FileUtils.mv(temp_file.path, download_path)
      else
        # Single frame
        if preview['path'] && File.exist?(preview['path'])
          filename = preview['filename']
          if filename
            base_filename = filename.sub(/\.[^.]+\z/, '')
            download_filename = "framed_#{base_filename}.jpg"
          else
            download_filename = "framed_image_#{timestamp}.jpg"
          end
          download_path = File.join('public/downloads', download_filename)
          FileUtils.cp(preview['path'], download_path)
        else
          status 400
          return { 'error' => "Invalid preview: missing or invalid file path" }.to_json
        end
      end
      
      # Return JSON response for single file
      {
        'url' => "/downloads/#{download_filename}",
        'filename' => download_filename,
        'count' => 1
      }.to_json
    else
      # For multiple images, create a ZIP
      zip_filename = "framed_images_#{timestamp}.zip"
      zip_path = File.join('public/downloads', zip_filename)

      # Create ZIP file with all images
      begin
        # Create a temporary directory for processed images
        temp_dir = Dir.mktmpdir
        
        # Process each preview and save to temp directory
        valid_previews.each_with_index do |preview, index|
          if preview['left_original'] && preview['middle_original'] && preview['right_original'] &&
             preview['left_filename'] && preview['middle_filename'] && preview['right_filename'] &&
             File.exist?(preview['left_original']) && File.exist?(preview['middle_original']) && File.exist?(preview['right_original'])
            # Process triple frame
            temp_file, _ = process_triple_image(
              File.new(preview['left_original']),
              File.new(preview['middle_original']),
              File.new(preview['right_original']),
              preview['left_filename'],
              preview['middle_filename'],
              preview['right_filename'],
              preview['left_gravity'],
              preview['middle_gravity'],
              preview['right_gravity']
            )
            temp_path = File.join(temp_dir, "framed_triple_#{index + 1}.jpg")
            FileUtils.mv(temp_file.path, temp_path)
          elsif preview['left_original'] && preview['right_original'] &&
                  preview['left_filename'] && preview['right_filename'] &&
                  File.exist?(preview['left_original']) && File.exist?(preview['right_original'])
            # Process double frame
            temp_file, _ = process_double_image(
              File.new(preview['left_original']),
              File.new(preview['right_original']),
              preview['left_filename'],
              preview['right_filename'],
              preview['left_gravity'],
              preview['right_gravity']
            )
            temp_path = File.join(temp_dir, "framed_double_#{index + 1}.jpg")
            FileUtils.mv(temp_file.path, temp_path)
          else
            # Copy single frame
            if preview['path'] && File.exist?(preview['path'])
              filename = preview['filename']
              if filename
                base_filename = filename.sub(/\.[^.]+\z/, '')
                temp_path = File.join(temp_dir, "framed_#{base_filename}.jpg")
              else
                temp_path = File.join(temp_dir, "framed_image_#{index + 1}.jpg")
              end
              FileUtils.cp(preview['path'], temp_path)
            else
              puts "Warning: Skipping invalid preview with missing or invalid path: #{preview.inspect}"
              next
            end
          end
        end

        # Create ZIP file
        Zip::File.open(zip_path, Zip::File::CREATE) do |zipfile|
          Dir.glob(File.join(temp_dir, '*.jpg')).each do |file|
            # Verify file before adding to ZIP
            unless File.exist?(file) && File.size(file) > 0
              raise "Source file missing or empty: #{file}"
            end
            zipfile.add(File.basename(file), file)
          end
        end

        # Verify ZIP was created successfully
        unless File.exist?(zip_path) && File.size(zip_path) > 0
          raise "ZIP file creation failed or file is empty"
        end

        # Clean up temp directory
        FileUtils.remove_entry(temp_dir)

        # Return JSON response for ZIP file
        {
          'url' => "/downloads/#{zip_filename}",
          'filename' => zip_filename,
          'count' => valid_previews.length
        }.to_json
      rescue => e
        status 500
        { 'error' => "Error creating ZIP file: #{e.message}" }.to_json
      end
    end
  rescue JSON::ParserError
    status 400
    { 'error' => "Invalid JSON in request" }.to_json
  rescue => e
    status 500
    { 'error' => "Error exporting images: #{e.message}" }.to_json
  end
end
