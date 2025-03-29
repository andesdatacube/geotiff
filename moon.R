##############################################################################
# 1) Define image layout, tile info, and GHOST_HEADER
##############################################################################
IMAGE_WIDTH <- 1024
IMAGE_HEIGHT <- 1024
TILE_WIDTH <- 128
TILE_LENGTH <- 128
BITS_PER_SAMPLE <- 8
SAMPLES_PER_PIXEL <- 1  # Grayscale
NUM_TILES_WIDE <- IMAGE_WIDTH %/% TILE_WIDTH    # 1024 / 128 = 8
NUM_TILES_HIGH <- IMAGE_HEIGHT %/% TILE_LENGTH  # 8
NUM_TILES <- NUM_TILES_WIDE * NUM_TILES_HIGH    # 64
BYTES_PER_TILE <- TILE_WIDTH * TILE_LENGTH * SAMPLES_PER_PIXEL  # 128*128*1 = 16384

ghost_header_str <- paste0(
  "GDAL_STRUCTURAL_METADATA_SIZE=000140 bytes\n",
  "LAYOUT=IFDS_BEFORE_DATA\n",
  "BLOCK_ORDER=ROW_MAJOR\n",
  "BLOCK_LEADER=SIZE_AS_UINT4\n",
  "BLOCK_TRAILER=LAST_4_BYTES_REPEATED\n",
  "KNOWN_INCOMPATIBLE_EDITION=NO "
)
# Convert the GHOST_HEADER to raw so we can measure its length in bytes
GHOST_HEADER <- charToRaw(ghost_header_str)

##############################################################################
# 2) Generate random tile data (8-bit)
##############################################################################
set.seed(123)  # For reproducibility if desired; remove or change as needed
all_pixels <- sample(0:255, NUM_TILES * BYTES_PER_TILE, replace = TRUE)
# Convert to raw
tile_data_all <- as.raw(all_pixels)

##############################################################################
# 3) Prepare the base TIFF header (IFH) with a custom offset for the IFD
##############################################################################
# Normally we do offset=8, but now we must skip the GHOST_HEADER as well.
# So the IFD starts at (8 + length(GHOST_HEADER)).
IFD_OFFSET <- 8 + length(GHOST_HEADER)

# We need to assemble the TIFF header: "II" (little-endian), magic 42 (2 bytes),
# and then the offset to the first IFD (4 bytes, little-endian).
# R’s writeBin() can handle endian conversion.

##############################################################################
# Helper functions for writing little-endian values to a raw vector
##############################################################################
writeUInt16LE <- function(x, con) {
  writeBin(as.integer(x), con, size = 2, endian = "little")
}

writeUInt32LE <- function(x, con) {
  writeBin(as.integer(x), con, size = 4, endian = "little")
}

writeDoubleLE <- function(x, con) {
  writeBin(as.double(x), con, size = 8, endian = "little")
}

writeRawData <- function(x, con) {
  writeBin(x, con)
}

##############################################################################
# 4) GeoTIFF data (unchanged from your snippet)
##############################################################################
# We'll define these as R vectors or raw blocks, and then write them.

model_transformation_vals <- c(
  118.4505876,  0.0,         0.0,         -5458203.076608,
  0.0,         -118.4505876, 0.0,          2729101.538304,
  0.0,          0.0,         0.0,          0.0,
  0.0,          0.0,         0.0,          1.0
)

