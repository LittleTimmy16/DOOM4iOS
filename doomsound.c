// doomsound.c
// Sound effects for doomgeneric on iOS.
// Doom hands us sound effects; we mix them into a buffer here, and doomios.m
// plays that buffer through AudioQueue. Music is stubbed out (silent) for now.

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <pthread.h>

#include "doomfeatures.h"
#include "doomtype.h"
#include "i_sound.h"
#include "w_wad.h"
#include "z_zone.h"

// Implemented in doomios.m
extern void DoomAudioStart(int rate);

#define OUT_RATE     44100
#define NUM_CHANNELS 16

// Variables that i_sound.c expects the old SDL sound code to define
int   use_libsamplerate   = 0;
float libsamplerate_scale = 0.65f;

typedef struct {
    int            active;
    const uint8_t *data;    // 8-bit unsigned samples
    uint32_t       length;  // number of source samples
    uint32_t       pos;     // position, 16.16 fixed point
    uint32_t       step;    // advance per output sample, 16.16 fixed point
    int            vol;     // 0..127
    int            lgain;   // 0..127
    int            rgain;   // 0..127
} mixchan_t;

static mixchan_t chans[NUM_CHANNELS];
static pthread_mutex_t mixMutex = PTHREAD_MUTEX_INITIALIZER;
static boolean use_prefix = true;

// ---------------------------------------------------------------
// Mixer (called on the audio thread)
// ---------------------------------------------------------------

void DoomAudioFill(int16_t *out, int frames)
{
    int i, k;

    pthread_mutex_lock(&mixMutex);

    for (i = 0; i < frames; i++)
    {
        int32_t l = 0, r = 0;

        for (k = 0; k < NUM_CHANNELS; k++)
        {
            mixchan_t *c = &chans[k];
            uint32_t idx;
            int32_t s;

            if (!c->active) continue;

            idx = c->pos >> 16;
            if (idx >= c->length)
            {
                c->active = 0;
                continue;
            }

            s = ((int32_t)c->data[idx] - 128) << 8;
            l += (s * c->vol * c->lgain) >> 14;
            r += (s * c->vol * c->rgain) >> 14;
            c->pos += c->step;
        }

        if (l > 32767) l = 32767;
        if (l < -32768) l = -32768;
        if (r > 32767) r = 32767;
        if (r < -32768) r = -32768;

        out[2 * i]     = (int16_t)l;
        out[2 * i + 1] = (int16_t)r;
    }

    pthread_mutex_unlock(&mixMutex);
}

// ---------------------------------------------------------------
// sound_module_t functions (called on the game thread)
// ---------------------------------------------------------------

static boolean Snd_Init(boolean use_sfx_prefix)
{
    use_prefix = use_sfx_prefix;
    memset(chans, 0, sizeof(chans));
    DoomAudioStart(OUT_RATE);
    return true;
}

static void Snd_Shutdown(void)
{
}

static int Snd_GetSfxLumpNum(sfxinfo_t *sfx)
{
    char namebuf[16];

    // Linked sounds use another sound's lump
    if (sfx->link != NULL) sfx = sfx->link;

    // Doom sound lumps have a "ds" prefix
    if (use_prefix)
        snprintf(namebuf, sizeof(namebuf), "ds%s", sfx->name);
    else
        snprintf(namebuf, sizeof(namebuf), "%s", sfx->name);

    return W_GetNumForName(namebuf);
}

static void Snd_Update(void)
{
}

static void SetPan(mixchan_t *c, int vol, int sep)
{
    int l = 254 - sep;
    int r = sep;

    c->vol   = vol;
    c->lgain = l < 127 ? l : 127;
    c->rgain = r < 127 ? r : 127;
}

static void Snd_UpdateSoundParams(int channel, int vol, int sep)
{
    if (channel < 0 || channel >= NUM_CHANNELS) return;

    pthread_mutex_lock(&mixMutex);
    SetPan(&chans[channel], vol, sep);
    pthread_mutex_unlock(&mixMutex);
}

