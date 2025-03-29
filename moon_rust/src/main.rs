use std::fs::File;
use std::io::{BufWriter, Write};
use rand::{thread_rng, Rng};

//////////////////////////////////////////////////////////////////////////////
// 1) Define image layout, tile info, and GHOST_HEADER
//////////////////////////////////////////////////////////////////////////////
const IMAGE_WIDTH: u32       = 1024;
const IMAGE_HEIGHT: u32      = 1024;
const TILE_WIDTH: u32        = 128;
const TILE_LENGTH: u32       = 128;
const BITS_PER_SAMPLE: u32   = 8;
const SAMPLES_PER_PIXEL: u32 = 1; // Grayscale

const NUM_TILES_WIDE: u32 = IMAGE_WIDTH / TILE_WIDTH;   // 1024/128 = 8
const NUM_TILES_HIGH: u32 = IMAGE_HEIGHT / TILE_LENGTH; // 1024/128 = 8
const NUM_TILES: u32      = NUM_TILES_WIDE * NUM_TILES_HIGH; // 64
const BYTES_PER_TILE: u32 = TILE_WIDTH * TILE_LENGTH * SAMPLES_PER_PIXEL; // 128*128*1 = 16384

static GHOST_HEADER: &str =
    "GDAL_STRUCTURAL_METADATA_SIZE=000140 bytes\n\
LAYOUT=IFDS_BEFORE_DATA\n\
BLOCK_ORDER=ROW_MAJOR\n\
BLOCK_LEADER=SIZE_AS_UINT4\n\
BLOCK_TRAILER=LAST_4_BYTES_REPEATED\n\
KNOWN_INCOMPATIBLE_EDITION=NO ";

//////////////////////////////////////////////////////////////////////////////
// 2) Helper functions to write little-endian data to a writer
//////////////////////////////////////////////////////////////////////////////
fn write_u16_le<W: Write>(writer: &mut W, value: u16) -> std::io::Result<()> {
    writer.write_all(&value.to_le_bytes())
}

fn write_u32_le<W: Write>(writer: &mut W, value: u32) -> std::io::Result<()> {
    writer.write_all(&value.to_le_bytes())
}

fn write_f64_le<W: Write>(writer: &mut W, value: f64) -> std::io::Result<()> {
    writer.write_all(&value.to_le_bytes())
}

//////////////////////////////////////////////////////////////////////////////
// 3) GeoTIFF data (same values as in Python/C)
//////////////////////////////////////////////////////////////////////////////
static MODEL_TRANSFORMATION: [f64; 16] = [
    118.4505876,  0.0,          0.0,         -5458203.076608,
    0.0,         -118.4505876,  0.0,          2729101.538304,
    0.0,          0.0,          0.0,          0.0,
    0.0,          0.0,          0.0,          1.0
];

// 76 unsigned shorts
static GEO_KEY: [u16; 76] = [
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
    3073, 34737, 20, 117, // still "20" here from your snippet
    3074, 0, 1, 32767,
    3075, 0, 1, 12,
    3076, 0, 1, 9001,
    3078, 34736, 1, 3,
    3082, 34736, 1, 4,
    3084, 34736, 1, 5
];

static GEO_DOUBLE_PARAMS: [f64; 6] = [
    1737400.0, 1737400.0, 0.0, 0.0, 0.0, 0.0
];

static GEO_ASCII_PARAMS: &str =
    "GCS Name = Moon 2000|Datum = D_Moon_2000|Ellipsoid = Moon_2000_IAU_IAG|\
Primem = Reference_Meridian|AUnits = Decimal_Degree|\
SimpleCylindrical Moon|";

//////////////////////////////////////////////////////////////////////////////
// 4) Helper to write a 12-byte TIFF tag
//////////////////////////////////////////////////////////////////////////////
fn write_tag<W: Write>(
    writer: &mut W,
    tag: u16,
    typ: u16,
    count: u32,
    value: u32,
) -> std::io::Result<()> {
    write_u16_le(writer, tag)?;
    write_u16_le(writer, typ)?;
    write_u32_le(writer, count)?;
    write_u32_le(writer, value)
}

