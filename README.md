# FrameKit

FrameKit is a web application that allows users to upload images and automatically adds a beautiful white frame with a subtle inner shadow effect, creating an elegant presentation-ready framed image.

## Features

- Upload any image file
- Automatically resizes and centers the image
- Adds a white frame with configurable dimensions
- Creates a subtle inner shadow effect for depth
- Downloads the framed image instantly

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

1. Click the "Choose File" button to select an image
2. Click "Upload" to process the image
3. The framed image will automatically download

## Technical Details

FrameKit uses:
- Sinatra for the web framework
- MiniMagick for image processing
- ImageMagick for the underlying image manipulations

The framing process:
1. Resizes the image while maintaining aspect ratio
2. Centers it within a white border
3. Adds a subtle inner shadow effect using multiple techniques
4. Outputs a high-quality JPEG

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License.
