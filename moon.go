package main

import (
    "bytes"
    "encoding/binary"
    "fmt"
    "math/rand"
    "os"
    "time"
)

// ---------------------------------------------------------------------------
// 1) Define image layout, tile info, and GHOST_HEADER (typed as uint32/[]byte)
// ---------------------------------------------------------------------------
const (
    IMAGE_WIDTH       uint32 = 1024
    IMAGE_HEIGHT      uint32 = 1024
    TILE_WIDTH        uint32 = 128
    TILE_LENGTH       uint32 = 128
    BITS_PER_SAMPLE   uint32 = 8
    SAMPLES_PER_PIXEL uint32 = 1 // Grayscale

    // We'll define these as typed constants to avoid mismatches.
    // 8 => tiles wide, 8 => tiles high => 64 total
    NUM_TILES_WIDE  = IMAGE_WIDTH / TILE_WIDTH
    NUM_TILES_HIGH  = IMAGE_HEIGHT / TILE_LENGTH
    NUM_TILES       = NUM_TILES_WIDE * NUM_TILES_HIGH
    BYTES_PER_TILE  uint32 = TILE_WIDTH * TILE_LENGTH * SAMPLES_PER_PIXEL
)

// GHOST_HEADER as a byte slice:
var GHOST_HEADER = []byte(
    "GDAL_STRUCTURAL_METADATA_SIZE=000140 bytes\n" +
        "LAYOUT=IFDS_BEFORE_DATA\n" +
        "BLOCK_ORDER=ROW_MAJOR\n" +
        "BLOCK_LEADER=SIZE_AS_UINT4\n" +
        "BLOCK_TRAILER=LAST_4_BYTES_REPEATED\n" +
        "KNOWN_INCOMPATIBLE_EDITION=NO ",
)

// ---------------------------------------------------------------------------
// 2) Generate random tile data (8-bit)
// ---------------------------------------------------------------------------
func generateRandomTileData() []byte {
    totalBytes := NUM_TILES * BYTES_PER_TILE
    data := make([]byte, totalBytes)
    rand.Seed(time.Now().UnixNano())
    for i := uint32(0); i < totalBytes; i++ {
        data[i] = byte(rand.Intn(256)) // 0..255
    }
    return data
}

// ---------------------------------------------------------------------------
// 3) Build the 8-byte TIFF header
// ---------------------------------------------------------------------------
func buildTiffHeader(ifdOffset uint32) []byte {
    buf := new(bytes.Buffer)
    // "II" => 0x49, 0x49
    buf.Write([]byte{0x49, 0x49})
    // magic 42 (uint16, little-endian)
    binary.Write(buf, binary.LittleEndian, uint16(42))
    // offset to first IFD (uint32, little-endian)
    binary.Write(buf, binary.LittleEndian, ifdOffset)
    return buf.Bytes()
}

// ---------------------------------------------------------------------------
// 4) GeoTIFF data
// ---------------------------------------------------------------------------
func geoData() (modelTransformation, geoKey, geoDoubleParams, geoAsciiParams []byte) {
    // model_transformation (16 doubles)
    mtVals := []float64{
        118.4505876, 0.0, 0.0, -5458203.076608,
        0.0, -118.4505876, 0.0, 2729101.538304,
        0.0, 0.0, 0.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    }
    mtBuf := new(bytes.Buffer)
    for _, v := range mtVals {
        binary.Write(mtBuf, binary.LittleEndian, v)
    }
    modelTransformation = mtBuf.Bytes()

    // geo_key (76 uint16)
    gkVals := []uint16{
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
        3073, 34737, 20, 117, // "20" from snippet
        3074, 0, 1, 32767,
        3075, 0, 1, 12,
        3076, 0, 1, 9001,
        3078, 34736, 1, 3,
        3082, 34736, 1, 4,
        3084, 34736, 1, 5,
    }
    gkBuf := new(bytes.Buffer)
    for _, v := range gkVals {
        binary.Write(gkBuf, binary.LittleEndian, v)
    }
    geoKey = gkBuf.Bytes()

    // geo_double_params (6 doubles)
    gdVals := []float64{
        1737400.0, 1737400.0, 0.0, 0.0, 0.0, 0.0,
    }
    gdBuf := new(bytes.Buffer)
    for _, v := range gdVals {
        binary.Write(gdBuf, binary.LittleEndian, v)
    }
    geoDoubleParams = gdBuf.Bytes()

    // geo_ascii_params
    geoAsciiParams = []byte(
        "GCS Name = Moon 2000|Datum = D_Moon_2000|Ellipsoid = Moon_2000_IAU_IAG|" +
            "Primem = Reference_Meridian|AUnits = Decimal_Degree|" +
            "SimpleCylindrical Moon|",
    )
    return
}

