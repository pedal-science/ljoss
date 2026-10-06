// ssli o -- play a WAV out of chosen channels of a CoreAudio device and record others, full duplex.
//
// Why this exists: the level campaign needs to put a *known* digital signal on the SSL's output
// channels 3 and 4 (one looped straight back into input 2 as the reference, one into the pedal) and
// record the SSL's inputs 1 and 2 at the same time, on one clock. `sox` and `ffmpeg` cannot choose
// output channels and cannot run both directions on one device with a known frame alignment.
//
//   ssli o --list
//   ssli o --play in.wav --record out.wav --device "SSL 2+" --out-map 3,4 --in-map 1,2 [--seconds 8]
//
// The played WAV is also written to `<record>.playback.wav`, frame-aligned with the capture, so the
// analysis can align the two by frame index rather than by guessing the device's latency.
//
// Build: clang -O2 -o ssli o ssli o.c -framework CoreAudio -framework AudioUnit -framework AudioToolbox \
//        -I/opt/homebrew/include -L/opt/homebrew/lib -lsndfile

#include <AudioToolbox/AudioToolbox.h>
#include <time.h>
#include <mach/mach_time.h>
#include <CoreAudio/CoreAudio.h>
#include <sndfile.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_CHANNELS 8

static void die(const char *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    fprintf(stderr, "sslio: ");
    vfprintf(stderr, fmt, args);
    fprintf(stderr, "\n");
    va_end(args);
    exit(1);
}

static void note(const char *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    fprintf(stderr, "\n");
    va_end(args);
}

// ---------------------------------------------------------------- device lookup

static CFStringRef copy_device_name(AudioDeviceID device)
{
    CFStringRef name = NULL;
    UInt32 size = sizeof(name);
    AudioObjectPropertyAddress address = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
                                          kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &name) != noErr)
        return NULL;
    return name;
}

static UInt32 channel_count(AudioDeviceID device, AudioObjectPropertyScope scope)
{
    AudioObjectPropertyAddress address = {kAudioDevicePropertyStreamConfiguration, scope,
                                          kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size) != noErr || size == 0)
        return 0;
    AudioBufferList *list = (AudioBufferList *)malloc(size);
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, list) != noErr)
    {
        free(list);
        return 0;
    }
    UInt32 channels = 0;
    for (UInt32 i = 0; i < list->mNumberBuffers; ++i)
        channels += list->mBuffers[i].mNumberChannels;
    free(list);
    return channels;
}

static double nominal_rate(AudioDeviceID device)
{
    Float64 rate = 0;
    UInt32 size = sizeof(rate);
    AudioObjectPropertyAddress address = {kAudioDevicePropertyNominalSampleRate,
                                          kAudioObjectPropertyScopeGlobal,
                                          kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &rate) != noErr)
        return 0;
    return rate;
}

static AudioDeviceID find_device(const char *needle)
{
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyDevices,
                                          kAudioObjectPropertyScopeGlobal,
                                          kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size) != noErr)
        die("cannot list audio devices");
    AudioDeviceID *devices = (AudioDeviceID *)malloc(size);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, devices);
    const UInt32 count = size / sizeof(AudioDeviceID);
    AudioDeviceID found = kAudioObjectUnknown;
    for (UInt32 i = 0; i < count; ++i)
    {
        CFStringRef name = copy_device_name(devices[i]);
        if (!name)
            continue;
        char buffer[256];
        CFStringGetCString(name, buffer, sizeof(buffer), kCFStringEncodingUTF8);
        CFRelease(name);
        if (strstr(buffer, needle))
        {
            found = devices[i];
            note("device: %s (id %u, %u in, %u out, %.0f Hz)", buffer, (unsigned)devices[i],
                 (unsigned)channel_count(devices[i], kAudioObjectPropertyScopeInput),
                 (unsigned)channel_count(devices[i], kAudioObjectPropertyScopeOutput),
                 nominal_rate(devices[i]));
            break;
        }
    }
    free(devices);
    return found;
}

