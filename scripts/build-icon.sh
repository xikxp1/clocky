#!/bin/bash
# Rebuild macOS icon assets locally from the generated artwork; no API calls.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_dir="$(cd -- "$script_dir/.." && pwd -P)"
resources="$project_dir/Resources"
staging="$(mktemp -d "${TMPDIR:-/tmp}/clocky-icon.XXXXXX")"
trap 'rm -rf -- "$staging"' EXIT

# Apply a rounded tile and transparent margins without modifying the source.
swift - "$resources/AppIcon-source.png" "$staging/AppIcon.png" <<'SWIFT'
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width == 1024, image.height == 1024,
      let context = CGContext(
        data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else {
    fatalError("Expected a readable 1024x1024 source image and an RGBA context")
}
let tile = CGRect(x: 64, y: 64, width: 896, height: 896)
context.addPath(CGPath(roundedRect: tile, cornerWidth: 200, cornerHeight: 200, transform: nil))
context.clip()
context.interpolationQuality = .high
context.draw(image, in: tile)
guard let icon = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL,
        UTType.png.identifier as CFString, 1, nil
      ) else {
    fatalError("Cannot create icon PNG")
}
CGImageDestinationAddImage(destination, icon, nil)
guard CGImageDestinationFinalize(destination) else {
    fatalError("Cannot write icon PNG")
}
SWIFT

iconset="$staging/AppIcon.iconset"
mkdir -p -- "$iconset"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$staging/AppIcon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    /usr/bin/sips -z "$retina" "$retina" "$staging/AppIcon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil --convert icns --output "$staging/AppIcon.icns" "$iconset"
cp -- "$staging/AppIcon.png" "$resources/AppIcon.png"
cp -- "$staging/AppIcon.icns" "$resources/AppIcon.icns"
printf 'Rebuilt Resources/AppIcon.png and Resources/AppIcon.icns\n'
