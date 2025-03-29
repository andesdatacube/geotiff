using Random

# Constants definition
const IMAGE_WIDTH = 1024
const IMAGE_HEIGHT = 1024
const TILE_WIDTH = 128
const TILE_LENGTH = 128
const BITS_PER_SAMPLE = 8
const SAMPLES_PER_PIXEL = 1
const NUM_TILES_WIDE = IMAGE_WIDTH ÷ TILE_WIDTH
const NUM_TILES_HIGH = IMAGE_HEIGHT ÷ TILE_LENGTH
const NUM_TILES = NUM_TILES_WIDE * NUM_TILES_HIGH
const BYTES_PER_TILE = TILE_WIDTH * TILE_LENGTH * SAMPLES_PER_PIXEL

const GHOST_HEADER = b"GDAL_STRUCTURAL_METADATA_SIZE=000140 bytes\nLAYOUT=IFDS_BEFORE_DATA\nBLOCK_ORDER=ROW_MAJOR\nBLOCK_LEADER=SIZE_AS_UINT4\nBLOCK_TRAILER=LAST_4_BYTES_REPEATED\nKNOWN_INCOMPATIBLE_EDITION=NO "

# Generate random tile data
all_pixels = rand(UInt8, NUM_TILES * BYTES_PER_TILE)
tile_data_all = all_pixels

# Prepare TIFF header with IFD offset
IFD_OFFSET = 8 + sizeof(GHOST_HEADER)
tiff_header = IOBuffer()
write(tiff_header, b"II")
write(tiff_header, htol(UInt16(42)))  # Magic number
write(tiff_header, htol(UInt32(IFD_OFFSET)))  # Offset to first IFD
tiff_header_bytes = take!(tiff_header)

# Model transformation parameters
model_transformation = [
    118.4505876, 0.0, 0.0, -5458203.076608,
    0.0, -118.4505876, 0.0, 2729101.538304,
    0.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 1.0
]
model_transformation_io = IOBuffer()
for val in model_transformation
    write(model_transformation_io, htol(Float64(val)))
end
model_transformation_bytes = take!(model_transformation_io)

# Geo key parameters
geo_key_values = UInt16[
    1, 1, 0, 18,
    1024, 0, 1, 1,
    1025, 0, 1, 1,
    2048, 0, 1, 32767,
    2049, 34737, 117, 0,
    2050, 0, 1, 32767,
    2054, 0, 1, 9102,
    2056, 0, 1, 32767,
    2057, 34736, 1, 0,
    2058, 34736, 1, 1,
    2061, 34736, 1, 2,
    3072, 0, 1, 32767,
    3073, 34737, 20, 117,
    3074, 0, 1, 32767,
    3075, 0, 1, 12,
    3076, 0, 1, 9001,
    3078, 34736, 1, 3,
    3082, 34736, 1, 4,
    3084, 34736, 1, 5
]
geo_key_io = IOBuffer()
for v in geo_key_values
    write(geo_key_io, htol(v))
end
geo_key_bytes = take!(geo_key_io)

# Geo double parameters
geo_double_params = [1737400.0, 1737400.0, 0.0, 0.0, 0.0, 0.0]
geo_double_io = IOBuffer()
for val in geo_double_params
    write(geo_double_io, htol(Float64(val)))
end
geo_double_bytes = take!(geo_double_io)

# Geo ASCII parameters
geo_ascii_params = b"GCS Name = Moon 2000|Datum = D_Moon_2000|Ellipsoid = Moon_2000_IAU_IAG|Primem = Reference_Meridian|AUnits = Decimal_Degree|SimpleCylindrical Moon|"

# Calculate offsets
NUM_TAGS = 14
IFD_SIZE = 2 + (NUM_TAGS * 12) + 4  # 2 bytes for tag count, 12 per tag, 4 for next IFD
offset_ifd = IFD_OFFSET
offset_after_ifd = offset_ifd + IFD_SIZE
offset_tile_offsets = offset_after_ifd
offset_tile_bytecounts = offset_tile_offsets + (NUM_TILES * 4)
offset_model_transform = offset_tile_bytecounts + (NUM_TILES * 4)
offset_geo_key = offset_model_transform + sizeof(model_transformation_bytes)
offset_geo_double = offset_geo_key + sizeof(geo_key_bytes)
offset_geo_ascii = offset_geo_double + sizeof(geo_double_bytes)
offset_tile_data = offset_geo_ascii + sizeof(geo_ascii_params)

# Build tile offsets and byte counts
tile_offsets_values = [offset_tile_data + i * BYTES_PER_TILE for i in 0:NUM_TILES-1]
tile_offsets_io = IOBuffer()
for offset in tile_offsets_values
    write(tile_offsets_io, htol(UInt32(offset)))
end
tile_offsets_bytes = take!(tile_offsets_io)

tile_bytecounts_values = fill(UInt32(BYTES_PER_TILE), NUM_TILES)
tile_bytecounts_io = IOBuffer()
for bc in tile_bytecounts_values
    write(tile_bytecounts_io, htol(bc))
end
tile_bytecounts_bytes = take!(tile_bytecounts_io)

# Construct IFD tags
tags = [
    (256, 3, 1, IMAGE_WIDTH),
    (257, 3, 1, IMAGE_HEIGHT),
    (258, 3, 1, BITS_PER_SAMPLE),
    (259, 3, 1, 1),
    (262, 3, 1, 1),
    (277, 3, 1, SAMPLES_PER_PIXEL),
    (322, 4, 1, TILE_WIDTH),
    (323, 4, 1, TILE_LENGTH),
    (324, 4, NUM_TILES, offset_tile_offsets),
    (325, 4, NUM_TILES, offset_tile_bytecounts),
    (34264, 12, 16, offset_model_transform),
    (34735, 3, 76, offset_geo_key),
    (34736, 12, 6, offset_geo_double),
    (34737, 2, sizeof(geo_ascii_params), offset_geo_ascii),
]

ifd_io = IOBuffer()
write(ifd_io, htol(UInt16(NUM_TAGS)))
for (tag, type_, count, value) in tags
    write(ifd_io, htol(UInt16(tag)))
    write(ifd_io, htol(UInt16(type_)))
    write(ifd_io, htol(UInt32(count)))
    write(ifd_io, htol(UInt32(value)))
end
write(ifd_io, htol(UInt32(0)))  # Next IFD offset
ifd_bytes = take!(ifd_io)

# Combine all components into final TIFF
final_io = IOBuffer()
write(final_io, tiff_header_bytes)
write(final_io, GHOST_HEADER)
write(final_io, ifd_bytes)
write(final_io, tile_offsets_bytes)
write(final_io, tile_bytecounts_bytes)
write(final_io, model_transformation_bytes)
write(final_io, geo_key_bytes)
write(final_io, geo_double_bytes)
write(final_io, geo_ascii_params)
write(final_io, tile_data_all)

final_bytes = take!(final_io)

# Write to file (CORRECTED)
open("moon.tif", "w") do f
    write(f, final_bytes)
end