static void list_devices(void)
{
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyDevices,
                                          kAudioObjectPropertyScopeGlobal,
                                          kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size);
    AudioDeviceID *devices = (AudioDeviceID *)malloc(size);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, devices);
    const UInt32 count = size / sizeof(AudioDeviceID);
    for (UInt32 i = 0; i < count; ++i)
    {
        CFStringRef name = copy_device_name(devices[i]);
        char buffer[256] = "?";
        if (name)
        {
            CFStringGetCString(name, buffer, sizeof(buffer), kCFStringEncodingUTF8);
            CFRelease(name);
        }
        printf("%-40s id=%-4u in=%u out=%u rate=%.0f\n", buffer, (unsigned)devices[i],
               (unsigned)channel_count(devices[i], kAudioObjectPropertyScopeInput),
               (unsigned)channel_count(devices[i], kAudioObjectPropertyScopeOutput),
               nominal_rate(devices[i]));
    }
    free(devices);
}

// ---------------------------------------------------------------- stream state

typedef struct
{
    float *play[MAX_CHANNELS];  // client playback channels (interleaved-free), count out_channels
    sf_count_t play_frames;
    sf_count_t play_position;

    int out_channels;           // device output channels opened
    int in_channels;            // device input channels opened
    int out_map[MAX_CHANNELS];  // client channel i -> device channel index (0-based)
    int in_map[MAX_CHANNELS];
    int play_channels;          // channels in the played WAV

    float *capture[MAX_CHANNELS];  // capture ring, one per device input channel
    sf_count_t capture_frames;
    sf_count_t capture_capacity;

    AudioUnit unit;
    double sample_rate;
    double first_render_wall;   // CLOCK_REALTIME at the first render callback: frame 0 of both files
    UInt64 render_calls;
    int finished;
    int render_errors;
    int input_render_errors;
} Stream;

static Stream g_stream;

static OSStatus render_callback(void *ref, AudioUnitRenderActionFlags *flags,
                                const AudioTimeStamp *timestamp, UInt32 bus, UInt32 frames,
                                AudioBufferList *output)
{
    Stream *s = (Stream *)ref;
    (void)bus;

    // Frame 0 of the capture and of the played file is this callback, so stamping the wall clock
    // here is what lets the analysis line the pedal's own clock up with the Mac's: a poll window
    // taken at time T is compared against the frames whose wall time this fixes.
    if (s->render_calls == 0)
    {
        struct timespec now;
        clock_gettime(CLOCK_REALTIME, &now);
        s->first_render_wall = (double)now.tv_sec + (double)now.tv_nsec / 1e9;
    }

    // The input lives on the same device as the output, so pulling it here keeps the two on one
    // clock and one frame index -- the alternative (an input callback and a ring) buys a latency
    // between the two that has to be measured back out again.
    AudioBufferList *input = NULL;
    if (s->in_channels > 0)
    {
        input = (AudioBufferList *)malloc(sizeof(AudioBufferList) +
                                          sizeof(AudioBuffer) * (s->in_channels - 1));
        input->mNumberBuffers = s->in_channels;
        for (int c = 0; c < s->in_channels; ++c)
        {
            input->mBuffers[c].mNumberChannels = 1;
            input->mBuffers[c].mDataByteSize = frames * sizeof(float);
            input->mBuffers[c].mData = malloc(frames * sizeof(float));
        }
        OSStatus status = AudioUnitRender(s->unit, flags, timestamp, 1, frames, input);
        if (status != noErr)
        {
            ++s->input_render_errors;
        }
        else if (s->capture_frames + frames <= s->capture_capacity)
        {
            for (int c = 0; c < s->in_channels; ++c)
                memcpy(s->capture[c] + s->capture_frames, input->mBuffers[c].mData,
                       frames * sizeof(float));
            s->capture_frames += frames;
        }
        for (int c = 0; c < s->in_channels; ++c)
            free(input->mBuffers[c].mData);
        free(input);
    }

    // Fill the output: every device channel silent, then whatever the map asks for.
    for (UInt32 b = 0; b < output->mNumberBuffers; ++b)
    {
        AudioBuffer *buffer = &output->mBuffers[b];
        memset(buffer->mData, 0, buffer->mDataByteSize);
    }
    // Non-interleaved: buffer b is device channel b when every buffer is mono.
    if (output->mNumberBuffers == (UInt32)s->out_channels)
    {
        for (int c = 0; c < s->play_channels; ++c)
        {
            const int device_channel = s->out_map[c];
            if (device_channel < 0 || device_channel >= s->out_channels)
                continue;
            float *destination = (float *)output->mBuffers[device_channel].mData;
            for (UInt32 f = 0; f < frames; ++f)
            {
                const sf_count_t at = s->play_position + f;
                destination[f] = at < s->play_frames ? s->play[c][at] : 0.0f;
            }
        }
    }
    else
    {
        // Interleaved fallback (a device that hands back one buffer): same map, strided writes.
        for (UInt32 b = 0; b < output->mNumberBuffers; ++b)
        {
            AudioBuffer *buffer = &output->mBuffers[b];
            const int first = (int)(b * 1);  // unused; kept for clarity of the mono assumption
            (void)first;
            float *data = (float *)buffer->mData;
            const UInt32 stride = buffer->mNumberChannels;
            for (int c = 0; c < s->play_channels; ++c)
            {
                const int device_channel = s->out_map[c];
                if (device_channel < 0 || device_channel >= (int)stride)
                    continue;
                for (UInt32 f = 0; f < frames; ++f)
                {
                    const sf_count_t at = s->play_position + f;
                    data[f * stride + device_channel] = at < s->play_frames ? s->play[c][at] : 0.0f;
                }
            }
        }
    }

    s->play_position += frames;
    ++s->render_calls;
    if (s->play_position >= s->play_frames)
        s->finished = 1;
    return noErr;
}

