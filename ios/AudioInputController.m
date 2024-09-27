#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

#import "AudioInputController.h"

@implementation AudioInputController {
    AudioComponentInstance remoteIOUnit;
    BOOL isInitialized;
    NSString* origAudioCategory;
    NSString* origAudioMode;
}

- (instancetype) init {
    _audioDataQueue = dispatch_queue_create(@"com.guilded.gg.vad".UTF8String, NULL);
    return self;
}

+ (instancetype) sharedInstance {
    static AudioInputController *instance = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });

    return instance;
}

- (OSStatus) start {
    return AudioOutputUnitStart(remoteIOUnit);
}

- (OSStatus) stop {
    OSStatus res = AudioOutputUnitStop(remoteIOUnit);
    AudioComponentInstanceDispose(remoteIOUnit);
    remoteIOUnit = nil;
    isInitialized = NO;

    [self restoreOriginalAudioSetup];
    [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    return res;
}

- (OSStatus) prepareWithSampleRate:(double)desiredSampleRate preferredBufferSize:(int)preferredBufferSize {
    NSLog(@"[WebRTCVad] sampleRate = %f", desiredSampleRate);

    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    double sampleRate = audioSession.sampleRate;

    // The math in this library supports 48khz, 32khz, 16khz, and 8khz. In most
    // cases, we should expect that the hardware sampling rate is 48khz. In
    // case it's not, we set audioSampleRate to a fake rate for reference
    // later. We may not be sampling at the fake rate, but when we run the math
    // we need to fudge and pass in a compatible rate. Tested with a bluetooth
    // mic at 44.1khz.
    if (
        desiredSampleRate &&
        sampleRate != 48000 &&
        sampleRate != 32000 &&
        sampleRate != 16000 &&
        sampleRate != 8000
    ) {
        self.audioSampleRate = desiredSampleRate;
    } else {
        self.audioSampleRate = sampleRate;
    }

    NSLog(@"[WebRTCVad] hardware sample rate = %f", sampleRate);

    if (self.audioSampleRate != sampleRate) {
        NSLog(@"[WebRTCVad] hardware sample rate not compatible, so pretending rate is %f for calculations", desiredSampleRate);
    }

    @try {
        [self storeOriginalAudioSetup];

        NSError *categoryErr;
        BOOL ok = [audioSession setCategory:AVAudioSessionCategoryRecord error:&categoryErr];

        NSLog(@"[WebRTCVad] set category %d, error %@", ok, categoryErr);

        NSError *modeErr;
        ok = [audioSession setMode:AVAudioSessionModeVoiceChat error:&modeErr];

        NSLog(@"[WebRTCVad] set mode %d, error %@", ok, modeErr);

        // After a lot of trial and error, it was discovered that a 48khz
        // device would be fine with buffer durations that yield ~2049-4094
        // samples. The iPhone 14/15 Pro does not respect that rule though, and
        // wants no less and no more than 2049 samples. It must also be known
        // that the requested buffer duration is just the _preferred_ duration,
        // but the OS does not give it exactly as the user requests. For
        // example, requesting 0.032 seconds for a 48khz device actually gives
        // 0.0427, and that is true up until you request 0.064 seconds.
        //
        // 48khz
        // requested => actual, worked* or not
        // 0.031 => 0.0213 did not work
        // 0.032 => 0.0427 worked
        // 0.063 => 0.0427 worked
        // 0.064 => 0.0853 worked, except for iPhone 14/15 Pro
        //
        // 44.1khz
        // 0.023 => 0.016 did not work
        // 0.024 => 0.032 worked
        // 0.095 => 0.064 worked
        // 0.096 => 0.128 did not work
        //
        // * "worked" means the app transmitted voice when it should and
        // received voice without distortion. Values outside of the good range
        // did exhibit one of these two issues.
        //
        // It seems the sensible overlap is around the ~2048 sample range.
        // Since the OS is not giving us exactly 2048, we'll add a few more on
        // as a buffer, so 2148, which should give us a number that rounds to
        // the OS's buffer durations. The mappings above may change over time.
        float bufferDuration = (preferredBufferSize > 0 ? preferredBufferSize : 2148) / sampleRate;

        NSLog(@"[WebRTCVad] requesting a buffer duration of %f", bufferDuration);

        [audioSession setPreferredIOBufferDuration:bufferDuration error:nil];

    } @catch (NSException *e) {
        NSLog(@"[WebRTCVad]: session setup failed: %@", e.reason);
    }


    return [self _initializeAudioGraph];
}

- (OSStatus) _initializeAudioGraph {
    OSStatus status = noErr;

    if (!isInitialized) {
        isInitialized = YES;
        // Describe the RemoteIO unit
        AudioComponentDescription audioComponentDescription;
        audioComponentDescription.componentType = kAudioUnitType_Output;
        audioComponentDescription.componentSubType = kAudioUnitSubType_RemoteIO;
        audioComponentDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
        audioComponentDescription.componentFlags = 0;
        audioComponentDescription.componentFlagsMask = 0;

        // Get the RemoteIO unit
        AudioComponent remoteIOComponent = AudioComponentFindNext(NULL,&audioComponentDescription);
        status = AudioComponentInstanceNew(remoteIOComponent, &(remoteIOUnit));
        if (_checkError(status, "Couldn't get RemoteIO unit instance")) {
            return status;
        }
    }

    double sampleRate = self.audioSampleRate;

    UInt32 enabledFlag = 1;
    AudioUnitElement bus0 = 0;
    AudioUnitElement bus1 = 1;

    // Configure the RemoteIO unit for input
    status = AudioUnitSetProperty(remoteIOUnit,
                                  kAudioOutputUnitProperty_EnableIO,
                                  kAudioUnitScope_Input,
                                  bus1,
                                  &enabledFlag,
                                  sizeof(enabledFlag));
    if (_checkError(status, "Couldn't enable RemoteIO input")) {
        return status;
    }

    AudioStreamBasicDescription asbd;
    memset(&asbd, 0, sizeof(asbd));
    asbd.mSampleRate = sampleRate;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    asbd.mBytesPerPacket = 2;
    asbd.mFramesPerPacket = 1;
    asbd.mBytesPerFrame = 2;
    asbd.mChannelsPerFrame = 1;
    asbd.mBitsPerChannel = 16;

    // Set format for output (bus 0) on the RemoteIO's input scope
    status = AudioUnitSetProperty(remoteIOUnit,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input,
                                  bus0,
                                  &asbd,
                                  sizeof(asbd));
    if (_checkError(status, "Couldn't set the ASBD for RemoteIO on input scope/bus 0")) {
        return status;
    }

    // Set format for mic input (bus 1) on RemoteIO's output scope
    status = AudioUnitSetProperty(remoteIOUnit,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Output,
                                  bus1,
                                  &asbd,
                                  sizeof(asbd));
    if (_checkError(status, "Couldn't set the ASBD for RemoteIO on output scope/bus 1")) {
        return status;
    }

    // Set the recording callback
    AURenderCallbackStruct callbackStruct;
    callbackStruct.inputProc = _recordingCallback;
    callbackStruct.inputProcRefCon = (__bridge void *) self;
    status = AudioUnitSetProperty(remoteIOUnit,
                                  kAudioOutputUnitProperty_SetInputCallback,
                                  kAudioUnitScope_Global,
                                  bus1,
                                  &callbackStruct,
                                  sizeof (callbackStruct));
    if (_checkError(status, "Couldn't set RemoteIO's render callback on bus 0")) {
        return status;
    }

    // Initialize the RemoteIO unit
    status = AudioUnitInitialize(remoteIOUnit);
    if (_checkError(status, "Couldn't initialize the RemoteIO unit")) {
        return status;
    }

    return status;
}

- (void)storeOriginalAudioSetup
{
    origAudioCategory = [AVAudioSession sharedInstance].category;
    origAudioMode =  [AVAudioSession sharedInstance].mode;
    NSLog(@"[WebRTCVad].storeOriginalAudioSetup(): origAudioCategory=%@, origAudioMode=%@", origAudioCategory, origAudioMode);
}

- (void)restoreOriginalAudioSetup
{
    @try {
        const AVAudioSession* audioSession = [AVAudioSession sharedInstance];
        BOOL ok = [audioSession setCategory:origAudioCategory error:nil];

        NSLog(@"[WebRTCVad] restore category %d", ok);

       ok = [audioSession setMode:origAudioMode error:nil];

        NSLog(@"[WebRTCVad] restore mode %d", ok);
    } @catch (NSException *e) {
        NSLog(@"[WebRTCVad]: session setup failed: %@", e.reason);
    }
}

static OSStatus _recordingCallback(void *inRefCon,
                                   AudioUnitRenderActionFlags *ioActionFlags,
                                   const AudioTimeStamp *inTimeStamp,
                                   UInt32 inBusNumber,
                                   UInt32 inNumberFrames,
                                   AudioBufferList *ioData) {
    OSStatus status;

    AudioInputController *audioInputController = (__bridge AudioInputController *) inRefCon;

    int channelCount = 1;

    // build the AudioBufferList structure
    AudioBufferList *bufferList = (AudioBufferList *) malloc (sizeof (AudioBufferList));
    bufferList->mNumberBuffers = channelCount;
    bufferList->mBuffers[0].mNumberChannels = 1;
    bufferList->mBuffers[0].mDataByteSize = inNumberFrames * 2;
    bufferList->mBuffers[0].mData = NULL;

    // get the recorded samples
    status = AudioUnitRender(audioInputController->remoteIOUnit,
                             ioActionFlags,
                             inTimeStamp,
                             inBusNumber,
                             inNumberFrames,
                             bufferList);
    if (status != noErr) {
        return status;
    }

    NSData *data = [[NSData alloc] initWithBytes:bufferList->mBuffers[0].mData
                                          length:bufferList->mBuffers[0].mDataByteSize];

    dispatch_async(audioInputController->_audioDataQueue, ^{
        [audioInputController.delegate processSampleData:data];
    });

    return noErr;
}

static OSStatus _checkError(OSStatus error, const char *operation)
{
    // TODO: Use resolver to throw errors
    if (error == noErr) {
        return error;
    }

    NSLog(@"[WebRTCVad] Error: (%s)\n", operation);
    return error;
}

@end

