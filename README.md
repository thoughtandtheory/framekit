# FrameKit

FrameKit is a web application that allows users to create beautifully framed images with precise control over image positioning. Whether you need a single framed image or a side-by-side presentation, FrameKit offers an elegant solution with a subtle inner shadow effect.

## Features

### Single Frame
- Upload any image file
- Automatically resizes and centers the image
- Configurable image positioning (top, bottom, left, right, corners)
- Adds a white frame with configurable dimensions
- Creates a subtle inner shadow effect for depth

### Double Frame
- Upload two images for side-by-side presentation
- Independent position control for each image
- Synchronized frame dimensions
- Perfect for before/after comparisons
- Maintains consistent spacing and alignment

### Triple Frame
- Upload three images for a triptych presentation
- Independent position control for each image
- Synchronized frame dimensions
- Perfect for showcasing a series or panoramic scenes
- Maintains consistent spacing and alignment

## Requirements

- Ruby 3.0.0 or higher
- Bundler
- ImageMagick (for image processing)

## Installation

1. Install ImageMagick:
   ```bash
   brew install imagemagick
   ```

2. Clone the repository:
   ```bash
   git clone git@github.com:thoughtandtheory/framekit.git
   cd framekit
   ```

3. Install dependencies:
   ```bash
   bundle install
   ```

## Running Locally

1. Start the server:
   ```bash
   bundle exec rackup -p 4568
   ```

2. Open your browser and visit:
   ```
   http://localhost:4568
   ```

## Usage

### Single Frame
1. Click "Single Frame" in the navigation
2. Click "Choose File" to select an image
3. Click "Upload" to process the image
4. Adjust image position using the gravity controls
5. Click "Export" to download the framed image

### Double Frame
1. Click "Double Frame" in the navigation
2. Select two images using the upload fields
3. Click "Upload" to process both images
4. Adjust each image's position independently:
   - Left image controls are under the left side
   - Right image controls are under the right side
5. Click "Export" to download the combined frame

### Triple Frame
1. Click "Triple Frame" in the navigation
2. Select three images using the upload fields
3. Click "Frame Images" to process all images
4. Adjust each image's position independently:
   - Left image controls for the left panel
   - Middle image controls for the center panel
   - Right image controls for the right panel
5. Click "Export" to download the combined frame

## Technical Details

FrameKit uses:
- Sinatra for the web framework
- MiniMagick for image processing
- ImageMagick for the underlying image manipulations

The framing process:
1. Validates and processes uploaded images
2. Resizes while maintaining aspect ratio
3. Positions images according to gravity settings
4. Adds white frame and inner shadow effects
5. Optimizes output with:
   - Progressive JPEG loading
   - Standard chroma subsampling
   - High quality (95) compression
   - Minimal metadata

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License.