# geo_key is 76 unsigned shorts
geo_key_vals <- c(
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

geo_double_params_vals <- c(1737400.0, 1737400.0, 0.0, 0.0, 0.0, 0.0)

geo_ascii_params_str <- paste0(
  "GCS Name = Moon 2000|Datum = D_Moon_2000|Ellipsoid = Moon_2000_IAU_IAG|",
  "Primem = Reference_Meridian|AUnits = Decimal_Degree|",
  "SimpleCylindrical Moon|"  # 20 chars
)
geo_ascii_params <- charToRaw(geo_ascii_params_str)

##############################################################################
# 5) Calculate offsets, now that the IFD starts at IFD_OFFSET
##############################################################################
# 14 tags * 12 bytes each = 168 bytes
# plus 2 bytes for count, plus 4 for next IFD offset => 174 total
NUM_TAGS <- 14
IFD_SIZE <- 2 + (NUM_TAGS * 12) + 4  # 174
offset_ifd <- IFD_OFFSET
offset_after_ifd <- offset_ifd + IFD_SIZE  # Where we place tile-offset array

offset_tile_offsets <- offset_after_ifd
offset_tile_bytecounts <- offset_tile_offsets + (NUM_TILES * 4)
offset_model_transform <- offset_tile_bytecounts + (NUM_TILES * 4)

# We'll figure out the length in bytes of model_transformation, geo_key, etc.
# Each double is 8 bytes.
len_model_transformation <- length(model_transformation_vals) * 8
len_geo_key <- length(geo_key_vals) * 2  # 76 * 2 bytes each (unsigned short)
len_geo_double_params <- length(geo_double_params_vals) * 8
len_geo_ascii_params <- length(geo_ascii_params)

offset_geo_key <- offset_model_transform + len_model_transformation
offset_geo_double <- offset_geo_key + len_geo_key
offset_geo_ascii <- offset_geo_double + len_geo_double_params
offset_tile_data <- offset_geo_ascii + len_geo_ascii_params

##############################################################################
# 6) Build tile offsets/bytecounts
##############################################################################
tile_offsets_values <- offset_tile_data + (0:(NUM_TILES-1)) * BYTES_PER_TILE
tile_bytecounts_values <- rep(BYTES_PER_TILE, NUM_TILES)

##############################################################################
# 7) Construct the 14 IFD tags (each is 12 bytes, little-endian)
##############################################################################
# Each tag: struct.pack('<HHLL', tag, type, count, value_or_offset)
# We'll build them in a raw connection.

makeTag <- function(tag, type, count, value) {
  # tag (2 bytes), type (2 bytes), count (4 bytes), value (4 bytes)
  # all little-endian
  tmp_con <- rawConnection(raw(0), "wb")
  writeUInt16LE(tag, tmp_con)
  writeUInt16LE(type, tmp_con)
  writeUInt32LE(count, tmp_con)
  writeUInt32LE(value, tmp_con)
  out <- rawConnectionValue(tmp_con)
  close(tmp_con)
  out
}

tags_raw <- c(
  makeTag(256, 3, 1, IMAGE_WIDTH),     # ImageWidth
  makeTag(257, 3, 1, IMAGE_HEIGHT),    # ImageLength
  makeTag(258, 3, 1, BITS_PER_SAMPLE),
  makeTag(259, 3, 1, 1),
  makeTag(262, 3, 1, 1),
  makeTag(277, 3, 1, SAMPLES_PER_PIXEL),
  makeTag(322, 4, 1, TILE_WIDTH),      # TileWidth
  makeTag(323, 4, 1, TILE_LENGTH),     # TileLength
  makeTag(324, 4, NUM_TILES, offset_tile_offsets),      # TileOffsets
  makeTag(325, 4, NUM_TILES, offset_tile_bytecounts),   # TileByteCounts
  makeTag(34264, 12, 16, offset_model_transform),       # ModelPixelScale/etc
  makeTag(34735, 3, 76, offset_geo_key),                # GeoKeyDirectoryTag
  makeTag(34736, 12, 6, offset_geo_double),             # GeoDoubleParamsTag
  makeTag(34737, 2, len_geo_ascii_params, offset_geo_ascii) # GeoASCIIParamsTag
)

# Build the IFD (2-byte tag count, the tags, then 4-byte next-IFD offset = 0)
buildIFD <- function(tags_raw) {
  tmp_con <- rawConnection(raw(0), "wb")
  writeUInt16LE(NUM_TAGS, tmp_con)     # number of tags
  writeRawData(tags_raw, tmp_con)      # the tag structures
  writeUInt32LE(0, tmp_con)            # next IFD offset = 0
  out <- rawConnectionValue(tmp_con)
  close(tmp_con)
  out
}

ifd <- buildIFD(tags_raw)

##############################################################################
# 8) Combine everything into final TIFF: header + ghost + IFD + data
##############################################################################
# We'll write everything to a raw connection in the correct order,
# then write that raw vector to 'moon.tif'.

# The key is: 
#  1) 8-byte TIFF header 
#  2) GHOST_HEADER 
#  3) IFD at offset IFD_OFFSET 
#  4) tile offset array 
#  5) tile bytecount array 
#  6) model_transformation 
#  7) geo_key 
#  8) geo_double_params 
#  9) geo_ascii_params 
# 10) tile_data_all

# Build the 8-byte TIFF header
buildTiffHeader <- function() {
  tmp_con <- rawConnection(raw(0), "wb")
  # "II" => 0x49, 0x49
  writeRawData(charToRaw("II"), tmp_con)
  # magic number 42 in little-endian (2 bytes)
  writeUInt16LE(42, tmp_con)
  # offset to first IFD (4 bytes), which is IFD_OFFSET
  writeUInt32LE(IFD_OFFSET, tmp_con)
  out <- rawConnectionValue(tmp_con)
  close(tmp_con)
  out
}

tiff_header <- buildTiffHeader()

# Create a helper function to write an entire numeric vector (doubles) in LE
packDoublesLE <- function(vals) {
  tmp_con <- rawConnection(raw(0), "wb")
  for (v in vals) {
    writeDoubleLE(v, tmp_con)
  }
  out <- rawConnectionValue(tmp_con)
  close(tmp_con)
  out
}

# Similarly, for 16-bit unsigned (GeoKey)
packUShortLE <- function(vals) {
  tmp_con <- rawConnection(raw(0), "wb")
  for (v in vals) {
    writeUInt16LE(v, tmp_con)
  }
  out <- rawConnectionValue(tmp_con)
  close(tmp_con)
  out
}

model_transformation_raw <- packDoublesLE(model_transformation_vals)
geo_key_raw <- packUShortLE(geo_key_vals)
geo_double_params_raw <- packDoublesLE(geo_double_params_vals)

# Pack tile offsets and bytecounts as 32-bit LE
packUInt32LE <- function(vals) {
  tmp_con <- rawConnection(raw(0), "wb")
  for (v in vals) {
    writeUInt32LE(v, tmp_con)
  }
  out <- rawConnectionValue(tmp_con)
  close(tmp_con)
  out
}

tile_offsets_data <- packUInt32LE(tile_offsets_values)
tile_bytecounts_data <- packUInt32LE(tile_bytecounts_values)

##############################################################################
# Finally, assemble everything in one raw vector and write to 'moon.tif'
##############################################################################
final_con <- file("moon.tif", "wb")

# 1) TIFF header
writeRawData(tiff_header, final_con)
# 2) GHOST_HEADER
writeRawData(GHOST_HEADER, final_con)
# 3) IFD
writeRawData(ifd, final_con)
# 4) tile offset array
writeRawData(tile_offsets_data, final_con)
# 5) tile bytecount array
writeRawData(tile_bytecounts_data, final_con)
# 6) model_transformation
writeRawData(model_transformation_raw, final_con)
# 7) geo_key
writeRawData(geo_key_raw, final_con)
# 8) geo_double_params
writeRawData(geo_double_params_raw, final_con)
# 9) geo_ascii_params
writeRawData(geo_ascii_params, final_con)
# 10) tile data
writeRawData(tile_data_all, final_con)

close(final_con)