// ---------------------------------------------------------------------------
// 5) Calculate offsets
// ---------------------------------------------------------------------------
// 14 tags => 14*12 = 168 bytes, plus 2 for tag count, plus 4 for next-IFD => 174.
func calcOffsets(ifdOffset uint32, mtLen, gkLen, gdLen, gaLen int) (
    offsetTileOffsets, offsetTileBytecounts,
    offsetModelTransform, offsetGeoKey,
    offsetGeoDouble, offsetGeoAscii, offsetTileData uint32) {

    numTags := uint16(14)
    ifdSize := uint32(2 + (numTags * 12) + 4) // 174
    offsetAfterIFD := ifdOffset + ifdSize

    offsetTileOffsets = offsetAfterIFD
    offsetTileBytecounts = offsetTileOffsets + (NUM_TILES * 4)
    offsetModelTransform = offsetTileBytecounts + (NUM_TILES * 4)
    offsetGeoKey = offsetModelTransform + uint32(mtLen)
    offsetGeoDouble = offsetGeoKey + uint32(gkLen)
    offsetGeoAscii = offsetGeoDouble + uint32(gdLen)
    offsetTileData = offsetGeoAscii + uint32(gaLen)

    return
}

// ---------------------------------------------------------------------------
// 6) Build tile offsets & bytecounts arrays
// ---------------------------------------------------------------------------
func buildTileOffsets(tileDataStart uint32) []byte {
    buf := new(bytes.Buffer)
    for i := uint32(0); i < NUM_TILES; i++ {
        off := tileDataStart + i*BYTES_PER_TILE
        binary.Write(buf, binary.LittleEndian, off)
    }
    return buf.Bytes()
}

func buildTileBytecounts() []byte {
    buf := new(bytes.Buffer)
    for i := uint32(0); i < NUM_TILES; i++ {
        binary.Write(buf, binary.LittleEndian, BYTES_PER_TILE)
    }
    return buf.Bytes()
}