// ---------------------------------------------------------------- WAV I/O

typedef struct
{
    SNDFILE *file;
    SF_INFO info;
} Wav;

static void wav_open_read(Wav *wav, const char *path, int *channels, int *rate)
{
    memset(&wav->info, 0, sizeof(wav->info));
    wav->file = sf_open(path, SFM_READ, &wav->info);
    if (!wav->file)
        die("cannot read %s: %s", path, sf_strerror(NULL));
    *channels = wav->info.channels;
    *rate = wav->info.samplerate;
}

static void wav_open_write(Wav *wav, const char *path, int channels, int rate)
{
    memset(&wav->info, 0, sizeof(wav->info));
    wav->info.channels = channels;
    wav->info.samplerate = rate;
    wav->info.format = SF_FORMAT_WAV | SF_FORMAT_FLOAT;
    wav->file = sf_open(path, SFM_WRITE, &wav->info);
    if (!wav->file)
        die("cannot write %s: %s", path, sf_strerror(NULL));
}

static int parse_channels(const char *text, int *map, int max)
{
    int count = 0;
    const char *at = text;
    while (*at && count < max)
    {
        char *end = NULL;
        long value = strtol(at, &end, 10);
        if (end == at)
            break;
        map[count++] = (int)value - 1;  // 1-based on the command line
        at = end;
        while (*at == ',' || *at == ' ')
            ++at;
    }
    return count;
}

static double now_seconds(void)
{
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0)
        mach_timebase_info(&timebase);
    return (double)mach_absolute_time() * timebase.numer / timebase.denom / 1e9;
}