//////////////////////////////////////////////////////////////////////////////
// 5) Main function: generate the TIFF
//////////////////////////////////////////////////////////////////////////////
fn main() -> std::io::Result<()> {
    let file = File::create("moon.tif")?;
    let mut writer = BufWriter::new(file);

    // Offsets
    //  - 8 bytes for TIFF header, then the ghost header
    //  - So the IFD (first directory) starts at 8 + ghost_header_len
    let ghost_header_len = GHOST_HEADER.len() as u32;
    let ifd_offset = 8 + ghost_header_len;

    // We have 14 tags, each 12 bytes => 168 bytes, plus 2 bytes for count,
    // plus 4 bytes for next IFD offset => 174 total
    let num_tags: u16 = 14;
    let ifd_size: u32 = 2 + (num_tags as u32 * 12) + 4; // 174
    let offset_ifd = ifd_offset;
    let offset_after_ifd = offset_ifd + ifd_size;

    // We'll have tile offsets array (NUM_TILES * 4 bytes),
    // tile bytecounts array (NUM_TILES * 4 bytes),
    // then model_transform, geo_key, geo_double, geo_ascii, tile data...
    let offset_tile_offsets = offset_after_ifd;
    let offset_tile_bytecounts = offset_tile_offsets + NUM_TILES * 4;

    let len_model_transformation = (MODEL_TRANSFORMATION.len() * 8) as u32; // 16 doubles => 128 bytes
    let len_geo_key = (GEO_KEY.len() * 2) as u32;                           // 76 shorts => 152 bytes
    let len_geo_double = (GEO_DOUBLE_PARAMS.len() * 8) as u32;             // 6 doubles => 48 bytes
    let len_geo_ascii = GEO_ASCII_PARAMS.len() as u32;                     // length of the ASCII string

    let offset_model_transform = offset_tile_bytecounts + NUM_TILES * 4;
    let offset_geo_key         = offset_model_transform + len_model_transformation;
    let offset_geo_double      = offset_geo_key + len_geo_key;
    let offset_geo_ascii       = offset_geo_double + len_geo_double;
    let offset_tile_data       = offset_geo_ascii + len_geo_ascii;

    // Random tile data (8-bit)
    let total_pixels = NUM_TILES as usize * BYTES_PER_TILE as usize;
    let mut rng = thread_rng();
    let mut tile_data_all = Vec::with_capacity(total_pixels);
    for _ in 0..total_pixels {
        tile_data_all.push(rng.gen_range(0..=255) as u8);
    }

    //////////////////////////////////////////////////////////////////////////
    // 1) Write the 8-byte TIFF header
    //    - "II" => 0x49, 0x49
    //    - magic 42 (u16, LE)
    //    - offset to IFD (u32, LE)
    //////////////////////////////////////////////////////////////////////////
    writer.write_all(b"II")?;            // 'I', 'I'
    write_u16_le(&mut writer, 42)?;      // magic number 42
    write_u32_le(&mut writer, ifd_offset)?; // offset to first IFD

    //////////////////////////////////////////////////////////////////////////
    // 2) Write the GHOST_HEADER
    //////////////////////////////////////////////////////////////////////////
    writer.write_all(GHOST_HEADER.as_bytes())?;

    //////////////////////////////////////////////////////////////////////////
    // 3) IFD: 14 tags, plus next-IFD offset = 0
    //////////////////////////////////////////////////////////////////////////
    //   - 2 bytes for tag count
    //   - 14 * 12 bytes for tags
    //   - 4 bytes for next IFD offset
    //////////////////////////////////////////////////////////////////////////

    // Write the tag count
    write_u16_le(&mut writer, num_tags)?;

    // Now write each tag
    // (tag, type, count, value)
    write_tag(&mut writer, 256, 3, 1, IMAGE_WIDTH)?;       // 256 (ImageWidth)
    write_tag(&mut writer, 257, 3, 1, IMAGE_HEIGHT)?;      // 257 (ImageHeight)
    write_tag(&mut writer, 258, 3, 1, BITS_PER_SAMPLE)?;   // 258 (BitsPerSample)
    write_tag(&mut writer, 259, 3, 1, 1)?;                 // 259 (No compression)
    write_tag(&mut writer, 262, 3, 1, 1)?;                 // 262 (Photometric)
    write_tag(&mut writer, 277, 3, 1, SAMPLES_PER_PIXEL)?; // 277 (SamplesPerPixel)
    write_tag(&mut writer, 322, 4, 1, TILE_WIDTH)?;        // 322 (TileWidth)
    write_tag(&mut writer, 323, 4, 1, TILE_LENGTH)?;       // 323 (TileLength)
    write_tag(&mut writer, 324, 4, NUM_TILES, offset_tile_offsets)?;    // TileOffsets
    write_tag(&mut writer, 325, 4, NUM_TILES, offset_tile_bytecounts)?; // TileByteCounts
    write_tag(&mut writer, 34264, 12, 16, offset_model_transform)?;     // ModelTransformationTag
    write_tag(&mut writer, 34735, 3, 76, offset_geo_key)?;              // GeoKeyDirectoryTag
    write_tag(&mut writer, 34736, 12, 6, offset_geo_double)?;           // GeoDoubleParamsTag
    write_tag(&mut writer, 34737, 2, len_geo_ascii, offset_geo_ascii)?; // GeoASCIIParamsTag

    // next IFD offset = 0
    write_u32_le(&mut writer, 0)?;

    //////////////////////////////////////////////////////////////////////////
    // 4) Tile offsets array (NUM_TILES), then tile bytecounts array (NUM_TILES)
    //////////////////////////////////////////////////////////////////////////
    for i in 0..NUM_TILES {
        let tile_offset = offset_tile_data + i * BYTES_PER_TILE;
        write_u32_le(&mut writer, tile_offset)?;
    }
    for _ in 0..NUM_TILES {
        write_u32_le(&mut writer, BYTES_PER_TILE)?;
    }

    //////////////////////////////////////////////////////////////////////////
    // 5) Model transformation (16 doubles)
    //////////////////////////////////////////////////////////////////////////
    for &val in MODEL_TRANSFORMATION.iter() {
        write_f64_le(&mut writer, val)?;
    }

    //////////////////////////////////////////////////////////////////////////
    // 6) GeoKey (76 SHORT)
    //////////////////////////////////////////////////////////////////////////
    for &val in GEO_KEY.iter() {
        write_u16_le(&mut writer, val)?;
    }

    //////////////////////////////////////////////////////////////////////////
    // 7) GeoDoubleParams (6 doubles)
    //////////////////////////////////////////////////////////////////////////
    for &val in GEO_DOUBLE_PARAMS.iter() {
        write_f64_le(&mut writer, val)?;
    }

    //////////////////////////////////////////////////////////////////////////
    // 8) GeoASCIIParams
    //////////////////////////////////////////////////////////////////////////
    writer.write_all(GEO_ASCII_PARAMS.as_bytes())?;

    //////////////////////////////////////////////////////////////////////////
    // 9) Tile data
    //////////////////////////////////////////////////////////////////////////
    writer.write_all(&tile_data_all)?;

    writer.flush()?;
    println!("Created 'moon.tif' successfully.");
    Ok(())
}