static int Snd_StartSound(sfxinfo_t *sfx, int channel, int vol, int sep)
{
    const uint8_t *lump;
    int lumpnum, lumplen;
    uint32_t rate, length;
    mixchan_t *c;

    if (channel < 0 || channel >= NUM_CHANNELS) return -1;

    lumpnum = sfx->lumpnum;
    if (lumpnum < 0) return -1;

    lumplen = W_LumpLength(lumpnum);
    lump = (const uint8_t *)W_CacheLumpNum(lumpnum, PU_STATIC);

    // DMX sound lump: 8-byte header, then 8-bit unsigned samples
    if (lump == NULL || lumplen < 8 || lump[0] != 0x03 || lump[1] != 0x00)
        return -1;

    rate   = lump[2] | (lump[3] << 8);
    length = lump[4] | (lump[5] << 8) | (lump[6] << 16) | ((uint32_t)lump[7] << 24);

    if (rate == 0 || length > (uint32_t)lumplen - 8 || length <= 48)
        return -1;

    pthread_mutex_lock(&mixMutex);

    c = &chans[channel];
    c->data   = lump + 8 + 16;     // skip header and 16 padding bytes
    c->length = length - 32;       // padding at both ends
    c->pos    = 0;
    c->step   = (uint32_t)(((uint64_t)rate << 16) / OUT_RATE);
    SetPan(c, vol, sep);
    c->active = 1;

    pthread_mutex_unlock(&mixMutex);

    return channel;
}

static void Snd_StopSound(int channel)
{
    if (channel < 0 || channel >= NUM_CHANNELS) return;

    pthread_mutex_lock(&mixMutex);
    chans[channel].active = 0;
    pthread_mutex_unlock(&mixMutex);
}

static boolean Snd_SoundIsPlaying(int channel)
{
    boolean playing;

    if (channel < 0 || channel >= NUM_CHANNELS) return false;

    pthread_mutex_lock(&mixMutex);
    playing = chans[channel].active ? true : false;
    pthread_mutex_unlock(&mixMutex);

    return playing;
}

static snddevice_t sfx_devices[] =
{
    SNDDEVICE_SB,
    SNDDEVICE_GUS,
};

sound_module_t DG_sound_module =
{
    .sound_devices     = sfx_devices,
    .num_sound_devices = 2,
    .Init              = Snd_Init,
    .Shutdown          = Snd_Shutdown,
    .GetSfxLumpNum     = Snd_GetSfxLumpNum,
    .Update            = Snd_Update,
    .UpdateSoundParams = Snd_UpdateSoundParams,
    .StartSound        = Snd_StartSound,
    .StopSound         = Snd_StopSound,
    .SoundIsPlaying    = Snd_SoundIsPlaying,
    .CacheSounds       = NULL,
};

// ---------------------------------------------------------------
// Music: silent placeholder
// ---------------------------------------------------------------

static int dummySong;

static boolean Mus_Init(void)                        { return true; }
static void    Mus_Shutdown(void)                    { }
static void    Mus_SetVolume(int volume)             { }
static void    Mus_Pause(void)                       { }
static void    Mus_Resume(void)                      { }
static void   *Mus_Register(void *data, int len)     { return &dummySong; }
static void    Mus_Unregister(void *handle)          { }
static void    Mus_Play(void *handle, boolean loop)  { }
static void    Mus_Stop(void)                        { }
static boolean Mus_IsPlaying(void)                   { return false; }
static void    Mus_Poll(void)                        { }

music_module_t DG_music_module =
{
    .sound_devices     = sfx_devices,
    .num_sound_devices = 2,
    .Init              = Mus_Init,
    .Shutdown          = Mus_Shutdown,
    .SetMusicVolume    = Mus_SetVolume,
    .PauseMusic        = Mus_Pause,
    .ResumeMusic       = Mus_Resume,
    .RegisterSong      = Mus_Register,
    .UnRegisterSong    = Mus_Unregister,
    .PlaySong          = Mus_Play,
    .StopSong          = Mus_Stop,
    .MusicIsPlaying    = Mus_IsPlaying,
    .Poll              = Mus_Poll,
};

