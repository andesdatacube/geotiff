#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

//////////////////////////////////////////////////////////////////////////////
// 1) Define image layout, tile info, and GHOST_HEADER
//////////////////////////////////////////////////////////////////////////////
#define IMAGE_WIDTH       1024
#define IMAGE_HEIGHT      1024
#define TILE_WIDTH        128
#define TILE_LENGTH       128
#define BITS_PER_SAMPLE   8
#define SAMPLES_PER_PIXEL 1  /* Grayscale */

#define NUM_TILES_WIDE  (IMAGE_WIDTH  / TILE_WIDTH)   /* 1024 / 128 = 8 */
#define NUM_TILES_HIGH (IMAGE_HEIGHT / TILE_LENGTH)   /* 1024 / 128 = 8 */
#define NUM_TILES      (NUM_TILES_WIDE * NUM_TILES_HIGH) /* 8 * 8 = 64 */
#define BYTES_PER_TILE (TILE_WIDTH * TILE_LENGTH * SAMPLES_PER_PIXEL) /* 16384 */

static const char GHOST_HEADER[] =
    "GDAL_STRUCTURAL_METADATA_SIZE=000140 bytes\n"
    "LAYOUT=IFDS_BEFORE_DATA\n"
    "BLOCK_ORDER=ROW_MAJOR\n"
    "BLOCK_LEADER=SIZE_AS_UINT4\n"
    "BLOCK_TRAILER=LAST_4_BYTES_REPEATED\n"
    "KNOWN_INCOMPATIBLE_EDITION=NO ";

//////////////////////////////////////////////////////////////////////////////
// 2) Generate random tile data (8-bit)
//////////////////////////////////////////////////////////////////////////////
// We'll create an array of size NUM_TILES * BYTES_PER_TILE, fill with random [0..255].
static uint8_t* generateRandomPixels(size_t num_pixels) {
    uint8_t* pixels = (uint8_t*)malloc(num_pixels);
    if (!pixels) {
        fprintf(stderr, "Failed to allocate memory for tile data.\n");
        exit(EXIT_FAILURE);
    }
    srand((unsigned)time(NULL));
    for (size_t i = 0; i < num_pixels; i++) {
        pixels[i] = (uint8_t)(rand() % 256);
    }
    return pixels;
}

//////////////////////////////////////////////////////////////////////////////
// 3) Prepare the base TIFF header (IFH) with a custom offset for the IFD
//////////////////////////////////////////////////////////////////////////////
// Normally we do offset=8, but now we must skip the GHOST_HEADER as well.
// So the IFD starts at (8 + length(GHOST_HEADER)).
//////////////////////////////////////////////////////////////////////////////

//////////////////////////////////////////////////////////////////////////////
// Helper functions to write little-endian values
//////////////////////////////////////////////////////////////////////////////
static void writeUInt16LE(FILE* fp, uint16_t val) {
    /* Write 2 bytes in little-endian order */
    uint8_t buf[2];
    buf[0] = (uint8_t)(val & 0xFF);
    buf[1] = (uint8_t)((val >> 8) & 0xFF);
    fwrite(buf, 1, 2, fp);
}

static void writeUInt32LE(FILE* fp, uint32_t val) {
    /* Write 4 bytes in little-endian order */
    uint8_t buf[4];
    buf[0] = (uint8_t)(val & 0xFF);
    buf[1] = (uint8_t)((val >> 8) & 0xFF);
    buf[2] = (uint8_t)((val >> 16) & 0xFF);
    buf[3] = (uint8_t)((val >> 24) & 0xFF);
    fwrite(buf, 1, 4, fp);
}

static void writeDoubleLE(FILE* fp, double val) {
    /* We’ll assume IEEE 754; need to reinterpret the bytes in little-endian. */
    union {
        double d;
        uint8_t b[8];
    } conv;
    conv.d = val;
    /* On a little-endian machine, this might be direct, but let's enforce ordering. */
    uint8_t buf[8];
    buf[0] = conv.b[0];
    buf[1] = conv.b[1];
    buf[2] = conv.b[2];
    buf[3] = conv.b[3];
    buf[4] = conv.b[4];
    buf[5] = conv.b[5];
    buf[6] = conv.b[6];
    buf[7] = conv.b[7];
    fwrite(buf, 1, 8, fp);
}

