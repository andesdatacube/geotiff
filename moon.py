import random
import struct

##############################################################################
# 1) Define image layout, tile info, and GHOST_HEADER
##############################################################################
IMAGE_WIDTH = 1024
IMAGE_HEIGHT = 1024
TILE_WIDTH = 128
TILE_LENGTH = 128
BITS_PER_SAMPLE = 8
SAMPLES_PER_PIXEL = 1  # Grayscale
NUM_TILES_WIDE = IMAGE_WIDTH // TILE_WIDTH   # 1024 / 128 = 8
NUM_TILES_HIGH = IMAGE_HEIGHT // TILE_LENGTH # 8
NUM_TILES = NUM_TILES_WIDE * NUM_TILES_HIGH  # 64
BYTES_PER_TILE = TILE_WIDTH * TILE_LENGTH * SAMPLES_PER_PIXEL  # 128*128*1 = 16384

GHOST_HEADER = (
    b"GDAL_STRUCTURAL_METADATA_SIZE=000140 bytes\n"
    b"LAYOUT=IFDS_BEFORE_DATA\n"
    b"BLOCK_ORDER=ROW_MAJOR\n"
    b"BLOCK_LEADER=SIZE_AS_UINT4\n"
    b"BLOCK_TRAILER=LAST_4_BYTES_REPEATED\n"
    b"KNOWN_INCOMPATIBLE_EDITION=NO "
)

##############################################################################
# 2) Generate random tile data (8-bit)
##############################################################################
all_pixels = [random.randint(0, 255) for _ in range(NUM_TILES * BYTES_PER_TILE)]
tile_data_all = struct.pack(f'<{len(all_pixels)}B', *all_pixels)

##############################################################################
# 3) Prepare the base TIFF header (IFH) with a custom offset for the IFD
##############################################################################
# Normally we do offset=8, but now we must skip the GHOST_HEADER as well.
# So the IFD starts at (8 + len(GHOST_HEADER)).
IFD_OFFSET = 8 + len(GHOST_HEADER)

# TIFF header: "II" (little-endian), magic 42, offset to first IFD
tiff_header = struct.pack('<2sHL', b'II', 42, IFD_OFFSET)

##############################################################################
# 4) GeoTIFF data (unchanged from your snippet)
##############################################################################
model_transformation = struct.pack(
    '<16d',
    118.4505876,  0.0,          0.0,         -5458203.076608,
    0.0,         -118.4505876,  0.0,          2729101.538304,
    0.0,          0.0,          0.0,          0.0,
    0.0,          0.0,          0.0,          1.0
)

geo_key = struct.pack(
    '<76H',
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
    3073, 34737, 20, 117,  # Note: still "20" here from your snippet
    3074, 0, 1, 32767,
    3075, 0, 1, 12,
    3076, 0, 1, 9001,
    3078, 34736, 1, 3,
    3082, 34736, 1, 4,
    3084, 34736, 1, 5
)

geo_double_params = struct.pack('<6d', 1737400.0, 1737400.0, 0.0, 0.0, 0.0, 0.0)

geo_ascii_params = (
    b'GCS Name = Moon 2000|Datum = D_Moon_2000|Ellipsoid = Moon_2000_IAU_IAG|'
    b'Primem = Reference_Meridian|AUnits = Decimal_Degree|'
    b'SimpleCylindrical Moon|'  # 20 chars
)

##############################################################################
# 5) Calculate offsets, now that the IFD starts at IFD_OFFSET
##############################################################################
# 14 tags * 12 bytes each = 168 bytes, plus 2 bytes for count, plus 4 for next IFD offset => 174 total
NUM_TAGS = 14
IFD_SIZE = 2 + (NUM_TAGS * 12) + 4  # 174
offset_ifd = IFD_OFFSET
offset_after_ifd = offset_ifd + IFD_SIZE  # Where we place tile-offset array

offset_tile_offsets = offset_after_ifd
offset_tile_bytecounts = offset_tile_offsets + (NUM_TILES * 4)
offset_model_transform = offset_tile_bytecounts + (NUM_TILES * 4)
offset_geo_key = offset_model_transform + len(model_transformation)
offset_geo_double = offset_geo_key + len(geo_key)
offset_geo_ascii = offset_geo_double + len(geo_double_params)
offset_tile_data = offset_geo_ascii + len(geo_ascii_params)

##############################################################################
# 6) Build tile offsets/bytecounts
##############################################################################
tile_offsets_values = [
    offset_tile_data + i * BYTES_PER_TILE
    for i in range(NUM_TILES)
]
tile_offsets_data = struct.pack(f'<{NUM_TILES}L', *tile_offsets_values)

tile_bytecounts_values = [BYTES_PER_TILE] * NUM_TILES
tile_bytecounts_data = struct.pack(f'<{NUM_TILES}L', *tile_bytecounts_values)

##############################################################################
# 7) Construct the 14 IFD tags
##############################################################################
tags = [
    struct.pack('<HHLL', 256, 3, 1, IMAGE_WIDTH),
    struct.pack('<HHLL', 257, 3, 1, IMAGE_HEIGHT),
    struct.pack('<HHLL', 258, 3, 1, BITS_PER_SAMPLE),
    struct.pack('<HHLL', 259, 3, 1, 1),
    struct.pack('<HHLL', 262, 3, 1, 1),
    struct.pack('<HHLL', 277, 3, 1, SAMPLES_PER_PIXEL),
    struct.pack('<HHLL', 322, 4, 1, TILE_WIDTH),
    struct.pack('<HHLL', 323, 4, 1, TILE_LENGTH),
    struct.pack('<HHLL', 324, 4, NUM_TILES, offset_tile_offsets),
    struct.pack('<HHLL', 325, 4, NUM_TILES, offset_tile_bytecounts),
    struct.pack('<HHLL', 34264, 12, 16, offset_model_transform),
    struct.pack('<HHLL', 34735, 3, 76, offset_geo_key),
    struct.pack('<HHLL', 34736, 12, 6, offset_geo_double),
    struct.pack('<HHLL', 34737, 2, len(geo_ascii_params), offset_geo_ascii),
]

ifd = (
    struct.pack('<H', NUM_TAGS)
    + b''.join(tags)
    + struct.pack('<L', 0)  # next IFD offset = 0
)

##############################################################################
# 8) Combine everything into final TIFF: header + ghost + IFD + data
##############################################################################
# The key is we write tiff_header (8 bytes), then the ghost header,
# then the IFD at offset IFD_OFFSET, which we set in the header.
tiff_data = (
    tiff_header
    + GHOST_HEADER
    + ifd
    + tile_offsets_data
    + tile_bytecounts_data
    + model_transformation
    + geo_key
    + geo_double_params
    + geo_ascii_params
    + tile_data_all
)

with open('moon.tif', 'wb') as f:
    f.write(tiff_data)
