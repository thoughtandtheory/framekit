class ImagesController < ApplicationController
  def index
  end

  def new
    @image = Image.new
  end

  def create
    @image = Image.new(image_params)
    
    if @image.save
      @image.file.attach(params[:image][:file])
      processed_image = process_image
      send_data processed_image.to_blob,
                filename: "framed_#{@image.file.filename}",
                type: 'image/jpeg',
                disposition: 'attachment'
    else
      render :new
    end
  end

  private

  def image_params
    params.require(:image).permit(:file)
  end

  def process_image
    original = MiniMagick::Image.read(@image.file.download)
    
    # Create a new image with white background
    result = MiniMagick::Image.create(nil, false) do |b|
      b.size "3840x2160"
      b.background "white"
      b.gravity "center"
    end

    # Calculate scaling to fit within frame while maintaining aspect ratio
    width = original[:width]
    height = original[:height]
    max_width = 3440  # 3840 - (200 * 2)
    max_height = 1760 # 2160 - (200 * 2)
    
    scale = [max_width.to_f / width, max_height.to_f / height].min
    new_width = (width * scale).to_i
    new_height = (height * scale).to_i

    # Resize original image
    original.resize "#{new_width}x#{new_height}"

    # Composite the resized image onto the white background
    result = result.composite(original) do |c|
      c.compose "Over"
      c.gravity "center"
    end

    result
  end
end
