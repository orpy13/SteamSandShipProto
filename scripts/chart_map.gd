class_name ChartMap
extends RefCounted
##
## CHART MAP — static helper that pre-renders the region tint into a square
## ImageTexture for the in-game chart UI (Tier 2, T2.3).
##
## Walks a grid of (world_x, world_z) sample points, asks `Regions.region_at`
## for the dominant region id at each, and writes the matching colour from
## `Regions.REGION_PALETTE` to the corresponding pixel. Works against both
## the noise sampler and a hand-painted region map — both flow through the
## same `Regions` API.
##
## Coordinate convention: pixel (0, 0) is the top-left of the image; world
## +Z (north) maps to the TOP row (matches the TextureRegionSampler's
## inverted-V mapping for authored region maps).
##

## Build the chart background. `size_px` = output texture side (default 256
## ≈ 16 m / pixel at full world coverage). `world_extent` defaults to
## `WORLD_HALF_EXTENT + BORDER_BAND` so the border biomes are visible.
static func build(size_px: int = 256, world_extent: float = 0.0) -> ImageTexture:
	var extent: float = world_extent if world_extent > 0.0 else \
			(Regions.WORLD_HALF_EXTENT + Regions.BORDER_BAND)
	var img := Image.create(size_px, size_px, false, Image.FORMAT_RGB8)
	var span := 2.0 * extent
	for py in range(size_px):
		var v := float(py) / float(size_px - 1)
		# Top row (py = 0) → v = 0 → world z = +extent (north).
		var z := (1.0 - v) * span - extent
		for px in range(size_px):
			var u := float(px) / float(size_px - 1)
			var x := u * span - extent
			var id := Regions.region_at(x, z)
			img.set_pixel(px, py, _color_for(id))
	return ImageTexture.create_from_image(img)


## Palette lookup with a black fallback if a region id isn't painted.
static func _color_for(id: String) -> Color:
	for entry in Regions.REGION_PALETTE:
		if String(entry["id"]) == id:
			return entry["color"]
	return Color.BLACK
