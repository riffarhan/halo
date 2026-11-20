#ifndef HALO_AUDIO_H
#define HALO_AUDIO_H

#include <CoreAudio/CoreAudio.h>

/// Forwards what apps play on the Halo Sync device (read from its loopback input) to a real speaker.
/// The two devices run on separate clocks, so the reader resamples by a hair to keep a small, steady
/// buffer between them. Everything on the audio threads is lock-free and allocation-free.
OSStatus halo_forward_start(AudioDeviceID source, AudioDeviceID destination);
void halo_forward_stop(void);
/// Whether audio is currently flowing to the speaker.
int halo_forward_running(void);
/// Average audio held between the two devices, in ms (the forwarding's own added delay).
double halo_forward_buffer_ms(void);
/// Times the speaker ran out of audio since start (should stay 0).
unsigned halo_forward_underruns(void);

#endif