//////////////////////////////////////////////////////////////////////////////
// 4) GeoTIFF data (unchanged from your snippet, but in C arrays)
//////////////////////////////////////////////////////////////////////////////
static const double model_transformation[] = {
    118.4505876,  0.0,          0.0,         -5458203.076608,
    0.0,         -118.4505876,  0.0,          2729101.538304,
    0.0,          0.0,          0.0,          0.0,
    0.0,          0.0,          0.0,          1.0
};

/* 76 unsigned shorts */
static const uint16_t geo_key[] = {
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
    3073, 34737, 20, 117,  /* Note: still "20" here from your snippet */
    3074, 0, 1, 32767,
    3075, 0, 1, 12,
    3076, 0, 1, 9001,
    3078, 34736, 1, 3,
    3082, 34736, 1, 4,
    3084, 34736, 1, 5
};

static const double geo_double_params[] = {
    1737400.0, 1737400.0, 0.0, 0.0, 0.0, 0.0
};

/* ASCII params */
static const char geo_ascii_params[] =
    "GCS Name = Moon 2000|Datum = D_Moon_2000|Ellipsoid = Moon_2000_IAU_IAG|"
    "Primem = Reference_Meridian|AUnits = Decimal_Degree|"
    "SimpleCylindrical Moon|";

//////////////////////////////////////////////////////////////////////////////
// 5) Calculate offsets, now that the IFD starts at IFD_OFFSET
//////////////////////////////////////////////////////////////////////////////
// 14 tags * 12 bytes each = 168 bytes, plus 2 bytes for count, plus 4 for next IFD offset => 174 total
// We'll compute these offsets in C similarly.
//////////////////////////////////////////////////////////////////////////////

/* Helper: Write a 12-byte TIFF tag in little-endian */
static void writeTag(FILE* fp, uint16_t tag, uint16_t type, uint32_t count, uint32_t value) {
    writeUInt16LE(fp, tag);
    writeUInt16LE(fp, type);
    writeUInt32LE(fp, count);
    writeUInt32LE(fp, value);
}