int main(int argc, const char *argv[])
{
    const char *play_path = NULL, *record_path = NULL, *device_name = "SSL";
    const char *out_map_text = "1,2", *in_map_text = "1,2";
    double seconds = 0;
    double rate = 48000;

    for (int i = 1; i < argc; ++i)
    {
        const char *a = argv[i];
        if (!strcmp(a, "--list"))
        {
            list_devices();
            return 0;
        }
        else if (!strcmp(a, "--play") && i + 1 < argc) play_path = argv[++i];
        else if (!strcmp(a, "--record") && i + 1 < argc) record_path = argv[++i];
        else if (!strcmp(a, "--device") && i + 1 < argc) device_name = argv[++i];
        else if (!strcmp(a, "--out-map") && i + 1 < argc) out_map_text = argv[++i];
        else if (!strcmp(a, "--in-map") && i + 1 < argc) in_map_text = argv[++i];
        else if (!strcmp(a, "--seconds") && i + 1 < argc) seconds = atof(argv[++i]);
        else if (!strcmp(a, "--rate") && i + 1 < argc) rate = atof(argv[++i]);
        else die("unknown argument %s", a);
    }
    if (!record_path)
        die("--record is required");

    AudioDeviceID device = find_device(device_name);
    if (device == kAudioObjectUnknown)
        die("no audio device matching '%s'", device_name);

    // One clock for both directions and the same rate as the pedal's engine, so a level comparison
    // is not also a resampling question.
    Float64 wanted_rate = rate;
    AudioObjectPropertyAddress rate_address = {kAudioDevicePropertyNominalSampleRate,
                                               kAudioObjectPropertyScopeGlobal,
                                               kAudioObjectPropertyElementMain};
    AudioObjectSetPropertyData(device, &rate_address, 0, NULL, sizeof(wanted_rate), &wanted_rate);

    Stream *s = &g_stream;
    memset(s, 0, sizeof(*s));
    s->out_channels = (int)channel_count(device, kAudioObjectPropertyScopeOutput);
    s->in_channels = (int)channel_count(device, kAudioObjectPropertyScopeInput);
    if (s->out_channels <= 0)
        die("device has no outputs");
    if (s->out_channels > MAX_CHANNELS || s->in_channels > MAX_CHANNELS)
        die("device has more channels than this tool handles (%d out, %d in)", s->out_channels,
            s->in_channels);

    const int out_count = parse_channels(out_map_text, s->out_map, MAX_CHANNELS);
    const int in_count = parse_channels(in_map_text, s->in_map, MAX_CHANNELS);

    // ---- the played signal
    int play_rate = 0;
    if (play_path)
    {
        Wav wav;
        int channels = 0;
        wav_open_read(&wav, play_path, &channels, &play_rate);
        if (channels != out_count)
            die("%s has %d channels but --out-map names %d", play_path, channels, out_count);
        if (play_rate != (int)rate)
            die("%s is %d Hz; the device is asked for %.0f Hz", play_path, play_rate, rate);
        s->play_channels = channels;
        s->play_frames = wav.info.frames;
        for (int c = 0; c < channels; ++c)
            s->play[c] = (float *)calloc((size_t)wav.info.frames, sizeof(float));
        float *interleaved = (float *)malloc((size_t)wav.info.frames * channels * sizeof(float));
        sf_readf_float(wav.file, interleaved, wav.info.frames);
        for (sf_count_t f = 0; f < wav.info.frames; ++f)
            for (int c = 0; c < channels; ++c)
                s->play[c][f] = interleaved[f * channels + c];
        free(interleaved);
        sf_close(wav.file);
    }
    else
    {
        s->play_channels = out_count;
        s->play_frames = (sf_count_t)(seconds * rate);
        for (int c = 0; c < out_count; ++c)
            s->play[c] = (float *)calloc((size_t)s->play_frames, sizeof(float));
    }
    if (seconds > 0 && (sf_count_t)(seconds * rate) > s->play_frames)
        s->play_frames = (sf_count_t)(seconds * rate);
    if (seconds <= 0)
        seconds = (double)s->play_frames / rate + 1.0;

    s->capture_capacity = (sf_count_t)((seconds + 2.0) * rate);
    for (int c = 0; c < s->in_channels; ++c)
        s->capture[c] = (float *)calloc((size_t)s->capture_capacity, sizeof(float));

    // ---- the audio unit
    AudioComponentDescription description = {kAudioUnitType_Output, kAudioUnitSubType_HALOutput,
                                             kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    if (!component)
        die("no HAL output unit");
    if (AudioComponentInstanceNew(component, &s->unit) != noErr)
        die("cannot instantiate the HAL output unit");

    UInt32 enable = 1;
    if (AudioUnitSetProperty(s->unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                             &enable, sizeof(enable)) != noErr)
        die("cannot enable input");
    if (AudioUnitSetProperty(s->unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                             &enable, sizeof(enable)) != noErr)
        die("cannot enable output");
    if (AudioUnitSetProperty(s->unit, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &device, sizeof(device)) != noErr)
        die("cannot select the device");

    // Client-side formats: float32 non-interleaved, all of the device's channels.
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    format.mSampleRate = rate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked |
                          kAudioFormatFlagIsNonInterleaved;
    format.mFramesPerPacket = 1;
    format.mChannelsPerFrame = 1;
    format.mBitsPerChannel = 32;
    format.mBytesPerFrame = 4;
    format.mBytesPerPacket = 4;

    AudioStreamBasicDescription input_format = format;
    input_format.mChannelsPerFrame = s->in_channels;
    input_format.mBytesPerFrame = 4;
    input_format.mBytesPerPacket = 4;
    if (s->in_channels > 0 &&
        AudioUnitSetProperty(s->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                             &input_format, sizeof(input_format)) != noErr)
        die("cannot set the input format");

    AudioStreamBasicDescription output_format = format;
    output_format.mChannelsPerFrame = s->out_channels;
    output_format.mBytesPerFrame = 4;
    output_format.mBytesPerPacket = 4;
    if (AudioUnitSetProperty(s->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                             &output_format, sizeof(output_format)) != noErr)
        die("cannot set the output format");

    AURenderCallbackStruct callback = {render_callback, s};
    if (AudioUnitSetProperty(s->unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                             &callback, sizeof(callback)) != noErr)
        die("cannot set the render callback");

    if (AudioUnitInitialize(s->unit) != noErr)
        die("cannot initialise the unit");

    UInt32 buffer_frames = 0;
    UInt32 buffer_size = sizeof(buffer_frames);
    AudioObjectPropertyAddress buffer_address = {kAudioDevicePropertyBufferFrameSize,
                                                 kAudioObjectPropertyScopeGlobal,
                                                 kAudioObjectPropertyElementMain};
    AudioObjectGetPropertyData(device, &buffer_address, 0, NULL, &buffer_size, &buffer_frames);

    const double started = now_seconds();
    if (AudioOutputUnitStart(s->unit) != noErr)
        die("cannot start the unit");
    note("playing %s -> channels %s, recording %s, %.2f s at %.0f Hz (buffer %u frames)",
         play_path ? play_path : "(silence)", out_map_text, record_path, seconds, rate,
         (unsigned)buffer_frames);

    // Run a little past the end of the signal so the tail is captured, then stop.
    const sf_count_t wanted = s->play_frames + (sf_count_t)(0.5 * rate);
    while (s->capture_frames < wanted && now_seconds() - started < seconds + 10.0)
        usleep(2000);
    AudioOutputUnitStop(s->unit);
    const double elapsed = now_seconds() - started;

    const sf_count_t captured = s->capture_frames;
    const sf_count_t frames_to_write = captured < wanted ? captured : wanted;
    note("captured %lld frames in %.3f s (%d input render errors, %llu render calls)",
         (long long)captured, elapsed, s->input_render_errors, (unsigned long long)s->render_calls);

    // ---- write: capture (device channels named on the command line) and the played signal
    {
        Wav wav;
        wav_open_write(&wav, record_path, in_count, (int)rate);
        float *interleaved = (float *)malloc((size_t)frames_to_write * in_count * sizeof(float));
        for (sf_count_t f = 0; f < frames_to_write; ++f)
            for (int c = 0; c < in_count; ++c)
            {
                const int device_channel = s->in_map[c];
                interleaved[f * in_count + c] =
                    (device_channel >= 0 && device_channel < s->in_channels)
                        ? s->capture[device_channel][f]
                        : 0.0f;
            }
        sf_writef_float(wav.file, interleaved, frames_to_write);
        sf_close(wav.file);
        free(interleaved);
    }
    {
        char path[1024];
        snprintf(path, sizeof(path), "%s.playback.wav", record_path);
        Wav wav;
        wav_open_write(&wav, path, s->play_channels, (int)rate);
        float *interleaved = (float *)malloc((size_t)frames_to_write * s->play_channels * sizeof(float));
        for (sf_count_t f = 0; f < frames_to_write; ++f)
            for (int c = 0; c < s->play_channels; ++c)
                interleaved[f * s->play_channels + c] = s->play[c][f];
        sf_writef_float(wav.file, interleaved, frames_to_write);
        sf_close(wav.file);
        free(interleaved);
    }

    AudioUnitUninitialize(s->unit);
    AudioComponentInstanceDispose(s->unit);
    printf("{\"captured_frames\": %lld, \"elapsed\": %.4f, \"rate\": %.0f, \"input_render_errors\": %d, "
           "\"render_calls\": %llu, \"first_render_wall\": %.6f, \"buffer_frames\": %u}\n",
           (long long)captured, elapsed, rate, s->input_render_errors,
           (unsigned long long)s->render_calls, s->first_render_wall, (unsigned)buffer_frames);
    return 0;
}
