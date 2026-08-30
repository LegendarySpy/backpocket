# Backpocket Icon Composer layers

Import the five SVG files in filename order. Every file uses the same 1024 × 1024 canvas, so leave each layer at `x: 0`, `y: 0`, and `100%` scale.

The left and right card rotations are baked into their SVGs because Icon Composer's documented composition controls cover position and scale but not rotation.

Suggested groups:

1. Cards: `01-card-left.svg`, `02-card-right.svg`, `03-card-front.svg`
2. Pocket: `04-pocket.svg`
3. Stitching: `05-stitching.svg`

Create the background in Icon Composer rather than importing it as artwork. A violet-to-blue gradient from `#8659F4` to `#2688D8` matches the supplied layers.