int main(void) {
    FILE* fp = fopen("moon.tif", "wb");
    if (!fp) {
        fprintf(stderr, "Unable to open output file.\n");
        return 1;
    }

    // 1) Offsets / lengths
    size_t ghost_header_len = strlen(GHOST_HEADER);
    uint32_t IFD_OFFSET = 8 + (uint32_t)ghost_header_len;  // offset to first IFD

    // We'll define the IFD size:
    const uint16_t NUM_TAGS = 14;
    const uint32_t IFD_SIZE = 2 + (NUM_TAGS * 12) + 4;  // 2 bytes for count, 14*12=168, +4 for next=0 => 174
    uint32_t offset_ifd = IFD_OFFSET;
    uint32_t offset_after_ifd = offset_ifd + IFD_SIZE;

    // We have NUM_TILES tile offsets, then tile bytecounts, then model transformation, etc.
    uint32_t offset_tile_offsets = offset_after_ifd;
    uint32_t offset_tile_bytecounts = offset_tile_offsets + (NUM_TILES * 4);
    uint32_t len_model_transformation = (uint32_t)(sizeof(model_transformation)); // 16 doubles => 128 bytes
    uint32_t len_geo_key = (uint32_t)(sizeof(geo_key));   // 76 shorts => 152 bytes
    uint32_t len_geo_double_params = (uint32_t)(sizeof(geo_double_params)); // 6 doubles => 48 bytes
    uint32_t len_geo_ascii_params = (uint32_t)(sizeof(geo_ascii_params) - 1);  // minus 1 for null terminator in the C string

    uint32_t offset_model_transform = offset_tile_bytecounts + (NUM_TILES * 4);
    uint32_t offset_geo_key         = offset_model_transform + len_model_transformation;
    uint32_t offset_geo_double      = offset_geo_key + len_geo_key;
    uint32_t offset_geo_ascii       = offset_geo_double + len_geo_double_params;
    uint32_t offset_tile_data       = offset_geo_ascii + len_geo_ascii_params;

    // 2) Generate random tile data
    size_t total_pixels = (size_t)NUM_TILES * BYTES_PER_TILE;
    uint8_t* tile_data_all = generateRandomPixels(total_pixels);

    // 3) Construct the 8-byte TIFF header: "II" (49 49), magic 42, offset IFD_OFFSET
    // "II" => 0x49, 0x49 in ASCII
    fputc(0x49, fp);
    fputc(0x49, fp);
    // magic 42 in little-endian
    writeUInt16LE(fp, 42);
    // offset to first IFD (4 bytes)
    writeUInt32LE(fp, IFD_OFFSET);

    // 4) Write the ghost header
    fwrite(GHOST_HEADER, 1, ghost_header_len, fp);

    // 5) Now write the IFD at offset IFD_OFFSET
    // First, the 2-byte tag count
    writeUInt16LE(fp, NUM_TAGS);

    // Write the 14 tags (each 12 bytes)
    // Tag structure: <HHLL> => (tag, type, count, value)
    // 256 (ImageWidth), type=3, count=1, value=IMAGE_WIDTH
    writeTag(fp, 256, 3, 1, IMAGE_WIDTH);
    // 257 (ImageHeight)
    writeTag(fp, 257, 3, 1, IMAGE_HEIGHT);
    // 258 (BitsPerSample)
    writeTag(fp, 258, 3, 1, BITS_PER_SAMPLE);
    // 259 (Compression) = 1 (no compression)
    writeTag(fp, 259, 3, 1, 1);
    // 262 (Photometric) = 1 (min-is-black)
    writeTag(fp, 262, 3, 1, 1);
    // 277 (SamplesPerPixel)
    writeTag(fp, 277, 3, 1, SAMPLES_PER_PIXEL);
    // 322 (TileWidth)
    writeTag(fp, 322, 4, 1, TILE_WIDTH);
    // 323 (TileLength)
    writeTag(fp, 323, 4, 1, TILE_LENGTH);
    // 324 (TileOffsets)
    writeTag(fp, 324, 4, NUM_TILES, offset_tile_offsets);
    // 325 (TileByteCounts)
    writeTag(fp, 325, 4, NUM_TILES, offset_tile_bytecounts);
    // 34264 (ModelTransformationTag) = 12 => double array
    writeTag(fp, 34264, 12, 16, offset_model_transform);
    // 34735 (GeoKeyDirectoryTag) = type=3 (SHORT)
    writeTag(fp, 34735, 3, 76, offset_geo_key);
    // 34736 (GeoDoubleParamsTag) = type=12 (DOUBLE)
    writeTag(fp, 34736, 12, 6, offset_geo_double);
    // 34737 (GeoASCIIParamsTag) = type=2 (ASCII), count=len_geo_ascii_params
    writeTag(fp, 34737, 2, len_geo_ascii_params, offset_geo_ascii);

    // next IFD offset (4 bytes) = 0
    writeUInt32LE(fp, 0);

    // 6) Build tile offsets, tile bytecounts (each 4 bytes, little-endian)
    // offsets start at offset_tile_data + i*(BYTES_PER_TILE)
    {
        uint32_t i;
        for (i = 0; i < NUM_TILES; i++) {
            uint32_t tile_offset = offset_tile_data + i * BYTES_PER_TILE;
            writeUInt32LE(fp, tile_offset);
        }
    }
    {
        uint32_t i;
        for (i = 0; i < NUM_TILES; i++) {
            // Each tile has BYTES_PER_TILE
            writeUInt32LE(fp, BYTES_PER_TILE);
        }
    }

    // 7) Write the model transformation (16 doubles, type=12 => doubles)
    //    Then the geo_key (76 shorts), geo_double_params (6 doubles), geo_ascii_params
    {
        // model_transformation
        size_t i;
        for (i = 0; i < sizeof(model_transformation) / sizeof(double); i++) {
            writeDoubleLE(fp, model_transformation[i]);
        }
    }
    {
        // geo_key (76 shorts)
        size_t i;
        size_t count = sizeof(geo_key) / sizeof(uint16_t);
        for (i = 0; i < count; i++) {
            writeUInt16LE(fp, geo_key[i]);
        }
    }
    {
        // geo_double_params
        size_t i;
        for (i = 0; i < sizeof(geo_double_params) / sizeof(double); i++) {
            writeDoubleLE(fp, geo_double_params[i]);
        }
    }
    {
        // geo_ascii_params (N bytes)
        fwrite(geo_ascii_params, 1, len_geo_ascii_params, fp);
    }

    // 8) Finally, write the tile data
    fwrite(tile_data_all, 1, total_pixels, fp);

    // Clean up
    fclose(fp);
    free(tile_data_all);

    printf("Created 'moon.tif' successfully.\n");
    return 0;
}

// Compile and run:
// gcc -o moon moon.c
// ./moon
