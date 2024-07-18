import type { NativeModule } from 'react-native';
import { NativeModules, NativeEventEmitter } from 'react-native';

const { RNWebrtcVad } = NativeModules;
const RNWebrtcVadEmitter = new NativeEventEmitter(RNWebrtcVad);

export type VADOptions = {
  mode?: 0 | 1 | 2 | 3;
  preferredBufferSize?: number;
};

export type VADDeviceSettings = {
  bufferSize: number;
  hwSampleRate: number;
};

declare module 'react-native' {
  interface NativeModulesStatic {
    RNWebrtcVad: {
      start(options: VADOptions): Promise<void>;
      stop(discard: boolean): Promise<string | null>;
      audioDeviceSettings(): Promise<VADDeviceSettings>;
    } & NativeModule;
  }
}

const EventTypeToNativeEventName = {
  speakingUpdate: 'RNWebrtcVad_SpeakingUpdate',
};

const VADRecorder = {
  start: (options: VADOptions) => RNWebrtcVad.start(options),
  stop: (discard = false) => RNWebrtcVad.stop(discard),
  audioDeviceSettings: () => RNWebrtcVad.audioDeviceSettings(),
  addUpdateListener: (cb: (e: { isVoice: boolean }) => void) => {
    return RNWebrtcVadEmitter.addListener(
      EventTypeToNativeEventName.speakingUpdate,
      cb,
    );
  },
};

export default VADRecorder;