// ---------------------------------------------------------------------------
// 7) Build the 14 IFD tags (12 bytes each), then 2-byte count + 4-byte next=0
// ---------------------------------------------------------------------------
func buildIFDTags(
    imageWidth, imageHeight, bitsPerSample, samplesPerPixel,
    tileWidth, tileLength uint32,
    offsetTileOffsets, offsetTileBytecounts,
    offsetModelTransform, offsetGeoKey, offsetGeoDouble, offsetGeoAscii uint32,
    asciiLen uint32,
) []byte {

    buf := new(bytes.Buffer)
    // Helper to write <HHLL>
    writeTag := func(tag, ttype, count, value uint32) {
        binary.Write(buf, binary.LittleEndian, uint16(tag))
        binary.Write(buf, binary.LittleEndian, uint16(ttype))
        binary.Write(buf, binary.LittleEndian, count)
        binary.Write(buf, binary.LittleEndian, value)
    }

    // 1) 256, 3, 1, IMAGE_WIDTH
    writeTag(256, 3, 1, imageWidth)
    // 2) 257, 3, 1, IMAGE_HEIGHT
    writeTag(257, 3, 1, imageHeight)
    // 3) 258, 3, 1, bitsPerSample
    writeTag(258, 3, 1, bitsPerSample)
    // 4) 259, 3, 1, 1
    writeTag(259, 3, 1, 1)
    // 5) 262, 3, 1, 1
    writeTag(262, 3, 1, 1)
    // 6) 277, 3, 1, samplesPerPixel
    writeTag(277, 3, 1, samplesPerPixel)
    // 7) 322, 4, 1, tileWidth
    writeTag(322, 4, 1, tileWidth)
    // 8) 323, 4, 1, tileLength
    writeTag(323, 4, 1, tileLength)
    // 9) 324, 4, NUM_TILES, offsetTileOffsets
    writeTag(324, 4, NUM_TILES, offsetTileOffsets)
    // 10) 325, 4, NUM_TILES, offsetTileBytecounts
    writeTag(325, 4, NUM_TILES, offsetTileBytecounts)
    // 11) 34264, 12, 16, offsetModelTransform
    writeTag(34264, 12, 16, offsetModelTransform)
    // 12) 34735, 3, 76, offsetGeoKey
    writeTag(34735, 3, 76, offsetGeoKey)
    // 13) 34736, 12, 6, offsetGeoDouble
    writeTag(34736, 12, 6, offsetGeoDouble)
    // 14) 34737, 2, asciiLen, offsetGeoAscii
    writeTag(34737, 2, asciiLen, offsetGeoAscii)

    return buf.Bytes()
}

func buildIFD(tags []byte, numTags uint16) []byte {
    buf := new(bytes.Buffer)
    // 2 bytes: tag count
    binary.Write(buf, binary.LittleEndian, numTags)
    // tags
    buf.Write(tags)
    // next IFD offset = 0
    binary.Write(buf, binary.LittleEndian, uint32(0))
    return buf.Bytes()
}

// ---------------------------------------------------------------------------
// 8) Combine everything into final TIFF
// ---------------------------------------------------------------------------
func main() {
    // 1) Random tile data
    tileDataAll := generateRandomTileData()

    // 2) Geo data
    modelTransformation, geoKey, geoDouble, geoAscii := geoData()

    // IFD offset = 8 + len(GHOST_HEADER)
    ifdOffset := uint32(8 + len(GHOST_HEADER))
    tiffHeader := buildTiffHeader(ifdOffset)

    // Offsets
    offsetTileOffsets,
        offsetTileBytecounts,
        offsetModelTransform,
        offsetGeoKey,
        offsetGeoDouble,
        offsetGeoAscii,
        offsetTileData :=
        calcOffsets(
            ifdOffset,
            len(modelTransformation),
            len(geoKey),
            len(geoDouble),
            len(geoAscii),
        )

    // Tile offsets/bytecounts array
    tileOffsetsData := buildTileOffsets(offsetTileData)
    tileBytecountsData := buildTileBytecounts()

    // Build the 14 tags
    tags := buildIFDTags(
        IMAGE_WIDTH,
        IMAGE_HEIGHT,
        BITS_PER_SAMPLE,
        SAMPLES_PER_PIXEL,
        TILE_WIDTH,
        TILE_LENGTH,
        offsetTileOffsets,
        offsetTileBytecounts,
        offsetModelTransform,
        offsetGeoKey,
        offsetGeoDouble,
        offsetGeoAscii,
        uint32(len(geoAscii)),
    )

    // Build the IFD
    numTags := uint16(14)
    ifd := buildIFD(tags, numTags)

    // Combine
    var final bytes.Buffer
    final.Write(tiffHeader)
    final.Write(GHOST_HEADER)
    final.Write(ifd)
    final.Write(tileOffsetsData)
    final.Write(tileBytecountsData)
    final.Write(modelTransformation)
    final.Write(geoKey)
    final.Write(geoDouble)
    final.Write(geoAscii)
    final.Write(tileDataAll)

    // Write to moon.tif
    err := os.WriteFile("moon.tif", final.Bytes(), 0644)
    if err != nil {
        fmt.Println("Failed to write moon.tif:", err)
        return
    }
    fmt.Println("Wrote moon.tif successfully.")
}
