#include <napi/native_api.h>
#include <hilog/log.h>
#include <cstring>
#include <cstdint>
#include <cstdio>
#include <vector>
#include <string>

// minimp3 is header-only: define implementation before include
#define MINIMP3_IMPLEMENTATION
extern "C" {
#include "minimp3.h"
}

#undef LOG_TAG
#define LOG_TAG "MP3Decoder"
#define LOG_DEBUG(...) OH_LOG_Print(LOG_APP, LOG_INFO, 0, LOG_TAG, __VA_ARGS__)

static napi_value DecodeMp3ToWav(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 2) {
        napi_throw_error(env, nullptr, "Expected 2 arguments (Uint8Array mp3Data, string outputPath)");
        return nullptr;
    }

    // --- 1. Read MP3 data from Uint8Array ---
    napi_typedarray_type type;
    size_t mp3Len = 0;
    void* mp3Data = nullptr;
    napi_value arrayBuf = nullptr;
    size_t byteOff = 0;
    napi_status status = napi_get_typedarray_info(env, args[0], &type, &mp3Len, &mp3Data, &arrayBuf, &byteOff);
    if (status != napi_ok || type != napi_uint8_array || mp3Data == nullptr || mp3Len < 4) {
        napi_throw_error(env, nullptr, "Invalid input: expected Uint8Array with MP3 data");
        return nullptr;
    }

    // --- 2. Read output path string ---
    size_t pathLen = 0;
    napi_get_value_string_utf8(env, args[1], nullptr, 0, &pathLen);
    std::string outPath(pathLen, '\0');
    napi_get_value_string_utf8(env, args[1], &outPath[0], pathLen + 1, &pathLen);

    // --- 3. Decode MP3 frames to PCM ---
    mp3dec_t mp3d;
    mp3dec_init(&mp3d);

    std::vector<short> pcmAll;
    int totalSamples = 0;
    int finalRate = 24000;
    int finalChannels = 1;

    uint8_t* buf = static_cast<uint8_t*>(mp3Data);
    size_t off = 0;

    while (off < mp3Len) {
        mp3dec_frame_info_t frameInfo;
        short pcm[MINIMP3_MAX_SAMPLES_PER_FRAME];

        int samples = mp3dec_decode_frame(&mp3d, buf + off, static_cast<int>(mp3Len - off), pcm, &frameInfo);

        if (samples > 0 && frameInfo.frame_bytes > 0) {
            size_t totalSamp = static_cast<size_t>(samples) * frameInfo.channels;
            pcmAll.insert(pcmAll.end(), pcm, pcm + totalSamp);
            totalSamples += samples;
            finalRate = frameInfo.hz;
            finalChannels = frameInfo.channels;
            off += frameInfo.frame_bytes;
        } else {
            off++;
            if (off >= mp3Len) break;
        }
    }

    if (pcmAll.empty()) {
        napi_throw_error(env, nullptr, "No PCM data decoded from MP3");
        return nullptr;
    }

    // Log decoded parameters
    int dataSize = static_cast<int>(pcmAll.size() * sizeof(short));
    LOG_DEBUG("Decoded: samples=%d rate=%d ch=%d pcmBytes=%d path=%s",
              totalSamples, finalRate, finalChannels, dataSize, outPath.c_str());

    // --- 4. Write WAV file directly from C++ ---
    FILE* f = fopen(outPath.c_str(), "wb");
    if (!f) {
        std::string err = "Cannot open output file: " + outPath;
        napi_throw_error(env, nullptr, err.c_str());
        return nullptr;
    }

    int16_t numChannels = static_cast<int16_t>(finalChannels);
    int32_t sampleRate = finalRate; // 使用 minimp3 从 MPEG 帧头读到的真实采样率（Edge TTS 固定 24kHz）
    LOG_DEBUG("WAV header: rate=%d ch=%d size=%d", sampleRate, numChannels, dataSize);
    int16_t bitsPerSample = 16;
    int16_t blockAlign = numChannels * (bitsPerSample / 8);
    int32_t byteRate = sampleRate * blockAlign;

    // RIFF header
    fwrite("RIFF", 1, 4, f);
    int32_t chunkSize = 36 + dataSize;
    fwrite(&chunkSize, 4, 1, f);
    fwrite("WAVE", 1, 4, f);

    // fmt subchunk
    fwrite("fmt ", 1, 4, f);
    int32_t subchunk1Size = 16;
    fwrite(&subchunk1Size, 4, 1, f);
    int16_t audioFormat = 1; // PCM
    fwrite(&audioFormat, 2, 1, f);
    fwrite(&numChannels, 2, 1, f);
    fwrite(&sampleRate, 4, 1, f);
    fwrite(&byteRate, 4, 1, f);
    fwrite(&blockAlign, 2, 1, f);
    fwrite(&bitsPerSample, 2, 1, f);

    // data chunk
    fwrite("data", 1, 4, f);
    fwrite(&dataSize, 4, 1, f);

    // PCM data
    fwrite(pcmAll.data(), 1, dataSize, f);

    fclose(f);
    LOG_DEBUG("WAV written OK: %s (%d bytes)", outPath.c_str(), 44 + dataSize);

    // Return success
    napi_value result;
    napi_get_boolean(env, true, &result);
    return result;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        { "decodeMp3ToWav", nullptr, DecodeMp3ToWav, nullptr, nullptr, nullptr, napi_default, nullptr }
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

NAPI_MODULE(mp3_decoder, Init)
