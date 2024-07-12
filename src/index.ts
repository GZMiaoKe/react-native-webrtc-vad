import type { NativeModule } from 'react-native';
import { NativeModules, NativeEventEmitter } from 'react-native';

const { RNWebrtcVad } = NativeModules;
const RNWebrtcVadEmitter = new NativeEventEmitter(RNWebrtcVad);

export type VADOptions = {
  mode?: 0 | 1 | 2 | 3;
};

export type VADDeviceSettings = {
  bufferSize: number;
  hwSampleRate: number;
};

declare module 'react-native' {
  interface NativeModulesStatic {
    RNWebrtcVad: {
      start(options: VADOptions): void;
      stop(): void;
      audioDeviceSettings(): Promise<VADDeviceSettings>;
    } & NativeModule;
  }
}

const EventTypeToNativeEventName = {
  speakingUpdate: 'RNWebrtcVad_SpeakingUpdate',
};

const VADRecorder = {
  start: (options: VADOptions) => RNWebrtcVad.start(options),
  stop: () => RNWebrtcVad.stop(),
  audioDeviceSettings: () => RNWebrtcVad.audioDeviceSettings(),
  addUpdateListener: (cb: (e: { isVoice: number | boolean }) => void) => {
    return RNWebrtcVadEmitter.addListener(
      EventTypeToNativeEventName.speakingUpdate,
      cb,
    );
  },
};

export default VADRecorder;
