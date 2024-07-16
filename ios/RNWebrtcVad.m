

#import "RNWebrtcVad.h"

#include "VoiceActivityDetector.h"

@implementation RNWebrtcVad {
    VoiceActivityDetector *voiceDetector;
    double cumulativeProcessedSampleLengthMs;
    BOOL hasListeners;
}

RCT_EXPORT_MODULE()

RCT_EXPORT_METHOD(start:(NSDictionary *)options)
{
    NSLog(@"[WebRTCVad] starting = %@", options);
    int mode = [options[@"mode"] intValue];
    int preferredBufferSize = -1;

    if ([options[@"preferredBufferSize"] intValue] > 0) {
        preferredBufferSize = [options[@"preferredBufferSize"] intValue];
    }

    // cache dir
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *cachesDir = [paths objectAtIndex:0];
    _fileURL = [cachesDir stringByAppendingPathComponent:@"vad.pcm"];

    // remove old file if already exist
    [[NSFileManager defaultManager] removeItemAtPath:_fileURL error:nil];

    voiceDetector = [[VoiceActivityDetector alloc] initWithMode:mode];
    AudioInputController *inputController = [AudioInputController sharedInstance];

    // If not specified, will match HW sample, which could be too high.
    // Ex: Most devices run at 48000,41000 (or 48kHz/44.1hHz). So cap at highest vad supported sample rate supported
    // See: https://github.com/TeamGuilded/react-native-webrtc-vad/blob/master/webrtc/common_audio/vad/include/webrtc_vad.h#L75
    [inputController prepareWithSampleRate:16000 preferredBufferSize:preferredBufferSize];

    [inputController start];
}

RCT_EXPORT_METHOD(stop:(RCTPromiseResolveBlock)resolve :(RCTPromiseRejectBlock)reject) {
    NSLog(@"[WebRTCVad] stopping");

    [[AudioInputController sharedInstance] stop];
    voiceDetector = nil;
    self.audioData = nil;
    NSString *fileURL = self.fileURL;
    self.fileURL = nil;
    resolve(fileURL);
}

RCT_EXPORT_METHOD(audioDeviceSettings:(RCTPromiseResolveBlock)resolve :(RCTPromiseRejectBlock)reject) {
    @try {
        AVAudioSession *audioSession = [AVAudioSession sharedInstance];

        NSDictionary *settings = @{
            @"bufferSize" : @(audioSession.IOBufferDuration * audioSession.sampleRate),
            @"hwSampleRate" : @(audioSession.sampleRate)
        };

        resolve(settings);
    } @catch (NSException *e) {
        NSLog(@"[WebRTCVad]: reporting audio device settings failed: %@", e.reason);
        reject(@"NSException", @"[WebRTCVad] reporting device settings failed", nil);
    }
}

+ (BOOL)requiresMainQueueSetup
{
  return NO;
}

-(instancetype) init {
    if (self = [super init]) {
        [AudioInputController sharedInstance].delegate = self;
        cumulativeProcessedSampleLengthMs = 0;
    }

    return self;
}

- (void) dealloc {
    voiceDetector = nil;
    self.audioData = nil;
    self.fileURL = nil;
}

- (void) processSampleData:(NSData *)data
{
    if (self.audioData == nil){
        self.audioData = [[NSMutableData alloc] init];
    }

    [self.audioData appendData:data];

    double sampleRate = [AudioInputController sharedInstance].audioSampleRate;

    // Google recommends sending samples (in 10ms, 20, or 30ms) chunk.
    // See: https://github.com/TeamGuilded/react-native-webrtc-vad/blob/master/webrtc/common_audio/vad/include/webrtc_vad.h#L75

    const double sampleLengthMs = 0.02;

    cumulativeProcessedSampleLengthMs += [data length] / sampleRate;
    int chunkSizeBytes = sampleLengthMs /* seconds/chunk */ * sampleRate * 2 /* bytes/sample */ ; /* bytes/chunk */

    if ([self.audioData length] >= chunkSizeBytes) {
        // Convert to short pointer
        const int16_t* audioSample = (const int16_t*) [self.audioData bytes];

        int isVoice = [voiceDetector isVoice:audioSample sample_rate:sampleRate length:chunkSizeBytes/2];

        // write to fileURL
        if (_fileURL != nil) {
            NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:_fileURL];
            if (fileHandle == nil) {
                [[NSFileManager defaultManager] createFileAtPath:_fileURL contents:nil attributes:nil];
                fileHandle = [NSFileHandle fileHandleForWritingAtPath:_fileURL];
            }
            [fileHandle seekToEndOfFile];
            [fileHandle writeData:self.audioData];
            [fileHandle closeFile];
        }

        // Clear audio buffer
        [self.audioData setLength:0];

        // Sends updates ~140ms apart back to listeners
        // This was chosen from some basic testing/tuning. At 20ms samples, we didn't wanna be
        // sending events over the react native bridge so often, as it's too frequent/not useful.
        // If we made it much longer (>=200ms) the delay of the speaking would be quite pronounced to the user.
        // So 140ms was the nice medium
        const double eventInterval = 0.140;
        if (cumulativeProcessedSampleLengthMs >= eventInterval) {

#ifdef DEBUG
        NSLog(@"Audio sample filled + analyzed %d", isVoice);
#endif
            cumulativeProcessedSampleLengthMs = 0;

            if (hasListeners) {
                [self sendEventWithName:@"RNWebrtcVad_SpeakingUpdate" body:@{ @"isVoice": @(isVoice) }];
            }
        }
    }
}

- (NSArray<NSString *> *) supportedEvents
{
    return @[@"RNWebrtcVad_SpeakingUpdate"];
}

// Will be called when this module's first listener is added.
- (void) startObserving
{
    hasListeners = YES;
}

// Will be called when this module's last listener is removed, or on dealloc.
- (void) stopObserving
{
    hasListeners = NO;
}

@end
